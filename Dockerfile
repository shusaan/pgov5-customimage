FROM registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-15.4-0
USER root
COPY pgdg-redhat-repo-latest.noarch_EL-8-aarch64.rpm pgdg-redhat-repo-latest.noarch_EL-8-x86_64.rpm /tmp/
RUN rpm -i /tmp/pgdg-redhat-repo-latest.noarch_EL-8-aarch64.rpm && rpm -i /tmp/pgdg-redhat-repo-latest.noarch_EL-8-x86_64.rpm && \
    microdnf install -y timescaledb_15-2.10.3-1.rhel8 && \
    microdnf clean all
USER 26