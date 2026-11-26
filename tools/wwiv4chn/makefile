# WWIV4CHN - Open Watcom (wmake) makefile.

CC      = wcc
# -zu: the INT 21h handler runs on the chain's stack (SS != DGROUP).
CFLAGS  = -q -bt=dos -ms -0 -os -s -wx -zu -i=../../include

wwiv4chn.exe: wwiv4chn.obj
	wlink option quiet system dos name $@ file wwiv4chn.obj

wwiv4chn.obj: wwiv4chn.c ../../include/fossil.h
	$(CC) $(CFLAGS) -fo=$@ wwiv4chn.c

clean: .SYMBOLIC
	rm -f *.obj *.exe *.map *.err
