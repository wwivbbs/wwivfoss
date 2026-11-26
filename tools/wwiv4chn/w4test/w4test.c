/*
 * W4TEST - a WWIV 4.07+ chain that tests WWIV4CHN
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 *   WWIV4CHN W4TEST.EXE CHAIN.TXT
 *
 * Finds the BBS function table the way WWIV 4's SKELETON.C does (BBS and
 * WWIV_FP in the environment, INT 6Ah before 4.21), then calls every
 * function in it and the DOS console calls a chain uses, printing what it
 * got back. tests/doors/w4test.sh holds the conversation the BBS side has
 * with it. Last, it stores a hang-up handler (slot 20) and waits for a key;
 * when the caller hangs up, the handler writes W4HUP.TXT and exits 7.
 *
 * Large model, as WWIV 4 chains were (Turbo C).
 */
#include <dos.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

unsigned __cdecl wcall(void __far* fn, unsigned nwords, ...);

static void __far* __far* funcs;

#define F(n) funcs[n]

static void outstr(const char* s) { wcall(F(4), 2, s); }
static void outchr(char c) { wcall(F(3), 1, c); }
static void nl(void) { wcall(F(5), 0); }
static void pl(const char* s) { wcall(F(8), 2, s); }
static void prt(int i, const char* s) { wcall(F(18), 3, i, s); }
static int empty(void) { return wcall(F(9), 0); }
static unsigned char getkey(void) { return (unsigned char)wcall(F(11), 0); }
static void input(char* s, int len) { wcall(F(12), 3, s, len); }
static void inputl(char* s, int len) { wcall(F(13), 3, s, len); }
static int yn(void) { return wcall(F(14), 0); }
static int ny(void) { return wcall(F(15), 0); }
static void ansic(int i) { wcall(F(16), 1, i); }
static char onek(const char* s) { return (char)wcall(F(17), 2, s); }
static void mpl(int i) { wcall(F(19), 1, i); }
static void pla(const char* s, int* abort) { wcall(F(2), 4, s, abort); }
static void inli(char* s, char* rollover, int maxlen, int crend) {
  wcall(F(0), 6, s, rollover, maxlen, crend);
}

static char buf[200];

static void say(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsprintf(buf, fmt, ap);
  va_end(ap);
  pl(buf);
}

/* DOS 09h, 0Ah, 01h. */
static void dos_print(const char* s) {
  union REGS r;
  struct SREGS sr;
  segread(&sr);
  r.h.ah = 0x09;
  r.x.dx = FP_OFF(s);
  sr.ds = FP_SEG(s);
  intdosx(&r, &r, &sr);
}

static void dos_input(unsigned char* b) {
  union REGS r;
  struct SREGS sr;
  segread(&sr);
  r.h.ah = 0x0A;
  r.x.dx = FP_OFF(b);
  sr.ds = FP_SEG(b);
  intdosx(&r, &r, &sr);
}

static unsigned char dos_fn(unsigned char fn) {
  union REGS r;
  r.h.ah = fn;
  intdos(&r, &r);
  return r.h.al;
}

/* Slot 20: WWIV4CHN returns into this from the first console call after
   the caller hangs up. */
static void __far __loadds hup_handler(void) {
  FILE* f = fopen("W4HUP.TXT", "w");
  if (f) {
    fputs("hang-up handler ran\n", f);
    fclose(f);
  }
  exit(7);
}

int main(void) {
  char* ss;
  int version = 0;
  unsigned seg, off;
  void __far* via6a;
  char s[100], roll[100];
  unsigned char dosbuf[40];
  int i, abort;

  ss = getenv("BBS");
  if (!ss || strncmp(ss, "WWIV", 4) != 0) {
    printf("W4TEST: BBS not set to WWIV\n");
    return 1;
  }
  for (i = 0; ss[i]; i++) {
    if (ss[i] >= '0' && ss[i] <= '9') {
      version = version * 10 + (ss[i] - '0');
    }
  }
  ss = getenv("WWIV_FP");
  if (!ss || sscanf(ss, "%x:%x", &seg, &off) != 2) {
    printf("W4TEST: WWIV_FP not set\n");
    return 1;
  }
  funcs = (void __far* __far*)MK_FP(seg, off);
  via6a = (void __far*)_dos_getvect(0x6A);

  pl("W4TEST ready");
  say("VERSION %d 6A %s", version, via6a == (void __far*)funcs ? "same" : "differs");

  outstr("OUTSTR ok");
  nl();
  for (ss = "OUTCHR ok"; *ss; ss++) {
    outchr(*ss);
  }
  nl();
  outstr("\x03" "5HEART\x03" "0");
  nl();
  prt(2, "PRT ok");
  nl();
  ansic(3);
  outstr("ANSIC");
  ansic(0);
  nl();
  outstr("MPL");
  mpl(5);
  nl();
  /* Input nobody typed would abort pla() below; show it instead. Seen
     under QEMU: a 03 from the BBS's first in-band FF 03 (see TODO.md). */
  while (!empty()) {
    say("STRAY %d", getkey());
  }
  abort = 0;
  pla("PLA ok", &abort);
  say("ABORT=%d", abort);
  dos_print("NAME=\x0f\x0fN SL=\x0f\x0fS$");
  nl();
  printf("TAB[\t]\n");
  say("EMPTY=%d", empty());

  outstr("INPUT? ");
  input(s, 10);
  say("GOT [%s]", s);
  outstr("INPUTL? ");
  inputl(s, 20);
  say("GOT [%s]", s);
  outstr("YN? ");
  i = yn();
  say("YN=%d", i);
  outstr("NY? ");
  i = ny();
  say("NY=%d", i);
  outstr("ONEK? ");
  i = onek("ABQ");
  say("ONEK=%c", i);
  outstr("GETKEY? ");
  i = getkey();
  nl();
  say("GETKEY=%d", i);

  pl("INLI?");
  roll[0] = '\0';
  inli(s, roll, 160, 1);
  i = strlen(s);
  say("INLI len=%d end=%d ROLL [%s]", i, i ? s[i - 1] : -1, roll);
  inli(s, roll, 160, 1);
  say("INLI2 [%s]", s);

  outstr("DOS0A? ");
  dosbuf[0] = 20;
  dos_input(dosbuf);
  dosbuf[2 + dosbuf[1]] = '\0';
  nl();
  say("DOS0A [%s]", (char*)dosbuf + 2);
  outstr("DOS01? ");
  i = dos_fn(0x01);
  nl();
  say("DOS01=%c", i);

  funcs[20] = (void __far*)hup_handler;
  pl("HANGUP?");
  for (;;) {
    dos_fn(0x07);
  }
}
