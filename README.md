# nginx TLS reverse proxy (local lab)

A small, deliberately boring demo whose only subject is nginx: an HTTPS reverse
proxy in front of a containerised Python app, with a redirect from HTTP, forwarded
headers you can inspect, and nine acceptance checks a third party can re-run.

Built to close a specific gap: nginx, TLS certificates and reverse proxies.

## What it does

```
client
  │  http://localhost:8080  ──301──▶  https://localhost:8443
  │                                     │
  └─────────────────────────────────────┘
                                        ▼
                        nginx 1.27.2   :80 / :443
                                        │ proxy_pass http://app_upstream
                                        ▼
                        FastAPI + uvicorn  :8000   (not published)
```

- `:8080` exists only to redirect. It never serves content.
- `:8443` is the only way in, and it is TLS.
- The app container has no host port at all, so there is no plaintext bypass.

## Run it

```bash
./scripts/gen-cert.sh --san     # self-signed cert for localhost, 30 days
docker compose up -d
./scripts/verify.sh             # expect: pass=9 fail=0, exit 0
```

`gen-cert.sh` without `--san` deliberately produces a certificate with no
subjectAltName. That variant is kept because it is how the SAN failure below was
produced, and it is worth re-running once to see it.

## Checks

`scripts/verify.sh` is the definition of done. Each check prints PASS/FAIL and the
script exits non-zero on any failure.

| # | Check | Expectation |
|---|-------|-------------|
| A | HTTPS health | `curl -sk https://localhost:8443/healthz` returns `{"status":"ok"}` |
| B | HTTP redirect | `:8080` returns 301 with `Location: https://localhost:8443/healthz` |
| C | Plaintext on TLS port | `curl http://localhost:8443/` returns 400 |
| D | Config test | `nginx -t` inside the running container says syntax is ok |
| E | Certificate | served cert has CN=localhost **and** SAN `DNS:localhost, IP:127.0.0.1` |
| F1 | Forwarded header | app logs an `X-Forwarded-For` that is present and is not nginx's own IP |
| F2 | Socket peer | the app sees nginx's container IP as its peer |
| G | TLS versions | 1.2 and 1.3 succeed when forced; 1.1 is rejected **by the server** |
| H | No bypass | `localhost:8000` refuses connections (curl exit 7) |

C returns 400 because nginx answers a plaintext request on a TLS listener with
"The plain HTTP request was sent to HTTPS port". That is nginx-specific behaviour,
not a general HTTP rule.

F1 and F2 are deliberately separate. `X-Forwarded-For` answers "who was the
original client" (from this host: `172.23.0.1`, the Docker bridge gateway); the
socket peer answers "who is talking to me now" (nginx, `172.23.0.3`). Conflating
them hides which layer set what.

G is split for a reason: in curl, `--tlsv1.2` means "1.2 **or higher**", so it can
negotiate 1.3 and prove nothing about 1.2. The check forces `--tls-max 1.2`. The
negative case prints the alert the server sent, and reports INCONCLUSIVE if the
client's own security level refuses to attempt TLS 1.1 before the server is reached.

## Decisions

| Decision | Why |
|---|---|
| `X-Forwarded-For $remote_addr`, not `$proxy_add_x_forwarded_for` | nginx is the edge here. Appending to a client-supplied header lets the client choose the first (trusted-looking) entry. |
| `X-Real-IP` identical to `X-Forwarded-For` | Intentional with a single trusted proxy; redundant but conventional, and some upstreams read only one. |
| `ssl_protocols TLSv1.2 TLSv1.3` written out | Current nginx already defaults to this. The line is documentation, not a behaviour change. |
| HSTS `max-age=60`, `always`, no `includeSubDomains`/`preload` | Browsers ignore HSTS on untrusted certs, so this does nothing until the cert is trusted. `always` keeps it on error responses too. Short value because HSTS binds to the hostname, not the port — a long max-age on `localhost` would affect every other local lab. |
| `client_max_body_size 1m`, `proxy_read_timeout 10s` | Explicit limits for a demo app; both are the kind of default worth stating rather than inheriting silently. |
| No gzip | The app returns a few dozen bytes, below `gzip_min_length`, so compression could not be demonstrated — only claimed. |
| No upstream keepalive | It needs `proxy_http_version 1.1` and `Connection ""`, and connection reuse is not visible in the access log. Unprovable here, so omitted. |
| App port unpublished | Removing the host mapping is part of the design, not an afterthought: otherwise the proxy is optional, and check H would fail. |
| Healthcheck in compose, not the Dockerfile | `depends_on: condition: service_healthy` reads it from compose; one definition cannot drift from the other. |
| uvicorn `--forwarded-allow-ips` left at its default | The default (127.0.0.1) is why F2 sees nginx's IP as the peer. Setting it to `*` would change that result. |
| Cert and config mounted as two narrow directories | Mounting `./nginx` over `/etc/nginx` hides `mime.types` and the stock includes. Mounting single files breaks when a file is missing (Docker creates a directory) or when an editor replaces the inode on save. |

## Failures found while building

**1. Certificate with no SAN.** Generated with `-subj "/CN=localhost"` only:

```
subject=CN = localhost
No extensions in certificate
```

Then, trusting that cert explicitly:

```bash
curl --cacert nginx/certs/server.crt https://localhost:8443/healthz
# {"status":"ok"}   exit 0
```

curl **accepted** it. OpenSSL falls back to the CN when no SAN exists, so curl is
the wrong witness for this failure. Browsers and Go reject CN-only certificates.
Fixed with `-addext "subjectAltName=DNS:localhost,IP:127.0.0.1"`, and check E now
asserts the SAN rather than just the subject — `openssl x509 -noout -subject
-dates` does not print the SAN at all, which is how a CN-only cert could pass a
careless check.

**2. Redirect without the published port.** The HTTP server first returned:

```
HTTP/1.1 301 Moved Permanently
Location: https://localhost/healthz
```

No port, so clients are sent to 443 — which this container does not publish. The
container cannot infer the published port, so it has to be written into the
redirect:

```nginx
return 301 https://$host:8443$request_uri;
```

Check B asserts the full `Location`, not just the status code, which is the only
reason this was caught automatically.

**3. Entrypoint check silently skipped, then correctly fatal.** The script was
mounted but created with mode 644. The official entrypoint only executes files
that are executable, so it was ignored — no error, and nginx started with a
missing certificate. After `chmod +x`, with the certificate moved aside:

```
/docker-entrypoint.sh: /docker-entrypoint.d/ is not empty, will attempt to perform configuration
FATAL: TLS certificate missing.
       expected: /etc/nginx/certs/server.crt and /etc/nginx/certs/server.key
       run: ./scripts/gen-cert.sh --san
```

and the container aborts before nginx starts. Two lessons: a mount is not a fix
unless the file is executable, and a check that only ever runs on the success path
is not a check.

## Limits, stated plainly

- The certificate is self-signed and untrusted. Browsers will warn; HSTS has no
  effect. Trusting it locally (e.g. mkcert) is out of scope.
- **No Let's Encrypt.** ACME needs a domain you control and port 80 reachable from
  the internet. With a real domain the changes would be: obtain the cert with
  certbot (`--webroot` or `--standalone`), point `ssl_certificate` at
  `/etc/letsencrypt/live/<domain>/fullchain.pem` and `ssl_certificate_key` at
  `privkey.pem`, add an ACME challenge location, and reload nginx on renewal
  (`certbot renew --deploy-hook "nginx -s reload"`). The redirect stays the same,
  minus the `:8443`, since 443 would be published directly.
- The certificate-presence check in `nginx/entrypoint/10-check-cert.sh` must be
  executable (mode 755) or the official entrypoint skips it silently. Both paths
  are now exercised: cert present, and cert absent (failure 3 above).
- Single host, one upstream, no rate limiting, no WAF, no upstream TLS.

## Versions

nginx 1.27.2 · OpenSSL 3.0.13 · python:3.12.7-slim · fastapi 0.115.0 · uvicorn 0.30.6
