#!/usr/bin/env bash
set -uo pipefail
ulimit -n 65535 2>/dev/null || ulimit -n 16384 2>/dev/null || true   # many users at once
DATA="${JINX_DATA:-/var/lib/pasarguard}"
RUN="${JINX_RUN:-/run/jinx}"
for path in "$DATA" "$RUN"; do
  case "$path" in /*) ;; *) echo "[jinx] data/run paths must be absolute" >&2; exit 1;; esac
  case "$path" in *[!A-Za-z0-9_./-]*) echo "[jinx] data/run paths contain unsupported characters" >&2; exit 1;; esac
done
MODE="$(echo "${JINX_MODE:-panel}" | tr 'A-Z' 'a-z')"
mkdir -p "$DATA/node-certs" /var/lib/pg-node "$RUN"
rm -f "$RUN"/*.pid "$RUN"/*.start "$RUN/fatal"
# Railway may inject its own PORT and health-checks that port: nginx answers on it too, the domain stays on 8080
RPORT="${PORT:-8080}"; case "$RPORT" in ''|*[!0-9]*) echo "[jinx] PORT must be a number from 1 to 65535" >&2; exit 1;; esac
# never take a port the parts inside use (panel 8000, fast ping 8099, owner service 8100/8101, core 62050, configs 10001-10099)
if [ "$RPORT" -eq 8000 ] || [ "$RPORT" -eq 8099 ] || [ "$RPORT" -eq 8100 ] || [ "$RPORT" -eq 8101 ] || [ "$RPORT" -eq 62050 ] \
   || { [ "$RPORT" -ge 10001 ] && [ "$RPORT" -le 10099 ]; } || [ "$RPORT" -lt 1 ] || [ "$RPORT" -gt 65535 ]; then
  echo "[jinx] Railway PORT=$RPORT conflicts with an internal service port; choose a free public port" >&2
  exit 1
fi
export PORT=8080   # fixed: set the Railway domain target port to 8080
export JINX_RPORT="$RPORT"
export JINX_DATA="$DATA" JINX_RUN="$RUN" JINX_MODE="$MODE"
export SQLALCHEMY_DATABASE_URL="${SQLALCHEMY_DATABASE_URL:-sqlite+aiosqlite:///${DATA}/db.sqlite3}"
echo "[jinx] mode: $MODE | region: ${RAILWAY_REPLICA_REGION:-unknown} | domain: ${RAILWAY_PUBLIC_DOMAIN:-${PUBLIC_DOMAIN:-not set yet}}"

# owner admin/admin is written by bootstrap.py on FIRST boot only
unset SUDO_USERNAME SUDO_PASSWORD

if [ "$MODE" = "node" ]; then
  # ---- location mode: only core + nginx, files come from JINX_CODE ----
  python /code/jinxnode.py setup 2>&1 || exit 1
  NODE_LISTEN=0.0.0.0          # the panel reaches this core through Railway's TCP proxy (port 62050)
else
  # ---- node secrets: generated once, kept on the volume ----
  if [ ! -f "$DATA/node_api_key" ]; then (umask 077; python -c "import uuid;print(uuid.uuid4())" > "$DATA/node_api_key"); fi
  chmod 600 "$DATA/node_api_key"
  # cert also valid for Railway TCP proxy hosts, so other regions can join as locations
  if [ ! -f "$DATA/node-certs/cert.pem" ] || [ ! -f "$DATA/node-certs/.san2" ]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -keyout "$DATA/node-certs/key.pem" -out "$DATA/node-certs/cert.pem" -subj "/CN=jinx-node" \
      -addext "subjectAltName=IP:127.0.0.1,DNS:localhost,DNS:*.proxy.rlwy.net,DNS:*.up.railway.app" >/dev/null 2>&1 \
      || { echo "[jinx] node certificate generation failed" >&2; exit 1; }
    touch "$DATA/node-certs/.san2"
  fi
  NODE_LISTEN=127.0.0.1
  EXTRA=""; [ "$RPORT" != "$PORT" ] && EXTRA="listen ${RPORT};"
  SUBPATH="${SUBSCRIPTION_PATH:-sub}"; SUBPATH="${SUBPATH#/}"; SUBPATH="${SUBPATH%/}"
  case "$SUBPATH" in ''|*[!A-Za-z0-9_-]*) echo "[jinx] invalid SUBSCRIPTION_PATH (use one URL path segment)" >&2; exit 1;; esac
  export SUBSCRIPTION_PATH="$SUBPATH"
  sed -e "s/__PORT__/${PORT}/g" -e "s/#__EXTRA_LISTEN__/${EXTRA}/" \
      -e "s|__SUB_PATH__|${SUBPATH}|g" -e "s|__DATA_DIR__|${DATA}|g" \
      /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
fi

# ---- unique config paths for this install (kept on the volume / taken from the code) ----
python /code/genpaths.py 2>&1 || exit 1
nginx -t 2>&1 || exit 1

# ---- supervisor: keeps ONE part alive; guard.py restarts a broken part by stopping it ----
supervise() {   # supervise <name> <command...>
  local name="$1"; shift
  while [ ! -f "$RUN/fatal" ]; do
    "$@" &
    local pid=$!
    printf '%s\n' "$pid" > "$RUN/$name.pid"
    local start_id=""
    for _ in 1 2 3 4 5; do
      if [ -r "/proc/$pid/stat" ]; then start_id=$(sed 's/^.*) //' "/proc/$pid/stat" | awk '{print $20}'); fi
      [ -n "$start_id" ] && break
      sleep 0.02
    done
    if [ -n "$start_id" ]; then printf '%s\n' "$start_id" > "$RUN/$name.start"; else rm -f "$RUN/$name.start"; fi
    wait "$pid"
    rm -f "$RUN/$name.pid" "$RUN/$name.start"
    echo "[jinx] $name stopped, starting again in 3s"
    sleep 3
  done
}

run_node()  { cd /opt/pg-node && SERVICE_PORT=62050 NODE_HOST=$NODE_LISTEN SERVICE_PROTOCOL=grpc \
                API_KEY="$(cat $DATA/node_api_key)" \
                SSL_CERT_FILE="$DATA/node-certs/cert.pem" SSL_KEY_FILE="$DATA/node-certs/key.pem" \
                exec ./main 2>&1; }
run_panel() { cd /code && exec python main.py 2>&1; }
run_nginx() { exec nginx -g 'daemon off;' 2>&1; }
run_boot()  { cd /code && exec python bootstrap.py 2>&1; }
run_join()  { cd /code && exec python jinxnode.py join 2>&1; }
run_guard() { cd /code && exec python guard.py 2>&1; }

# nginx first: Railway's health check and the "getting ready" page on the domain answer within seconds
supervise nginx run_nginx &
if [ "$MODE" != "node" ]; then
  migration_try=1
  until ( cd /code && python -m alembic upgrade head 2>&1 ); do
    if [ "$migration_try" -ge 5 ]; then
      echo "[jinx] database migration failed after $migration_try attempts" >&2
      exit 1
    fi
    delay=$((migration_try * 3))
    echo "[jinx] database migration failed, retrying in ${delay}s ($migration_try/5)" >&2
    sleep "$delay"
    migration_try=$((migration_try + 1))
  done
fi
supervise node  run_node  &
if [ "$MODE" = "node" ]; then
  supervise join run_join &   # checks in with the panel every minute
else
  supervise panel run_panel &
  supervise boot  run_boot  &   # auto setup + owner key + locations
fi
supervise guard run_guard &   # guard bots + /jx-status

# ---- last line of defence: full service restart only if guard asks for it,
#      or the whole service does not answer for ~3 minutes ----
sleep 120; fails=0
while true; do
  if [ -f "$RUN/fatal" ]; then echo "[jinx] guard asked for a full restart ($(cat $RUN/fatal))"; break; fi
  if /usr/local/bin/jinx-healthcheck; then fails=0; else fails=$((fails+1)); fi
  if [ "$fails" -ge 6 ]; then echo "[jinx] watchdog: service not answering, restarting"; break; fi
  sleep 30
done
touch "$RUN/fatal"
for f in "$RUN"/*.pid; do kill "$(cat "$f")" 2>/dev/null; done
exit 1
