/*
 * WWIVFOSS - FOSSIL driver for DOS doors
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 */
#ifndef WWIVFOSS_WWIVFOSS_H
#define WWIVFOSS_WWIVFOSS_H

#define WWIVFOSS_VERSION "0.1.0-dev"

/* Command line options, shared with the interrupt handler. */
struct options {
  int  port;           /* 1-based COM port number */
  char transport;      /* 'U' uart, 'V' vdd, 'O' OS/2 pipe */
  int  node;           /* node number, for vdd/pipe transports */
  int  force_carrier;  /* report DCD even when the line is down */
  int  idle;           /* release timeslices while doors poll */
  int  inband;         /* -E: line state travels in the byte stream */
};

extern struct options g_opts;

/*
 * A transport moves bytes between the FOSSIL dispatcher and the BBS.
 *
 * Every function except open/close may be called from interrupt context:
 * no DOS calls, no C runtime calls, and never pass the address of a stack
 * local (these modules are built with -zu, so SS != DGROUP).
 */
struct transport {
  const char* name;
  int      (*open)(void);         /* 1 on success */
  void     (*close)(void);
  unsigned (*rx_avail)(void);     /* bytes waiting */
  int      (*rx_peek)(void);      /* next byte, or -1 */
  int      (*rx_get)(void);       /* next byte, or -1 */
  int      (*tx_put)(unsigned char ch); /* 1 if accepted */
  unsigned (*tx_free)(void);      /* bytes of output room */
  int      (*tx_empty)(void);     /* 1 if everything has been sent */
  int      (*carrier)(void);      /* 1 if the caller is connected */
  int      (*overrun)(void);      /* 1 if input was lost; clears flag */
  void     (*set_dtr)(int on);
  void     (*purge_rx)(void);
  void     (*purge_tx)(void);
  unsigned char (*irq_vector)(void); /* hooked hardware vector, or 0 */
};

extern const struct transport uart_transport;
extern const struct transport vdd_transport;
extern const struct transport pipe_transport;

extern const struct transport* g_transport;

/* fossil.c */
void fossil_install(void);
void fossil_remove(void);
const char* fossil_ident(void);
unsigned fossil_entry_segment(void);

#endif /* WWIVFOSS_WWIVFOSS_H */
