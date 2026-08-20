# Microsoft SQL Server 2022 for Railway.
#
# Three Railway-specific problems are fixed here. Each one is shipped unfixed by
# at least one live marketplace listing, and three of the five listings in this
# category never finish their first boot because of them:
#
#   1. Railway mounts volumes owned by uid 0, and this image runs as `mssql`
#      (uid 10001). A volume on /var/opt/mssql is therefore unwritable by the
#      process that has to write it, and the server exits immediately with
#      "The system directory [/.system] could not be created ... Access Denied".
#      The entrypoint repairs ownership as root and then drops back to uid 10001,
#      so the database does not run as root either.
#   2. SQL Server refuses to initialise on a password that fails its complexity
#      policy, and it does so *after* the deploy looks like it started. The
#      entrypoint validates the password itself and says exactly what is wrong.
#   3. `2022-latest` moves. SQL Server upgrades its system databases when a newer
#      engine attaches them and there is no supported downgrade, so an unpinned
#      tag turns an unrelated redeploy into a one-way upgrade. Pinned by digest.
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
    MSSQL_DATA_DIR="/var/opt/mssql/data" \
    MSSQL_LOG_DIR="/var/opt/mssql/log" \
    MSSQL_BACKUP_DIR="/var/opt/mssql/backup"

EXPOSE 1433

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["/opt/mssql/bin/sqlservr"]
