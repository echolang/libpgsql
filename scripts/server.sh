# start_server NAME IMAGE PORT: a PostgreSQL in Docker on 127.0.0.1:PORT with the test roles,
# waited for until a TCP login works. Sourced by test-live.sh and bench/run.sh.
start_server() {
    local name=$1 image=$2 port=$3 dir
    dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    docker run -d --rm --name "$name" \
        -e POSTGRES_PASSWORD=rootpw -e POSTGRES_DB=shop \
        -v "$dir/init.sql:/docker-entrypoint-initdb.d/10-init.sql:ro" \
        -v "$dir/init.sh:/docker-entrypoint-initdb.d/20-hba.sh:ro" \
        -v "$dir/pg_hba.conf:/docker-entrypoint-initdb.d/pg_hba.conf.test:ro" \
        -p "127.0.0.1:$port:5432" "$image" >/dev/null
    # the entrypoint initialises on a temporary socket-only server, then starts the real one
    echo "waiting for $image on 127.0.0.1:$port"
    for _ in $(seq 1 120); do
        if docker exec -e PGPASSWORD=rootpw "$name" psql -h 127.0.0.1 -U postgres -d shop -tAc 'SELECT 1' >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    docker exec -e PGPASSWORD=rootpw "$name" psql -h 127.0.0.1 -U postgres -d shop -tAc 'SELECT version()'
}
