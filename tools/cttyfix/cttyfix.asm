; CTTYFIX - makes DOS's "is a key waiting?" calls truthful when the console
; is redirected to COM1 (CTTY COM1) under DOSBox-X. Used by
; configs/wwiv/wwivchain.sh for old WWIV 4.x chains.
;
; DOSBox-X's COM1 device always reports input ready, so INT 21h AH=0Bh
; returns FFh and AH=06h DL=FFh goes on to wait for a byte even with none
; waiting. A Turbo Pascal 3 keyboard flush (while KeyPressed do
; Read(Kbd, ch)) then never ends, and swallows the caller's keys: Food
; Fight 2.00c hangs at its first screen clear.
;
; This TSR answers both calls from the UART's line status register (COM1
; at 3F8h, LSR bit 0 = data ready) and passes everything else on to DOS.
; Load it before the chain: CTTYFIX.COM, then the program. It stays
; resident (about 100 bytes) and can't be unloaded.

.8086
_TEXT   segment byte public 'CODE'
        assume cs:_TEXT, ds:_TEXT
        org 100h

LSR     equ 3FDh                ; COM1 line status register
ZF      equ 40h                 ; zero flag in FLAGS

start:  jmp init

old21   dd ?

; INT 21h handler.
new21:
        cmp ah, 0Bh             ; check input status
        je status
        cmp ah, 06h             ; direct console I/O ...
        jne chain
        cmp dl, 0FFh            ; ... input
        jne chain
        push ax
        push dx
        mov dx, LSR
        in al, dx
        pop dx
        test al, 1
        pop ax
        jnz chain               ; a byte is waiting: let DOS read it
        xor al, al              ; none: AL = 0, ZF set
        push bp
        mov bp, sp
        or word ptr [bp+6], ZF  ; caller's FLAGS (above BP, IP, CS)
        pop bp
        iret
status:
        push dx
        mov dx, LSR
        in al, dx
        pop dx
        and al, 1
        neg al                  ; 1 -> FFh (waiting), 0 -> 0
        iret
chain:
        jmp dword ptr cs:[old21]

; Not kept resident.
init:
        mov ax, 3521h
        int 21h
        mov word ptr old21, bx
        mov word ptr old21+2, es
        mov dx, offset new21
        mov ax, 2521h
        int 21h
        mov dx, offset init + 15 ; keep PSP .. init, in paragraphs
        mov cl, 4
        shr dx, cl
        mov ax, 3100h            ; terminate and stay resident
        int 21h

_TEXT   ends
        end start
