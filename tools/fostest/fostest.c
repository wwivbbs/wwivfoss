/*
 * WWIVFOSS - FOSSIL driver for DOS doors
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * FOSTEST: a minimal FOSSIL door used to test drivers.
 *
 *   FOSTEST [port]      port is 1-based (default 1)
 *
 * Initialises the FOSSIL, prints driver information, sends a banner, then
 * echoes everything it receives. Exit codes:
 *
 *   0  received 'Q' (commands are uppercase only)
 *   1  no FOSSIL present
 *   2  carrier lost (the caller hung up)
 *   3  received 'H': the door hung up by lowering DTR (function 06h)
 *
 * ESC on the local keyboard also exits (0).
 */
#include <conio.h>
#include <dos.h>
#include <i86.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fossil.h"

static union REGS r;
static struct SREGS sr;
static unsigned port;

static unsigned fossil(unsigned char fn, unsigned char al) {
  r.h.ah = fn;
  r.h.al = al;
  r.x.dx = port;
  int86(0x14, &r, &r);
  return r.x.ax;
}

/* Block write, retrying partial writes as the FOSSIL spec allows. */
static void send(const char* s) {
  static char buf[128];
  unsigned len, done = 0;
  strncpy(buf, s, sizeof(buf) - 1);
  len = (unsigned)strlen(buf);
  while (done < len) {
    segread(&sr);
    r.h.ah = F_BLOCK_WRITE;
    r.x.cx = len - done;
    r.x.dx = port;
    sr.es = FP_SEG((char __far*)(buf + done));
    r.x.di = FP_OFF((char __far*)(buf + done));
    int86x(0x14, &r, &r, &sr);
    done += r.x.ax;
    if (r.x.ax == 0 && !(fossil(F_STATUS, 0) & FST_DCD)) {
      return;
    }
  }
}

int main(int argc, char** argv) {
  static struct fossil_info info;
  unsigned st;
  unsigned long received = 0;
  int ch;

  port = (argc > 1) ? (unsigned)(atoi(argv[1]) - 1) : 0;

  r.h.ah = F_INIT;
  r.x.dx = port;
  int86(0x14, &r, &r);
  if (r.x.ax != FOSSIL_SIGNATURE) {
    printf("FOSTEST: no FOSSIL on port %u (AX=%04X)\n", port + 1, r.x.ax);
    return 1;
  }
  printf("FOSTEST: FOSSIL revision %u, highest function %02Xh\n",
         r.h.bh, r.h.bl);

  segread(&sr);
  r.h.ah = F_DRIVER_INFO;
  r.x.cx = sizeof(info);
  r.x.dx = port;
  sr.es = FP_SEG((void __far*)&info);
  r.x.di = FP_OFF((void __far*)&info);
  int86x(0x14, &r, &r, &sr);
  printf("FOSTEST: driver: %Fs\n",
         (char __far*)MK_FP(info.ident_seg, info.ident_off));
  printf("FOSTEST: info bytes %u, in buffer %u, out buffer %u\n",
         r.x.ax, info.ibufr, info.obufr);

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
    if (ch == 'Q') {
      send("\r\nBYE\r\n");
      fossil(F_FLUSH_OUT, 0);
      printf("FOSTEST: received %lu bytes, exiting\n", received);
      break;
    }
    if (ch == 'H') {
      send("\r\nHANGUP\r\n");
      fossil(F_FLUSH_OUT, 0);
      fossil(F_DTR, 0);
      fossil(F_FLUSH_OUT, 0);
      printf("FOSTEST: lowered DTR after %lu bytes\n", received);
      return 3;
    }
    fossil(F_TX_WAIT, (unsigned char)ch);
  }

  fossil(F_DEINIT, 0);
  return 0;
}
