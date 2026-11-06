-- one role per authentication method; pg_hba.conf (scripts/pg_hba.conf) maps them. Before 14
-- the server hashed passwords with md5 by default, which SCRAM cannot check
SET password_encryption = 'scram-sha-256';
ALTER ROLE postgres PASSWORD 'rootpw';
CREATE ROLE app LOGIN PASSWORD 'secret';
ALTER DATABASE shop OWNER TO app;
GRANT ALL ON SCHEMA public TO app;
CREATE ROLE app_clear LOGIN PASSWORD 'secret';
CREATE ROLE trusty LOGIN;
SET password_encryption = 'md5';
CREATE ROLE app_md5 LOGIN PASSWORD 'secret';
GRANT CONNECT ON DATABASE shop TO app_clear, app_md5, trusty;
