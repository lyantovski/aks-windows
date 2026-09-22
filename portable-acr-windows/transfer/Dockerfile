FROM alpine:3.22

ARG ORAS_VERSION=1.2.3

RUN apk add --no-cache bash ca-certificates coreutils curl jq tar zstd \
    && architecture="$(uname -m)" \
    && case "${architecture}" in \
         x86_64) oras_arch="amd64" ;; \
         aarch64) oras_arch="arm64" ;; \
         *) echo "Unsupported architecture: ${architecture}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL \
       "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${oras_arch}.tar.gz" \
       | tar -xz -C /usr/local/bin oras \
    && oras version

COPY export.sh import.sh /usr/local/bin/

RUN chmod 0755 /usr/local/bin/export.sh /usr/local/bin/import.sh

ENTRYPOINT ["/bin/bash"]
