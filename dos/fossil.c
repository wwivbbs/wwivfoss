/*
 * WWIVFOSS - FOSSIL driver for DOS doors
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * FOSSIL revision 5 INT 14h dispatcher.
 *
 * This module runs in interrupt context on the door's stack. It is built
 * with -s -zu: no stack checks and no assumption that SS == DGROUP. Keep
 * all working storage static and never pass the address of a local.
 */
#include <dos.h>
#include <i86.h>
#include <stdlib.h>

#include "foss_protocol.h"
#include "fossil.h"
#include "wwivfoss.h"

/* Release the CPU after this many back to back empty polls. */
#define IDLE_AFTER_POLLS 16

/* Reported in 1Bh; the uart transport has 2 KB rings each way. */
#define REPORTED_IBUF 2048
#define REPORTED_OBUF 2048

typedef void (__interrupt __far *intvec_t)(void);

extern void __far int14_entry(void);
#pragma aux int14_entry "*";

void __interrupt __far int14_handler(union INTPACK r);
#pragma aux int14_handler "*";

static intvec_t old_int14;
static int installed;
static volatile int in_handler;
static unsigned empty_polls;
static char ident[] = "WWIVFOSS " WWIVFOSS_VERSION " (https://github.com/wwivbbs)";
static struct fossil_info info;

const char* fossil_ident(void) { return ident; }

unsigned fossil_entry_segment(void) {
  return FP_SEG((void __far*)int14_entry);
}

/* ---------------------------------------------------------------------- */
/* Low level helpers (inline asm so no runtime calls happen in ISR context) */

static unsigned char release_timeslice(void);
/* INT 2Fh AX=1680h: AL=0 if a multitasker took the timeslice. */
#pragma aux release_timeslice = \
    "mov ax, 1680h"             \
    "int 2Fh"                   \
    value [al] modify [ax];

static void cpu_halt(void);
/* Wait for the next interrupt; emulators idle the host CPU here. */
#pragma aux cpu_halt = \
    "sti"              \
    "hlt";

static unsigned kbd_peek(void) {
  unsigned result = 0;
  _asm {
    mov ah, 1
    int 16h
    jnz have_key
    mov ax, 0FFFFh
  have_key:
    mov result, ax
  }
  return result;
}

static unsigned kbd_read(void) {
  unsigned result = 0;
  _asm {
    xor ah, ah
    int 16h
    mov result, ax
  }
  return result;
}

static void bios_set_cursor(unsigned pos) {
  _asm {
    mov dx, pos
    mov ah, 2
    xor bh, bh
    int 10h
  }
}

static unsigned bios_get_cursor(void) {
  unsigned result = 0;
  _asm {
    mov ah, 3
    xor bh, bh
    int 10h
    mov result, dx
  }
  return result;
}

static void bios_write_char(unsigned char c) {
  _asm {
    mov al, c
    mov ah, 0Eh
    xor bx, bx
    int 10h
  }
}

static void dos_write_char(unsigned char c) {
  /* Goes through DOS so ANSI.SYS (if loaded) interprets it. */
  _asm {
    mov dl, c
    mov ah, 2
    int 21h
  }
}

/* ---------------------------------------------------------------------- */

static int carrier(void) {
  return g_opts.force_carrier || g_transport->carrier();
}

static unsigned status(void) {
  unsigned s = FST_ALWAYS;
  if (carrier()) {
    s |= FST_DCD;
  }
  if (g_transport->rx_avail()) {
    s |= FST_RDA;
  }
  if (g_transport->overrun()) {
    s |= FST_OVRN;
  }
  if (g_transport->tx_free()) {
    s |= FST_THRE;
  }
  if (g_transport->tx_empty()) {
    s |= FST_TSRE;
  }
  return s;
}

/* Give up the CPU now (used while blocking). */
static void idle_now(void) {
  if (!g_opts.idle) {
    return;
  }
  empty_polls = 0;
  if (release_timeslice() != 0) {
    /* No multitasker answered; halt until the next interrupt. */
    cpu_halt();
  }
}

/* Called on every poll that found nothing to do. */
static void idle_poll(void) {
  if (++empty_polls >= IDLE_AFTER_POLLS) {
    idle_now();
  }
}

static int port_is_ours(unsigned dx, unsigned char fn) {
  if (dx == (unsigned)(g_opts.port - 1)) {
    return 1;
  }
  /* DX=00FFh with init means "no port, just tell me you're there". */
  return dx == 0x00FF && (fn == F_INIT || fn == F_INIT_EXT);
}

static void fill_info(void) {
  info.size = sizeof(info);
  info.majver = FOSSIL_REVISION;
  info.minver = 1;
  info.ident_off = FP_OFF((char __far*)ident);
  info.ident_seg = FP_SEG((char __far*)ident);
  info.ibufr = REPORTED_IBUF;
  info.ifree = REPORTED_IBUF - g_transport->rx_avail();
  info.obufr = REPORTED_OBUF;
  info.ofree = g_transport->tx_free();
  info.swidth = 80;
  info.sheight = 25;
  info.baud = 0x23;  /* 38400 8N1 */
}

void __interrupt __far int14_handler(union INTPACK r) {
  static unsigned char fn;
  static unsigned count;
  static int ch;
  static unsigned char __far* buf;
  static unsigned char* src;

  fn = r.h.ah;

  /* Private API for WWIVFOSS -U; see foss_protocol.h. */
  if (fn == WWIVFOSS_API_FUNC && r.w.bx == WWIVFOSS_API_MAGIC) {
    if (r.h.al == WWIVFOSS_API_QUERY) {
      r.w.ax = WWIVFOSS_API_MAGIC;
      r.w.bx = _psp;
      r.w.cx = fossil_entry_segment();
      r.w.dx = g_transport->irq_vector();
    } else if (r.h.al == WWIVFOSS_API_SHUTDOWN && !in_handler) {
      _enable();
      g_transport->close();
      fossil_remove();
      r.w.ax = WWIVFOSS_API_MAGIC;
    }
    return;
  }

  if (in_handler || !port_is_ours(r.w.dx, fn)) {
    _chain_intr(old_int14);
  }
  in_handler = 1;
  /* Let the UART IRQ run while we wait inside blocking functions. */
  _enable();

  switch (fn) {
  case F_SET_BAUD:
    /* The BBS owns the connection speed; nothing to do. */
    r.w.ax = status();
    break;

  case F_TX_WAIT:
    while (!g_transport->tx_put(r.h.al)) {
      if (!carrier()) {
        break;
      }
      idle_now();
    }
    r.w.ax = status();
    break;

  case F_RX_WAIT:
    while ((ch = g_transport->rx_get()) < 0) {
      if (!carrier()) {
        break;
      }
      idle_now();
    }
    /* On carrier loss return AH bit 7 set (timeout), like the BIOS. */
    r.w.ax = (ch < 0) ? 0x8000 : (unsigned)ch;
    break;

  case F_STATUS:
    r.w.ax = status();
    if (!(r.w.ax & FST_RDA)) {
      idle_poll();
    } else {
      empty_polls = 0;
    }
    break;

  case F_INIT:
  case F_INIT_EXT:
    r.w.ax = FOSSIL_SIGNATURE;
    r.w.bx = (FOSSIL_REVISION << 8) | FOSSIL_HIGHEST_FUNC;
    break;

  case F_DEINIT:
  case F_DEINIT_EXT:
    break;

  case F_DTR:
    g_transport->set_dtr(r.h.al & 1);
    break;

  case F_TIMER_INFO:
    r.h.al = 0x1C;   /* timer tick interrupt */
    r.h.ah = 18;     /* ticks per second */
    r.w.dx = 55;     /* milliseconds per tick */
    break;

  case F_FLUSH_OUT:
    while (!g_transport->tx_empty() && carrier()) {
      idle_now();
    }
    break;

  case F_PURGE_OUT:
    g_transport->purge_tx();
    break;

  case F_PURGE_IN:
    g_transport->purge_rx();
    break;

  case F_TX_NOWAIT:
    r.w.ax = g_transport->tx_put(r.h.al) ? 1 : 0;
    break;

  case F_PEEK:
    ch = g_transport->rx_peek();
    if (ch < 0) {
      r.w.ax = 0xFFFF;
      idle_poll();
    } else {
      r.w.ax = (unsigned)ch;
      empty_polls = 0;
    }
    break;

  case F_KBD_PEEK:
    r.w.ax = kbd_peek();
    break;

  case F_KBD_READ:
    r.w.ax = kbd_read();
    break;

  case F_FLOW_CONTROL:
    /* Flow control is the BBS's job; accept and ignore. */
    break;

  case F_CTRL_C:
    r.w.ax = 0;
    break;

  case F_SET_CURSOR:
    bios_set_cursor(r.w.dx);
    break;

  case F_GET_CURSOR:
    r.w.dx = bios_get_cursor();
    break;

  case F_WRITE_ANSI:
    dos_write_char(r.h.al);
    break;

  case F_WRITE_BIOS:
    bios_write_char(r.h.al);
    break;

  case F_BLOCK_READ:
    buf = (unsigned char __far*)MK_FP(r.w.es, r.w.di);
    for (count = 0; count < r.w.cx; count++) {
      if ((ch = g_transport->rx_get()) < 0) {
        break;
      }
      buf[count] = (unsigned char)ch;
    }
    r.w.ax = count;
    if (count == 0) {
      idle_poll();
    } else {
      empty_polls = 0;
    }
    break;

  case F_BLOCK_WRITE:
    buf = (unsigned char __far*)MK_FP(r.w.es, r.w.di);
    for (count = 0; count < r.w.cx; count++) {
      if (!g_transport->tx_put(buf[count])) {
        break;
      }
    }
    r.w.ax = count;
    break;

  case F_DRIVER_INFO:
    fill_info();
    buf = (unsigned char __far*)MK_FP(r.w.es, r.w.di);
    src = (unsigned char*)&info;
    count = r.w.cx < sizeof(info) ? r.w.cx : sizeof(info);
    for (ch = 0; ch < (int)count; ch++) {
      buf[ch] = src[ch];
    }
    r.w.ax = count;
    break;

  case F_WATCHDOG:
  case F_TIMER_CHAIN:
  case F_REBOOT:
  case F_BREAK:
  default:
    /* Not supported; leave registers unchanged. */
    break;
  }

  in_handler = 0;
}

void fossil_install(void) {
  old_int14 = _dos_getvect(0x14);
  _dos_setvect(0x14, (intvec_t)int14_entry);
  installed = 1;
}

void fossil_remove(void) {
  if (!installed) {
    return;
  }
  /*
   * If something hooked INT 14h after us and is still resident, restoring
   * the old vector unhooks it too. The door has exited, so that should only
   * happen with a misbehaving TSR; restore anyway so we never leave a vector
   * pointing into freed memory.
   */
  _dos_setvect(0x14, old_int14);
  installed = 0;
}
