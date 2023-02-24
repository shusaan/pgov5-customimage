FROM registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-14.6-2
USER root

RUN curl -sSL -o /etc/yum.repos.d/timescale_timescaledb.repo "https://packagecloud.io/install/repositories/timescale/timescaledb/config_file.repo?os=el&dist=8" && \
    microdnf --disablerepo=crunchypg14 update -y && \
    microdnf --disablerepo=crunchypg14 install -y timescaledb-2-postgresql-14-2.9.3-0.el8.x86_64 && \
    microdnf --disablerepo=crunchypg14 install -y timescaledb-toolkit-postgresql-14-1.14.0-0.x86_64 && \
    microdnf clean all
RUN sed -i '/\\c "\${PG_DATABASE}"$/a CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;' /opt/crunchy/bin/postgres/setup.sql && \
    sed -i '/SET application_name="container_setup";$/a CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;' /opt/crunchy/bin/postgres/setup.sql
USER 26
# magical user used here: https://github.com/CrunchyData/crunchy-containers/blob/master/build/postgres/Dockerfile
# https://github.com/CrunchyData/postgres-operator/issues/2692
