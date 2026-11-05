#!/usr/bin/env bash
# Super JinX health check: nginx edge must answer; in panel mode the panel API too.
curl -fsS -o /dev/null --max-time 4 http://127.0.0.1:8080/healthz || exit 1
if [ -n "${JINX_RPORT:-}" ] && [ "$JINX_RPORT" != "8080" ]; then
  curl -fsS -o /dev/null --max-time 4 "http://127.0.0.1:${JINX_RPORT}/healthz" || exit 1
fi
mode=$(printf '%s' "${JINX_MODE:-panel}" | tr 'A-Z' 'a-z')
[ "$mode" = "node" ] && exit 0
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:8000/api/system)
[ "$code" = "200" ] || [ "$code" = "401" ] || [ "$code" = "403" ] || exit 1
exit 0
