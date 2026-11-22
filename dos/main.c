/*
 * WWIVFOSS - FOSSIL driver for DOS doors
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * Runner: install the FOSSIL, run the door, remove the FOSSIL.
 */
#include <ctype.h>
#include <process.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wwivfoss.h"

/* DOS command tails are limited to 127 bytes, including "/C ". */
#define MAX_COMMAND 120

struct options g_opts = {1, 'U', 0, 0, 1};
const struct transport* g_transport;

static void usage(void) {
  fprintf(stderr,
    "Usage:\r\n"
    "  WWIVFOSS [options] COMMAND [ARGS...]\r\n"
    "\r\n"
    "Options:\r\n"
    "  -P#   COM port for the uart transport (1-4, default 1)\r\n"
    "  -T?   Transport: U=uart (default), V=vdd, O=OS/2 pipe\r\n"
    "  -N#   Node number (vdd and pipe transports)\r\n"
    "  -C    Force carrier detect on\r\n"
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

int main(int argc, char** argv) {
  char command[MAX_COMMAND + 1];
  const char* comspec;
  int first = 0;
  int i;
  int rc;

  fprintf(stderr, "%s\r\n", fossil_ident());
  command[0] = '\0';

  for (i = 1; i < argc; i++) {
    const char* arg = argv[i];
    if (command[0] == '\0' && (arg[0] == '-' || arg[0] == '/') && arg[1]) {
      const char* val = arg + 2;
      switch (toupper((unsigned char)arg[1])) {
      case 'P': g_opts.port = atoi(val); break;
      case 'T': g_opts.transport = *val; break;
      case 'N': g_opts.node = atoi(val); break;
      case 'C': g_opts.force_carrier = 1; break;
      case 'I': g_opts.idle = (*val != '0'); break;
      case '?': usage(); return 0;
      default:
        fprintf(stderr, "Unknown option: %s\r\n", arg);
        usage();
        return 1;
      }
      continue;
    }
    /* First positional argument starts the door command line. */
    if (!first) {
      first = i;
    }
    if (strlen(command) + strlen(arg) + 1 > MAX_COMMAND) {
      fprintf(stderr, "Command line too long.\r\n");
      return 1;
    }
    if (command[0]) {
      strcat(command, " ");
    }
    strcat(command, arg);
  }

  if (!command[0]) {
    usage();
    return 1;
  }

  g_transport = pick_transport(g_opts.transport);
  if (!g_transport) {
    fprintf(stderr, "Unknown transport: %c\r\n", g_opts.transport);
    return 1;
  }
  if (!g_transport->open()) {
    fprintf(stderr, "Unable to open the %s transport (port %d).\r\n",
            g_transport->name, g_opts.port);
    return 2;
  }
  if (!g_opts.force_carrier && !g_transport->carrier()) {
    fprintf(stderr,
            "Warning: no carrier detect on COM%d. Use -C if your emulator\r\n"
            "doesn't provide DCD on its serial port.\r\n", g_opts.port);
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

  if (rc == -1) {
    perror("WWIVFOSS: unable to run command");
    return 3;
  }
  return rc;
}
