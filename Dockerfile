FROM registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-15.4-0
USER root
USER root
COPY ./tsamd/lib/* /usr/pgsql-15/lib/
COPY ./tsamd/ext/* /usr/pgsql-15/share/extension/
USER 26