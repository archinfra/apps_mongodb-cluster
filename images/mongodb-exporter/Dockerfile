ARG EXPORTER_IMAGE=percona/mongodb_exporter:0.51.0
FROM ${EXPORTER_IMAGE} AS exporter

FROM docker.io/bitnami/minideb:bookworm
USER root
RUN install_packages bash ca-certificates
COPY --from=exporter /mongodb_exporter /bin/mongodb_exporter
RUN chmod 0755 /bin/mongodb_exporter
USER 1001
ENTRYPOINT ["/bin/mongodb_exporter"]
