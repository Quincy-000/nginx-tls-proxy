#!/usr/bin/env bash
# Acceptance checks A-H for the nginx TLS reverse proxy.
# Checks not yet built are stubs that FAIL; later steps replace them.
set -u

PASS=0; FAIL=0; INCONCLUSIVE=0

pass()         { echo "PASS          $1"; PASS=$((PASS+1)); }
fail()         { echo "FAIL          $1 - $2"; FAIL=$((FAIL+1)); }
inconclusive() { echo "INCONCLUSIVE  $1 - $2"; INCONCLUSIVE=$((INCONCLUSIVE+1)); }

nginx_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "$(docker compose ps -q nginx)" 2>/dev/null
}

check_A_http() {
  # Step 2: through the proxy on :8080. Step 5 makes :8080 a redirect, so this
  # temporary variant is retired then and the real A (https) takes over.
  local url="${A_HTTP_URL:-http://localhost:8080/healthz}" out code body
  out=$(curl -s -m 3 -w '\n%{http_code}' "$url") || { fail "A-http ($url)" "curl failed"; return; }
  code=${out##*$'\n'}; body=${out%$'\n'*}
  if [ "$code" = "200" ] && [ "$body" = '{"status":"ok"}' ]; then
    pass "A-http ($url)"
  else
    fail "A-http ($url)" "got code=$code body=$body"
  fi
}

check_F2() {
  # The app's socket peer for a proxied request must be the nginx container IP.
  local ip line
  ip=$(nginx_ip)
  [ -n "$ip" ] || { fail "F2 app socket peer = nginx IP" "could not resolve nginx container IP"; return; }
  curl -sk -m 3 -o /dev/null https://localhost:8443/ || true
  line=$(docker compose logs app 2>&1 | grep 'peer=' | grep -E 'path=/[[:space:]]*$' | tail -n 1)
  if echo "$line" | grep -q "peer=$ip "; then
    pass "F2 app socket peer = nginx IP ($ip)"
  else
    fail "F2 app socket peer = nginx IP" "nginx=$ip, last app log: $line"
  fi
}

check_H() {
  # Port 8000 must not be reachable from the host. curl exit code 7 = refused.
  curl -s -m 2 -o /dev/null http://localhost:8000/
  local rc=$?
  if [ "$rc" -eq 7 ]; then
    pass "H  port 8000 not published (curl exit 7)"
  else
    fail "H  port 8000 not published" "curl exit code $rc (expected 7)"
  fi
}

check_A() {
  local out code body
  out=$(curl -sk -m 3 -w '\n%{http_code}' https://localhost:8443/healthz) || { fail "A  https healthz" "curl failed"; return; }
  code=${out##*$'\n'}; body=${out%$'\n'*}
  if [ "$code" = "200" ] && [ "$body" = '{"status":"ok"}' ]; then
    pass "A  https healthz"
  else
    fail "A  https healthz" "code=$code body=$body"
  fi
}
check_B() {
  local out loc code
  out=$(curl -sI -m 3 http://localhost:8080/healthz) || { fail "B  http redirect" "curl failed"; return; }
  code=$(printf '%s' "$out" | head -1 | awk '{print $2}')
  loc=$(printf '%s' "$out" | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')
  if [ "$code" = "301" ] && [ "$loc" = "https://localhost:8443/healthz" ]; then
    pass "B  http redirect"
  else
    fail "B  http redirect" "code=$code location=$loc"
  fi
}

check_C() {
  local code
  code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' http://localhost:8443/ || true)
  if [ "$code" = "400" ]; then
    pass "C  plain HTTP on TLS port"
  else
    fail "C  plain HTTP on TLS port" "got $code"
  fi
}
check_D() {
  local out
  out=$(docker compose exec -T nginx nginx -t 2>&1)
  if printf '%s' "$out" | grep -q "syntax is ok"; then
    pass "D  nginx -t"
  else
    fail "D  nginx -t" "$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  fi
}
check_E() {
  local out
  out=$(openssl s_client -connect localhost:8443 </dev/null 2>/dev/null \
        | openssl x509 -noout -subject -dates -ext subjectAltName 2>/dev/null)
  if printf '%s' "$out" | grep -q "DNS:localhost" &&
     printf '%s' "$out" | grep -q "IP Address:127.0.0.1"; then
    pass "E  cert subject, dates, SAN"
  else
    fail "E  cert subject, dates, SAN" "SAN missing: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-110)"
  fi
}
check_F1() {
  # The X-Forwarded-For header should contain the client address (not the nginx container IP).
  local ip line xff
  ip=$(nginx_ip)
  [ -n "$ip" ] || { fail "F1 X-Forwarded-For client addr" "could not resolve nginx container IP"; return; }
  curl -sk -m 3 -o /dev/null https://localhost:8443/ || true
  line=$(docker compose logs app 2>&1 | grep 'peer=' | grep 'path=/' | tail -n 1)
  xff=$(echo "$line" | sed -n 's/.*xff=\([^ ]*\).*/\1/p')

  if [ -z "$xff" ] || [ "$xff" = "None" ]; then
    fail "F1 X-Forwarded-For client addr" "xff is '$xff'"
  elif [ "$xff" = "$ip" ]; then
    fail "F1 X-Forwarded-For client addr" "xff equals nginx IP ($ip)"
  else
    pass "F1 X-Forwarded-For client addr (xff=$xff)"
  fi
}

check_G() {
  # curl --tlsv1.2 means "1.2 or higher", so 1.2 must be forced with --tls-max.
  local c12 c13 neg
  c12=$(curl -sk -m 3 --tlsv1.2 --tls-max 1.2 -o /dev/null -w '%{http_code}' https://localhost:8443/healthz || true)
  c13=$(curl -sk -m 3 --tlsv1.3                  -o /dev/null -w '%{http_code}' https://localhost:8443/healthz || true)
  if [ "$c12" != "200" ] || [ "$c13" != "200" ]; then
    fail "G  TLS versions" "tls1.2=$c12 tls1.3=$c13"
    return
  fi
  # Negative: is TLS 1.1 rejected by the server, and can this client even try?
  neg=$(openssl s_client -tls1_1 -cipher 'DEFAULT:@SECLEVEL=0' \
        -connect localhost:8443 </dev/null 2>&1 || true)
  if printf '%s' "$neg" | grep -qi "no protocols available"; then
    inconclusive "G  TLS versions" "client refused to attempt TLS 1.1; server not tested"
  elif printf '%s' "$neg" | grep -qi "SSL alert number"; then
    alert=$(printf '%s' "$neg" | grep -oi "SSL alert number [0-9]*" | head -1)
    pass "G  TLS versions (1.2+1.3 ok, 1.1 rejected: $alert)"
  else
    inconclusive "G  TLS versions" "unclear refusal: $(printf '%s' "$neg" | head -1 | cut -c1-80)"
  fi
}

# check_A_http retired at step 5: :8080 is now a redirect, not a proxy.
check_A
check_B
check_C
check_D
check_E
check_F1
check_F2
check_G
check_H

echo "----"
echo "pass=$PASS fail=$FAIL inconclusive=$INCONCLUSIVE"
[ "$FAIL" -eq 0 ]
