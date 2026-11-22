/*
 * WWIVFOSS - FOSSIL driver for DOS doors
 * Copyright 2026 WWIV Software Services
 * Licensed under the Apache License, Version 2.0 (see LICENSE).
 *
 * Contract between WWIVFOSS (DOS side) and the BBS (host side).
 *
 * DRAFT. Nothing here is implemented yet. The uart transport currently uses
 * a raw byte stream with carrier on the DCD line; see docs/design.md
 * ("Open questions") for why an in-band control channel may be needed.
 */
#ifndef WWIVFOSS_FOSS_PROTOCOL_H
#define WWIVFOSS_FOSS_PROTOCOL_H

#define WWIVFOSS_PROTOCOL_VERSION 0

/*
 * Named pipe names used by the OS/2 pipe transport. These match what wwivd
 * already creates: data on WWIV<node>, control on WWIV<node>C.
 */
#define WWIVFOSS_PIPE_DATA_FMT     "\\PIPE\\WWIV%d"
#define WWIVFOSS_PIPE_CONTROL_FMT  "\\PIPE\\WWIV%dC"

/* Control codes sent on the control pipe. */
#define WWIVFOSS_CTL_DISCONNECT    'D'  /* host -> DOS: caller hung up */
#define WWIVFOSS_CTL_HANGUP        'H'  /* DOS -> host: door lowered DTR */

/*
 * Reserved: optional in-band control framing for the uart transport, to be
 * enabled only when both ends are WWIVFOSS-aware (negotiated at startup).
 * An escape byte followed by a command byte would carry carrier, DTR and
 * break, with the escape byte doubled for literal data.
 */
#define WWIVFOSS_INBAND_ESCAPE     0x00  /* placeholder, not final */

#endif /* WWIVFOSS_FOSS_PROTOCOL_H */
