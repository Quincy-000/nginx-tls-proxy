#!/bin/sh
# Runs from /docker-entrypoint.d before nginx starts (introduced in step 4).
# Fails fast, with a readable message, when the certificate is missing.
set -eu

CRT=/etc/nginx/certs/server.crt
KEY=/etc/nginx/certs/server.key

if [ ! -f "$CRT" ] || [ ! -f "$KEY" ]; then
    echo "FATAL: TLS certificate missing." >&2
    echo "       expected: $CRT and $KEY" >&2
    echo "       run: ./scripts/gen-cert.sh --san" >&2
    exit 1
fi
