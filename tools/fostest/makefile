# FOSTEST - Open Watcom (wmake) makefile.

CC      = wcc
CFLAGS  = -q -bt=dos -ms -0 -os -wx -i=../../include

fostest.exe: fostest.obj
	wlink option quiet system dos name $@ file fostest.obj

fostest.obj: fostest.c ../../include/fossil.h
	$(CC) $(CFLAGS) -fo=$@ fostest.c

clean: .SYMBOLIC
	rm -f *.obj *.exe *.map *.err
