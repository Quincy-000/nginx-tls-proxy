#!/usr/bin/env bash
# Acceptance checks A-H for the nginx TLS reverse proxy.
# Checks not yet built are stubs that FAIL; later steps replace them.
set -u

PASS=0; FAIL=0; INCONCLUSIVE=0

pass()         { echo "PASS          $1"; PASS=$((PASS+1)); }
fail()         { echo "FAIL          $1 - $2"; FAIL=$((FAIL+1)); }
inconclusive() { echo "INCONCLUSIVE  $1 - $2"; INCONCLUSIVE=$((INCONCLUSIVE+1)); }

check_A_http() {
  # Step 1: direct to the app on :8000. Step 2 repoints this to :8080 via the proxy.
  local url="${A_HTTP_URL:-http://localhost:8000/healthz}" out code body
  out=$(curl -s -m 3 -w '\n%{http_code}' "$url") || { fail "A-http ($url)" "curl failed"; return; }
  code=${out##*$'\n'}; body=${out%$'\n'*}
  if [ "$code" = "200" ] && [ "$body" = '{"status":"ok"}' ]; then
    pass "A-http ($url)"
  else
    fail "A-http ($url)" "got code=$code body=$body"
  fi
}

check_A()  { fail "A  https healthz"               "not implemented"; }
check_B()  { fail "B  http redirect"               "not implemented"; }
check_C()  { fail "C  plain HTTP on TLS port"      "not implemented"; }
check_D()  { fail "D  nginx -t"                    "not implemented"; }
check_E()  { fail "E  cert subject, dates, SAN"    "not implemented"; }
check_F1() { fail "F1 X-Forwarded-For client addr" "not implemented"; }
check_F2() { fail "F2 app socket peer = nginx IP"  "not implemented"; }
check_G()  { fail "G  TLS versions"                "not implemented"; }
check_H()  { fail "H  port 8000 not published"     "not implemented"; }

check_A_http
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
