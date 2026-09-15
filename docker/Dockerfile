# syntax=docker/dockerfile:1
#
# Overpass API (Fishtechy fork) - container image
# ------------------------------------------------
# Two stages:
#   1. "builder"  - compiles Overpass API from source (autotools) exactly the
#      way the OSM wiki install guide does it by hand.
#   2. runtime    - a slim image with only the compiled binaries + Apache,
#      which serves the CGI "interpreter" frontend and runs the dispatcher.
#
# Build context MUST be the repository root (the folder that contains "src/").
#
#   docker build -f docker/Dockerfile -t overpass-api:latest .

##############################
# 1. Builder
##############################
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      autoconf \
      automake \
      libtool \
      pkg-config \
      m4 \
      libexpat1-dev \
      zlib1g-dev \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
# Only the autotools project (src/) is needed to build the binaries.
COPY src/ ./src/

WORKDIR /build/src
RUN autoreconf -i \
    && ./configure --prefix=/usr/local \
    && make -j"$(nproc)" \
    && make install

##############################
# 2. Runtime
##############################
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
      apache2 \
      libexpat1 \
      zlib1g \
      bzip2 \
      wget \
      ca-certificates \
      procps \
    && rm -rf /var/lib/apt/lists/* \
    # Classic CGI needs a non-threaded MPM.
    && a2dismod mpm_event >/dev/null 2>&1 || true \
    && a2enmod mpm_prefork \
    && a2enmod cgi \
    && a2dissite 000-default

# Compiled binaries + scripts + cgi-bin from the builder stage.
COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY --from=builder /usr/local/cgi-bin/ /usr/local/cgi-bin/

COPY docker/apache-overpass.conf /etc/apache2/sites-available/overpass.conf
RUN a2ensite overpass

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# --- Runtime configuration (override any of these with `-e` / compose) -----
# Overpass's own binaries resolve the database directory from this env var
# (see template_db/dispatcher_client.cc), so it must be set identically for
# the dispatcher, the CGI interpreter (via Apache SetEnv) and the diff-updater.
ENV OVERPASS_DB_DIR=/db/ \
    OVERPASS_META=yes \
    OVERPASS_DIFF_UPDATES=1 \
    OVERPASS_DIFF_URL=https://planet.openstreetmap.org/replication/minute \
    OVERPASS_IMPORT_FILE=/data/import.osm.bz2 \
    OVERPASS_REPLICATION_SEQUENCE_NUMBER=""

EXPOSE 80
VOLUME ["/db"]

ENTRYPOINT ["/entrypoint.sh"]