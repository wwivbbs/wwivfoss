@echo off
rem Runs a DOS door under DOSBox-X with WWIVFOSS for a WWIV chain on
rem Windows: the Windows counterpart of dosdoor.sh. WWIV listens on a local
rem port (%Z) and DOSBox-X connects its COM1 to it.
rem
rem   dosdoor.cmd [-r|--raw] PORT TEMPDIR DOORDIR COMMAND [ARGS...]
rem
rem Match the chain's exec mode (ChainEdit, E) Exec Mode):
rem
rem   "WWIVFOSS (Socket Port)"   (recommended) no option. WWIVFOSS runs with
rem                              -E -H10 (in-band line control, heartbeats).
rem   "Listen Socket Port"       -r / --raw. A plain byte stream; WWIVFOSS
rem                              runs with -E-.
rem
rem Example chain command line:
rem
rem   C:\wwiv\doors\dosdoor.cmd %Z %I C:\wwiv\doors\gw WAR.EXE /W T:\CHAIN.TXT
rem
rem Inside DOS:
rem   C:  the door's directory (DOORDIR); COMMAND runs from C:\
rem   T:  this node's WWIV temp directory (%I), with the drop files
rem   W:  the directory holding this script, WWIVFOSS.EXE and WWIV4CHN.EXE;
rem       on PATH
rem
rem Environment:
rem   DOSDOOR_DOSBOX   DOSBox-X binary (default: dosbox-x.exe next to this
rem                    script, then C:\DOSBox-X\dosbox-x.exe, then PATH)
rem   DOSDOOR_FLAGS    extra WWIVFOSS options (e.g. -ST:\STATS.TXT)
rem   DOSDOOR_CONF     extra DOSBox-X config file merged in
rem   DOSDOOR_ECHO=1   echo the commands on the DOSBox-X screen (debugging)
rem   DOSDOOR_SHOW=1   show the DOSBox-X window (debugging); hidden otherwise
rem   DOSDOOR_LOG      troubleshooting: directory to save a copy of the drop
rem                    files and DOSBox-X config as the door saw them, and
rem                    DOSBox-X's output (dosbox.log)
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

if defined DOSDOOR_DOSBOX goto have_dosbox
set "DOSDOOR_DOSBOX=dosbox-x.exe"
if exist "%HERE%\dosbox-x.exe" set "DOSDOOR_DOSBOX=%HERE%\dosbox-x.exe"
if not exist "%HERE%\dosbox-x.exe" if exist "C:\DOSBox-X\dosbox-x.exe" set "DOSDOOR_DOSBOX=C:\DOSBox-X\dosbox-x.exe"
:have_dosbox

set "ECHO_CMD=@echo off"
if "%DOSDOOR_ECHO%"=="1" set "ECHO_CMD=@echo on"

rem Written line by line rather than in a ( ) block, so paths holding
rem parentheses (Program Files (x86)) don't end the block.
set "CONF=%TEMPDIR%\dosdoor.conf"
> "%CONF%" echo [dosbox]
>>"%CONF%" echo quit warning = false
>>"%CONF%" echo.
>>"%CONF%" echo [cpu]
>>"%CONF%" echo cycles = max
>>"%CONF%" echo.
>>"%CONF%" echo [serial]
>>"%CONF%" echo serial1 = nullmodem server:127.0.0.1 port:%PORT% transparent:1
>>"%CONF%" echo.
>>"%CONF%" echo [autoexec]
>>"%CONF%" echo %ECHO_CMD%
>>"%CONF%" echo mount c "%DOORDIR%"
>>"%CONF%" echo mount t "%TEMPDIR%"
>>"%CONF%" echo mount w "%HERE%"
>>"%CONF%" echo set PATH=%%PATH%%;W:\
>>"%CONF%" echo c:
>>"%CONF%" echo cd \
>>"%CONF%" echo W:\WWIVFOSS.EXE -P1 %LINE_FLAGS% %DOSDOOR_FLAGS%%DOSCMD%
>>"%CONF%" echo exit

set "LOG=NUL"
if not defined DOSDOOR_LOG goto run
if not exist "%DOSDOOR_LOG%" mkdir "%DOSDOOR_LOG%"
copy /y "%TEMPDIR%\*" "%DOSDOOR_LOG%\" > NUL 2>&1
set "LOG=%DOSDOOR_LOG%\dosbox.log"

:run
set "EXTRA_CONF="
if defined DOSDOOR_CONF set EXTRA_CONF=-conf "%DOSDOOR_CONF%"

rem The caller sees the door through COM1, so DOSBox-X needs no window.
if not "%DOSDOOR_SHOW%"=="1" set "SDL_VIDEODRIVER=dummy"
set "SDL_AUDIODRIVER=dummy"
"%DOSDOOR_DOSBOX%" -conf "%CONF%" %EXTRA_CONF% -nogui -nomenu -fastlaunch > "%LOG%" 2>&1
exit /b %ERRORLEVEL%

:trim
rem Drops a trailing backslash from the variable named %1.
call set "T=%%%1%%"
if "%T:~-1%"=="\" set "%1=%T:~0,-1%"
exit /b 0

:usage
echo usage: dosdoor.cmd [-r^|--raw] PORT TEMPDIR DOORDIR COMMAND [ARGS...]
echo See the comments at the top of %~nx0 for details.
exit /b 2
