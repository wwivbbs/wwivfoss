/*
 * WWIV4CHN - runs a WWIV 3.x/4.x chain on a FOSSIL
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 *   WWIV4CHN COMMAND [ARGS...]
 *
 * WWIV 3 and 4 ran chains with "DOS interrupts" on: the chain talked to the
 * caller through DOS's console calls and WWIV sent them to the modem. WWIV
 * 4.07 and later also gave chains a table of BBS functions to call. This
 * does both on a FOSSIL (WWIVFOSS): it hooks INT 21h and INT 29h, publishes
 * the function table, runs COMMAND, and while it runs
 *
 *   - console output (INT 21h 02h, 06h, 09h, 40h on a console handle, and
 *     INT 29h) goes to the caller through WWIV 4's outchr(): heart codes
 *     (^C0-^C9) become ANSI colors (WWIV's default colors), ^O^O<letter>
 *     prints a user field from CHAIN.TXT, tabs expand to 8 columns and ^L
 *     clears the screen;
 *   - console input (01h, 06h, 07h, 08h, 0Ah, 0Ch, 3Fh on a console
 *     handle) comes from the caller, and the input status calls (0Bh, 06h
 *     with DL=FFh) say whether the caller has typed something;
 *   - INT 21h 2Ch (get time) with no key waiting first polls the FOSSIL,
 *     which lets WWIVFOSS idle, as WWIV 4.30 released a timeslice there;
 *   - the function table (inli, checka, pla, outchr, outstr, nl, pl, empty,
 *     inkey, getkey, input, inputl, yn, ny, ansic, onek, prt, mpl) is
 *     passed in the environment as WWIV_FP=SSSS:OOOO with BBS=WWIV v4.30,
 *     and through the INT 6Ah vector for chains written for 4.07-4.20;
 *   - when the caller hangs up, the chain's next console call ends it, or
 *     returns into the chain's hang-up handler if it stored one in slot 20
 *     (it then has 2 seconds, or the ticks it stores there, up to 500).
 *     Function 01h then returns ^C and 0Ah returns "EXIT", so a command
 *     shell run as a chain quits.
 *
 * The behavior follows WWIV 4.30's newintr1() and RETURN.C, except that DEL
 * edits like backspace, 0Ah echoes the final CR as DOS does, and a chain
 * that only calls the table after a hang-up is ended after 10 seconds.
 * Nothing goes to the local screen. Programs that write to video memory
 * or use the BIOS for the screen or keyboard aren't covered; WWIV 3 and 4
 * didn't cover them either.
 *
 * CHAIN.TXT: when an argument names a file called CHAIN.TXT, its gfiles and
 * data directory lines (17, 18) are pointed at that file's directory if they
 * hold Unix paths (WWIV 5 on Linux), since WWIV 4 chains write there. Its
 * ANSI line (14) decides whether heart codes become colors or are dropped;
 * line 9 is the screen width for inli(), lines 2-11 the ^O^O fields.
 *
 * Exit code: the chain's, or 255 if it couldn't be run.
 */
#include <dos.h>
#include <i86.h>
#include <process.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../include/fossil.h"

typedef void (__interrupt __far *intvec_t)(void);

#define PORT       0       /* FOSSIL port: COM1 */
#define ZF         0x0040  /* zero flag in FLAGS */
#define MAX_CHAIN  4096    /* biggest CHAIN.TXT we rewrite */
#define HUP_TICKS  36      /* a chain's hang-up handler gets ~2 s */
#define HUP_MAX    500     /* ... or what it stores in slot 20, up to this */
#define API_HUP_TICKS 182  /* table-only chains: ended 10 s after hang-up */

/* WWIV 4's default colors for ^C0-^C9 (PC attributes). */
static const unsigned char colors[10] = {7, 11, 14, 5, 31, 2, 12, 9, 6, 3};
/* PC color <-> ANSI color; the mapping is its own inverse. */
static const char pc_to_ansi[8] = "04261537";

/* The function table (WWIV 4's funcs[]); api.asm has the entry points. */
static void __far* funcs[25];
extern unsigned short api_offsets[20];
#pragma aux api_offsets "*"
unsigned __cdecl api_call(unsigned slot, unsigned __far* args);

static intvec_t old_int21;
static intvec_t old_int29;
static intvec_t old_int6a;
static int ansi = 1;          /* heart codes to colors, else dropped */
static unsigned screenchars = 80;
static char info[12][32];     /* CHAIN.TXT lines 1-11 */
static int in_handler;
static int hung_up;
static int hangup_seen;       /* a console call has acted on the hang-up */
static unsigned long hangup_tick;
static int api_hup_seen;
static unsigned long api_hup_tick;

static unsigned char outbuf[256];
static unsigned outlen;

/* Cooked console input (0Ah, 3Fh): one line, handed out across calls. */
static char line[260];
static unsigned line_len;
static unsigned line_pos;
static int input_extern;      /* 0Ah: ^Z can be typed */

/* Typed-ahead text (inli's rollover word). */
static char charbuffer[161];
static unsigned cbp;

/* ----- DOS, BIOS and FOSSIL calls ----- */

/*
 * Interrupt calls are inline: they run inside the INT 21h handler on the
 * chain's stack (SS isn't DGROUP), where the C library's int86() breaks
 * (it keeps a temporary on the stack and reaches it through DS).
 */
unsigned fossil_call(unsigned ax, unsigned dx);
#pragma aux fossil_call = \
  "int 14h" \
  parm [ax] [dx] value [ax] modify [bx cx dx si di es]

/* FOSSIL block write (19h): returns the number of bytes taken. */
unsigned fossil_block(unsigned count, unsigned char __far* buf);
#pragma aux fossil_block = \
  "mov ah, 19h" \
  "xor dx, dx" \
  "int 14h" \
  parm [cx] [es di] value [ax] modify [bx cx dx si di es]

/* INT 21h 4400h: a handle's device information word, 0 on error. */
unsigned dos_dev_info(unsigned handle);
#pragma aux dos_dev_info = \
  "mov ax, 4400h" \
  "int 21h" \
  "sbb ax, ax" \
  "not ax" \
  "and dx, ax" \
  parm [bx] value [dx] modify [ax]

/* INT 21h 4Ch, from inside a table call (our own stack). */
void dos_exit(unsigned ax);
#pragma aux dos_exit = \
  "int 21h" \
  parm [ax] aborts

unsigned code_segment(void);
#pragma aux code_segment = \
  "mov ax, cs" \
  value [ax]

/* BIOS timer ticks since midnight (18.2 a second). */
static unsigned long ticks(void) {
  return *(unsigned long volatile __far*)MK_FP(0x40, 0x6C);
}

static unsigned fossil(unsigned char fn, unsigned char al) {
  return fossil_call(((unsigned)fn << 8) | al, PORT);
}

static void flush_out(void) {
  static unsigned i;

  if (outlen == 0 || hung_up) {
    outlen = 0;
    return;
  }
  /* The rest one byte at a time, waiting for room. */
  for (i = fossil_block(outlen, outbuf); i < outlen; i++) {
    if (!(fossil(F_TX_WAIT, outbuf[i]) & FST_DCD)) {
      hung_up = 1;
      break;
    }
  }
  outlen = 0;
}

static void out_byte(unsigned char c) {
  if (outlen == sizeof(outbuf)) {
    flush_out();
  }
  outbuf[outlen++] = c;
}

/* ----- output: WWIV 4's outchr() ----- */

/* The caller's screen as far as we can tell: the color (for ansic()) and
   the column (for tabs and inli()), kept from everything sent. */
static unsigned char curatr = 7;
static unsigned col;
static unsigned saved_col;
static unsigned char esc[24];
static unsigned esc_len;      /* > 0 inside an escape sequence */

static unsigned char change_color;  /* 1 after ^C, 2 after ^O, 3 after ^O^O */
static int eol_pending;       /* nl() goes back to color 0 first */

static void outchr(unsigned char c);
static void outstr(const char __far* s);
static void pausescr(void);

/* An ANSI sequence went out: follow its color and cursor changes. */
static void do_ansi(void) {
  static unsigned args[10];
  static unsigned nargs;
  static unsigned i;
  static unsigned v;
  static unsigned char cmd;

  if (esc_len < 3 || esc[1] != '[') {
    return;
  }
  cmd = esc[esc_len - 1];
  nargs = 0;
  v = 0;
  for (i = 2; i < esc_len - 1; i++) {
    if (esc[i] == ';') {
      if (nargs < 10) {
        args[nargs++] = v;
      }
      v = 0;
    } else if (esc[i] >= '0' && esc[i] <= '9') {
      v = v * 10 + (esc[i] - '0');
    }
  }
  if (esc_len > 3 && nargs < 10) {
    args[nargs++] = v;
  }
  v = (nargs && args[0]) ? args[0] : 1;
  switch (cmd) {
  case 'H':
  case 'f':
    col = (nargs > 1 && args[1]) ? args[1] - 1 : 0;
    break;
  case 'C':
    col = (col + v > 79) ? 79 : col + v;
    break;
  case 'D':
    col = (col > v) ? col - v : 0;
    break;
  case 's':
    saved_col = col;
    break;
  case 'u':
    col = saved_col;
    break;
  case 'J':
    if (nargs && args[0] == 2) {
      col = 0;
    }
    break;
  case 'm':
    if (nargs == 0) {
      args[0] = 0;
      nargs = 1;
    }
    for (i = 0; i < nargs; i++) {
      v = args[i];
      if (v == 0) {
        curatr = 0x07;
      } else if (v == 1) {
        curatr |= 0x08;
      } else if (v == 5) {
        curatr |= 0x80;
      } else if (v == 7) {
        v = curatr & 0x77;
        curatr = (unsigned char)((curatr & 0x88) | (v << 4) | (v >> 4));
      } else if (v == 8) {
        curatr = 0;
      } else if (v >= 30 && v <= 37) {
        curatr = (unsigned char)((curatr & 0xF8) | (pc_to_ansi[v - 30] - '0'));
      } else if (v >= 40 && v <= 47) {
        curatr = (unsigned char)((curatr & 0x8F) | ((pc_to_ansi[v - 40] - '0') << 4));
      }
    }
    break;
  }
}

/* Sends one byte to the caller, keeping track of the screen. */
static void emit(unsigned char c) {
  out_byte(c);
  if (esc_len) {
    if (esc_len < sizeof(esc)) {
      esc[esc_len++] = c;
    }
    if ((c > '@' && c != '[') || esc[1] != '[') {
      do_ansi();
      esc_len = 0;
    }
    return;
  }
  if (c == 27) {
    esc[0] = 27;
    esc_len = 1;
  } else if (c == '\r' || c == 12) {
    col = 0;
  } else if (c == 8) {
    if (col) {
      --col;
    }
  } else if (c >= 32) {
    if (++col >= 80) {
      col = 0;
    }
  }
}

static void emit_str(const char* s) {
  while (*s) {
    emit((unsigned char)*s++);
  }
}

/* SGR for a PC attribute: ESC[0;1;5;3x;4ym. */
static void out_color(unsigned char attr) {
  emit_str("\x1b[0");
  if (attr & 0x08) {
    emit_str(";1");
  }
  if (attr & 0x80) {
    emit_str(";5");
  }
  emit_str(";3");
  emit(pc_to_ansi[attr & 7]);
  emit_str(";4");
  emit(pc_to_ansi[(attr >> 4) & 7]);
  emit('m');
}

/* WWIV's setc(): change color, if the caller has ANSI. */
static void setc(unsigned char attr) {
  if (ansi && attr != curatr) {
    out_color(attr);
  }
}

/* WWIV's ansic(): color n (0-9); the next nl() goes back to color 0. */
static void ansic(int n) {
  unsigned char c;
  if (n < 0 || n > 9) {
    return;
  }
  c = colors[n];
  if (c == curatr) {
    return;
  }
  setc(c);
  eol_pending = ansi && c != colors[0];
}

/* ^O^O<c>: a field of the user's record. WWIV 4 had them all; CHAIN.TXT
   has these. */
static const char __far* interpret(unsigned char c) {
  switch (c) {
  case 'N': return info[2];   /* name */
  case 'R': return info[3];   /* real name */
  case 'I': return info[4];   /* call sign */
  case 'A': return info[5];   /* age */
  case 'X': return info[6];   /* sex */
  case 'g': return info[7];   /* gold */
  case 'L': return info[8];   /* last on */
  case 'S': return info[11];  /* security level */
  case '!': pausescr(); return "";
  }
  return "";
}

static void outchr(unsigned char c) {
  static unsigned n;

  switch (change_color) {
  case 1:
    change_color = 0;
    if (c >= '0' && c <= '9') {
      ansic(c - '0');
    }
    return;
  case 2:
    change_color = (c == 15) ? 3 : 0;
    return;
  case 3:
    change_color = 0;
    outstr(interpret(c));
    return;
  }
  if (c == 3) {
    change_color = 1;
    return;
  }
  if (c == 15) {
    change_color = 2;
    return;
  }
  if (c == 10) {
    eol_pending = 0;  /* a chain's own LF doesn't reset the color */
  }
  if (c == 9) {
    for (n = 8 - col % 8; n > 0; n--) {
      emit(' ');
    }
  } else if (c == 12 && ansi && !esc_len) {
    emit_str("\x1b[2J\x1b[H");
  } else {
    emit(c);
  }
}

static void outstr(const char __far* s) {
  if (hung_up) {
    return;
  }
  while (*s) {
    outchr((unsigned char)*s++);
  }
}

static void nl(void) {
  if (eol_pending) {
    eol_pending = 0;
    setc(colors[0]);
  }
  outstr("\r\n");
}

static void pl(const char __far* s) {
  outstr(s);
  nl();
}

static void backspace(void) {
  outstr("\b \b");
}

static void prt(int n, const char __far* s) {
  ansic(n);
  outstr(s);
  ansic(0);
}

/* WWIV's mpl(): a reverse-video input field n wide, cursor at its start. */
static void mpl(int n) {
  static char num[8];
  static int i;
  if (!ansi || n <= 0) {
    return;
  }
  ansic(4);
  for (i = 0; i < n; i++) {
    outchr(' ');
  }
  i = sizeof(num) - 1;
  num[i] = '\0';
  do {
    num[--i] = (char)('0' + n % 10);
    n /= 10;
  } while (n && i > 0);
  outstr("\x1b[");
  outstr(num + i);
  outstr("D");
}

/* ----- input ----- */

static int key_waiting(void) {
  unsigned st = fossil(F_STATUS, 0);
  if (!(st & FST_DCD)) {
    hung_up = 1;
    return 0;
  }
  return (st & FST_RDA) != 0;
}

/* Waits for a key; -1 if the caller hung up. */
static int get_key(void) {
  unsigned v;
  flush_out();
  if (hung_up) {
    return -1;
  }
  v = fossil(F_RX_WAIT, 0);
  if (v & 0x8000) {
    hung_up = 1;
    return -1;
  }
  return v & 0xFF;
}

/* The next typed-ahead character, or 0. */
static unsigned char buffered(void) {
  if (cbp) {
    if (charbuffer[cbp]) {
      return (unsigned char)charbuffer[cbp++];
    }
    cbp = 0;
  }
  return 0;
}

static int empty(void) {
  if (cbp && charbuffer[cbp]) {
    return 0;
  }
  return !key_waiting();
}

static unsigned char inkey(void) {
  unsigned char c = buffered();
  int k;
  if (c) {
    return c;
  }
  if (!key_waiting()) {
    return 0;
  }
  k = get_key();
  return (unsigned char)(k < 0 ? 0 : k);
}

/* Waits for a key; 0 if the caller hung up. */
static unsigned char getkey(void) {
  unsigned char c = buffered();
  int k;
  if (c) {
    return c;
  }
  k = get_key();
  return (unsigned char)(k < 0 ? 0 : k);
}

static unsigned char upcase(unsigned char c) {
  return (c >= 'a' && c <= 'z') ? (unsigned char)(c - 32) : c;
}

/* WWIV's input1(): a line of up to maxlen characters into s, upper case
   unless lc; CR ends it (and prints CR LF if crend). */
static void input1(char __far* s, int maxlen, int lc, int crend) {
  int curpos = 0;
  int done = 0;
  unsigned char ch;

  while (!done && !hung_up) {
    ch = getkey();
    if (ch == 127) {
      ch = 8;
    }
    if (ch > 31) {
      if (curpos < maxlen) {
        if (!lc) {
          ch = upcase(ch);
        }
        s[curpos++] = (char)ch;
        outchr(ch);
      }
    } else {
      switch (ch) {
      case 14:
      case 13:
        s[curpos] = '\0';
        done = 1;
        if (crend) {
          nl();
        }
        break;
      case 26:
        if (input_extern && curpos < maxlen) {
          s[curpos++] = 26;
          outstr("^Z");
        }
        break;
      case 8:
        if (curpos) {
          curpos--;
          backspace();
          if (s[curpos] == 26) {
            backspace();
          }
        }
        break;
      case 24:
        while (curpos) {
          curpos--;
          backspace();
          if (s[curpos] == 26) {
            backspace();
          }
        }
        break;
      }
    }
  }
  if (hung_up) {
    s[0] = '\0';
  }
}

/* WWIV's inli(): a line for a message editor. Holds heart codes (^P
   digit); when the line fills up, the last word goes to rollover, to start
   the next line, and the line ends in ^A. */
static void inli(char __far* s, char __far* rollover, int maxlen, int crend) {
  static char s1[161];
  int cp, i, i1, done;
  unsigned begx, n;
  unsigned char ch = 0;

  begx = col;
  if (rollover[0]) {
    /* The rolled-over word is typed first. */
    n = 0;
    for (i = 0; rollover[i] && n < sizeof(s1) - 2; i++) {
      s1[n++] = rollover[i];
    }
    if (cbp) {
      for (i = cbp; charbuffer[i] && n < sizeof(s1) - 2; i++) {
        s1[n++] = charbuffer[i];
      }
    }
    s1[n] = '\0';
    charbuffer[0] = '\0';
    memcpy(charbuffer + 1, s1, n + 1);
    cbp = 1;
    rollover[0] = '\0';
  }
  cp = 0;
  done = 0;
  do {
    ch = getkey();
    if (ch == 127) {
      ch = 8;
    }
    if (ch >= 32) {
      if (col < screenchars - 1 && cp < maxlen) {
        s[cp++] = (char)ch;
        outchr(ch);
        if (col == screenchars - 1) {
          done = 1;
        }
      } else if (col >= screenchars - 1) {
        done = 1;
      }
    } else {
      switch (ch) {
      case 13:
        s[cp] = '\0';
        done = 1;
        break;
      case 8:
        if (cp) {
          if (cp >= 2 && s[cp - 2] == 3) {
            cp -= 2;
            ansic(0);
          } else if (cp >= 2 && s[cp - 2] == 15) {
            if (s[cp - 1] != '!') {
              for (i = (int)_fstrlen(interpret(s[cp - 1])); i > 0; i--) {
                backspace();
              }
            }
            cp -= 2;
            if (cp && s[cp - 1] == 15) {
              cp--;
            }
          } else if (s[cp - 1] == 8) {
            cp--;
            outchr(32);
          } else {
            cp--;
            backspace();
          }
        }
        break;
      case 24:  /* ^X: erase the line */
        while (col > begx) {
          backspace();
        }
        cp = 0;
        ansic(0);
        break;
      case 23:  /* ^W: erase a word */
        if (cp) {
          do {
            if (cp >= 2 && s[cp - 2] == 3) {
              cp -= 2;
              ansic(0);
            } else if (s[cp - 1] == 8) {
              cp--;
              outchr(32);
            } else {
              cp--;
              backspace();
            }
          } while (cp && s[cp - 1] != 32 && s[cp - 1] != 8 &&
                   !(cp >= 2 && s[cp - 2] == 3));
        }
        break;
      case 14:  /* ^N: overstrike */
        if (col && cp < maxlen) {
          outchr(8);
          s[cp++] = 8;
        }
        break;
      case 16:  /* ^P: a color, or ^P^P<c> a ^O^O code */
        if (cp < maxlen - 1) {
          ch = getkey();
          if (ch >= '0' && ch <= '9') {
            s[cp++] = 3;
            s[cp++] = (char)ch;
            ansic(ch - '0');
          } else if (ch == 16 && cp < maxlen - 2) {
            ch = getkey();
            if (ch != 16) {
              s[cp++] = 15;
              s[cp++] = 15;
              s[cp++] = (char)ch;
              outchr(15);
              outchr(15);
              outchr(ch);
            }
          }
        }
        break;
      case 9:
        i = 5 - (cp % 5);
        if (cp + i < maxlen && col + i < screenchars) {
          i = 5 - ((col + 1) % 5);
          for (i1 = 0; i1 < i && cp < maxlen; i1++) {
            s[cp++] = 32;
            outchr(32);
          }
        }
        break;
      }
    }
  } while (!done && !hung_up);
  if (hung_up) {
    s[cp] = '\0';
    return;
  }
  if (ch != 13) {
    /* Full: move the last word to rollover. */
    i = cp - 1;
    while (i > 0 && ((s[i] != 32 && s[i] != 8) || s[i - 1] == 3)) {
      i--;
    }
    if (i > (int)(col / 2) && i != cp - 1) {
      i1 = cp - i - 1;
      for (i = 0; i < i1; i++) {
        outchr(8);
      }
      for (i = 0; i < i1; i++) {
        outchr(32);
      }
      for (i = 0; i < i1; i++) {
        rollover[i] = s[cp - i1 + i];
      }
      rollover[i1] = '\0';
      cp -= i1;
    }
    s[cp++] = 1;
    s[cp] = '\0';
  }
  if (crend) {
    nl();
  }
}

/* WWIV's checka(): while printing, space, ^C or ^X aborts, ^N skips to
   the next item, P or ^S pauses until a key. */
static void checka(int __far* abort, int __far* next) {
  unsigned char ch;
  while (!empty() && !*abort && !hung_up) {
    ch = inkey();
    switch (ch) {
    case 14:
      *next = 1;
      /* fall through */
    case 3:
    case 32:
    case 24:
      *abort = 1;
      break;
    case 'P':
    case 'p':
    case 19:
      getkey();
      break;
    }
  }
}

/* WWIV's pla(): a line the caller can abort. */
static void pla(const char __far* s, int __far* abort) {
  static int next;
  if (hung_up) {
    *abort = 1;
  }
  checka(abort, &next);
  while (*s && !*abort) {
    outchr((unsigned char)*s++);
    checka(abort, &next);
  }
  if (!*abort) {
    nl();
  }
}

static void pausescr(void) {
  unsigned char old;
  int i;
  if (ansi) {
    old = curatr;
    setc(colors[3]);
    outstr("[PAUSE]\x1b[7D");
    setc(old);
    getkey();
    outstr("       \x1b[7D");
  } else {
    outstr("[PAUSE]");
    getkey();
    for (i = 0; i < 7; i++) {
      backspace();
    }
  }
}

/* yn() and ny(): Y or N; Enter means N (yn) or Y (ny). */
static unsigned char get_yn(void) {
  unsigned char ch = 0;
  ansic(1);
  while (!hung_up && (ch = upcase(getkey())) != 'Y' && ch != 'N' && ch != 13) {
  }
  return ch;
}

static int yn(void) {
  unsigned char ch = get_yn();
  outstr(ch == 'Y' ? "Yes" : "No");
  nl();
  return ch == 'Y';
}

static int ny(void) {
  unsigned char ch = get_yn();
  outstr(ch == 'N' ? "No" : "Yes");
  nl();
  return ch == 'Y' || ch == 13;
}

/* WWIV's onek(): one of the keys in s (upper case). */
static unsigned char onek(const char __far* s) {
  unsigned char ch;
  while (!_fstrchr(s, ch = upcase(getkey())) && !hung_up) {
  }
  if (hung_up) {
    ch = (unsigned char)s[0];
  }
  outchr(ch);
  nl();
  return ch;
}

/* ----- the function table ----- */

#define ARG_STR(i)  ((char __far*)MK_FP(a[(i) + 1], a[i]))
#define ARG_INTP(i) ((int __far*)MK_FP(a[(i) + 1], a[i]))

/*
 * Runs table function `slot` (from api.asm, on our own stack). a points at
 * the chain's arguments as Turbo C large model pushed them: a far pointer
 * takes two words (offset, segment), an int or char one.
 */
unsigned __cdecl api_call(unsigned slot, unsigned __far* a) {
  unsigned rv = 0;

  switch (slot) {
  case 0:  inli(ARG_STR(0), ARG_STR(2), (int)a[4], (int)a[5]); break;
  case 1:  checka(ARG_INTP(0), ARG_INTP(2)); break;
  case 2:  pla(ARG_STR(0), ARG_INTP(2)); break;
  case 3:  outchr((unsigned char)a[0]); break;
  case 4:  outstr(ARG_STR(0)); break;
  case 5:  nl(); break;
  case 8:  pl(ARG_STR(0)); break;
  case 9:  rv = empty(); break;
  case 10: rv = empty(); break;  /* inkey: WWIV 4 returned empty() here */
  case 11: rv = getkey(); break;
  case 12: input1(ARG_STR(0), (int)a[2], 0, 1); break;
  case 13: input1(ARG_STR(0), (int)a[2], 1, 1); break;
  case 14: rv = yn(); break;
  case 15: rv = ny(); break;
  case 16: ansic((int)a[0]); break;
  case 17: rv = onek(ARG_STR(0)); break;
  case 18: prt((int)a[0], ARG_STR(1)); break;
  case 19: mpl((int)a[0]); break;
  }
  flush_out();

  /* WWIV ended a chain only from its DOS calls; one that only calls the
     table would run on after a hang-up, so end it after a while. */
  if (hung_up && !in_handler) {
    if (!api_hup_seen) {
      api_hup_seen = 1;
      api_hup_tick = ticks();
    } else if (ticks() - api_hup_tick > API_HUP_TICKS) {
      dos_exit(0x4C00);
    }
  }
  return rv;
}

/* ----- DOS ----- */

/* True if the handle is the console: a device, standard input (bit 0) or
   output (bit 1). Asks DOS itself (in_handler is set). */
static int is_console(unsigned handle, unsigned bit) {
  unsigned info_word = dos_dev_info(handle);
  return (info_word & 0x80) && (info_word & bit);
}

/* The caller's registers that console_input() reads and sets. */
static unsigned char in_al;
static unsigned in_flags;
static unsigned in_ds;
static unsigned in_dx;

/* Runs console input function fn (01h, 06h with DL = FFh, 07h, 08h,
   0Ah). On hang-up hung_up is set and the handler ends the program. */
static void console_input(unsigned char fn) {
  static unsigned char c;
  static unsigned char __far* buf;
  static unsigned n;
  static unsigned i;

  switch (fn) {
  case 0x01:  /* read with echo; ^C once the caller is gone */
    c = getkey();
    outchr(c);
    in_al = hung_up ? 3 : c;
    break;
  case 0x06:  /* direct console input */
    if (empty()) {
      in_al = 0;
      in_flags |= ZF;
    } else {
      in_al = getkey();
      in_flags &= ~ZF;
    }
    break;
  case 0x07:  /* read without echo */
  case 0x08:
    in_al = getkey();
    break;
  case 0x0A:  /* buffered input: DS:DX = max, count, text */
    buf = (unsigned char __far*)MK_FP(in_ds, in_dx);
    if (buf[0] == 0) {
      break;
    }
    input_extern = 1;
    input1(line, buf[0] - 1, 1, 0);
    input_extern = 0;
    if (hung_up) {
      strcpy(line, "EXIT");  /* a command shell quits */
    } else {
      emit('\r');
      flush_out();
    }
    n = strlen(line);
    if (n > (unsigned)buf[0] - 1) {
      n = buf[0] - 1;
    }
    for (i = 0; i < n; i++) {
      buf[2 + i] = (unsigned char)line[i];
    }
    buf[2 + n] = '\r';
    buf[1] = (unsigned char)n;
    line_len = line_pos = 0;
    break;
  }
}

/* console_input() on the interrupted registers. */
#define CONSOLE_INPUT(fn) \
  do { \
    in_al = r.h.al; in_flags = r.w.flags; in_ds = r.w.ds; in_dx = r.w.dx; \
    console_input(fn); \
    r.h.al = in_al; r.w.flags = in_flags; \
  } while (0)

static void __interrupt __far int21_handler(union INTPACK r) {
  static unsigned char fn;
  static unsigned i;
  static unsigned n;
  static unsigned char __far* p;
  static unsigned long limit;

  fn = r.h.ah;
  if (in_handler) {
    _chain_intr(old_int21);
  }
  switch (fn) {
  case 0x01: case 0x02: case 0x06: case 0x07: case 0x08: case 0x09:
  case 0x0A: case 0x0B: case 0x0C: case 0x3F: case 0x40:
    break;
  case 0x2C:
    /* Get time: chains that wait on the clock poll here. With no key
       waiting, poll the FOSSIL too; WWIVFOSS idles after a few empty
       polls (WWIV 4.30 released a timeslice). */
    _enable();
    if (!(cbp && charbuffer[cbp])) {
      key_waiting();
    }
    _chain_intr(old_int21);
  default:
    _chain_intr(old_int21);
  }
  in_handler = 1;
  _enable();

  switch (fn) {
  case 0x02:
    outchr(r.h.dl);
    flush_out();
    break;
  case 0x06:
    if (r.h.dl == 0xFF) {
      CONSOLE_INPUT(0x06);
    } else {
      outchr(r.h.dl);
      flush_out();
    }
    break;
  case 0x09:
    p = (unsigned char __far*)MK_FP(r.w.ds, r.w.dx);
    for (i = 0; p[i] != '$' && i < 0xFFFF; i++) {
      outchr(p[i]);
    }
    flush_out();
    r.h.al = '$';
    break;
  case 0x0B:
    r.h.al = empty() ? 0x00 : 0xFF;
    break;
  case 0x0C:  /* flush input, then run function AL */
    fossil(F_PURGE_IN, 0);
    line_len = line_pos = 0;
    cbp = 0;
    if (r.h.al == 0x06 && r.h.dl != 0xFF) {
      outchr(r.h.dl);
      flush_out();
    } else if (r.h.al == 0x01 || r.h.al == 0x06 || r.h.al == 0x07 ||
               r.h.al == 0x08 || r.h.al == 0x0A) {
      CONSOLE_INPUT(r.h.al);
    }
    break;
  case 0x3F:
    if (!is_console(r.w.bx, 0x01)) {
      in_handler = 0;
      _chain_intr(old_int21);
    }
    /* Cooked mode: a whole line with CR LF, as DOS reads CON. */
    if (line_pos >= line_len) {
      line_pos = 0;
      input1(line, sizeof(line) - 3, 1, 1);
      if (hung_up) {
        line_len = 0;
      } else {
        line_len = strlen(line);
        line[line_len++] = '\r';
        line[line_len++] = '\n';
      }
    }
    n = line_len - line_pos;
    if (n > r.w.cx) {
      n = r.w.cx;
    }
    p = (unsigned char __far*)MK_FP(r.w.ds, r.w.dx);
    for (i = 0; i < n; i++) {
      p[i] = (unsigned char)line[line_pos++];
    }
    r.w.ax = n;
    r.w.flags &= ~INTR_CF;
    break;
  case 0x40:
    if (!is_console(r.w.bx, 0x02)) {
      in_handler = 0;
      _chain_intr(old_int21);
    }
    p = (unsigned char __far*)MK_FP(r.w.ds, r.w.dx);
    for (i = 0; i < r.w.cx; i++) {
      outchr(p[i]);
    }
    flush_out();
    r.w.ax = r.w.cx;
    r.w.flags &= ~INTR_CF;
    break;
  default:  /* 01h, 07h, 08h, 0Ah */
    CONSOLE_INPUT(fn);
    break;
  }
  flush_out();
  in_handler = 0;

  if (!hung_up) {
    return;
  }
  /* The caller hung up: as WWIV 4 did, return into the chain's hang-up
     handler if it stored one in slot 20, and end the chain (4Ch) at once
     if not, or once the handler's time is up. */
  if (!hangup_seen) {
    hangup_seen = 1;
    hangup_tick = ticks();
    if (funcs[20]) {
      r.w.ip = FP_OFF(funcs[20]);
      r.w.cs = FP_SEG(funcs[20]);
      funcs[20] = MK_FP(0, HUP_TICKS);
      return;
    }
  } else {
    limit = (unsigned long)funcs[20];
    if (limit > HUP_MAX) {
      limit = HUP_TICKS;
    }
    if (ticks() - hangup_tick <= limit) {
      return;
    }
  }
  r.w.ax = 0x4C00;
  _chain_intr(old_int21);
}

static void __interrupt __far int29_handler(union INTPACK r) {
  if (in_handler) {
    _chain_intr(old_int29);
  }
  in_handler = 1;
  _enable();
  outchr(r.h.al);
  flush_out();
  in_handler = 0;
}

/* ----- CHAIN.TXT ----- */

static const char* base_name(const char* path) {
  const char* b = path;
  for (; *path; path++) {
    if (*path == '\\' || *path == '/' || *path == ':') {
      b = path + 1;
    }
  }
  return b;
}

/* Reads CHAIN.TXT: the user fields (lines 1-11), ansi (line 14), and
   points Unix paths on lines 17 and 18 at the file's own directory. */
static void fix_chain_txt(const char* path) {
  static char data[MAX_CHAIN];
  static char out[MAX_CHAIN + 64];
  static char dir[80];
  FILE* f;
  size_t len, o;
  char* s;
  char* e;
  int lineno;
  int changed = 0;

  f = fopen(path, "rb");
  if (!f) {
    return;
  }
  len = fread(data, 1, sizeof(data) - 1, f);
  fclose(f);
  if (len == sizeof(data) - 1) {
    return;  /* too big to be CHAIN.TXT */
  }
  data[len] = '\0';

  len = (size_t)(base_name(path) - path);
  if (len == 0 || len >= sizeof(dir)) {
    strcpy(dir, ".\\");
  } else {
    memcpy(dir, path, len);
    dir[len] = '\0';
    if (dir[len - 1] == ':') {
      strcat(dir, "\\");
    }
  }

  o = 0;
  lineno = 1;
  for (s = data; *s; lineno++) {
    e = strchr(s, '\n');
    if (!e) {
      e = s + strlen(s);
    }
    len = (size_t)(e - s);
    if (len > 0 && s[len - 1] == '\r') {
      --len;
    }
    if (lineno < 12) {
      memcpy(info[lineno], s, len < 31 ? len : 31);
      info[lineno][len < 31 ? len : 31] = '\0';
    }
    if (lineno == 9 && atoi(info[9]) >= 20) {
      screenchars = atoi(info[9]);
    }
    if (lineno == 14) {
      ansi = !(len == 1 && s[0] == '0');
    }
    if ((lineno == 17 || lineno == 18) && len > 0 && s[0] == '/') {
      changed = 1;
      memcpy(out + o, dir, strlen(dir));
      o += strlen(dir);
    } else {
      memcpy(out + o, s, len);
      o += len;
    }
    out[o++] = '\r';
    out[o++] = '\n';
    s = *e ? e + 1 : e;
  }
  if (!changed) {
    return;
  }
  f = fopen(path, "wb");
  if (!f) {
    fprintf(stderr, "WWIV4CHN: can't update %s\r\n", path);
    return;
  }
  fwrite(out, 1, o, f);
  fclose(f);
}

/* ----- main ----- */

int main(int argc, char** argv) {
  static char env_fp[] = "WWIV_FP=0000:0000";
  int i;
  int rc;
  unsigned cs;

  if (argc < 2 || strcmp(argv[1], "-?") == 0 || stricmp(argv[1], "/?") == 0) {
    fprintf(stderr,
      "WWIV4CHN - runs a WWIV 3/4 chain on a FOSSIL\r\n"
      "Usage: WWIV4CHN COMMAND [ARGS...]\r\n"
      "Example: WWIV4CHN FOODFITE.COM T:\\CHAIN.TXT\r\n");
    return 255;
  }
  if (fossil(F_INIT, 0) != FOSSIL_SIGNATURE) {
    fprintf(stderr, "WWIV4CHN: no FOSSIL driver (run under WWIVFOSS)\r\n");
    return 255;
  }
  for (i = 2; i < argc; i++) {
    if (stricmp(base_name(argv[i]), "CHAIN.TXT") == 0) {
      fix_chain_txt(argv[i]);
    }
  }

  /* The function table, as WWIV 4.30 passed it. */
  cs = code_segment();
  for (i = 0; i < 20; i++) {
    funcs[i] = api_offsets[i] ? MK_FP(cs, api_offsets[i]) : NULL;
  }
  sprintf(env_fp + 8, "%04X:%04X", FP_SEG(funcs), FP_OFF(funcs));
  putenv("BBS=WWIV v4.30");
  putenv(env_fp);
  if (!getenv("PKNOFASTCHAR")) {
    putenv("PKNOFASTCHAR=Y");  /* keeps PKZIP off the video memory */
  }

  old_int21 = _dos_getvect(0x21);
  old_int29 = _dos_getvect(0x29);
  old_int6a = _dos_getvect(0x6A);
  _dos_setvect(0x6A, (intvec_t)(void __far*)funcs);  /* 4.07-4.20 */
  _dos_setvect(0x21, (intvec_t)int21_handler);
  _dos_setvect(0x29, (intvec_t)int29_handler);
  rc = spawnvp(P_WAIT, argv[1], (const char* const*)&argv[1]);
  flush_out();
  _dos_setvect(0x29, old_int29);
  _dos_setvect(0x21, old_int21);
  _dos_setvect(0x6A, old_int6a);

  if (rc == -1) {
    perror("WWIV4CHN: unable to run command");
    return 255;
  }
  return rc;
}
