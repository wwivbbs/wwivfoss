# QEXIT - Open Watcom (wmake) makefile.

AS      = wasm
AFLAGS  = -q -0

qexit.com: qexit.obj
	wlink option quiet format dos com name $@ file qexit.obj

qexit.obj: qexit.asm
	$(AS) $(AFLAGS) -fo=$@ qexit.asm

clean: .SYMBOLIC
	rm -f *.obj *.com *.map *.err
