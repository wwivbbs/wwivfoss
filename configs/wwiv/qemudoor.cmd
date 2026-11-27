@echo off
rem Runs a DOS door under QEMU (FreeDOS) with WWIVFOSS for a WWIV chain on
rem Windows: the Windows counterpart of qemudoor.sh, with the same arguments
rem as dosdoor.cmd. WWIV listens on a local port (%Z) and QEMU connects its
rem COM1 to it.
rem
rem   qemudoor.cmd [-r|--raw] PORT TEMPDIR DOORDIR COMMAND [ARGS...]
rem
rem Match the chain's exec mode (ChainEdit, E) Exec Mode):
rem
rem   "WWIVFOSS (Socket Port)"   (recommended) no option. WWIVFOSS runs with
rem                              -E -H10: QEMU never drops carrier, so
rem                              hang-ups come in-band.
rem   "Listen Socket Port"       -r / --raw. WWIVFOSS runs with -E-. The door
rem                              never sees a hang-up; WWIV stops QEMU.
rem
rem Example chain command line:
rem
rem   C:\wwiv\doors\qemudoor.cmd %Z %I C:\wwiv\doors\gw WAR.EXE /W T:\CHAIN.TXT
rem
rem Unlike qemudoor.sh, no disk images are built for each call (Windows has
rem no mtools): QEMU shows DOS the directories themselves, as FAT drives
rem (vvfat, "fat:rw:"), and writes the door's changes straight back.
rem
rem Inside DOS:
rem   C:  the door's directory (DOORDIR); COMMAND runs from C:\
rem   D:  this node's WWIV temp directory (%I), with the drop files. T: is
rem       the same drive (SWSUBST), so point the door's drop file path at
rem       T:\ as with dosdoor.cmd. WWIVFOSS.EXE, SWSUBST.EXE, QEXIT.COM and
rem       WWIV4CHN.EXE (if present) are copied here for the call, and D:\ is
rem       on PATH.
rem   A:  the FreeDOS boot floppy, never changed (QEMU snapshot=on).
rem
rem One node at a time per door: vvfat doesn't share a directory with
rem another QEMU. Set the chain's Multi user to No.
rem
rem Next to this script:
rem   WWIVFOSS.EXE
rem   SWSUBST.EXE         FreeDOS 1.4 base/swsubst.zip, BIN\SWSUBST.EXE
rem   QEXIT.COM           B0 00 E6 F4 CD 20 (powers QEMU off, isa-debug-exit)
rem   qemudoor-boot.img   FreeDOS 1.4 1.44 MB boot floppy whose FDCONFIG.SYS
rem                       is: FILES=30 / BUFFERS=20 / LASTDRIVE=Z /
rem                       SHELL=A:\FREEDOS\BIN\COMMAND.COM A:\FREEDOS\BIN
rem                       /E:1024 /P=D:\DOOR.BAT
rem   WWIV4CHN.EXE        (optional) for WWIV 3/4 chains
rem
rem Environment:
rem   QEMUDOOR_QEMU    QEMU binary (default: C:\Program Files\qemu\
rem                    qemu-system-i386.exe, then PATH)
rem   QEMUDOOR_BOOT    boot floppy (default: qemudoor-boot.img here)
rem   QEMUDOOR_FLAGS   extra WWIVFOSS options (e.g. -ST:\STATS.TXT)
rem   QEMUDOOR_ARGS    extra QEMU options
rem   QEMUDOOR_LOG     troubleshooting: directory to save the drop files and
rem                    DOOR.BAT as the door saw them, and QEMU's output
setlocal EnableExtensions DisableDelayedExpansion

rem Before any shift: shift moves %1 into %0 too.
set "HERE=%~dp0"

set "LINE_FLAGS=-E -H10"
if /i "%~1"=="-r" (set "LINE_FLAGS=-E-" & shift)
if /i "%~1"=="--raw" (set "LINE_FLAGS=-E-" & shift)
if /i "%~1"=="-h" goto usage
if /i "%~1"=="--help" goto usage
if "%~4"=="" goto usage

set "PORT=%~1"
set "TEMPDIR=%~f2"
set "DOORDIR=%~f3"
shift & shift & shift

rem The DOS command line: everything after DOORDIR, as given.
set "DOSCMD="
:collect
if "%~1"=="" goto collected
set "DOSCMD=%DOSCMD% %1"
shift
goto collect
:collected

call :trim HERE
call :trim TEMPDIR
call :trim DOORDIR

if not defined QEMUDOOR_BOOT set "QEMUDOOR_BOOT=%HERE%\qemudoor-boot.img"
if defined QEMUDOOR_QEMU goto have_qemu
set "QEMUDOOR_QEMU=qemu-system-i386.exe"
if exist "C:\Program Files\qemu\qemu-system-i386.exe" set "QEMUDOOR_QEMU=C:\Program Files\qemu\qemu-system-i386.exe"
:have_qemu

if not exist "%DOORDIR%\" (echo qemudoor: not a directory: "%DOORDIR%" 1>&2 & exit /b 1)
if not exist "%TEMPDIR%\" (echo qemudoor: not a directory: "%TEMPDIR%" 1>&2 & exit /b 1)
for %%F in ("%QEMUDOOR_BOOT%" "%HERE%\WWIVFOSS.EXE" "%HERE%\SWSUBST.EXE" "%HERE%\QEXIT.COM") do (
  if not exist "%%~F" (echo qemudoor: missing %%~F 1>&2 & exit /b 1)
)

rem The DOS side's programs, on D: for this call.
copy /y "%HERE%\WWIVFOSS.EXE" "%TEMPDIR%\" > NUL
copy /y "%HERE%\SWSUBST.EXE" "%TEMPDIR%\" > NUL
copy /y "%HERE%\QEXIT.COM" "%TEMPDIR%\" > NUL
if exist "%HERE%\WWIV4CHN.EXE" copy /y "%HERE%\WWIV4CHN.EXE" "%TEMPDIR%\" > NUL

rem FreeDOS's shell runs D:\DOOR.BAT (see qemudoor-boot.img above), which
rem powers QEMU off at the end. echo writes CR LF, as DOS wants.
set "BAT=%TEMPDIR%\DOOR.BAT"
> "%BAT%" echo @echo off
>>"%BAT%" echo set COMSPEC=A:\FREEDOS\BIN\COMMAND.COM
>>"%BAT%" echo set PATH=D:\;A:\FREEDOS\BIN
>>"%BAT%" echo D:\SWSUBST T: D:\ ^> NUL
>>"%BAT%" echo C:
>>"%BAT%" echo cd \
>>"%BAT%" echo D:\WWIVFOSS.EXE -P1 %LINE_FLAGS% %QEMUDOOR_FLAGS%%DOSCMD%
>>"%BAT%" echo D:\QEXIT.COM

set "LOG=NUL"
if not defined QEMUDOOR_LOG goto run
if not exist "%QEMUDOOR_LOG%" mkdir "%QEMUDOOR_LOG%"
copy /y "%TEMPDIR%\*" "%QEMUDOOR_LOG%\" > NUL 2>&1
set "LOG=%QEMUDOOR_LOG%\qemu.log"

:run
"%QEMUDOOR_QEMU%" -M pc -m 16 ^
  -drive "file=%QEMUDOOR_BOOT%,format=raw,if=floppy,index=0,snapshot=on" -boot a ^
  -drive "file=fat:rw:%DOORDIR%,format=raw,if=ide,index=0" ^
  -drive "file=fat:rw:%TEMPDIR%,format=raw,if=ide,index=1" ^
  -display none ^
  -chardev "socket,id=bbs,host=127.0.0.1,port=%PORT%" -serial chardev:bbs ^
  -device isa-debug-exit,iobase=0xf4,iosize=0x04 ^
  -no-reboot %QEMUDOOR_ARGS% > "%LOG%" 2>&1
rem isa-debug-exit makes QEMU exit with 1 when QEXIT.COM powers it off.
if "%ERRORLEVEL%"=="1" exit /b 0
exit /b %ERRORLEVEL%

:trim
rem Drops a trailing backslash from the variable named %1.
call set "T=%%%1%%"
if "%T:~-1%"=="\" set "%1=%T:~0,-1%"
exit /b 0

:usage
echo usage: qemudoor.cmd [-r^|--raw] PORT TEMPDIR DOORDIR COMMAND [ARGS...]
echo See the comments at the top of %~nx0 for details.
exit /b 2
