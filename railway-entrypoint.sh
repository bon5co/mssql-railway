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
if [ "${MSSQL_RUN_AS_ROOT:-true}" = "true" ]; then
  chown -R 0:0 "$DATA_ROOT"
else
  chown -R "${MSSQL_UID}:${MSSQL_GID}" "$DATA_ROOT"
fi
chmod 0770 "$DATA_ROOT"
log "ulimits: stack=$(ulimit -s) nofile=$(ulimit -n) memlock=$(ulimit -l)"
log "volume ${DATA_ROOT} owner ${owner_before} -> $(stat -c '%u:%g' "$DATA_ROOT")"

# --- 3. Memory and CPU ceilings ---------------------------------------------
# SQL Server sizes itself from what the kernel reports, and on Railway that is
# the HOST: a container with a 8 GB limit logged "Processors: 48, Total Memory:
# 412550619136 bytes" and then died during startup of master with
# "Reason: 0x00000006 Message: Stack Overflow" before it ever listened. Docker's
# own cgroup reporting hides this locally (there the engine reads the limit
# correctly), so it only appears on the platform. Read the cgroup ourselves and
# hand the engine a memory ceiling and a CPU affinity mask it can actually honour.
cgroup_mem_bytes() {
  if [ -r /sys/fs/cgroup/memory.max ]; then
    v="$(cat /sys/fs/cgroup/memory.max)"
  elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    v="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
  else
    v="max"
  fi
  case "$v" in ''|max|0) echo 0 ;; *) echo "$v" ;; esac
}
cgroup_cpus() {
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r q p_ < /sys/fs/cgroup/cpu.max || true
    if [ "${q:-max}" != "max" ] && [ "${p_:-0}" -gt 0 ]; then
      echo $(( (q + p_ - 1) / p_ )); return
    fi
  elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
    q="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)"
    p_="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"
    if [ "$q" -gt 0 ] && [ "$p_" -gt 0 ]; then echo $(( (q + p_ - 1) / p_ )); return; fi
  fi
  echo 0
}

host_mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
mem_bytes="$(cgroup_mem_bytes)"
cpu_quota="$(cgroup_cpus)"
online_cpus="$(nproc --all 2>/dev/null || echo 1)"
log "cgroup memory.max=${mem_bytes} host MemTotal=$((host_mem_kb / 1024))MB cpu quota=${cpu_quota} online=${online_cpus}"

if [ -z "${MSSQL_MEMORY_LIMIT_MB:-}" ] && [ "$mem_bytes" -gt 0 ]; then
  mem_mb=$((mem_bytes / 1024 / 1024))
  # SQL Server's own guidance is to leave headroom for the OS and for the
  # non-buffer-pool allocations it makes outside this ceiling.
  limit_mb=$((mem_mb * 70 / 100))
  [ "$limit_mb" -lt 2048 ] && limit_mb=2048
  export MSSQL_MEMORY_LIMIT_MB="$limit_mb"
  log "MSSQL_MEMORY_LIMIT_MB=${limit_mb} (container limit ${mem_mb}MB)"
fi

AFFINITY=""
if [ "$cpu_quota" -gt 0 ] && [ "$online_cpus" -gt "$cpu_quota" ] && command -v taskset >/dev/null 2>&1; then
  AFFINITY="taskset -c 0-$((cpu_quota - 1))"
  log "pinning to CPUs 0-$((cpu_quota - 1)) (${online_cpus} online, quota ${cpu_quota})"
fi

# --- 3b. Write-through IO for the volume filesystem ---------------------------
# Railway mounts volumes as a bind mount whose filesystem does not honour the
# forced-unit-access (FUA) writes SQL Server issues by default: the engine logs
# "There have been 256 misaligned log IOs which required falling back to
# synchronous IO" while starting up master and then dies with
# "Message: Stack Overflow ... Last errno: 22 (Invalid argument)" before it ever
# listens, on a deploy Railway still reports as SUCCESS. Microsoft's documented
# setting for filesystems without proper direct-IO support is writethrough plus
# alternatewritethrough, with trace flag 3979 to disable the FUA path.
if [ "${MSSQL_FORCE_WRITETHROUGH:-true}" = "true" ]; then
  conf="${MSSQL_ROOT:-/var/opt/mssql}/mssql.conf"
  if ! grep -q "alternatewritethrough" "$conf" 2>/dev/null; then
    {
      echo "[control]"
      echo "writethrough = 1"
      echo "alternatewritethrough = 1"
      echo ""
      echo "[traceflag]"
      echo "traceflag0 = 3979"
    } >> "$conf"
    log "wrote write-through IO settings to ${conf}"
  else
    log "write-through IO settings already present in ${conf}"
  fi
fi

# --- 4. Parallelism sized from the cgroup ------------------------------------
# SQL Server 2022 already reads the cgroup memory limit, but it counts logical
# processors from the HOST (measured: "5 logical processors" inside a 2-CPU
# container), so MAXDOP is left at a value the container cannot deliver. Applied
# after the engine is up, in the background, because it is a T-SQL setting.
if [ "${MSSQL_TUNE_PARALLELISM:-true}" = "true" ]; then
  /usr/local/bin/tune.sh &
fi

if [ "${MSSQL_RUN_AS_ROOT:-true}" = "true" ]; then
  log "starting SQL Server as root"
  exec $AFFINITY /opt/mssql/bin/launch_sqlservr.sh "$@"
fi

log "starting SQL Server as uid ${MSSQL_UID}"
exec $AFFINITY setpriv --reuid="$MSSQL_UID" --regid="$MSSQL_GID" --init-groups \
  /opt/mssql/bin/launch_sqlservr.sh "$@"
