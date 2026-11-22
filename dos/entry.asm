; WWIVFOSS - FOSSIL driver for DOS doors
; Copyright 2026 WWIV Software Services
; Licensed under the Apache License, Version 2.0 (see LICENSE).
;
; INT 14h entry point with the FOSSIL signature header.
;
; FOSSIL detection reads the word at offset 6 of the INT 14h handler
; (must be 1954h) and the byte at offset 8 (highest supported function).
; The C handler can't guarantee that layout, so the vector points here
; and we jump to int14_handler in fossil.c.

.8086

_TEXT   segment word public 'CODE'

        extrn   int14_handler : far
        public  int14_entry

int14_entry:
        jmp     short trampoline        ; offset 0-1
        nop                             ; offset 2
        nop                             ; offset 3
        nop                             ; offset 4
        nop                             ; offset 5
        dw      1954h                   ; offset 6: FOSSIL signature
        db      1Bh                     ; offset 8: highest function
trampoline:
        jmp     far ptr int14_handler

_TEXT   ends

        end
