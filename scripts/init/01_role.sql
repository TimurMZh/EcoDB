-- Create the stand-in superuser eco (same statement scripts/init-db.ps1 runs).
-- Re-running does not change an existing password.
--   psql -h localhost -U postgres -d postgres -v eco_password=eco -f scripts/init/01_role.sql
SELECT format('CREATE ROLE eco LOGIN SUPERUSER PASSWORD %L', :'eco_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eco')
\gexec
