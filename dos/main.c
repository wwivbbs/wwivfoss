/*
 * WWIVFOSS - FOSSIL driver for DOS doors
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * Three ways to run:
 *   WWIVFOSS [options] COMMAND   runner: install, run COMMAND, remove
 *   WWIVFOSS -L [options]        load resident (TSR)
 *   WWIVFOSS -U                  unload the resident copy
 */
#include <ctype.h>
#include <dos.h>
#include <i86.h>
#include <process.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "foss_protocol.h"
#include "wwivfoss.h"

/* DOS command tails are limited to 127 bytes, including "/C ". */
#define MAX_COMMAND 120

/* Exit codes. A runner otherwise returns the door's own exit code. */
#define EXIT_USAGE      1
#define EXIT_TRANSPORT  2
#define EXIT_SPAWN      3
#define EXIT_LOADED     4   /* -L: already resident */
#define EXIT_NOT_LOADED 5   /* -U: nothing to unload */
#define EXIT_HOOKED     6   /* -U: another program hooked our vectors */
#define EXIT_FREE       7   /* -U: couldn't free the resident memory */

struct options g_opts = {1, 'U', 0, 0, 1, 0, NULL};
const struct transport* g_transport;

static void usage(void) {
  fprintf(stderr,
    "Usage:\r\n"
    "  WWIVFOSS [options] COMMAND [ARGS...]   run a door, then unload\r\n"
    "  WWIVFOSS -L [options]                  load resident\r\n"
    "  WWIVFOSS -U                            unload resident copy\r\n"
    "\r\n"
    "Options:\r\n"
    "  -P#   COM port for the uart transport (1-4, default 1)\r\n"
    "  -E    In-band line control (carrier/DTR in the byte stream;\r\n"
    "        needed for QEMU, see foss_protocol.h)\r\n"
    "  -C    Force carrier detect on\r\n"
    "  -Sfile Write FOSSIL call counts to file when the door exits\r\n"
    "        (runner) or on -U (resident)\r\n"
    "  -T?   Transport: U=uart (default), V=vdd, O=OS/2 pipe\r\n"
    "  -N#   Node number (vdd and pipe transports)\r\n"
    "  -I0   Don't release timeslices while doors poll\r\n"
    "  -?    This help\r\n"
    "\r\n"
    "Example:\r\n"
    "  WWIVFOSS -P1 C:\\DOORS\\LORD\\START.BAT 1\r\n");
}

static const struct transport* pick_transport(char t) {
  switch (toupper((unsigned char)t)) {
  case 'U': return &uart_transport;
  case 'V': return &vdd_transport;
  case 'O': return &pipe_transport;
  }
  return NULL;
}

/* True if the program name has a .BAT extension. */
static int is_batch(const char* prog) {
  const char* dot = strrchr(prog, '.');
  const char* slash = strrchr(prog, '\\');
  if (!dot || (slash && slash > dot)) {
    return 0;
  }
  return stricmp(dot, ".BAT") == 0;
}

/* Calls the private API of a resident copy. Returns 1 if one answered. */
static int resident_api(unsigned char subfn, union REGS* out) {
  union REGS r;
  memset(&r, 0, sizeof(r));
  r.h.ah = WWIVFOSS_API_FUNC;
  r.h.al = subfn;
  r.x.bx = WWIVFOSS_API_MAGIC;
  int86(0x14, &r, out);
  return out->x.ax == WWIVFOSS_API_MAGIC;
}

/* Writes FOSSIL call counts to g_opts.stats_file (if set). */
static void write_stats(const struct wwivfoss_stats __far* st) {
  FILE* f;
  unsigned i;
  if (!g_opts.stats_file || !*g_opts.stats_file) {
    return;
  }
  f = fopen(g_opts.stats_file, "w");
  if (!f) {
    fprintf(stderr, "Can't write %s\r\n", g_opts.stats_file);
    return;
  }
  fprintf(f, "total %lu\n", st->total);
  for (i = 0; i < WWIVFOSS_STATS_FUNCS; i++) {
    if (st->by_func[i]) {
      fprintf(f, "%02X %u\n", i, st->by_func[i]);
    }
  }
  fclose(f);
}

static int open_transport(void) {
  g_transport = pick_transport(g_opts.transport);
  if (!g_transport) {
    fprintf(stderr, "Unknown transport: %c\r\n", g_opts.transport);
    return 0;
  }
  if (!g_transport->open()) {
    fprintf(stderr, "Unable to open the %s transport (port %d).\r\n",
            g_transport->name, g_opts.port);
    return 0;
  }
  if (!g_opts.force_carrier && !g_transport->carrier()) {
    fprintf(stderr,
            "Warning: no carrier detect on COM%d. Use -C if your emulator\r\n"
            "doesn't provide DCD on its serial port.\r\n", g_opts.port);
  }
  return 1;
}

static int run_door(char** argv, int first, const char* command) {
  const char* comspec;
  int rc;

  if (!open_transport()) {
    return EXIT_TRANSPORT;
  }
  /* Ctrl-Break must not kill us while our vectors are installed. */
  signal(SIGINT, SIG_IGN);
  signal(SIGBREAK, SIG_IGN);

  fossil_install();
  /*
   * Run .EXE/.COM doors directly so their exit code comes back (COMMAND /C
   * doesn't return it on every DOS) and the shell doesn't sit in memory
   * under the door. Batch files, and anything not found on PATH, go
   * through COMSPEC /C.
   */
  rc = -1;
  if (!is_batch(argv[first])) {
    rc = spawnvp(P_WAIT, argv[first], (const char* const*)&argv[first]);
  }
  if (rc == -1) {
    comspec = getenv("COMSPEC");
    if (!comspec) {
      comspec = "COMMAND.COM";
    }
    rc = spawnl(P_WAIT, comspec, comspec, "/C", command, NULL);
  }
  fossil_remove();
  g_transport->close();
  write_stats(fossil_stats());

  if (rc == -1) {
    perror("WWIVFOSS: unable to run command");
    return EXIT_SPAWN;
  }
  return rc;
}

static int load_resident(void) {
  union REGS r;
  unsigned __far* env_seg;
  unsigned paras;

  if (resident_api(WWIVFOSS_API_QUERY, &r)) {
    printf("WWIVFOSS is already resident.\r\n");
    return EXIT_LOADED;
  }
  if (!open_transport()) {
    return EXIT_TRANSPORT;
  }
  fossil_install();

  /* Release our copy of the environment; the TSR doesn't need it. */
  env_seg = (unsigned __far*)MK_FP(_psp, 0x2C);
  if (*env_seg) {
    _dos_freemem(*env_seg);
    *env_seg = 0;
  }
  /* Keep the whole block the C runtime sized for us (from its MCB). */
  paras = *(unsigned __far*)MK_FP(_psp - 1, 3);
  printf("WWIVFOSS resident on COM%d (%u KB)%s. WWIVFOSS -U unloads.\r\n",
          g_opts.port, (paras + 63) / 64, g_opts.inband ? ", in-band" : "");
  fflush(stdout);
  fflush(stderr);
  _dos_keep(0, paras);
  return 0;  /* not reached */
}

static int unload_resident(void) {
  union REGS r;
  unsigned psp, seg, vec;
  void (__interrupt __far* v)(void);

  if (!resident_api(WWIVFOSS_API_QUERY, &r)) {
    printf("WWIVFOSS is not resident.\r\n");
    return EXIT_NOT_LOADED;
  }
  psp = r.x.bx;
  seg = r.x.cx;
  vec = r.x.dx;

  /* Like BNU: refuse if something hooked our vectors after we loaded. */
  v = _dos_getvect(0x14);
  if (FP_SEG(v) != seg) {
    printf("Can't unload: INT 14h was hooked by another program.\r\n");
    return EXIT_HOOKED;
  }
  if (vec) {
    v = _dos_getvect(vec);
    if (FP_SEG(v) != seg) {
      printf("Can't unload: INT %02Xh was hooked by another program.\r\n", vec);
      return EXIT_HOOKED;
    }
  }

  {
    union REGS sr_in;
    struct SREGS sregs;
    memset(&sr_in, 0, sizeof(sr_in));
    sr_in.h.ah = WWIVFOSS_API_FUNC;
    sr_in.h.al = WWIVFOSS_API_STATS;
    sr_in.x.bx = WWIVFOSS_API_MAGIC;
    segread(&sregs);
    int86x(0x14, &sr_in, &r, &sregs);
    if (r.x.ax == WWIVFOSS_API_MAGIC) {
      write_stats((const struct wwivfoss_stats __far*)MK_FP(sregs.es, r.x.bx));
    }
  }

  resident_api(WWIVFOSS_API_SHUTDOWN, &r);

  /*
   * The resident copy restored INT 14h and its IRQ. If any other vector
   * still points into its memory (the C runtime hooking something at
   * startup, say), freeing the block would leave a dangling handler, so
   * leave the memory allocated instead.
   */
  {
    unsigned long lo = (unsigned long)psp << 4;
    unsigned long hi = lo + ((unsigned long)*(unsigned __far*)MK_FP(psp - 1, 3) << 4);
    unsigned n;
    for (n = 0; n < 256; n++) {
      unsigned long a;
      if (n == 0x30 || n == 0x31) {
        continue;  /* not vectors: DOS's CP/M "CALL 5" far jump lives here */
      }
      v = _dos_getvect(n);
      a = ((unsigned long)FP_SEG(v) << 4) + FP_OFF(v);
      if (a >= lo && a < hi) {
        printf("Unloaded, but INT %02Xh still points into it; "
                "leaving its memory allocated.\r\n", n);
        return EXIT_FREE;
      }
    }
  }

  if (_dos_freemem(psp) != 0) {
    printf("Unloaded, but couldn't free its memory (PSP %04X).\r\n", psp);
    return EXIT_FREE;
  }
  printf("WWIVFOSS unloaded.\r\n");
  return 0;
}

int main(int argc, char** argv) {
  char command[MAX_COMMAND + 1];
  int first = 0;
  int load = 0;
  int unload = 0;
  int i;

  fprintf(stderr, "%s\r\n", fossil_ident());
  command[0] = '\0';

  for (i = 1; i < argc; i++) {
    const char* arg = argv[i];
    if (!first && (arg[0] == '-' || arg[0] == '/') && arg[1]) {
      const char* val = arg + 2;
      switch (toupper((unsigned char)arg[1])) {
      case 'P': g_opts.port = atoi(val); break;
      case 'E': g_opts.inband = 1; break;
      case 'C': g_opts.force_carrier = 1; break;
      case 'S': g_opts.stats_file = val; break;
      case 'T': g_opts.transport = *val; break;
      case 'N': g_opts.node = atoi(val); break;
      case 'I': g_opts.idle = (*val != '0'); break;
      case 'L': load = 1; break;
      case 'U': unload = 1; break;
      case '?': usage(); return 0;
      default:
        fprintf(stderr, "Unknown option: %s\r\n", arg);
        usage();
        return EXIT_USAGE;
      }
      continue;
    }
    /* First positional argument starts the door command line. */
    if (!first) {
      first = i;
    }
    if (strlen(command) + strlen(arg) + 1 > MAX_COMMAND) {
      fprintf(stderr, "Command line too long.\r\n");
      return EXIT_USAGE;
    }
    if (command[0]) {
      strcat(command, " ");
    }
    strcat(command, arg);
  }

  if (load + unload + (first != 0) != 1) {
    usage();
    return EXIT_USAGE;
  }
  if (unload) {
    return unload_resident();
  }
  if (load) {
    return load_resident();
  }
  return run_door(argv, first, command);
}
