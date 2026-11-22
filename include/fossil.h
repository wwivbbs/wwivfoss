/*
 * WWIVFOSS - FOSSIL driver for DOS doors
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * FOSSIL revision 5 constants, from the public FOSSIL specification
 * (FSC-0015 and the X00/BNU documentation).
 */
#ifndef WWIVFOSS_FOSSIL_H
#define WWIVFOSS_FOSSIL_H

#define FOSSIL_SIGNATURE      0x1954
#define FOSSIL_REVISION       5
#define FOSSIL_HIGHEST_FUNC   0x1B

/* Status word returned in AX by most functions (function 03h). */
#define FST_ALWAYS            0x0008  /* AL bit 3, always set */
#define FST_DCD               0x0080  /* AL bit 7, carrier detect */
#define FST_RDA               0x0100  /* AH bit 0, input data available */
#define FST_OVRN              0x0200  /* AH bit 1, input buffer overrun */
#define FST_THRE              0x2000  /* AH bit 5, room in output buffer */
#define FST_TSRE              0x4000  /* AH bit 6, output buffer empty */

/* Function numbers (AH). */
#define F_SET_BAUD            0x00
#define F_TX_WAIT             0x01
#define F_RX_WAIT             0x02
#define F_STATUS              0x03
#define F_INIT                0x04
#define F_DEINIT              0x05
#define F_DTR                 0x06
#define F_TIMER_INFO          0x07
#define F_FLUSH_OUT           0x08
#define F_PURGE_OUT           0x09
#define F_PURGE_IN            0x0A
#define F_TX_NOWAIT           0x0B
#define F_PEEK                0x0C
#define F_KBD_PEEK            0x0D
#define F_KBD_READ            0x0E
#define F_FLOW_CONTROL        0x0F
#define F_CTRL_C              0x10
#define F_SET_CURSOR          0x11
#define F_GET_CURSOR          0x12
#define F_WRITE_ANSI          0x13
#define F_WATCHDOG            0x14
#define F_WRITE_BIOS          0x15
#define F_TIMER_CHAIN         0x16
#define F_REBOOT              0x17
#define F_BLOCK_READ          0x18
#define F_BLOCK_WRITE         0x19
#define F_BREAK               0x1A
#define F_DRIVER_INFO         0x1B
#define F_INIT_EXT            0x1C  /* same as 04h */
#define F_DEINIT_EXT          0x1D  /* same as 05h */

#pragma pack(1)
/* Function 1Bh driver information block. */
struct fossil_info {
  unsigned short size;        /* size of this structure */
  unsigned char  majver;      /* FOSSIL spec revision */
  unsigned char  minver;      /* driver revision */
  unsigned short ident_off;   /* far pointer to ASCIIZ identifier */
  unsigned short ident_seg;
  unsigned short ibufr;       /* input buffer size */
  unsigned short ifree;       /* bytes free in input buffer */
  unsigned short obufr;       /* output buffer size */
  unsigned short ofree;       /* bytes free in output buffer */
  unsigned char  swidth;      /* screen width */
  unsigned char  sheight;     /* screen height */
  unsigned char  baud;        /* baud rate mask, function 00h format */
};
#pragma pack()

#endif /* WWIVFOSS_FOSSIL_H */
