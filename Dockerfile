FROM registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-15.4-0
USER root
RUN curl -sSL -o /etc/yum.repos.d/timescale_timescaledb.repo "https://packagecloud.io/install/repositories/timescale/timescaledb/config_file.repo?os=el&dist=8" && \
    microdnf install -y timescaledb-toolkit-postgresql-15-1.17.0-0.x86_64 && \
    microdnf install -y timescaledb-2-loader-postgresql-15-2.10.3-0.el8.x86_64 && \
    microdnf install -y timescaledb-2-postgresql-15-2.10.3-0.el8.x86_64 && \
    microdnf clean all
USER 26