# mssql-railway

Wrapper image for running Microsoft SQL Server 2022 on [Railway](https://railway.com).

Published as `ghcr.io/bon5co/mssql-railway`.

## Why a wrapper is needed

Railway volumes report a filesystem sector size of **16384 bytes**. SQL Server refuses to place
a data or log file on any volume reporting more than 4096:

```
Cannot use file '/data/x.mdf', because it is on a volume with sector size 16384.
SQL Server supports a maximum sector size of 4096 bytes.
```

No configuration reaches that check — write-through (`[control] writethrough`,
`alternatewritethrough`), trace flag 3979 and trace flag 1800 were each verified applied on a
live deploy and the rejection is unchanged, because the engine reads the sector size the
filesystem reports rather than probing the IO path.

Mounting the volume at `/var/opt/mssql`, which is the layout every published Railway template
for SQL Server uses, is worse than a rejection: the system databases land on the volume and the
engine dies during master recovery with

```
There have been 256 misaligned log IOs which required falling back to synchronous IO
Reason: 0x00000006 Message: Stack Overflow ... Last errno: 22
```

Railway reports that deployment **SUCCESS**, so the service looks healthy while the engine is
not running.

## What this image does instead

Data and log files stay on the container's own filesystem, where the sector size is 4096 and the
engine starts normally. Durability comes from SQL Server's own backup format, which *is* accepted
on the 16K-sector volume:

- **Phase 1** — the engine starts on private port `14330`, a port Railway does not route. Any
  `*.bak` in `$MSSQL_BACKUP_DIR` is restored, and the persisted server logins are replayed with
  their original SIDs and password hashes so restored database users still map. The engine is
  then shut down.
- **Phase 2** — the engine is re-exec'd on `1433`. The first connection the deployment ever
  accepts is therefore against fully restored state.
- While running, every user database is backed up to the volume every
  `$MSSQL_BACKUP_INTERVAL_MINUTES` minutes, and once more on `SIGTERM` before shutdown.

The volume holds `backups/` (one `.bak` per user database) and `state/logins.sql`.

### What survives a redeploy, and what does not

Survives: user databases (schema and data, as of the last backup), and SQL logins.

Does not survive: anything in `master`, `msdb` or `model` — server-level configuration, SQL Agent
jobs, linked servers. Data written after the last backup is lost if the container is killed
without a `SIGTERM`, which is why the shutdown hook takes a final backup.

## Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `MSSQL_SA_PASSWORD` | *(required)* | SA password. The container refuses to start without one. |
| `MSSQL_BACKUP_DIR` | `/data/backups` | Backup destination, on the volume. |
| `MSSQL_STATE_DIR` | `/data/state` | Persisted logins, on the volume. |
| `MSSQL_BACKUP_INTERVAL_MINUTES` | `15` | Backup cadence. |
| `MSSQL_PID` | `Developer` | Edition (see licensing). |

The entrypoint also repairs the ownership of the volume mount, which Railway creates as uid 0
while the engine runs as uid 10001, and sizes the engine's memory limit and CPU affinity from
`/sys/fs/cgroup` — a container reports the host's core count, not its own quota.

## Licensing

`MSSQL_PID` is baked as `Developer`, which is free but **licensed for development and test use
only, not for production**. For production, set `MSSQL_PID=Express`, which is free to deploy but
caps each database at 10 GB and the engine at roughly 1410 MB of memory, and has no backup
compression. Any paid edition (`Standard`, `Enterprise`) requires your own licence from
Microsoft. Accepting the EULA is a condition of running the image.

## Building

```
docker build -t mssql-railway .
```

The image is published to GHCR by `.github/workflows/publish.yml` on every push to `main`.
