#!/bin/bash
# Set MAXDOP and the cost threshold for parallelism from the container's real CPU
# quota. SQL Server sees the host's logical processor count inside a container, so
# its own defaults are sized for a machine this deploy does not have.
set -uo pipefail
log() { echo "[railway/tune] $*"; }

cpus=8
if [ -r /sys/fs/cgroup/cpu.max ]; then
  read -r quota period < /sys/fs/cgroup/cpu.max || true
  if [ "${quota:-max}" != "max" ] && [ -n "${period:-}" ] && [ "$period" -gt 0 ]; then
    cpus=$(( (quota + period - 1) / period ))
  fi
fi
[ "$cpus" -lt 1 ] && cpus=1
# Microsoft's guidance for a single NUMA node with 8 or fewer logical processors
# is MAXDOP <= that count; keep 8 as the ceiling.
maxdop=$cpus
[ "$maxdop" -gt 8 ] && maxdop=8
cost="${MSSQL_COST_THRESHOLD:-50}"

sqlcmd=/opt/mssql-tools18/bin/sqlcmd
[ -x "$sqlcmd" ] || sqlcmd=/opt/mssql-tools/bin/sqlcmd
if [ ! -x "$sqlcmd" ]; then
  log "sqlcmd not present in image; skipping parallelism tuning"
  exit 0
fi

for _ in $(seq 1 60); do
  if "$sqlcmd" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -l 5 -Q "SELECT 1" >/dev/null 2>&1; then
    "$sqlcmd" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "
      EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
      EXEC sp_configure 'max degree of parallelism', ${maxdop}; RECONFIGURE;
      EXEC sp_configure 'cost threshold for parallelism', ${cost}; RECONFIGURE;" >/dev/null 2>&1 \
      && log "cpu_quota=${cpus} maxdop=${maxdop} cost_threshold=${cost}" \
      || log "tuning query failed; leaving server defaults"
    exit 0
  fi
  sleep 5
done
log "server did not accept connections within 300s; leaving server defaults"
