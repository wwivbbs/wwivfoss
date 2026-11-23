/*
 * WWIVFOSS - FOSSIL driver for DOS doors
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * Contract between WWIVFOSS (DOS side) and the BBS (host side), and the
 * private INT 14h API between a resident copy of WWIVFOSS and WWIVFOSS -U.
 */
#ifndef WWIVFOSS_FOSS_PROTOCOL_H
#define WWIVFOSS_FOSS_PROTOCOL_H

#define WWIVFOSS_PROTOCOL_VERSION 1

/*
 * In-band line control for the uart transport (WWIVFOSS -E).
 *
 * Some emulators (QEMU) don't drop DCD when the socket to the BBS closes,
 * so carrier and DTR travel in the byte stream instead. The framing is the
 * same as DOSBox-X's nullmodem in non-transparent mode, so one BBS-side
 * implementation works with both:
 *
 *   FF FF      a literal FF data byte
 *   FF nn      line state from the other end (nn != FF):
 *                bit 0  RTS
 *                bit 1  DTR   (BBS -> DOS: 0 means the caller hung up;
 *                              DOS -> BBS: 0 means the door hung up)
 *                bit 2  break
 *
 * Both directions start out as RTS|DTR (03h). With -E, the BBS sends FF 00
 * before closing the socket when the caller drops, and hangs up the caller
 * when it receives a line state with DTR clear.
 *
 * Doors that read the UART's modem status register directly (rather than
 * FOSSIL status) would never see the hangup, since the emulator holds DCD
 * high. So when DTR from the BBS goes low, WWIVFOSS puts the UART in
 * loopback mode with OUT2 low, which makes DCD read low; DTR going high
 * again, or closing the port, restores normal mode.
 */
#define WWIVFOSS_INBAND_ESCAPE     0xFF
#define WWIVFOSS_LINE_RTS          0x01
#define WWIVFOSS_LINE_DTR          0x02
#define WWIVFOSS_LINE_BREAK        0x04

/*
 * Private INT 14h API, used by WWIVFOSS -U to find and unload a resident
 * copy. Handled before the port check, so DX is ignored.
 *
 *   AH = 7Eh, BX = 5746h ('WF'), AL = subfunction
 *
 *   AL = 00h  query
 *             returns AX = 5746h, BX = resident PSP segment,
 *                     CX = resident code segment,
 *                     DX = hardware interrupt vector in use (0 if none)
 *   AL = 01h  shut down: close the transport, restore INT 14h
 *             returns AX = 5746h. The caller then frees the PSP block.
 */
#define WWIVFOSS_API_FUNC          0x7E
#define WWIVFOSS_API_MAGIC         0x5746
#define WWIVFOSS_API_QUERY         0x00
#define WWIVFOSS_API_SHUTDOWN      0x01
#define WWIVFOSS_API_STATS         0x02

/*
 *   AL = 02h  statistics: returns AX = 5746h, ES:BX -> struct
 *             wwivfoss_stats (counts of FOSSIL calls handled since load)
 */
#define WWIVFOSS_STATS_FUNCS       0x20
struct wwivfoss_stats {
  unsigned long  total;                        /* all handled calls */
  unsigned short by_func[WWIVFOSS_STATS_FUNCS]; /* per AH, saturating */
};

/*
 * Named pipe names used by the OS/2 pipe transport (planned). These match
 * what wwivd already creates: data on WWIV<node>, control on WWIV<node>C.
 */
#define WWIVFOSS_PIPE_DATA_FMT     "\\PIPE\\WWIV%d"
#define WWIVFOSS_PIPE_CONTROL_FMT  "\\PIPE\\WWIV%dC"
#define WWIVFOSS_CTL_DISCONNECT    'D'  /* host -> DOS: caller hung up */
#define WWIVFOSS_CTL_HANGUP        'H'  /* DOS -> host: door lowered DTR */

#endif /* WWIVFOSS_FOSS_PROTOCOL_H */
