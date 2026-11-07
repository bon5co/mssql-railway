# Microsoft SQL Server 2022 for Railway.
#
# Railway volumes report a filesystem sector size of 16384 bytes; SQL Server accepts a
# maximum of 4096, so a database file cannot live on the volume (Msg 1802) and the
# system databases crash the engine during master recovery when /var/opt/mssql is the
# mount. Data files therefore stay on the image layer and durability comes from native
# backups written to the volume and restored on boot.
FROM mcr.microsoft.com/mssql/server:2022-latest@sha256:cf8f0ab2ebe61feec2eed2629061a07d247f791c2a8ddda74a4ac9f06a291718

USER root

# Baked so that no template variable needs a literal default (a literal default is
# dropped by templateGenerate and publishes as a blank required field).
ENV ACCEPT_EULA=Y \
    MSSQL_PID=Developer \
    MSSQL_BACKUP_DIR=/data/backups \
    MSSQL_STATE_DIR=/data/state \
    MSSQL_BACKUP_INTERVAL_MINUTES=15 \
    PATH="/opt/mssql-tools18/bin:${PATH}"

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh \
    && test -x /opt/mssql-tools18/bin/sqlcmd

EXPOSE 1433
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
