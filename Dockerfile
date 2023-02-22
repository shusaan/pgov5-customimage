FROM registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-13.9-2

USER root

RUN curl -sSL -o /etc/yum.repos.d/timescale_timescaledb.repo "https://packagecloud.io/install/repositories/timescale/timescaledb/config_file.repo?os=el&dist=8" && \
    microdnf --disablerepo=crunchypg13 update -y && \
    microdnf --disablerepo=crunchypg13 install -y timescaledb-2-postgresql-13-2.9.3-0.el8.x86_64 && \
    microdnf --disablerepo=crunchypg13 install -y timescaledb-toolkit-postgresql-13-1.14.0-0.x86_64 && \
    microdnf clean all
USER 26
# magical user used here: https://github.com/CrunchyData/crunchy-containers/blob/master/build/postgres/Dockerfile
# https://github.com/CrunchyData/postgres-operator/issues/2692
