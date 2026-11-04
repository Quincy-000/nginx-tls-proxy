#!/usr/bin/env bash
# Generate a self-signed certificate for localhost.
#
# Default (no argument): NO subjectAltName, on purpose. This produces the
# failure the README needs as evidence (check E cannot pass without a SAN).
# Use --san to generate the real certificate.
set -eu
cd "$(dirname "$0")/.."
mkdir -p nginx/certs
OUT=nginx/certs

if [ "${1:-}" = "--san" ]; then
  echo "generating WITH subjectAltName (DNS:localhost, IP:127.0.0.1)"
  openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout "$OUT/server.key" -out "$OUT/server.crt" \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
else
  echo "generating WITHOUT subjectAltName (deliberate failure, step 4)"
  openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout "$OUT/server.key" -out "$OUT/server.crt" \
    -subj "/CN=localhost"
fi

chmod 644 "$OUT/server.crt"
chmod 600 "$OUT/server.key"

echo "--- what the cert actually says ---"
openssl x509 -in "$OUT/server.crt" -noout -subject -dates
openssl x509 -in "$OUT/server.crt" -noout -ext subjectAltName || \
  echo "no subjectAltName extension present"
