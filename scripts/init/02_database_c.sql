-- UTF-8 and the C locale match the old container initdb flags
-- (--encoding=UTF8 --lc-collate=C --lc-ctype=C).
SELECT format(
    'CREATE DATABASE eco_monitoring WITH OWNER = eco ENCODING %L LC_COLLATE = %L LC_CTYPE = %L TEMPLATE = template0',
    'UTF8', 'C', 'C')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'eco_monitoring')
\gexec
