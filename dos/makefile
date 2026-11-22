# WWIVFOSS - Open Watcom (wmake) makefile.
#
#   wmake          build WWIVFOSS.EXE
#   wmake clean

CC      = wcc
AS      = wasm
# -ms small model, -0 8086, -os optimise for size, -s no stack checks.
CFLAGS  = -q -bt=dos -ms -0 -os -s -wx -i=../include
# Modules that run in interrupt context: don't assume SS == DGROUP.
ISRFLAGS = -zu
AFLAGS  = -q -0

OBJS = main.obj fossil.obj entry.obj uart.obj stubs.obj

wwivfoss.exe: $(OBJS)
	wlink option quiet system dos name $@ file { $(OBJS) } option map

main.obj: main.c wwivfoss.h
	$(CC) $(CFLAGS) -fo=$@ main.c

fossil.obj: fossil.c wwivfoss.h ../include/fossil.h
	$(CC) $(CFLAGS) $(ISRFLAGS) -fo=$@ fossil.c

uart.obj: uart.c wwivfoss.h
	$(CC) $(CFLAGS) $(ISRFLAGS) -fo=$@ uart.c

stubs.obj: stubs.c wwivfoss.h
	$(CC) $(CFLAGS) -fo=$@ stubs.c

entry.obj: entry.asm
	$(AS) $(AFLAGS) -fo=$@ entry.asm

clean: .SYMBOLIC
	rm -f *.obj *.exe *.map *.err
