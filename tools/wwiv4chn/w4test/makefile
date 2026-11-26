# W4TEST - Open Watcom (wmake) makefile. Large model, like a Turbo C chain.

CC      = wcc
AS      = wasm
CFLAGS  = -q -bt=dos -ml -0 -os -wx
AFLAGS  = -q -0 -ml

w4test.exe: w4test.obj wcall.obj
	wlink option quiet system dos name $@ file w4test.obj,wcall.obj

w4test.obj: w4test.c
	$(CC) $(CFLAGS) -fo=$@ w4test.c

wcall.obj: wcall.asm
	$(AS) $(AFLAGS) -fo=$@ wcall.asm

clean: .SYMBOLIC
	rm -f *.obj *.exe *.map *.err
