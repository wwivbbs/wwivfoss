; W4TEST - calls a WWIV 4 chain function as Turbo C did
; Copyright 2026 WWIV Software Services
; Licensed under the Apache License, Version 2.0 (see LICENSE).
;
;   unsigned __cdecl wcall(void __far* fn, unsigned nwords, ...);
;
; Pushes the nwords argument words (far pointers are two: offset, segment),
; then PUSHF / CALL FAR fn, as a Turbo C chain calls a "far interrupt"
; function pointer; returns fn's AX. Large model.

.8086

wcall_TEXT segment byte public 'CODE'
        assume  cs:wcall_TEXT
        public  _wcall

_wcall  proc    far
        push    bp
        mov     bp, sp                  ; [bp+6] fn, [bp+10] nwords, [bp+12] words
        push    si
        push    di
        push    ds
        mov     cx, [bp+10]
        mov     si, cx
        shl     si, 1
        add     si, bp
        add     si, 10                  ; the last word
        jcxz    call_it
push_words:
        push    word ptr ss:[si]
        sub     si, 2
        loop    push_words
call_it:
        pushf
        call    dword ptr [bp+6]
        lea     sp, [bp-6]
        pop     ds
        pop     di
        pop     si
        pop     bp
        ret
_wcall  endp

wcall_TEXT ends

        end
