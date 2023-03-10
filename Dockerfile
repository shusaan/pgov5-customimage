FROM ghcr.io/shusaan/pgov5-customimage:2565918b098c8f042769f5baceff264a9429ffed
# Pg13 image

USER root

RUN curl -sSL -o /etc/yum.repos.d/timescale_timescaledb.repo "https://packagecloud.io/install/repositories/timescale/timescaledb/config_file.repo?os=el&dist=8" && \
    microdnf --disablerepo=crunchypg14 install -y timescaledb-2-loader-postgresql-13-2.9.2-0.el8.x86_64 && \
    microdnf --disablerepo=crunchypg14 install -y timescaledb-toolkit-postgresql-13-1.14.0-0.x86_64 && \
    microdnf --disablerepo=crunchypg14 install -y timescaledb-2-postgresql-13-2.9.2-0.el8.x86_64 && \
    microdnf clean all
USER 26