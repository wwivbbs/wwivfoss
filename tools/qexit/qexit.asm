; QEXIT - powers QEMU off from DOS, with an exit code
; Copyright 2026 WWIV Software Services
; Licensed under the Apache License, Version 2.0 (see LICENSE).
;
;   QEXIT [n]       n = 0-9, default 0
;   QEXIT --help    usage (also -h, -? and /?)
;
; QEMU must be started with
;
;   -device isa-debug-exit,iobase=0xf4,iosize=0x04
;
; A write to port F4h then ends QEMU at once, with exit code
; (n << 1) | 1: QEXIT 0 exits with 1, QEXIT 1 with 3, and so on (never 0,
; which is QEMU's own normal exit). The door launchers (qemudoor.sh,
; qemudoor.cmd) run QEXIT after the door; the tests use n to report a
; result.
;
; QEMU stops without DOS knowing, so first QEXIT asks DOS to write out
; its disk buffers (INT 21h AH=0Dh). Otherwise sectors DOS still holds,
; such as the FAT and directory entries of files the door just closed,
; never reach the disk; with a QEMU vvfat (fat:rw:) drive those files
; then come out short or missing on the host.
;
; Without isa-debug-exit (real DOS, DOSBox-X, QEMU started without it)
; the OUT does nothing, and QEXIT returns to DOS with errorlevel n.

.8086
_TEXT   segment byte public 'CODE'
        assume cs:_TEXT, ds:_TEXT, es:_TEXT, ss:_TEXT
        org 100h

DEBUG_EXIT equ 0F4h             ; isa-debug-exit's I/O port

start:
        cld
        xor bl, bl              ; BL = exit code n
        mov si, 81h             ; command tail
        mov cl, ds:[80h]        ; its length
        xor ch, ch
skip:   jcxz quit               ; no argument: n = 0
        lodsb
        dec cx
        cmp al, ' '
        je skip
        cmp al, 9               ; tab
        je skip

        ; The first character of the argument. A digit alone is n.
        mov ah, al
        sub ah, '0'
        cmp ah, 9
        ja usage                ; not a digit: --help, -h, -?, /? or junk
        mov bl, ah
        jcxz quit               ; digit at the end of the tail
        mov al, [si]
        cmp al, ' '
        je quit
        cmp al, 9
        je quit
        cmp al, 13
        je quit
        jmp short usage         ; more than one digit

quit:
        mov ah, 0Dh             ; disk reset: flush all DOS disk buffers
        int 21h
        mov al, bl
        out DEBUG_EXIT, al      ; QEMU exits here
        mov ah, 4Ch             ; not under QEMU: return errorlevel n
        int 21h

usage:
        ; Help asked for (--help, -h, -?, /?): errorlevel 0. Any other
        ; argument is a mistake: errorlevel 2. Either way, don't power off.
        mov bl, 2
        cmp al, '/'
        je help
        cmp al, '-'
        jne show
help:   xor bl, bl
show:   mov dx, offset usage_text
        mov ah, 09h
        int 21h
        mov al, bl
        mov ah, 4Ch
        int 21h

usage_text:
        db 'QEXIT - powers QEMU off, with an exit code', 13, 10
        db 13, 10
        db '  QEXIT [n]     n = 0-9 (default 0); QEMU exits with (n << 1) | 1', 13, 10
        db '  QEXIT --help  this help', 13, 10
        db 13, 10
        db 'Needs QEMU started with', 13, 10
        db '  -device isa-debug-exit,iobase=0xf4,iosize=0x04', 13, 10
        db 'DOS disk buffers are flushed first. Without that device, QEXIT', 13, 10
        db 'returns to DOS with errorlevel n.', 13, 10
        db '$'

_TEXT   ends
        end start
