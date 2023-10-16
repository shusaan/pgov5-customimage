FROM registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-15.4-0
USER root
ADD ./pgdg-redhat-all.repo /etc/yum.repos.d/pgdg-redhat-all.repo
RUN microdnf install -y microdnf install -y timescaledb_15-2.10.3-1.rhel8.aarch64 && \
    microdnf clean all
USER 26