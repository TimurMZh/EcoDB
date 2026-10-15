@echo off
setlocal EnableExtensions

rem Run once on the database server, as Administrator.
rem Creates the scheduled task "EcoDB weekly backup": Sunday 02:00,
rem whether or not anyone is logged on. The task account is SYSTEM,
rem which must be able to run docker and write D:\eco-backups.
rem Set SHARE in backup.bat before the first run.

set "TASK=EcoDB weekly backup"
set "BAT=%~dp0backup.bat"

if not exist "%BAT%" (
    echo Missing %BAT%
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-backup-task.ps1"
if errorlevel 1 (
    echo Failed to create the scheduled task.
    exit /b 1
)

echo Created "%TASK%": every Sunday at 02:00, account SYSTEM.
echo Set SHARE in backup.bat to the off-server folder before the first run.
schtasks /Query /TN "%TASK%" /FO LIST
exit /b 0
