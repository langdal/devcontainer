#!/bin/bash
# scripts/test/fixtures/pg-smoke.sh
#
# Bring up postgres in the rootless dockerd, wait for ready, run a
# trivial query via psql from inside another short-lived container,
# clean up. Mirrors the testcontainers loopback-port pattern.
set -u

NAME="pg-smoke-$$"
PORT_BIND="127.0.0.1:0:5432"

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --rm -d --name "$NAME" \
    -e POSTGRES_PASSWORD=test \
    -p "$PORT_BIND" \
    postgres:16-alpine >/dev/null

# Resolve the port docker assigned.
hostport=""
for _ in $(seq 1 30); do
    hostport=$(docker port "$NAME" 5432 2>/dev/null | head -1 | awk -F: '{print $NF}')
    [ -n "$hostport" ] && break
    sleep 0.5
done
if [ -z "$hostport" ]; then
    echo "pg-smoke: could not resolve mapped port" >&2
    exit 1
fi

# Wait for the database to be ready.
for _ in $(seq 1 60); do
    if docker exec "$NAME" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

# Run a query via a one-shot postgres-client container that connects to
# the host-mapped port. This verifies the loopback-port pattern, which
# is what testcontainers libraries rely on.
result=$(docker run --rm --network host -e PGPASSWORD=test postgres:16-alpine \
    psql -h 127.0.0.1 -p "$hostport" -U postgres -tAc 'SELECT 42;' 2>/dev/null)

if [ "$result" = "42" ]; then
    echo "pg-smoke: ok (port $hostport)"
    exit 0
fi
echo "pg-smoke: query returned [$result] (expected 42)" >&2
exit 1
