#!/bin/sh
set -e

# Trust the hall-pass MITM CA if the shared volume has been populated.
# The entrypoint runs as root so we can write to the CA dir and run
# update-ca-certificates directly (no_new_privileges blocks sudo/setuid).
if [ -f /ca/ca.crt ]; then
    cp /ca/ca.crt /usr/local/share/ca-certificates/hall-pass.crt
    update-ca-certificates --fresh > /dev/null
fi

# Drop privileges to agent for all subsequent work.
exec gosu agent /app/docker-entrypoint-agent.sh "$@"
