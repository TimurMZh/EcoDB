# Apply numbered SQL migrations. Already-applied versions are skipped.
# Recreate the eco schema from scratch: .\sql\apply.ps1 -Reset

param(
    [switch]$Reset
)

$ErrorActionPreference = 'Stop'

function Resolve-PgBin {
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
    throw "psql.exe not found. Install PostgreSQL 14, or set PGBIN to its bin directory."
}

$pgBin = Resolve-PgBin
$psql = Join-Path $pgBin 'psql.exe'
$pgIsReady = Join-Path $pgBin 'pg_isready.exe'
$root = Split-Path -Parent $PSScriptRoot

if (-not $env:PGHOST) { $env:PGHOST = 'localhost' }
if (-not $env:PGPORT) { $env:PGPORT = '5432' }
if (-not $env:PGUSER) { $env:PGUSER = 'eco' }
if (-not $env:PGDATABASE) { $env:PGDATABASE = 'eco_monitoring' }
if (-not $env:PGPASSWORD) { $env:PGPASSWORD = 'eco' }
$env:PGCLIENTENCODING = 'UTF8'

Write-Host "Waiting for PostgreSQL at $($env:PGHOST):$($env:PGPORT) ..."
$ready = $false
for ($i = 1; $i -le 60; $i++) {
    & $pgIsReady -q
    if ($LASTEXITCODE -eq 0) {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 1
}
if (-not $ready) {
    Write-Error "PostgreSQL is not ready after 60s"
    exit 1
}

function Invoke-PsqlScalar {
    param([string]$Sql)
    $out = & $psql -X -q -tAc $Sql
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    return ("$out").Trim()
}

$admin = Invoke-PsqlScalar "SELECT 1 FROM pg_roles WHERE rolname = 'eco_admin'"
if ($admin -eq '1') {
    $env:PGOPTIONS = ("$($env:PGOPTIONS) -c role=eco_admin").Trim()
    Write-Host "Running as role eco_admin"
}

if ($Reset) {
    Write-Host "Dropping schema eco (reset) ..."
    & $psql -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS eco CASCADE;"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host "Applying migrations to $($env:PGDATABASE) ..."
$files = Get-ChildItem -Path (Join-Path $root 'sql\migrations') -Filter '*.sql' | Sort-Object Name
foreach ($file in $files) {
    $ver = ($file.BaseName -split '_', 2)[0]
    $applied = 'f'
    $hasJournal = Invoke-PsqlScalar "SELECT to_regclass('eco.schema_migrations') IS NOT NULL"
    if ($hasJournal -eq 't') {
        $applied = Invoke-PsqlScalar "SELECT EXISTS (SELECT 1 FROM eco.schema_migrations WHERE version = '$ver')"
    }
    if ($applied -eq 't') {
        Write-Host "  skip $($file.Name) (already applied)"
        continue
    }
    Write-Host "  -> $($file.Name)"
    & $psql -v ON_ERROR_STOP=1 -f $file.FullName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host ""
Write-Host "Schema objects in eco:"
& $psql -v ON_ERROR_STOP=1 -c @"
SELECT
  CASE c.relkind
    WHEN 'r' THEN 'table'
    WHEN 'v' THEN 'view'
    ELSE c.relkind::text
  END AS kind,
  c.relname AS name
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'eco'
  AND c.relkind IN ('r', 'v')
  AND c.relname NOT LIKE 'pg_%'
ORDER BY kind, name;
"@
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "Applied migrations:"
& $psql -v ON_ERROR_STOP=1 -c "SELECT version, description, applied_at FROM eco.schema_migrations ORDER BY version;"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Done."
exit 0
