/*
 * WWIVFOSS - FOSSIL driver for DOS doors
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * Placeholders for the planned transports (see docs/design.md):
 *   vdd  - Windows NTVDM / NTVDMx64, BOP into vdd/ DLL
 *   pipe - OS/2 VDM named pipes, \PIPE\WWIV<node> and \PIPE\WWIV<node>C
 *
 * open() fails, so none of the other functions are ever called.
 */
#include <stdio.h>

#include "wwivfoss.h"

static int vdd_open(void) {
  fprintf(stderr, "WWIVFOSS: the vdd transport is not implemented yet.\r\n");
  return 0;
}

static int pipe_open(void) {
  fprintf(stderr, "WWIVFOSS: the OS/2 pipe transport is not implemented yet.\r\n");
  return 0;
}

static void stub_close(void) {}
static unsigned stub_zero(void) { return 0; }
static int stub_none(void) { return -1; }
static int stub_put(unsigned char c) { (void)c; return 0; }
static int stub_false(void) { return 0; }
static void stub_set(int on) { (void)on; }

const struct transport vdd_transport = {
  "vdd",
  vdd_open, stub_close, stub_zero, stub_none, stub_none, stub_put,
  stub_zero, stub_false, stub_false, stub_false, stub_set, stub_close,
  stub_close,
};

const struct transport pipe_transport = {
  "pipe",
  pipe_open, stub_close, stub_zero, stub_none, stub_none, stub_put,
  stub_zero, stub_false, stub_false, stub_false, stub_set, stub_close,
  stub_close,
};
