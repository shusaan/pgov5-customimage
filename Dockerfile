FROM registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-15.4-0
USER root
ADD ./pgdg-redhat-repo-latest.noarch_EL-8-aarch64.rpm /tmp/pgdg-redhat-repo-latest.noarch_EL-8-aarch64.rpm
ADD ./pgdg-redhat-repo-latest.noarch_EL-8-x86_64.rpm /tmp/pgdg-redhat-repo-latest.noarch_EL-8-x86_64.rpm
RUN if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
        rpm -i /tmp/pgdg-redhat-repo-latest.noarch_EL-8-x86_64.rpm && microdnf install -y timescaledb_15-2.10.3-1.rhel8 && microdnf clean all; \
    elif [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
        rpm -i /tmp/pgdg-redhat-repo-latest.noarch_EL-8-aarch64.rpm && microdnf install -y timescaledb_15-2.10.3-1.rhel8 && microdnf clean all; \
    fi && rm -rf /tmp/*
USER 26