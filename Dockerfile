FROM registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-15.4-0
#registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-15.3-3
#registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-15.2-0
USER root
COPY ./tsamd/lib/* /usr/pgsql-15/lib/
COPY ./tsamd/ext/* /usr/pgsql-15/share/extension/
# RUN curl -sSL -o /etc/yum.repos.d/timescale_timescaledb.repo "https://packagecloud.io/install/repositories/timescale/timescaledb/config_file.repo?os=el&dist=8" && \
#     microdnf install -y timescaledb-toolkit-postgresql-15-1.17.0-0.x86_64 && \
#     microdnf install -y timescaledb-2-loader-postgresql-15-2.10.3-0.el8.x86_64 && \
#     microdnf install -y timescaledb-2-postgresql-15-2.10.3-0.el8.x86_64 && \
#     microdnf clean all

USER 26
#timescaledb-toolkit-postgresql-15-1.15.0-0.x86_64