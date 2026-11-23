/*
 * WWIVFOSS - FOSSIL driver for DOS doors
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * uart transport: a 16550 UART, usually emulated (QEMU, DOSBox-X, 86Box,
 * dosemu2) with the COM port connected to a TCP socket the BBS listens on.
 *
 * Both directions are interrupt driven through ring buffers. Doors often
 * assume a block write (19h) takes everything, so the transmit ring has to
 * be large enough to absorb a screenful; emulators that model serial timing
 * (DOSBox-X) only accept one byte per character time.
 *
 * Built with -s -zu: callable from interrupt context. See wwivfoss.h.
 */
#include <conio.h>
#include <dos.h>
#include <i86.h>

#include "foss_protocol.h"
#include "wwivfoss.h"

#define RXBUF_SIZE 2048            /* must be a power of two */
#define RXBUF_MASK (RXBUF_SIZE - 1)
#define TXBUF_SIZE 2048            /* must be a power of two */
#define TXBUF_MASK (TXBUF_SIZE - 1)

/* 16550 registers (offsets from the base port). */
#define RBR 0
#define THR 0
#define DLL 0
#define IER 1
#define DLM 1
#define IIR 2
#define FCR 2
#define LCR 3
#define MCR 4
#define LSR 5
#define MSR 6

#define IER_RDA   0x01
#define IER_THRE  0x02
#define IER_MSR   0x08
#define IIR_NONE  0x01
#define IIR_ID    0x06
#define IIR_MSR   0x00
#define IIR_THRE  0x02
#define IIR_RDA   0x04             /* also covers the FIFO timeout (0x0C) */
#define IIR_LSR   0x06
#define IIR_FIFO  0xC0
#define LSR_DR    0x01
#define LSR_OE    0x02
#define LSR_THRE  0x20
#define LSR_TEMT  0x40
#define MSR_DCD   0x80
#define MCR_DTR   0x01
#define MCR_RTS   0x02
#define MCR_OUT2  0x08
#define MCR_LOOP  0x10
#define FCR_ENABLE_CLEAR 0xC7      /* enable, clear rx+tx, 14 byte trigger */
#define FCR_CLEAR_TX     0xC5
#define FIFO_DEPTH 16

#define PIC1_CMD  0x20
#define PIC1_MASK 0x21
#define PIC_EOI   0x20

typedef void (__interrupt __far *intvec_t)(void);

static const unsigned com_base[4] = {0x3F8, 0x2F8, 0x3E8, 0x2E8};
static const unsigned char com_irq[4] = {4, 3, 4, 3};

static unsigned base;
static unsigned char irq_bit;
static unsigned char irq_vector;
static unsigned char irq_was_masked;
static unsigned char tx_burst;     /* bytes per THRE: 16 with a FIFO */
static intvec_t old_irq;

static unsigned char rxbuf[RXBUF_SIZE];
static volatile unsigned rx_head;  /* written by the ISR */
static volatile unsigned rx_tail;  /* written by the foreground */
static volatile unsigned char rx_lost;

static unsigned char txbuf[TXBUF_SIZE];
static volatile unsigned tx_head;  /* written by the foreground */
static volatile unsigned tx_tail;  /* written by the ISR */
static volatile unsigned char tx_busy;  /* a THRE interrupt is expected */

/* -E in-band line control (see foss_protocol.h). */
static volatile unsigned char remote_lines;  /* last line state from BBS */
static unsigned char rx_escape;              /* saw FF, waiting for next */

/*
 * Modem status, cached so FOSSIL status (03h), which doors call in tight
 * loops, needs no port I/O. Under software emulation (QEMU TCG) every port
 * access is a VM exit that contends with the thread feeding socket data
 * into the UART, so polling the MSR starved our own receive path. The ISR
 * updates the cache on modem status interrupts, and it's re-read at most
 * once per timer tick as a fallback.
 */
static volatile unsigned char msr_cache;
static unsigned long msr_tick;
static volatile unsigned long __far* const bios_ticks =
    (volatile unsigned long __far*)0x0040006CL;

static int uart_carrier(void);

/*
 * -E: make a hangup visible to doors that read the UART's modem status
 * register directly instead of asking the FOSSIL (Food Fight, among others).
 * Emulators like QEMU hold DCD high forever, so the in-band hangup would
 * otherwise only reach doors that use FOSSIL status (03h). In loopback mode
 * a 16550 mirrors its outputs onto its modem status inputs, with DCD
 * following OUT2; loopback with OUT2 low therefore reads as carrier lost.
 * Undone when the BBS raises DTR again and whenever the port is closed.
 * Called with interrupts off (from the ISR).
 */
static void apply_remote_lines(void) {
  unsigned char mcr = (unsigned char)inp(base + MCR);
  if (remote_lines & WWIVFOSS_LINE_DTR) {
    if (mcr & MCR_LOOP) {
      outp(base + MCR, (mcr & ~MCR_LOOP) | MCR_OUT2);
    }
  } else if (!(mcr & MCR_LOOP)) {
    outp(base + MCR, (mcr | MCR_LOOP) & ~MCR_OUT2);
  }
  msr_cache = (unsigned char)inp(base + MSR);
}

/* Move bytes from the TX ring into the UART. Interrupts must be off. */
static void tx_fill(void) {
  unsigned n;
  for (n = 0; n < tx_burst && tx_tail != tx_head; n++) {
    outp(base + THR, txbuf[tx_tail]);
    tx_tail = (tx_tail + 1) & TXBUF_MASK;
  }
  tx_busy = (unsigned char)(n != 0);
}

static void rx_drain(void) {
  unsigned next;
  unsigned char c;
  unsigned char lsr;
  while ((lsr = (unsigned char)inp(base + LSR)) & LSR_DR) {
    if (lsr & LSR_OE) {
      rx_lost = 1;
    }
    c = (unsigned char)inp(base + RBR);
    if (g_opts.inband) {
      if (rx_escape) {
        rx_escape = 0;
        if (c != WWIVFOSS_INBAND_ESCAPE) {
          remote_lines = c;          /* FF nn: line state, not data */
          apply_remote_lines();
          continue;
        }
      } else if (c == WWIVFOSS_INBAND_ESCAPE) {
        rx_escape = 1;
        continue;
      }
    }
    next = (rx_head + 1) & RXBUF_MASK;
    if (next == rx_tail) {
      rx_lost = 1;
    } else {
      rxbuf[rx_head] = c;
      rx_head = next;
    }
  }
}

static void __interrupt __far uart_isr(void) {
  unsigned char iir;
  unsigned guard;

  for (guard = 0; guard < 32; guard++) {
    iir = (unsigned char)inp(base + IIR);
    if (iir & IIR_NONE) {
      break;
    }
    switch (iir & IIR_ID) {
    case IIR_RDA:
      rx_drain();
      break;
    case IIR_THRE:
      tx_fill();
      break;
    case IIR_LSR:
      if (inp(base + LSR) & LSR_OE) {
        rx_lost = 1;
      }
      break;
    case IIR_MSR:
      msr_cache = (unsigned char)inp(base + MSR);
      break;
    }
  }
  /*
   * Self-heal a lost THRE interrupt. Some UART emulations (seen with
   * DOSBox-X when a byte arrives while we transmit) clear a pending THRE
   * when IIR reports a higher-priority receive interrupt; without this the
   * transmitter stalls with bytes queued.
   */
  if (tx_busy && (inp(base + LSR) & LSR_THRE)) {
    tx_fill();  /* sends more, or clears tx_busy if the ring is empty */
  }
  outp(PIC1_CMD, PIC_EOI);
}

static int uart_open(void) {
  int idx = g_opts.port - 1;
  unsigned char mask;

  if (idx < 0 || idx > 3) {
    return 0;
  }
  base = com_base[idx];
  irq_bit = (unsigned char)(1 << com_irq[idx]);
  irq_vector = (unsigned char)(8 + com_irq[idx]);

  /* Floating bus reads back FFh: no UART at this address. */
  if (inp(base + LSR) == 0xFF) {
    return 0;
  }

  _disable();
  outp(base + IER, 0);
  /* 115200 8N1. Emulators ignore the divisor; real hardware won't. */
  outp(base + LCR, 0x80);
  outp(base + DLL, 1);
  outp(base + DLM, 0);
  outp(base + LCR, 0x03);
  outp(base + FCR, FCR_ENABLE_CLEAR);
  tx_burst = ((inp(base + IIR) & IIR_FIFO) == IIR_FIFO) ? FIFO_DEPTH : 1;

  old_irq = _dos_getvect(irq_vector);
  _dos_setvect(irq_vector, uart_isr);
  mask = (unsigned char)inp(PIC1_MASK);
  irq_was_masked = (unsigned char)(mask & irq_bit);
  outp(PIC1_MASK, mask & ~irq_bit);

  rx_head = rx_tail = 0;
  rx_lost = 0;
  tx_head = tx_tail = 0;
  tx_busy = 0;
  remote_lines = WWIVFOSS_LINE_RTS | WWIVFOSS_LINE_DTR;
  rx_escape = 0;
  rx_drain();
  rx_head = rx_tail = 0;
  outp(base + MCR, MCR_DTR | MCR_RTS | MCR_OUT2);
  msr_cache = (unsigned char)inp(base + MSR);
  msr_tick = *bios_ticks;
  outp(base + IER, IER_RDA | IER_THRE | IER_MSR);
  _enable();
  return 1;
}

static void uart_close(void) {
  volatile unsigned long __far* ticks =
      (volatile unsigned long __far*)MK_FP(0x40, 0x6C);
  unsigned long start = *ticks;

  /* Let queued output drain: up to ~2s (36 ticks) while carrier is up. */
  while ((tx_head != tx_tail || tx_busy) && *ticks - start < 36) {
    if (!uart_carrier() && !g_opts.force_carrier) {
      break;
    }
  }
  /*
   * Emulators buffer serial output before writing it to the socket, and
   * some (DOSBox-X 2025.02) drop that buffer if they exit right after the
   * door. Give them two timer ticks (~110ms) to flush.
   */
  start = *ticks;
  while (*ticks - start < 2) {
  }

  _disable();
  outp(base + IER, 0);
  /*
   * Leave DTR raised: the BBS keeps the caller after the door exits, so
   * closing must not hang up. Only OUT2 (the IRQ gate) is dropped.
   */
  outp(base + MCR, MCR_DTR | MCR_RTS);
  if (irq_was_masked) {
    outp(PIC1_MASK, inp(PIC1_MASK) | irq_bit);
  }
  _dos_setvect(irq_vector, old_irq);
  _enable();
}

static unsigned uart_rx_avail(void) {
  return (rx_head - rx_tail) & RXBUF_MASK;
}

static int uart_rx_peek(void) {
  if (rx_head == rx_tail) {
    return -1;
  }
  return rxbuf[rx_tail];
}

static int uart_rx_get(void) {
  int c;
  if (rx_head == rx_tail) {
    return -1;
  }
  c = rxbuf[rx_tail];
  rx_tail = (rx_tail + 1) & RXBUF_MASK;
  return c;
}

static unsigned uart_tx_free(void) {
  return (TXBUF_SIZE - 1) - ((tx_head - tx_tail) & TXBUF_MASK);
}

/* Append to the TX ring. Interrupts must be off and room checked. */
static void tx_push(unsigned char c) {
  txbuf[tx_head] = c;
  tx_head = (tx_head + 1) & TXBUF_MASK;
}

/* Start the transmitter if it's idle; THRE interrupts do the rest. */
static void tx_kick(void) {
  /* Don't trust tx_busy alone: if a THRE interrupt was lost, the UART sits
     idle while tx_busy stays set and the ring never drains. */
  if (inp(base + LSR) & LSR_THRE) {
    tx_fill();
  }
}

static int uart_tx_put(unsigned char c) {
  /* With -E a literal FF goes out doubled, so it needs two slots. */
  unsigned need = (g_opts.inband && c == WWIVFOSS_INBAND_ESCAPE) ? 2 : 1;
  if (uart_tx_free() < need) {
    /* Full: make sure the transmitter is running (a lost THRE interrupt
       would otherwise leave a door spinning here forever). */
    _disable();
    tx_kick();
    _enable();
    if (uart_tx_free() < need) {
      return 0;
    }
  }
  _disable();
  tx_push(c);
  if (need == 2) {
    tx_push(c);
  }
  tx_kick();
  _enable();
  return 1;
}

static int uart_tx_empty(void) {
  if (tx_head != tx_tail) {
    return 0;
  }
  if (!tx_busy) {
    return 1;  /* the common case needs no port I/O */
  }
  /*
   * The ring is empty but no THRE interrupt has confirmed the last byte
   * left. If that interrupt was lost, tx_busy would stay set forever and a
   * door flushing output (08h) would wait forever, so ask the UART.
   */
  if (inp(base + LSR) & LSR_TEMT) {
    tx_busy = 0;
    return 1;
  }
  return 0;
}

static int uart_carrier(void) {
  if (*bios_ticks != msr_tick) {
    msr_tick = *bios_ticks;
    msr_cache = (unsigned char)inp(base + MSR);
  }
  if (!(msr_cache & MSR_DCD)) {
    return 0;
  }
  /* With -E the BBS reports a hangup as DTR low in the byte stream. */
  return !g_opts.inband || (remote_lines & WWIVFOSS_LINE_DTR);
}

static int uart_overrun(void) {
  /* Overruns are recorded by the ISR (LSR OE) and the ring (full). */
  int lost = rx_lost;
  rx_lost = 0;
  return lost;
}

static void uart_set_dtr(int on) {
  unsigned char mcr = (unsigned char)inp(base + MCR);
  outp(base + MCR, on ? (mcr | MCR_DTR) : (mcr & ~MCR_DTR));
  if (g_opts.inband) {
    /* Tell the BBS: FF 01 (door hung up) or FF 03 (DTR raised). */
    _disable();
    if (uart_tx_free() >= 2) {
      tx_push(WWIVFOSS_INBAND_ESCAPE);
      tx_push((unsigned char)(WWIVFOSS_LINE_RTS | (on ? WWIVFOSS_LINE_DTR : 0)));
      tx_kick();
    }
    _enable();
  }
}

static void uart_purge_rx(void) {
  _disable();
  rx_tail = rx_head;
  rx_lost = 0;
  _enable();
}

static void uart_purge_tx(void) {
  _disable();
  tx_head = tx_tail;
  outp(base + FCR, FCR_CLEAR_TX);
  tx_busy = 0;
  _enable();
}

static unsigned char uart_irq_vector(void) {
  return irq_vector;
}

const struct transport uart_transport = {
  "uart",
  uart_open,
  uart_close,
  uart_rx_avail,
  uart_rx_peek,
  uart_rx_get,
  uart_tx_put,
  uart_tx_free,
  uart_tx_empty,
  uart_carrier,
  uart_overrun,
  uart_set_dtr,
  uart_purge_rx,
  uart_purge_tx,
  uart_irq_vector,
};
