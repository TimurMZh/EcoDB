# Backups

Weekly logical backup of `eco_monitoring`, copies kept off the database server, and a restore test once a quarter.

The database runs in Docker: container `eco-postgis`, image `postgis/postgis:14-3.4`. Live data is the Docker volume `eco_pgdata`. A dump on that same disk is not a backup.

`docs/data-requirements.md` still lists a daily dump and 30 days of copies as not yet agreed. This note is the weekly procedure.

## What is saved

| File | Command | Contents |
| --- | --- | --- |
| `eco_monitoring_YYYYMMDD.dump` | `pg_dump -Fc` | Database `eco_monitoring` (schema `eco`, data, views) |
| `eco_globals_YYYYMMDD.sql` | `pg_dumpall --globals-only` | Logins and roles (`eco_admin`, `eco_etl`, `eco_gis`, and the rest) |

Custom format (`-Fc`) is restored with `pg_restore`. Without the globals file, a restore has no logins.

`pg_dump` does not include files outside the database. If `DB_input\` (Excel and PDF sources) exists only on this server, copy that folder with the same weekly job.

## Where copies live

| Place | Role | How long |
| --- | --- | --- |
| `D:\eco-backups\staging` on the database server | Fresh dump, until the off-server copy is verified | Delete after a successful copy |
| File share, NAS, or a second server (not this host) | Copies that are kept | 12 weekly dumps (about one quarter) |

Twelve weeks is the retention so the quarterly test always has a real dump. The 30-day floor in `docs/data-requirements.md` is shorter than that.

## Weekly dump

The job is `scripts/backup.bat`. It runs on the database server, inside the container, as the bootstrap user `eco`. Sunday 02:00, when ETL is not loading.

On Windows, do not redirect `pg_dump -Fc` through PowerShell. `>` treats the stream as text and corrupts the file. The script writes the dump inside the container, then `docker cp` copies it out. The date stamp comes from PowerShell; the dump itself does not.

Set `SHARE` at the top of `scripts/backup.bat` to the off-server folder before the first run. `docker exec` uses the container's local socket, so the script does not store a password.

Register it once on the server, from an Administrator prompt:

```bat
scripts\install-backup-task.bat
```

That creates the task **EcoDB weekly backup**: every Sunday at 02:00, account `SYSTEM`, including when nobody is logged on. `SYSTEM` must be able to run `docker` and write `D:\eco-backups`. If the server is off at 02:00, the task starts when it is next available. A failed run exits 1, leaves the staging files in place, and appends a line to `D:\eco-backups\backup.log`.

## Copy off the database server

After the checksum, the script copies that week's dump, globals file, and `.sha256` files to `SHARE`. It recomputes SHA256 on the share and compares it with the `.sha256` file. On a match it deletes the staging copies. On a mismatch it removes the share copies of that week and leaves staging in place.

It then deletes files on the share older than 84 days (12 weeks): `eco_monitoring_*.dump`, `eco_globals_*.sql`, and their `.sha256` files.

## Recovery test, once a quarter

Do this in the first week of each quarter, on a machine that is not the production database server. Use the newest dump from the share. Do not restore over `eco-postgis`.

1. Copy that week's `.dump`, `.sql`, and `.sha256` to the test machine and check the checksum.
2. Start an empty database with the same image:

```bat
docker run -d --name eco-restore-test -e POSTGRES_USER=eco -e POSTGRES_PASSWORD=restore-test -e POSTGRES_DB=eco_monitoring postgis/postgis:14-3.4
docker exec eco-restore-test pg_isready -U eco -d eco_monitoring
```

Wait until `pg_isready` accepts connections.

3. Load roles, then the database. `--exit-on-error` stops on the first restore error:

```bat
docker cp eco_globals_YYYYMMDD.sql eco-restore-test:/tmp/globals.sql
docker cp eco_monitoring_YYYYMMDD.dump eco-restore-test:/tmp/eco.dump
docker exec eco-restore-test psql -U eco -d eco_monitoring -v ON_ERROR_STOP=1 -f /tmp/globals.sql
docker exec eco-restore-test pg_restore -U eco -d eco_monitoring --exit-on-error /tmp/eco.dump
```

4. Check schema, row counts, the ArcGIS view, and PostGIS. Counts should match production at the time of the dump:

```bat
docker exec eco-restore-test psql -U eco -d eco_monitoring -c "SELECT version FROM eco.schema_migrations ORDER BY version;"
docker exec eco-restore-test psql -U eco -d eco_monitoring -c "SELECT COUNT(*) FROM eco.results;"
docker exec eco-restore-test psql -U eco -d eco_monitoring -c "SELECT COUNT(*) FROM eco.vw_results_flat;"
docker exec eco-restore-test psql -U eco -d eco_monitoring -c "SELECT PostGIS_Version();"
```

5. Append one line to a log kept with the backups: date, file name, checksum, `eco.results` count, pass or fail, person.
6. Remove the test container:

```bat
docker rm -f eco-restore-test
```

A failed test means there is no confirmed backup yet. Fix the dump or the restore steps and run the test again before the next weekly job.

## Record

| Item | Value |
| --- | --- |
| Schedule | Weekly, Sunday 02:00, task **EcoDB weekly backup** (`scripts/install-backup-task.bat`) |
| Script | `scripts/backup.bat` |
| Database | `eco_monitoring` |
| Format | `pg_dump -Fc` plus `pg_dumpall --globals-only` |
| Retention | 12 weekly copies on a named share that is not the database server |
| Staging | `D:\eco-backups\staging`, deleted after a verified copy |
| Restore test | First week of each quarter, throwaway `postgis/postgis:14-3.4` container, log line as above |
| Failure | Whoever runs the server is told when the scheduled task fails |
