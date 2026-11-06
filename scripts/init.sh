#!/bin/sh
# runs inside the container on first start, after init.sql: swap in the test pg_hba.conf
cp /docker-entrypoint-initdb.d/pg_hba.conf.test "$PGDATA/pg_hba.conf"
