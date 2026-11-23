/*
 * WWIVFOSS - FOSSIL driver for DOS doors
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * FOSTEST: a FOSSIL door used to test drivers.
 *
 *   FOSTEST [port] [/W]   port is 1-based (default 1); /W waits up to 30
 *                         seconds for carrier first, like a BBS waiting for
 *                         the next caller (exit 4 if none comes)
 *
 * Initialises the FOSSIL, prints driver information, sends a banner, then
 * echoes what it receives. Uppercase letters from the caller are commands:
 *
 *   Q  quit (exit 0)
 *   H  hang up by lowering DTR, FOSSIL 06h (exit 3)
 *   F  local functions: 00h 03h 06h 07h 0Bh 0Dh 0Fh 10h 11h 12h 13h 15h 1Bh
 *   P  peek: 0Ch is non-destructive and agrees with 02h
 *   X  purge: 0Ah drops pending input, 09h drops pending output
 *   B  binary: send bytes 00..FF with 19h, receive 00..FF with 18h
 *   K  keyboard: 0Dh peeks and 0Eh reads a key typed on the DOS console
 *   R  receive speed: read 32 KB with 18h, report the time
 *   T  transmit speed: write 32 KB with 19h, report the time
 *
 * Each test reports "<NAME> OK" or "<NAME> FAIL <detail>" to the caller and
 * to stdout. Exit codes: 0 quit, 1 no FOSSIL, 2 carrier lost, 3 hung up,
 * 4 no caller arrived (/W).
 */
#include <conio.h>
#include <dos.h>
#include <i86.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fossil.h"

#define TIMEOUT_TICKS (18 * 15)   /* ~15 seconds */

static union REGS r;
static struct SREGS sr;
static unsigned port;
static unsigned long received;
static char line[96];

static volatile unsigned long __far* const bios_ticks =
    (volatile unsigned long __far*)MK_FP(0x40, 0x6C);

/* Calls the FOSSIL with AH=fn, AL=al, DX=port; returns AX. */
static unsigned fossil(unsigned char fn, unsigned char al) {
  r.h.ah = fn;
  r.h.al = al;
  r.x.dx = port;
  int86(0x14, &r, &r);
  return r.x.ax;
}

/* Block write (19h), retrying partial writes as the spec allows. */
static int send_bytes(const unsigned char* buf, unsigned len) {
  unsigned done = 0;
  unsigned long start = *bios_ticks;
  while (done < len) {
    segread(&sr);
    r.h.ah = F_BLOCK_WRITE;
    r.x.cx = len - done;
    r.x.dx = port;
    sr.es = FP_SEG((const unsigned char __far*)(buf + done));
    r.x.di = FP_OFF((const unsigned char __far*)(buf + done));
    int86x(0x14, &r, &r, &sr);
    done += r.x.ax;
    if (r.x.ax == 0) {
      if (!(fossil(F_STATUS, 0) & FST_DCD) || *bios_ticks - start > TIMEOUT_TICKS) {
        return 0;
      }
    }
  }
  return 1;
}

static void send(const char* s) {
  send_bytes((const unsigned char*)s, (unsigned)strlen(s));
}

/* Report a test result to the caller and to stdout. */
static void report(const char* name, const char* detail) {
  if (detail) {
    sprintf(line, "\r\n%s FAIL %s\r\n", name, detail);
  } else {
    sprintf(line, "\r\n%s OK\r\n", name);
  }
  send(line);
  printf("FOSTEST:%s", line + 1);
}

static int carrier(void) {
  return (fossil(F_STATUS, 0) & FST_DCD) != 0;
}

/* Waits until 0Ch shows input; returns the peeked char or -1. */
static int wait_for_input(void) {
  unsigned long start = *bios_ticks;
  unsigned ax;
  while ((ax = fossil(F_PEEK, 0)) == 0xFFFF) {
    if (!carrier() || *bios_ticks - start > TIMEOUT_TICKS) {
      return -1;
    }
  }
  return ax & 0xFF;
}

static void get_info(struct fossil_info* info) {
  segread(&sr);
  r.h.ah = F_DRIVER_INFO;
  r.x.cx = sizeof(*info);
  r.x.dx = port;
  sr.es = FP_SEG((void __far*)info);
  r.x.di = FP_OFF((void __far*)info);
  int86x(0x14, &r, &r, &sr);
}

static void flush_keyboard(void) {
  while (kbhit()) {
    (void)getch();
  }
}

/* F: functions that don't need the caller's cooperation. */
static void test_functions(void) {
  static struct fossil_info info;
  unsigned ax;

  ax = fossil(F_SET_BAUD, 0x83);  /* 2400 8N1; ignored, returns status */
  if (!(ax & FST_ALWAYS)) { report("FUNCS", "00h status bit 3"); return; }

  ax = fossil(F_STATUS, 0);
  if (!(ax & FST_ALWAYS) || !(ax & FST_DCD)) { report("FUNCS", "03h status"); return; }

  fossil(F_DTR, 1);  /* raise DTR: must not hang up */
  if (!carrier()) { report("FUNCS", "06h raise DTR dropped carrier"); return; }

  fossil(F_TIMER_INFO, 0);
  if (r.h.al != 0x1C || r.h.ah != 18 || r.x.dx != 55) { report("FUNCS", "07h timer info"); return; }

  if (fossil(F_TX_NOWAIT, '.') != 1) { report("FUNCS", "0Bh transmit no wait"); return; }

  flush_keyboard();
  if (fossil(F_KBD_PEEK, 0) != 0xFFFF) { report("FUNCS", "0Dh with no key"); return; }

  fossil(F_FLOW_CONTROL, 0xF2);  /* CTS/RTS; accepted and ignored */

  if (fossil(F_CTRL_C, 0) != 0) { report("FUNCS", "10h ctrl-c check"); return; }

  r.h.ah = F_SET_CURSOR;
  r.x.dx = 0x1405;  /* row 20, column 5 */
  int86(0x14, &r, &r);
  fossil(F_GET_CURSOR, 0);
  if (r.x.dx != 0x1405) { report("FUNCS", "11h/12h cursor"); return; }

  fossil(F_WRITE_BIOS, 'X');
  fossil(F_GET_CURSOR, 0);
  if (r.x.dx != 0x1406) { report("FUNCS", "15h BIOS write didn't advance"); return; }

  fossil(F_WRITE_ANSI, 'Y');  /* through DOS stdout; just must not hang */

  get_info(&info);
  if (r.x.ax != sizeof(info) || info.size != sizeof(info) || info.majver != FOSSIL_REVISION) {
    report("FUNCS", "1Bh size/revision"); return;
  }
  if (info.ifree != info.ibufr) { report("FUNCS", "1Bh ifree with empty input"); return; }
  if (info.ofree > info.obufr) { report("FUNCS", "1Bh ofree"); return; }

  report("FUNCS", NULL);
}

/* P: 0Ch peeks without consuming; 02h then returns the same char. */
static void test_peek(void) {
  int first;
  unsigned ax;

  send("\r\nPEEK READY\r\n");
  first = wait_for_input();
  if (first < 0) { report("PEEK", "nothing arrived"); return; }
  if ((fossil(F_PEEK, 0) & 0xFF) != (unsigned)first) { report("PEEK", "second peek differs"); return; }
  ax = fossil(F_RX_WAIT, 0);
  if ((ax & 0xFF) != (unsigned)first) { report("PEEK", "02h differs from peek"); return; }
  if (fossil(F_PEEK, 0) != 0xFFFF) { report("PEEK", "0Ch not empty after read"); return; }
  report("PEEK", NULL);
}

/* X: 0Ah drops buffered input; 09h drops buffered output. */
static void test_purge(void) {
  static struct fossil_info info;
  static unsigned char fill[1500];
  unsigned long start = *bios_ticks;

  send("\r\nPURGE READY\r\n");
  /* The caller sends 8 bytes; wait until all of them are buffered. */
  do {
    get_info(&info);
    if (!carrier() || *bios_ticks - start > TIMEOUT_TICKS) {
      report("PURGE", "input never arrived"); return;
    }
  } while (info.ibufr - info.ifree < 8);

  fossil(F_PURGE_IN, 0);
  if (fossil(F_STATUS, 0) & FST_RDA) { report("PURGE", "0Ah left input available"); return; }
  if (fossil(F_PEEK, 0) != 0xFFFF) { report("PURGE", "0Ah left input to peek"); return; }
  get_info(&info);
  if (info.ifree != info.ibufr) { report("PURGE", "0Ah left ifree short"); return; }

  /* Queue more output than an emulator drains at once, then drop it. */
  memset(fill, '~', sizeof(fill));
  send_bytes(fill, sizeof(fill));
  fossil(F_PURGE_OUT, 0);
  get_info(&info);
  if (info.ofree != info.obufr - 1 && info.ofree != info.obufr) {
    report("PURGE", "09h left output queued"); return;
  }
  report("PURGE", NULL);
}

/* B: every byte value out with 19h and back in with 18h. */
static void test_binary(void) {
  static unsigned char buf[256];
  unsigned got = 0;
  unsigned i;
  unsigned long start;

  for (i = 0; i < 256; i++) {
    buf[i] = (unsigned char)i;
  }
  send("\r\nBIN START\r\n");
  if (!send_bytes(buf, 256)) { report("BIN", "send failed"); return; }
  send("\r\nBIN SENT\r\n");

  memset(buf, 0, sizeof(buf));
  start = *bios_ticks;
  while (got < 256) {
    segread(&sr);
    r.h.ah = F_BLOCK_READ;
    r.x.cx = 256 - got;
    r.x.dx = port;
    sr.es = FP_SEG((unsigned char __far*)(buf + got));
    r.x.di = FP_OFF((unsigned char __far*)(buf + got));
    int86x(0x14, &r, &r, &sr);
    got += r.x.ax;
    if (r.x.ax == 0 && (!carrier() || *bios_ticks - start > TIMEOUT_TICKS)) {
      sprintf(line, "received %u of 256", got);
      report("BIN", line);
      return;
    }
  }
  for (i = 0; i < 256; i++) {
    if (buf[i] != i) {
      sprintf(line, "byte %u was %02X", i, buf[i]);
      report("BIN", line);
      return;
    }
  }
  report("BIN", NULL);
}

/* K: a key typed on the DOS console shows up through 0Dh and 0Eh. */
static void test_keyboard(void) {
  unsigned long start = *bios_ticks;
  unsigned peeked, key;

  flush_keyboard();
  send("\r\nKEY READY\r\n");
  while ((peeked = fossil(F_KBD_PEEK, 0)) == 0xFFFF) {
    if (!carrier() || *bios_ticks - start > TIMEOUT_TICKS) {
      report("KEY", "no key arrived"); return;
    }
  }
  if (fossil(F_KBD_PEEK, 0) != peeked) { report("KEY", "second 0Dh differs"); return; }
  key = fossil(F_KBD_READ, 0);
  if (key != peeked) { report("KEY", "0Eh differs from 0Dh"); return; }
  if (fossil(F_KBD_PEEK, 0) != 0xFFFF) { report("KEY", "0Dh not empty after 0Eh"); return; }
  sprintf(line, "\r\nKEY GOT %c", key & 0xFF);
  send(line);
  report("KEY", NULL);
}

#define SPEED_BYTES 32768UL

/* R: receive SPEED_BYTES with block reads and report the time taken. */
static void test_rx_speed(void) {
  static unsigned char buf[1024];
  unsigned long got = 0, start = 0;
  unsigned long last = *bios_ticks;

  send("\r\nRX READY\r\n");
  while (got < SPEED_BYTES) {
    segread(&sr);
    r.h.ah = F_BLOCK_READ;
    r.x.cx = sizeof(buf);
    r.x.dx = port;
    sr.es = FP_SEG((unsigned char __far*)buf);
    r.x.di = FP_OFF((unsigned char __far*)buf);
    int86x(0x14, &r, &r, &sr);
    if (r.x.ax) {
      if (!got) {
        start = *bios_ticks;
      }
      got += r.x.ax;
      last = *bios_ticks;
    } else if (!carrier() || *bios_ticks - last > TIMEOUT_TICKS) {
      sprintf(line, "received %lu of %lu", got, SPEED_BYTES);
      report("RX", line);
      return;
    }
  }
  sprintf(line, "\r\nRX TICKS %lu\r\n", *bios_ticks - start);
  send(line);
  report("RX", NULL);
}

/* T: transmit SPEED_BYTES with block writes and report the time taken. */
static void test_tx_speed(void) {
  static unsigned char buf[1024];
  unsigned long sent = 0, start;
  memset(buf, 'T', sizeof(buf));
  send("\r\nTX START\r\n");
  start = *bios_ticks;
  while (sent < SPEED_BYTES) {
    if (!send_bytes(buf, sizeof(buf))) {
      report("TX", "send failed");
      return;
    }
    sent += sizeof(buf);
  }
  fossil(F_FLUSH_OUT, 0);
  sprintf(line, "\r\nTX TICKS %lu\r\n", *bios_ticks - start);
  send(line);
  report("TX", NULL);
}

int main(int argc, char** argv) {
  static struct fossil_info info;
  unsigned st;
  int ch;

  int wait_for_caller = 0;
  int i;

  port = 0;
  for (i = 1; i < argc; i++) {
    if (argv[i][0] == '/' && (argv[i][1] == 'W' || argv[i][1] == 'w')) {
      wait_for_caller = 1;
    } else {
      port = (unsigned)(atoi(argv[i]) - 1);
    }
  }

  r.h.ah = F_INIT;
  r.x.dx = port;
  int86(0x14, &r, &r);
  if (r.x.ax != FOSSIL_SIGNATURE) {
    printf("FOSTEST: no FOSSIL on port %u (AX=%04X)\n", port + 1, r.x.ax);
    return 1;
  }
  printf("FOSTEST: FOSSIL revision %u, highest function %02Xh\n", r.h.bh, r.h.bl);

  get_info(&info);
  printf("FOSTEST: driver: %Fs\n", (char __far*)MK_FP(info.ident_seg, info.ident_off));
  printf("FOSTEST: info bytes %u, in buffer %u, out buffer %u\n",
         r.x.ax, info.ibufr, info.obufr);

  if (wait_for_caller) {
    unsigned long start = *bios_ticks;
    printf("FOSTEST: waiting for a caller\n");
    while (!carrier()) {
      if (*bios_ticks - start > 18UL * 30) {
        printf("FOSTEST: no caller within 30 seconds\n");
        return 4;
      }
    }
  }

  send("FOSTEST ready. Type text to echo; Q quits, H hangs up.\r\n");

  for (;;) {
    st = fossil(F_STATUS, 0);
    if (!(st & FST_DCD)) {
      printf("FOSTEST: carrier lost after %lu bytes\n", received);
      return 2;
    }
    if (kbhit() && getch() == 27) {
      printf("FOSTEST: local abort\n");
      break;
    }
    if (!(st & FST_RDA)) {
      continue;
    }
    ch = fossil(F_RX_WAIT, 0) & 0xFF;
    ++received;
    switch (ch) {
    case 'Q':
      send("\r\nBYE\r\n");
      fossil(F_FLUSH_OUT, 0);
      printf("FOSTEST: received %lu bytes, exiting\n", received);
      fossil(F_DEINIT, 0);
      return 0;
    case 'H':
      send("\r\nHANGUP\r\n");
      fossil(F_FLUSH_OUT, 0);
      fossil(F_DTR, 0);
      fossil(F_FLUSH_OUT, 0);
      printf("FOSTEST: lowered DTR after %lu bytes\n", received);
      return 3;
    case 'F': test_functions(); break;
    case 'P': test_peek(); break;
    case 'X': test_purge(); break;
    case 'B': test_binary(); break;
    case 'K': test_keyboard(); break;
    case 'R': test_rx_speed(); break;
    case 'T': test_tx_speed(); break;
    default:
      fossil(F_TX_WAIT, (unsigned char)ch);
      break;
    }
  }

  fossil(F_DEINIT, 0);
  return 0;
}
