# Create the eco superuser and the eco_monitoring database on a local
# PostgreSQL 14 instance. PostGIS itself is installed with Stack Builder
# before this script runs; migration 001 creates the extension.
#
# The installer superuser password is read from PG_SUPER_PASSWORD, or
# prompted. It is not accepted as a script argument.
#
#   powershell -ExecutionPolicy Bypass -File scripts\init-db.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\init-db.ps1 -EcoPassword 'change-me'

param(
    [string]$PgBin,
    [string]$SuperUser = 'postgres',
    [string]$PgHost = 'localhost',
    [int]$Port = 5432,
    [string]$EcoPassword = 'eco'
)

$ErrorActionPreference = 'Stop'

function Resolve-PgBin {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath (Join-Path $Explicit 'psql.exe'))) {
            throw "psql.exe not found in $Explicit"
        }
        return $Explicit
    }
    if ($env:PGBIN -and (Test-Path -LiteralPath (Join-Path $env:PGBIN 'psql.exe'))) {
        return $env:PGBIN
    }
    $default = 'C:\Program Files\PostgreSQL\14\bin'
    if (Test-Path -LiteralPath (Join-Path $default 'psql.exe')) {
        return $default
    }
    $cmd = Get-Command psql.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return (Split-Path -Parent $cmd.Source)
    }
    throw "psql.exe not found. Install PostgreSQL 14, or pass -PgBin / set PGBIN."
}

function Invoke-PsqlFile {
    param(
        [string]$Psql,
        [string]$Database,
        [string]$File
    )
    & $Psql -h $PgHost -p $Port -U $SuperUser -d $Database -v ON_ERROR_STOP=1 -f $File
    return $LASTEXITCODE
}

function New-RoleSql {
    param([string]$Password)
    # Same statement as scripts/init/01_role.sql. The password is written to a
    # temp file with a dollar-quote tag, not placed on the psql command line.
    $tag = 'p' + [guid]::NewGuid().ToString('N')
    while ($Password.Contains('$' + $tag + '$')) {
        $tag = 'p' + [guid]::NewGuid().ToString('N')
    }
    $quoted = '$' + $tag + '$' + $Password + '$' + $tag + '$'
    return @"
SELECT format('CREATE ROLE eco LOGIN SUPERUSER PASSWORD %L', $quoted)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eco')
\gexec
"@
}

$pgBin = Resolve-PgBin -Explicit $PgBin
$psql = Join-Path $pgBin 'psql.exe'
$pgIsReady = Join-Path $pgBin 'pg_isready.exe'
$initDir = Join-Path $PSScriptRoot 'init'

$savedPassword = $env:PGPASSWORD
try {
    if ($env:PG_SUPER_PASSWORD) {
        $env:PGPASSWORD = $env:PG_SUPER_PASSWORD
    } else {
        $secure = Read-Host "Password for PostgreSQL superuser '$SuperUser'" -AsSecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }

    & $pgIsReady -q -h $PgHost -p $Port
    if ($LASTEXITCODE -ne 0) {
        throw "PostgreSQL is not accepting connections at ${PgHost}:${Port}. Start the service (Get-Service postgresql-x64-14; Start-Service postgresql-x64-14) and run this script again."
    }

    $utf8 = New-Object System.Text.UTF8Encoding $false
    $roleFile = Join-Path ([System.IO.Path]::GetTempPath()) ('ecodb-role-' + [guid]::NewGuid().ToString('N') + '.sql')
    [System.IO.File]::WriteAllText($roleFile, (New-RoleSql -Password $EcoPassword), $utf8)
    try {
        $code = Invoke-PsqlFile -Psql $psql -Database 'postgres' -File $roleFile
        if ($code -ne 0) { exit $code }
    } finally {
        Remove-Item -LiteralPath $roleFile -Force -ErrorAction SilentlyContinue
    }

    $code = Invoke-PsqlFile -Psql $psql -Database 'postgres' -File (Join-Path $initDir '02_database_c.sql')
    if ($code -ne 0) {
        Write-Host "Could not create eco_monitoring with locale C. Retrying with the cluster default collation (UTF-8)."
        $code = Invoke-PsqlFile -Psql $psql -Database 'postgres' -File (Join-Path $initDir '02_database_default.sql')
        if ($code -ne 0) { exit $code }
    }

    $code = Invoke-PsqlFile -Psql $psql -Database 'postgres' -File (Join-Path $initDir '03_postgis.sql')
    if ($code -ne 0) { exit $code }
} finally {
    $env:PGPASSWORD = $savedPassword
}

Write-Host "Database eco_monitoring is ready. User eco can connect on ${PgHost}:${Port}."
if ($EcoPassword -eq 'eco') {
    Write-Host "Stand password for eco is 'eco'. Change it before any production use (docs/roles.md)."
}
Write-Host "Next: powershell -ExecutionPolicy Bypass -File sql\apply.ps1"
exit 0
