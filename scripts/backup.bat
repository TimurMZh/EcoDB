@echo off
setlocal EnableExtensions

rem Weekly logical backup of eco_monitoring.
rem Dumps inside the Docker container (custom format is binary; do not
rem redirect pg_dump through PowerShell), copies the files off this server,
rem checks the checksum, then deletes the local staging copies.
rem
rem Before the first run, set SHARE below to a folder that is not on this
rem server. Register the weekly task once, on the server, as Administrator:
rem   scripts\install-backup-task.bat
rem
rem docker exec uses the container's local socket, which trusts user eco.
rem No password is stored in this file.

set "CONTAINER=eco-postgis"
set "DB=eco_monitoring"
set "DBUSER=eco"
set "ROOT=D:\eco-backups"
set "STAGING=%ROOT%\staging"
set "LOG=%ROOT%\backup.log"
set "LOCK=%ROOT%\backup.lock"
set "KEEP_DAYS=84"

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

set "DOCKER=docker"
where docker >nul 2>&1
if errorlevel 1 (
    if exist "C:\Program Files\Docker\Docker\resources\bin\docker.exe" (
        set "DOCKER=C:\Program Files\Docker\Docker\resources\bin\docker.exe"
    ) else (
        set "REASON=docker not found on PATH"
        goto :fail
    )
)

"%DOCKER%" inspect -f "{{.State.Running}}" %CONTAINER% 2>nul | findstr /I /X "true" >nul
if errorlevel 1 (
    set "REASON=container %CONTAINER% is not running"
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

"%DOCKER%" exec %CONTAINER% pg_dump -U %DBUSER% -d %DB% -Fc --no-password -f /tmp/eco_monitoring_%STAMP%.dump
if errorlevel 1 (
    set "REASON=pg_dump failed"
    goto :fail
)

"%DOCKER%" exec %CONTAINER% pg_dumpall -U %DBUSER% --globals-only --no-password -f /tmp/eco_globals_%STAMP%.sql
if errorlevel 1 (
    set "REASON=pg_dumpall --globals-only failed"
    goto :fail
)

"%DOCKER%" cp %CONTAINER%:/tmp/eco_monitoring_%STAMP%.dump "%STAGING%\eco_monitoring_%STAMP%.dump"
if errorlevel 1 (
    set "REASON=docker cp of the database dump failed"
    goto :fail
)
"%DOCKER%" cp %CONTAINER%:/tmp/eco_globals_%STAMP%.sql "%STAGING%\eco_globals_%STAMP%.sql"
if errorlevel 1 (
    set "REASON=docker cp of the globals file failed"
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

call :cleanup_tmp
del /f /q "%LOCK%"
call :log "OK %STAMP% copied to %SHARE%"
exit /b 0

:sharebad
del /f /q "%SHARE%\eco_monitoring_%STAMP%.dump" "%SHARE%\eco_monitoring_%STAMP%.dump.sha256" "%SHARE%\eco_globals_%STAMP%.sql" "%SHARE%\eco_globals_%STAMP%.sql.sha256"
goto :fail

:fail
call :log "FAILED: %REASON%"
if "%LOCKHELD%"=="1" (
    call :cleanup_tmp
    del /f /q "%LOCK%"
)
exit /b 1

:cleanup_tmp
if not defined STAMP exit /b 0
"%DOCKER%" exec %CONTAINER% rm -f /tmp/eco_monitoring_%STAMP%.dump /tmp/eco_globals_%STAMP%.sql >nul 2>&1
exit /b 0

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
