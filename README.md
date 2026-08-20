# mssql-railway

Microsoft SQL Server 2022 packaged for [Railway](https://railway.com), pinned to
CU26 (`16.0.4265.3`) by digest.

Image: `ghcr.io/bon5co/mssql-railway:2022-CU26`

## What this wrapper adds

Three things, each of which is shipped broken by at least one live Railway
listing for this database:

1. **It boots on a Railway volume.** Railway mounts volumes owned by uid 0 and
   the official image runs as `mssql` (uid 10001), so the data directory is
   unwritable by the only process that needs it. Unrepaired, the container exits
   1 with `The system directory [/.system] could not be created ... Access
   Denied errno = 0xD(13) Permission denied`. The entrypoint repairs ownership
   as root and then drops back to uid 10001 with `setpriv` — the database does
   not run as root.
2. **It fails fast on a bad SA password.** SQL Server applies Windows password
   policy to the SA account and refuses to initialise without at least eight
   characters from three of {uppercase, lowercase, digits, symbols}. It does so
   after the container appears to have started, which reads as a mystery crash
   loop. The entrypoint checks the password itself and names the problem.
3. **It sizes parallelism from the container.** SQL Server 2022 already reads
   the cgroup memory limit, but it counts logical processors from the host — a
   two-CPU container reports `5 total logical processors` — so MAXDOP is left
   sized for a machine the deploy does not have. `MAXDOP` and the cost threshold
   for parallelism are set from `/sys/fs/cgroup/cpu.max` once the engine is up.

Also: the SQL Server Agent is enabled, and the image is pinned by digest.
SQL Server upgrades its system databases when a newer engine attaches them and
has no supported downgrade, so a moving tag turns an unrelated redeploy into a
one-way upgrade.

## Variables

| Variable | Required | Notes |
| --- | --- | --- |
| `MSSQL_SA_PASSWORD` | yes | 8+ chars, three of upper/lower/digit/symbol. |
| `MSSQL_TUNE_PARALLELISM` | no | `false` to leave server defaults. |
| `MSSQL_COST_THRESHOLD` | no | Default `50`. |

`ACCEPT_EULA`, `MSSQL_PID` (Developer), `MSSQL_AGENT_ENABLED`, `MSSQL_TCP_PORT`
and the data/log/backup directories are baked into the image.

## Railway notes

- Mount a volume at `/var/opt/mssql`.
- SQL Server speaks TDS, not HTTP: publish a **TCP proxy** on port 1433 and set
  no healthcheck path.

## Licence

The wrapper is MIT. The image it wraps is Microsoft's, under the terms accepted
by `ACCEPT_EULA=Y`; Developer Edition is licensed for development and test use.
