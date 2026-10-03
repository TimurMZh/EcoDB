# Database roles

Migration `011_roles.sql` creates three group roles. They cannot log in and only hold permissions. People and services get their own login, which is added to one group. Passwords are never stored in the repository.


| Group       | Can do                                                                                                                                                  | Typical logins                     |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| `eco_read`  | `SELECT` on all tables and views in `eco`                                                                                                               | analysts, notebook users           |
| `eco_edit`  | `eco_read` + `INSERT` / `UPDATE` / `DELETE` on data, dictionaries (points, parameters, aliases, labs), staging and QA runs; runs ETL functions. No DDL. | `eco_etl` (loaders), lab operators |
| `eco_admin` | `eco_edit` + owns the database and schema `eco`: migrations, guideline values, QC codes, QA rules                                                       | 1–2 named administrators           |


Separate from the groups:

- `eco_gis` — ArcGIS login (migration `010`). `SELECT` on the four Query Layer views only, `statement_timeout = 60s`. Not a member of any group.
- `eco` — bootstrap superuser created by Docker (`POSTGRES_USER`). Use it only for creating logins and emergencies, not for daily work.
- `PUBLIC` has no access to the database or schema `eco`.

Tables only `eco_admin` can change: `ref_media_types`, `ref_qc_codes`, `guideline_standards`, `guideline_values`, `qa_rules`, `schema_migrations`. A change to a guideline value changes every exceedance, so it is an admin task.

## After installation on the server

Run once, after `docker compose up -d` and `./sql/apply.sh`.

1. Open `psql` as the bootstrap superuser:
  ```bash
   docker exec -it eco-postgis psql -U eco -d eco_monitoring
  ```
2. Create the logins. `\password` asks for the password interactively, so it does not end up in shell history or logs. Use 20+ random characters.
  ```sql
   -- administrator (replace with a real name)
   CREATE ROLE admin LOGIN IN ROLE eco_admin;
   \password admin

   -- ETL service account
   CREATE ROLE eco_etl LOGIN IN ROLE eco_edit;
   \password eco_etl

   -- read-only user (repeat per person)
   CREATE ROLE analyst LOGIN IN ROLE eco_read;
   \password analyst

   -- replace the dev password of the ArcGIS login
   \password eco_gis

   -- last: replace the bootstrap superuser password and keep it in a safe place
   \password eco
  ```
3. Check the result:
  ```bash
   psql -h localhost -U eco -d eco_monitoring -v ON_ERROR_STOP=1 -f sql/verify_roles.sql
  ```
   It prints `Roles OK` and a list of logins with their groups. Any problem stops the script with an error that names the role and the object.



## Which login runs what


| Task                                                                               | Login                                                   |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `./sql/apply.sh`, `./sql/apply.sh --reset`                                         | admin login (the script switches to `eco_admin` itself) |
| `python etl/phase2.py seed`, `python etl/phase3.py seed` (writes guideline values) | admin login                                             |
| `python etl/phase2.py air`, `python etl/phase3.py water`, `python etl/phase4.py`   | `eco_etl`                                               |
| ArcGIS Query Layers                                                                | `eco_gis`                                               |
| Notebook / ad-hoc queries                                                          | `eco_read` member                                       |


Without an argument, `phase2.py` and `phase3.py` run `seed` first. Under `eco_etl` that fails with `permission denied for table guideline_standards`. Pass `air` / `water` explicitly.

Credentials go through environment variables (`PGUSER`, `PGPASSWORD`, …) or a `pgpass` file, for example:

```powershell
$env:PGUSER = "eco_etl"; $env:PGPASSWORD = "<from password manager>"
python etl/phase2.py air
```



## Day-to-day commands

Run as the bootstrap superuser.

```sql
-- new user
CREATE ROLE <name> LOGIN IN ROLE eco_read;      -- or eco_edit / eco_admin
\password <name>

-- move a user to another group
REVOKE eco_read FROM <name>;
GRANT eco_edit TO <name>;

-- block a login immediately (keeps the role and its history)
ALTER ROLE <name> NOLOGIN;

-- temporary access
ALTER ROLE <name> VALID UNTIL '2026-12-31';

-- remove a user
DROP ROLE <name>;
```

`DROP ROLE` fails if the user owns objects. Logins should not own anything, because objects belong to `eco_admin`. If it happens, run `REASSIGN OWNED BY <name> TO eco_admin; DROP OWNED BY <name>;` first.

## New tables and migrations

New migrations run as `eco_admin`, so new tables automatically get `SELECT` for `eco_read` and write access for `eco_edit`. If a new table is reference data that only admins should change, add a `REVOKE INSERT, UPDATE, DELETE ON <table> FROM eco_edit;` in the same migration and add it to `admin_only` in `sql/verify_roles.sql`. New views are not visible to `eco_gis` until granted explicitly.