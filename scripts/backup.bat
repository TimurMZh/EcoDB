@echo off
setlocal EnableExtensions

rem Weekly logical backup of eco_monitoring.
rem pg_dump writes the custom-format file itself (-f). Do not redirect
rem pg_dump through PowerShell: ">" treats the stream as text and corrupts it.
rem The script then copies the files off this server, checks the checksum,
rem and deletes the local staging copies.
rem
rem Before the first run:
rem   1. Install PostgreSQL 14 (docs/install-windows.md).
rem   2. Set SHARE below to a folder that is not on this server.
rem   3. Create %ROOT%\pgpass.conf (one line, see docs/backups.md).
rem   4. Register the weekly task once, on the server, as Administrator:
rem        scripts\install-backup-task.bat
rem
rem The password is not stored in this file. libpq reads PGPASSFILE.

if not defined PGBIN set "PGBIN=C:\Program Files\PostgreSQL\14\bin"
if not defined PGHOST set "PGHOST=localhost"
if not defined PGPORT set "PGPORT=5432"
if not defined PGUSER set "PGUSER=eco"
if not defined PGDATABASE set "PGDATABASE=eco_monitoring"

set "DB=eco_monitoring"
set "ROOT=D:\eco-backups"
set "STAGING=%ROOT%\staging"
set "LOG=%ROOT%\backup.log"
set "LOCK=%ROOT%\backup.lock"
set "KEEP_DAYS=84"
if not defined PGPASSFILE set "PGPASSFILE=%ROOT%\pgpass.conf"

rem Off-server folder. Required. Example: \\fileserver\eco-backups\weekly
set "SHARE="

set "LOCKHELD=0"
set "REASON="

if not exist "%ROOT%\" mkdir "%ROOT%"
if not exist "%STAGING%\" mkdir "%STAGING%"

for /f %%D in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd"') do set "STAMP=%%D"
if not defined STAMP (
    set "REASON=could not read the date"
    goto :fail
)

call :log "start %STAMP%"

if not exist "%PGBIN%\pg_dump.exe" (
    set "REASON=pg_dump not found in %PGBIN%. Install PostgreSQL 14 or set PGBIN."
    goto :fail
)
if not exist "%PGBIN%\pg_dumpall.exe" (
    set "REASON=pg_dumpall not found in %PGBIN%."
    goto :fail
)

"%PGBIN%\pg_isready.exe" -q -h "%PGHOST%" -p %PGPORT% -d "%PGDATABASE%"
if errorlevel 1 (
    set "REASON=PostgreSQL is not accepting connections at %PGHOST%:%PGPORT%"
    goto :fail
)

if not exist "%PGPASSFILE%" (
    set "REASON=password file not found: %PGPASSFILE%. See docs/backups.md."
    goto :fail
)

if exist "%LOCK%" (
    forfiles /P "%ROOT%" /M "backup.lock" /D -1 >nul 2>&1
    if not errorlevel 1 del /f /q "%LOCK%"
)
if exist "%LOCK%" (
    set "REASON=backup already running, lock %LOCK%"
    goto :fail
)
> "%LOCK%" echo %STAMP%
set "LOCKHELD=1"

"%PGBIN%\pg_dump.exe" -h "%PGHOST%" -p %PGPORT% -U "%PGUSER%" -d "%DB%" -Fc --no-password -f "%STAGING%\eco_monitoring_%STAMP%.dump"
if errorlevel 1 (
    del /f /q "%STAGING%\eco_monitoring_%STAMP%.dump" 2>nul
    set "REASON=pg_dump failed"
    goto :fail
)

"%PGBIN%\pg_dumpall.exe" -h "%PGHOST%" -p %PGPORT% -U "%PGUSER%" --globals-only --no-password -f "%STAGING%\eco_globals_%STAMP%.sql"
if errorlevel 1 (
    del /f /q "%STAGING%\eco_monitoring_%STAMP%.dump" "%STAGING%\eco_globals_%STAMP%.sql" 2>nul
    set "REASON=pg_dumpall --globals-only failed"
    goto :fail
)

call :writehash "%STAGING%\eco_monitoring_%STAMP%.dump" "%STAGING%\eco_monitoring_%STAMP%.dump.sha256"
if errorlevel 1 (
    set "REASON=checksum of the database dump failed"
    goto :fail
)
call :writehash "%STAGING%\eco_globals_%STAMP%.sql" "%STAGING%\eco_globals_%STAMP%.sql.sha256"
if errorlevel 1 (
    set "REASON=checksum of the globals file failed"
    goto :fail
)

if not defined SHARE (
    set "REASON=SHARE is empty. Set it at the top of backup.bat. Staging files kept."
    goto :fail
)
if not exist "%SHARE%\" (
    set "REASON=share not reachable: %SHARE%. Staging files kept."
    goto :fail
)

robocopy "%STAGING%" "%SHARE%" ^
    "eco_monitoring_%STAMP%.dump" ^
    "eco_monitoring_%STAMP%.dump.sha256" ^
    "eco_globals_%STAMP%.sql" ^
    "eco_globals_%STAMP%.sql.sha256" ^
    /R:2 /W:10 /NFL /NDL /NP
if errorlevel 8 (
    set "REASON=robocopy failed. Staging files kept."
    goto :fail
)

call :samehash "%SHARE%\eco_monitoring_%STAMP%.dump" "%SHARE%\eco_monitoring_%STAMP%.dump.sha256"
if errorlevel 1 (
    set "REASON=checksum mismatch for the database dump on the share. Share copy removed. Staging files kept."
    goto :sharebad
)
call :samehash "%SHARE%\eco_globals_%STAMP%.sql" "%SHARE%\eco_globals_%STAMP%.sql.sha256"
if errorlevel 1 (
    set "REASON=checksum mismatch for the globals file on the share. Share copy removed. Staging files kept."
    goto :sharebad
)

del /f /q "%STAGING%\eco_monitoring_%STAMP%.dump" "%STAGING%\eco_monitoring_%STAMP%.dump.sha256" "%STAGING%\eco_globals_%STAMP%.sql" "%STAGING%\eco_globals_%STAMP%.sql.sha256"

call :prune "eco_monitoring_*.dump"
call :prune "eco_monitoring_*.sha256"
call :prune "eco_globals_*.sql"
call :prune "eco_globals_*.sha256"

del /f /q "%LOCK%"
call :log "OK %STAMP% copied to %SHARE%"
exit /b 0

:sharebad
del /f /q "%SHARE%\eco_monitoring_%STAMP%.dump" "%SHARE%\eco_monitoring_%STAMP%.dump.sha256" "%SHARE%\eco_globals_%STAMP%.sql" "%SHARE%\eco_globals_%STAMP%.sql.sha256"
goto :fail

:fail
call :log "FAILED: %REASON%"
if "%LOCKHELD%"=="1" del /f /q "%LOCK%"
exit /b 1

:prune
forfiles /P "%SHARE%" /M "%~1" /D -%KEEP_DAYS% /C "cmd /c del /f /q @path" >nul 2>&1
exit /b 0

:writehash
call :hashof "%~1"
if errorlevel 1 exit /b 1
if not defined HASH exit /b 1
> "%~2" echo %HASH%
exit /b 0

:samehash
call :hashof "%~1"
if errorlevel 1 exit /b 1
set "GOT=%HASH%"
set "EXPECTED="
for /f "usebackq tokens=*" %%L in ("%~2") do (
    if not defined EXPECTED set "EXPECTED=%%L"
)
set "EXPECTED=%EXPECTED: =%"
if not defined EXPECTED exit /b 1
if /I not "%GOT%"=="%EXPECTED%" exit /b 1
exit /b 0

:hashof
set "HASH="
for /f "skip=1 tokens=*" %%H in ('certutil -hashfile "%~1" SHA256') do (
    if not defined HASH set "HASH=%%H"
)
if not defined HASH exit /b 1
set "HASH=%HASH: =%"
if not defined HASH exit /b 1
exit /b 0

:log
set "NOW="
for /f %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-ddTHH:mm:ss"') do set "NOW=%%T"
>>"%LOG%" echo %NOW% %~1
echo %NOW% %~1
exit /b 0
