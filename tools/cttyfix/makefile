# CTTYFIX - Open Watcom (wmake) makefile.

AS      = wasm
AFLAGS  = -q -0

cttyfix.com: cttyfix.obj
	wlink option quiet format dos com name $@ file cttyfix.obj

cttyfix.obj: cttyfix.asm
	$(AS) $(AFLAGS) -fo=$@ cttyfix.asm

clean: .SYMBOLIC
	rm -f *.obj *.com *.map *.err
