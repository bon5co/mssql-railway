#!/bin/bash
# Railway entrypoint for Microsoft SQL Server.
#
# Runs as root, repairs the volume, validates the SA password, then drops back to
# the image's own `mssql` user (uid 10001) before starting the engine. The engine
# itself never runs as root.
set -euo pipefail

MSSQL_UID=10001
MSSQL_GID=0
DATA_ROOT="${MSSQL_DATA_ROOT:-/var/opt/mssql}"

log() { echo "[railway] $*"; }

# --- 1. Password gate --------------------------------------------------------
# SQL Server applies Windows password policy to the SA account and refuses to
# initialise without a compliant one. It does that AFTER the container looks like
# it started, so an unusable password reads as a mystery crash loop. Check it
# here and say what is wrong.
pw="${MSSQL_SA_PASSWORD:-${SA_PASSWORD:-}}"
if [ -z "$pw" ]; then
  log "FATAL: MSSQL_SA_PASSWORD is empty. Set it to a password of at least 8 characters"
  log "       containing three of: uppercase, lowercase, digits, symbols."
  exit 1
fi
if [ "${#pw}" -lt 8 ]; then
  log "FATAL: MSSQL_SA_PASSWORD is ${#pw} characters; SQL Server requires at least 8."
  exit 1
fi
classes=0
[[ "$pw" =~ [A-Z] ]] && classes=$((classes + 1))
[[ "$pw" =~ [a-z] ]] && classes=$((classes + 1))
[[ "$pw" =~ [0-9] ]] && classes=$((classes + 1))
[[ "$pw" =~ [^A-Za-z0-9] ]] && classes=$((classes + 1))
if [ "$classes" -lt 3 ]; then
  log "FATAL: MSSQL_SA_PASSWORD uses only ${classes} character classes; SQL Server requires"
  log "       three of: uppercase, lowercase, digits, symbols. The server would exit 255 with"
  log "       'Password validation failed' after the deploy appeared to start."
  exit 1
fi
export MSSQL_SA_PASSWORD="$pw"
unset SA_PASSWORD

# --- 2. Volume ownership -----------------------------------------------------
# Railway mounts volumes owned by uid 0 and this image runs as uid 10001, so a
# volume on the data directory is unwritable by the only process that needs it.
# Unrepaired, sqlservr exits 1 with:
#   Error: The system directory [/.system] could not be created ... Permission denied
mkdir -p "$DATA_ROOT/data" "$DATA_ROOT/log" "$DATA_ROOT/backup" "$DATA_ROOT/secrets"
owner_before="$(stat -c '%u:%g' "$DATA_ROOT")"
chown -R "${MSSQL_UID}:${MSSQL_GID}" "$DATA_ROOT"
chmod 0770 "$DATA_ROOT"
log "volume ${DATA_ROOT} owner ${owner_before} -> $(stat -c '%u:%g' "$DATA_ROOT")"

# --- 3. Parallelism sized from the cgroup ------------------------------------
# SQL Server 2022 already reads the cgroup memory limit, but it counts logical
# processors from the HOST (measured: "5 logical processors" inside a 2-CPU
# container), so MAXDOP is left at a value the container cannot deliver. Applied
# after the engine is up, in the background, because it is a T-SQL setting.
if [ "${MSSQL_TUNE_PARALLELISM:-true}" = "true" ]; then
  /usr/local/bin/tune.sh &
fi

log "starting SQL Server as uid ${MSSQL_UID}"
exec setpriv --reuid="$MSSQL_UID" --regid="$MSSQL_GID" --init-groups \
  /opt/mssql/bin/launch_sqlservr.sh "$@"
