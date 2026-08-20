# Microsoft SQL Server 2022 for Railway.
#
# The problem this image exists to fix is where the volume goes. Every listing in
# this category mounts it on /var/opt/mssql, which is the path the Docker Hub
# README gives — and on Railway a volume there kills the engine before it ever
# listens, on a deploy Railway still reports as SUCCESS:
#
#     Starting up database 'master'.
#     There have been 256 misaligned log IOs which required falling back to
#     synchronous IO.  The current IO is on file /var/opt/mssql/data/master.mdf.
#     This program has encountered a fatal error and cannot continue running
#             Reason: 0x00000006        Message: Stack Overflow
#             Last errno: 22 (Invalid argument)
#
# The instance-wide state SQL Server keeps under /var/opt/mssql (the .system
# hive, the secrets directory) cannot live on Railway's volume filesystem; the
# database files themselves can. So the volume is mounted on /data and the data,
# log and backup directories are pointed at it, which keeps master, msdb and
# every user database — logins, SA password, schemas, rows — across redeploys.
#
# Also fixed here:
#   * SQL Server refuses to initialise on a password that fails its complexity
#     policy, and it does so *after* the deploy looks like it started. The
#     entrypoint validates the password itself and says exactly what is wrong.
#   * The container sees the HOST's CPU count and RAM (measured on Railway: 48
#     processors, 393438 MB), so both the memory ceiling and MAXDOP are sized
#     from /sys/fs/cgroup instead.
#   * `2022-latest` moves. SQL Server upgrades its system databases when a newer
#     engine attaches them and there is no supported downgrade, so an unpinned
#     tag turns an unrelated redeploy into a one-way upgrade. Pinned by digest.
FROM mcr.microsoft.com/mssql/server@sha256:ba4c8329f48fb8f02e1416be6a930ebfd71268caee78aa985f3af4315e457c89

USER root

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY tune.sh /usr/local/bin/tune.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh /usr/local/bin/tune.sh

# Literals that belong to the image, not to the deploy form: Railway drops a
# template variable's default unless it is an expression, so anything with a
# fixed sane value is baked here instead of published as a blank required field.
ENV ACCEPT_EULA="Y" \
    MSSQL_PID="Developer" \
    MSSQL_AGENT_ENABLED="true" \
    MSSQL_TCP_PORT="1433" \
    MSSQL_DATA_DIR="/data" \
    MSSQL_LOG_DIR="/data" \
    MSSQL_BACKUP_DIR="/data"

EXPOSE 1433

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["/opt/mssql/bin/sqlservr"]
