; WWIV4CHN - entry points for WWIV 4's chain function table
; Copyright 2026 WWIV Software Services
; Licensed under the Apache License, Version 2.0 (see LICENSE).
;
; WWIV 4.07+ chains call the BBS through a table of far pointers (see
; wwiv4chn.c). Each entry was a Turbo C "far interrupt" function: the chain
; pushes its C arguments (large model: far pointers, 2-byte ints), then
; PUSHF / CALL FAR; the function returns with IRET and the chain pops the
; arguments. Results come back in AX.
;
; The entries below save the chain's registers, switch from the chain's
; stack to our own (so the C code runs with SS = DS = DGROUP) and call
;
;     unsigned __cdecl api_call(unsigned slot, unsigned __far* args);
;
; args points at the chain's arguments, still on its stack. AX on return is
; api_call's result; every other register is the chain's.

.8086

DGROUP  group   _DATA, _BSS

_TEXT   segment byte public 'CODE'
_TEXT   ends
_DATA   segment word public 'DATA'
_DATA   ends
_BSS    segment word public 'BSS'
_BSS    ends

_BSS    segment
chain_ss        dw      ?
chain_sp        dw      ?
                dw      1024 dup (?)    ; 2 KB for api_call
api_stack_top   label   word
_BSS    ends

; Offsets of the entries in _TEXT, by slot; 0 = no function. wwiv4chn.c
; makes far pointers of them (with CS) for the table the chain gets.
_DATA   segment
        public  api_offsets
api_offsets     dw      e0, e1, e2, e3, e4, e5, 0, 0, e8, e9
                dw      e10, e11, e12, e13, e14, e15, e16, e17, e18, e19
_DATA   ends

_TEXT   segment
        assume  cs:_TEXT, ds:DGROUP
        extrn   _api_call : near

; BX = slot; the chain's BX is on the stack, above IP, CS and FLAGS.
common:
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        mov     si, sp
        add     si, 22                  ; 8 saved words, IP, CS, FLAGS
        mov     di, ss                  ; DI:SI = the chain's arguments
        mov     ax, DGROUP
        mov     ds, ax
        mov     chain_ss, di
        mov     chain_sp, sp
        cli
        mov     ss, ax
        mov     sp, offset DGROUP:api_stack_top
        sti
        cld
        push    di
        push    si
        push    bx
        call    _api_call               ; result in AX
        cli
        mov     ss, chain_ss            ; DS is still DGROUP
        mov     sp, chain_sp
        sti
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        iret

e0:     push    bx
        mov     bx, 0
        jmp     common
e1:     push    bx
        mov     bx, 1
        jmp     common
e2:     push    bx
        mov     bx, 2
        jmp     common
e3:     push    bx
        mov     bx, 3
        jmp     common
e4:     push    bx
        mov     bx, 4
        jmp     common
e5:     push    bx
        mov     bx, 5
        jmp     common
e8:     push    bx
        mov     bx, 8
        jmp     common
e9:     push    bx
        mov     bx, 9
        jmp     common
e10:    push    bx
        mov     bx, 10
        jmp     common
e11:    push    bx
        mov     bx, 11
        jmp     common
e12:    push    bx
        mov     bx, 12
        jmp     common
e13:    push    bx
        mov     bx, 13
        jmp     common
e14:    push    bx
        mov     bx, 14
        jmp     common
e15:    push    bx
        mov     bx, 15
        jmp     common
e16:    push    bx
        mov     bx, 16
        jmp     common
e17:    push    bx
        mov     bx, 17
        jmp     common
e18:    push    bx
        mov     bx, 18
        jmp     common
e19:    push    bx
        mov     bx, 19
        jmp     common

_TEXT   ends

        end
