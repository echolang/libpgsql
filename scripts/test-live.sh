#!/usr/bin/env bash
#
# Run the live tests against a throwaway PostgreSQL in Docker.
#
#   scripts/test-live.sh                         # postgres:18-alpine
#   IMAGE=postgres:13-alpine scripts/test-live.sh
#   scripts/test-live.sh --filter group:live     # extra echoc test arguments
#
# The server gets one role per authentication method (scripts/init.sql, scripts/pg_hba.conf):
# app (SCRAM-SHA-256), app_md5 (md5), app_clear (cleartext password) and trusty (trust).

set -euo pipefail

IMAGE=${IMAGE:-postgres:18-alpine}
NAME=libpgsql-live-$$
PORT=${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}

cd "$(dirname "$0")/.."
source scripts/server.sh
start_server "$NAME" "$IMAGE" "$PORT"
# -v: the server's data volume goes with it, or every run leaves one behind
trap 'docker rm -f -v "$NAME" >/dev/null 2>&1 || true' EXIT

export PGSQL_TEST_URL="postgres://app:secret@127.0.0.1:$PORT/shop"
export PGSQL_ROOT_URL="postgres://postgres:rootpw@127.0.0.1:$PORT/shop"
echoc test --define pgsql --timeout 120000 "$@"
