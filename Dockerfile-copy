FROM registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-15.4-0
USER root
COPY ./tsarm/lib/* /usr/pgsql-15/lib/
COPY ./tsarm/ext/* /usr/pgsql-15/share/extension/
USER 26