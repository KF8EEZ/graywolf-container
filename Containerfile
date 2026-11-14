# syntax=docker/dockerfile:1
#
# Graywolf APRS container. Multi-arch (linux/amd64, linux/arm64): the same file
# builds on a PC or a Raspberry Pi 5, or cross-builds with `--platform`.
#
# Rather than compiling the Rust modem + Go app + Svelte UI, this fetches the
# official release tarball for the target architecture and verifies it against
# the published checksums.txt.

ARG DEBIAN_RELEASE=trixie-slim

FROM docker.io/library/debian:${DEBIAN_RELEASE} AS fetch
ARG GRAYWOLF_VERSION=0.14.14
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/chrissnell/graywolf/releases/download/v${GRAYWOLF_VERSION}"; \
    tarball="graywolf_${GRAYWOLF_VERSION}_linux_${arch}.tar.gz"; \
    curl -fsSL -O "${base}/${tarball}"; \
    curl -fsSL -O "${base}/checksums.txt"; \
    grep " ${tarball}\$" checksums.txt | sha256sum -c -; \
    mkdir /out; \
    tar -xzf "${tarball}" -C /out graywolf graywolf-modem

FROM docker.io/library/debian:${DEBIAN_RELEASE}
ARG GRAYWOLF_VERSION=0.14.14
LABEL org.opencontainers.image.title="graywolf" \
      org.opencontainers.image.description="Graywolf APRS TNC / digipeater / iGate" \
      org.opencontainers.image.version="${GRAYWOLF_VERSION}" \
      org.opencontainers.image.source="https://github.com/KF8EEZ/graywolf-container" \
      org.opencontainers.image.documentation="https://KF8EEZ.github.io/graywolf-container/" \
      org.opencontainers.image.url="https://github.com/chrissnell/graywolf"

# libasound2: sound card access (Digirig audio). No other runtime deps needed.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libasound2t64 ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir /data && chown 1000:1000 /data

COPY --from=fetch /out/graywolf /out/graywolf-modem /usr/bin/

# Config DB, history DB and map tile cache all live under /data.
WORKDIR /data
VOLUME /data
USER 1000:1000
EXPOSE 8080

ENTRYPOINT ["/usr/bin/graywolf", \
            "-modem", "/usr/bin/graywolf-modem", \
            "-config", "/data/graywolf.db", \
            "-history-db", "/data/graywolf-history.db", \
            "-tile-cache-dir", "/data/tiles", \
            "-http", "0.0.0.0:8080"]
