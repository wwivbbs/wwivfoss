/*
 * WWIV4CHN - runs a WWIV 3.x/4.x chain on a FOSSIL
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 *   WWIV4CHN COMMAND [ARGS...]
 *
 * WWIV 3 and 4 ran chains with "DOS interrupts" on: the chain talked to the
 * caller through DOS's console calls and WWIV sent them to the modem. This
 * does the same on a FOSSIL (WWIVFOSS): it hooks INT 21h and INT 29h, runs
 * COMMAND, and while it runs
 *
 *   - console output (INT 21h 02h, 06h, 09h, 40h on a console handle, and
 *     INT 29h) goes to the caller, with WWIV heart codes (^C0-^C9) turned
 *     into ANSI colors and ^L into a screen clear;
 *   - console input (01h, 06h, 07h, 08h, 0Ah, 0Ch, 3Fh on a console
 *     handle) comes from the caller, and the input status calls (0Bh, 06h
 *     with DL=FFh) say whether the caller has typed something;
 *   - when the caller hangs up, the chain's next console call ends it.
 *
 * Nothing goes to the local screen. Programs that write to video memory
 * or use the BIOS for the screen or keyboard aren't covered; WWIV 3 and 4
 * didn't cover them either.
 *
 * CHAIN.TXT: when an argument names a file called CHAIN.TXT, its gfiles and
 * data directory lines (17, 18) are pointed at that file's directory if they
 * hold Unix paths (WWIV 5 on Linux), since WWIV 4 chains write there. Its
 * ANSI line (14) decides whether heart codes become colors or are dropped.
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

/* WWIV 4's default colors for ^C0-^C9 (PC attributes). */
static const unsigned char colors[10] = {7, 11, 14, 5, 31, 2, 12, 9, 6, 3};
static const char pc_to_ansi[8] = "04261537";

static intvec_t old_int21;
static intvec_t old_int29;
static int ansi = 1;          /* heart codes to colors, else dropped */
static int in_handler;
static int after_heart;
static int hung_up;

static unsigned char outbuf[256];
static unsigned outlen;

/* Cooked console input (3Fh): one line, handed out across calls. */
static char line[130];
static unsigned line_len;
static unsigned line_pos;

/* ----- FOSSIL ----- */

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

static void out_str(const char* s) {
  while (*s) {
    out_byte((unsigned char)*s++);
  }
}

/* SGR for a PC attribute: ESC[0;1;5;3x;4ym. */
static void out_color(unsigned char attr) {
  out_str("\x1b[0");
  if (attr & 0x08) {
    out_str(";1");
  }
  if (attr & 0x80) {
    out_str(";5");
  }
  out_str(";3");
  out_byte(pc_to_ansi[attr & 7]);
  out_str(";4");
  out_byte(pc_to_ansi[(attr >> 4) & 7]);
  out_byte('m');
}

/* Program output, with WWIV's codes translated. */
static void out_char(unsigned char c) {
  if (after_heart) {
    after_heart = 0;
    if (ansi && c >= '0' && c <= '9') {
      out_color(colors[c - '0']);
    }
    return;
  }
  if (c == 0x03) {
    after_heart = 1;
  } else if (c == 0x0C && ansi) {
    out_str("\x1b[2J\x1b[H");
  } else {
    out_byte(c);
  }
}

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

/* DOS-style line input into buf (at most max-1 characters, then CR).
   Returns the length, without the CR; -1 on hang-up. */
static int read_line(char __far* buf, unsigned max) {
  unsigned n = 0;
  int c;
  if (max == 0) {
    return 0;
  }
  for (;;) {
    c = get_key();
    if (c < 0) {
      return -1;
    }
    if (c == '\r') {
      buf[n] = '\r';
      out_byte('\r');
      flush_out();
      return n;
    }
    if (c == 8 || c == 127) {
      if (n > 0) {
        --n;
        out_str("\b \b");
      }
    } else if (c >= ' ' && n + 1 < max) {
      buf[n++] = (char)c;
      out_byte((unsigned char)c);
    }
    flush_out();
  }
}

/* ----- DOS ----- */

/* True if the handle is the console: a device, standard input (bit 0) or
   output (bit 1). Asks DOS itself (in_handler is set). */
static int is_console(unsigned handle, unsigned bit) {
  unsigned info = dos_dev_info(handle);
  return (info & 0x80) && (info & bit);
}

/* The caller's registers that console_input() reads and sets. */
static unsigned char in_al;
static unsigned in_flags;
static unsigned in_ds;
static unsigned in_dx;

/* Runs console input function fn (01h, 06h with DL = FFh, 07h, 08h,
   0Ah). On hang-up hung_up is set and the handler ends the program. */
static void console_input(unsigned char fn) {
  static int c;
  static unsigned char __far* buf;
  switch (fn) {
  case 0x01:  /* read with echo */
    c = get_key();
    if (c >= 0) {
      out_byte((unsigned char)c);
      flush_out();
    }
    in_al = (unsigned char)c;
    break;
  case 0x06:  /* direct console input */
    if (key_waiting()) {
      in_al = (unsigned char)get_key();
      in_flags &= ~ZF;
    } else {
      in_al = 0;
      in_flags |= ZF;
    }
    break;
  case 0x07:  /* read without echo */
  case 0x08:
    in_al = (unsigned char)get_key();
    break;
  case 0x0A:  /* buffered input: DS:DX = max, count, text */
    buf = (unsigned char __far*)MK_FP(in_ds, in_dx);
    c = read_line((char __far*)buf + 2, buf[0]);
    buf[1] = (unsigned char)(c < 0 ? 0 : c);
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
  static int len;

  fn = r.h.ah;
  if (in_handler) {
    _chain_intr(old_int21);
  }
  switch (fn) {
  case 0x01: case 0x02: case 0x06: case 0x07: case 0x08: case 0x09:
  case 0x0A: case 0x0B: case 0x0C: case 0x3F: case 0x40:
    break;
  default:
    _chain_intr(old_int21);
  }
  in_handler = 1;
  _enable();

  switch (fn) {
  case 0x02:
    out_char(r.h.dl);
    flush_out();
    break;
  case 0x06:
    if (r.h.dl == 0xFF) {
      CONSOLE_INPUT(0x06);
    } else {
      out_char(r.h.dl);
      flush_out();
    }
    break;
  case 0x09:
    p = (unsigned char __far*)MK_FP(r.w.ds, r.w.dx);
    for (i = 0; p[i] != '$' && i < 0xFFFF; i++) {
      out_char(p[i]);
    }
    flush_out();
    r.h.al = '$';
    break;
  case 0x0B:
    r.h.al = key_waiting() ? 0xFF : 0x00;
    break;
  case 0x0C:  /* flush input, then run function AL */
    fossil(F_PURGE_IN, 0);
    line_len = line_pos = 0;
    if (r.h.al == 0x06 && r.h.dl != 0xFF) {
      out_char(r.h.dl);
      flush_out();
    } else {
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
      len = read_line(line, sizeof(line) - 1);
      if (len < 0) {
        line_len = 0;
      } else {
        line[len] = '\r';
        line[len + 1] = '\n';
        line_len = len + 2;
        out_byte('\n');
        flush_out();
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
      out_char(p[i]);
    }
    flush_out();
    r.w.ax = r.w.cx;
    r.w.flags &= ~INTR_CF;
    break;
  default:  /* 01h, 07h, 08h, 0Ah */
    CONSOLE_INPUT(fn);
    break;
  }

  in_handler = 0;
  if (hung_up) {
    /* End the chain, as WWIV did when the caller dropped carrier. */
    r.w.ax = 0x4C00;
    _chain_intr(old_int21);
  }
}

static void __interrupt __far int29_handler(union INTPACK r) {
  if (in_handler) {
    _chain_intr(old_int29);
  }
  in_handler = 1;
  _enable();
  out_char(r.h.al);
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

/* Reads CHAIN.TXT: sets ansi from line 14, and points Unix paths on lines
   17 and 18 at the file's own directory. */
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
  int i;
  int rc;

  if (argc < 2 || strcmp(argv[1], "-?") == 0 || stricmp(argv[1], "/?") == 0) {
    fprintf(stderr,
      "WWIV4CHN - runs a WWIV 3/4 chain (DOS console I/O) on a FOSSIL\r\n"
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

  old_int21 = _dos_getvect(0x21);
  old_int29 = _dos_getvect(0x29);
  _dos_setvect(0x21, (intvec_t)int21_handler);
  _dos_setvect(0x29, (intvec_t)int29_handler);
  rc = spawnvp(P_WAIT, argv[1], (const char* const*)&argv[1]);
  flush_out();
  _dos_setvect(0x29, old_int29);
  _dos_setvect(0x21, old_int21);

  if (rc == -1) {
    perror("WWIV4CHN: unable to run command");
    return 255;
  }
  return rc;
}
