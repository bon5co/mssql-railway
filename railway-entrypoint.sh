#!/bin/bash
# Railway entrypoint for SQL Server.
#
# Boot sequence:
#   1. repair the uid-0 volume mount and size the engine from the cgroup
#   2. start the engine on a private port (14330) that Railway does not route
#   3. restore every backup found on the volume, then replay persisted logins
#   4. shut that instance down and re-exec the engine on 1433, so the first
#      connection the deploy ever accepts is against restored state
#   5. back up on a timer and once more on SIGTERM
set -uo pipefail

log() { echo "[railway] $*"; }
die() { echo "[railway] FATAL: $*" >&2; exit 1; }

MSSQL_UID=10001
MSSQL_GID=0
PRIVATE_PORT=14330
DATA_DIR=/var/opt/mssql
SQLCMD=/opt/mssql-tools18/bin/sqlcmd

[ -n "${MSSQL_SA_PASSWORD:-}" ] || die "MSSQL_SA_PASSWORD is empty. SQL Server has no other way in; refusing to boot."

BACKUP_DIR=${MSSQL_BACKUP_DIR:-/data/backups}
STATE_DIR=${MSSQL_STATE_DIR:-/data/state}
INTERVAL_MIN=${MSSQL_BACKUP_INTERVAL_MINUTES:-15}
case "$INTERVAL_MIN" in ''|*[!0-9]*) INTERVAL_MIN=15 ;; esac
[ "$INTERVAL_MIN" -ge 1 ] 2>/dev/null || INTERVAL_MIN=15

# ---------------------------------------------------------------- volume repair
# Railway mounts volumes owned by uid 0 while this image runs as uid 10001.
for d in "$BACKUP_DIR" "$STATE_DIR"; do
    mkdir -p "$d" || die "cannot create $d"
done
MOUNT_ROOT=$(dirname "$BACKUP_DIR")
OWNER=$(stat -c %u:%g "$MOUNT_ROOT" 2>/dev/null || echo "?")
log "volume $MOUNT_ROOT owned by $OWNER"
if [ "$OWNER" != "${MSSQL_UID}:${MSSQL_GID}" ]; then
    chown -R "${MSSQL_UID}:${MSSQL_GID}" "$MOUNT_ROOT" 2>/dev/null \
        && log "repaired ownership of $MOUNT_ROOT to ${MSSQL_UID}:${MSSQL_GID}"
fi
chown -R "${MSSQL_UID}:${MSSQL_GID}" "$DATA_DIR" 2>/dev/null || true

# ------------------------------------------------------------- cgroup sizing
CPU_QUOTA=$(awk '{ if ($1 == "max") print 0; else printf "%d", ($1 / $2) + 0.5 }' /sys/fs/cgroup/cpu.max 2>/dev/null || echo 0)
[ "${CPU_QUOTA:-0}" -gt 0 ] 2>/dev/null || CPU_QUOTA=$(nproc)
MEM_MAX=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
if [ "$MEM_MAX" = "max" ]; then MEM_MB=0; else MEM_MB=$((MEM_MAX / 1024 / 1024)); fi
ENGINE_MB=$((MEM_MB * 70 / 100))
log "cpu_quota=${CPU_QUOTA} container_mem=${MEM_MB}MB (host reports $(nproc) cpus)"

write_conf() {
    # $1 = tcp port
    {
        echo "[network]"
        echo "tcpport = $1"
        # SQL Server rejects a memory limit below its 2 GB floor, so only pin it
        # when the container is large enough for the clamp to be meaningful.
        if [ "$ENGINE_MB" -ge 2048 ]; then
            echo
            echo "[memory]"
            echo "memorylimitmb = ${ENGINE_MB}"
        fi
    } > "$DATA_DIR/mssql.conf"
    chown "${MSSQL_UID}:${MSSQL_GID}" "$DATA_DIR/mssql.conf"
}

# SQL Server sizes its scheduler count from the CPUs it can SEE, which in a container
# is the host's count, not the cgroup quota.
CPU_LIST="0-$((CPU_QUOTA - 1))"
[ "$CPU_QUOTA" -eq 1 ] && CPU_LIST="0"
run_engine() { # background; $@ ignored
    setpriv --reuid="$MSSQL_UID" --regid="$MSSQL_GID" --clear-groups \
        taskset -c "$CPU_LIST" /opt/mssql/bin/sqlservr &
    ENGINE_PID=$!
}

q() { # port, sql -> stdout, trimmed columns
    local port=$1; shift
    "$SQLCMD" -S "127.0.0.1,${port}" -U sa -P "$MSSQL_SA_PASSWORD" -C -b -h -1 -W -Q "$*"
}

# sqlcmd rejects -y alongside either -W or -h -1 ("The y and the W options are mutually
# exclusive", "The -h and the -y 0 options are mutually exclusive"), and without -y it
# truncates variable-length output at 256 characters - which silently corrupts a dumped
# login SID or password hash. Long values therefore go through this variant, which keeps
# -h -1 by asking for an explicit width rather than the unlimited -y 0, and strips the
# padding -W would have removed afterwards.
qlong() { # port, sql -> stdout, untruncated
    local port=$1; shift
    "$SQLCMD" -S "127.0.0.1,${port}" -U sa -P "$MSSQL_SA_PASSWORD" -C -b -h -1 -y 8000 -Q "$*" | sed -e "s/[[:space:]]*$//"
}

wait_ready() {
    local port=$1 i
    for i in $(seq 1 90); do
        if q "$port" "SELECT 1" >/dev/null 2>&1; then return 0; fi
        kill -0 "$ENGINE_PID" 2>/dev/null || return 1
        sleep 2
    done
    return 1
}

# ------------------------------------------------------------------- restore
restore_all() {
    local port=$1 f db restored=0
    shopt -s nullglob
    for f in "$BACKUP_DIR"/*.bak; do
        db=$(basename "$f" .bak)
        if q "$port" "RESTORE DATABASE [${db}] FROM DISK = N'${f}' WITH REPLACE, RECOVERY" >/dev/null 2>&1; then
            log "restored database [${db}] from $(basename "$f")"
            restored=$((restored + 1))
        else
            log "WARNING: restore of [${db}] from $(basename "$f") failed"
        fi
    done
    shopt -u nullglob
    log "restore pass complete (${restored} database(s))"

    if [ -s "$STATE_DIR/logins.sql" ]; then
        if "$SQLCMD" -S "127.0.0.1,${port}" -U sa -P "$MSSQL_SA_PASSWORD" -C -b \
             -i "$STATE_DIR/logins.sql" >/dev/null 2>&1; then
            log "replayed persisted logins"
        else
            log "WARNING: replaying persisted logins failed"
        fi
    fi
}

# -------------------------------------------------------------------- backup
dump_logins() {
    local port=$1
    # Server logins live in master, which is on the image layer. Re-emit them with
    # their original SID and password hash so restored database users still map.
    qlong "$port" "SET NOCOUNT ON;
SELECT 'IF SUSER_SID(''' + REPLACE(p.name, '''', '''''') + ''') IS NULL CREATE LOGIN [' + p.name + '] WITH PASSWORD = ' + CONVERT(varchar(max), l.password_hash, 1) + ' HASHED, SID = ' + CONVERT(varchar(max), p.sid, 1) + ', CHECK_POLICY = OFF;'
FROM sys.server_principals p
JOIN sys.sql_logins l ON l.principal_id = p.principal_id
WHERE p.type = 'S' AND p.name NOT LIKE '##%' AND p.name <> 'sa';" \
        > "$STATE_DIR/logins.sql.tmp" 2>/dev/null \
        && mv "$STATE_DIR/logins.sql.tmp" "$STATE_DIR/logins.sql" \
        || log "WARNING: could not persist server logins"
    rm -f "$STATE_DIR/logins.sql.tmp"
}

backup_all() {
    local port=$1 db n=0
    for db in $(q "$port" "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0 AND is_read_only = 0;" 2>/dev/null); do
        [ -n "$db" ] || continue
        case "$db" in *[!A-Za-z0-9_.-]*) log "skipping backup of [$db]: unsupported characters in name"; continue ;; esac
        BAK="BACKUP DATABASE [${db}] TO DISK = N'${BACKUP_DIR}/${db}.bak' WITH INIT, FORMAT, COPY_ONLY"

        # Backup compression is not available in every edition; fall back without it.

        if q "$port" "$BAK, COMPRESSION" >/dev/null 2>&1 || q "$port" "$BAK" >/dev/null 2>&1; then
            n=$((n + 1))
        else
            log "WARNING: backup of [${db}] failed"
        fi
    done
    dump_logins "$port"
    log "backup pass complete (${n} database(s) to ${BACKUP_DIR})"
}

# ================================================================= phase 1
log "phase 1: recovering state on private port ${PRIVATE_PORT}"
write_conf "$PRIVATE_PORT"
run_engine
if wait_ready "$PRIVATE_PORT"; then
    restore_all "$PRIVATE_PORT"
    q "$PRIVATE_PORT" "SHUTDOWN WITH NOWAIT" >/dev/null 2>&1
    wait "$ENGINE_PID" 2>/dev/null
    log "phase 1 complete"
else
    log "WARNING: engine did not become ready on the private port; skipping restore"
    kill "$ENGINE_PID" 2>/dev/null
    wait "$ENGINE_PID" 2>/dev/null
fi

# ================================================================= phase 2
log "phase 2: serving on 1433 (backup every ${INTERVAL_MIN} min to ${BACKUP_DIR})"
write_conf 1433
run_engine

shutdown() {
    log "SIGTERM received; taking a final backup before shutdown"
    backup_all 1433
    kill -TERM "$ENGINE_PID" 2>/dev/null
    wait "$ENGINE_PID" 2>/dev/null
    exit 0
}
trap shutdown TERM INT

if wait_ready 1433; then
    log "engine ready"
    backup_all 1433
    (
        while sleep $((INTERVAL_MIN * 60)); do
            kill -0 "$ENGINE_PID" 2>/dev/null || exit 0
            backup_all 1433
        done
    ) &
else
    die "engine did not become ready on 1433"
fi

wait "$ENGINE_PID"
