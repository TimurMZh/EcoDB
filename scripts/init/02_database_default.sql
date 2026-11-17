-- Used only when the server has no C locale (some Windows installs).
-- Encoding stays UTF-8. Collation then follows the cluster default.
SELECT 'CREATE DATABASE eco_monitoring WITH OWNER = eco ENCODING ''UTF8'' TEMPLATE = template0'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'eco_monitoring')
\gexec
