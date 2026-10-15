# Registers "EcoDB weekly backup". Called by install-backup-task.bat.
$ErrorActionPreference = 'Stop'

$bat = $env:BAT
$task = $env:TASK
if (-not $bat -or -not (Test-Path -LiteralPath $bat)) {
    Write-Error "backup.bat not found."
    exit 1
}

$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + $bat + '"')
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '02:00'
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "Created scheduled task '$task'."
