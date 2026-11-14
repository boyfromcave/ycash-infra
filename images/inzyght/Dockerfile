# Inzyght, the Ycash block explorer (https://github.com/miodragpop/inzyght), for the explorer stack
# (explorer/README.md). Built UNMODIFIED from the author's repository at one commit: the build stage
# clones that commit itself, so no Inzyght source is copied into this repository and none is patched
# (AGENTS.md rule 5; workspace docs/plans/explorer/explorer-plan.md, E2).
#   docker build -t ycash/inzyght:local images/inzyght           (make image-inzyght)
#
# Inzyght has no licence file yet: build and run this image locally only. Do not push it to a
# registry until the author has answered (explorer plan §3.2, EX-2).
#
# INZYGHT_COMMIT is a full 40-hex SHA. The CMake build fetches its own dependencies at the tags its
# CMakeLists.txt names (curl 8.18.0, libzmq 4.3.5, glaze 7.7.0, Drogon 1.9.13); those are tags, not
# commits, so they are as reproducible as upstream's tags.
ARG INZYGHT_COMMIT=17f505f273c053247b59d20270e4d6a7b74994fb

# Debian 13: GCC 14 for C++23 (glaze 7 needs GCC 13 or later), CMake 3.31, libpq 17.
FROM debian:trixie@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6 AS build
ARG INZYGHT_COMMIT
ARG JOBS=
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates git cmake make g++ pkg-config \
      libssl-dev libpq-dev zlib1g-dev uuid-dev libjsoncpp-dev libc-ares-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN echo "$INZYGHT_COMMIT" | grep -qxE '[0-9a-f]{40}' || { echo "INZYGHT_COMMIT must be a full 40-hex SHA" >&2; exit 1; } \
 && git init -q . \
 && git remote add origin https://github.com/miodragpop/inzyght \
 && git fetch -q --depth 1 origin "$INZYGHT_COMMIT" \
 && git checkout -q FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "$INZYGHT_COMMIT"
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DFETCHCONTENT_QUIET=ON \
 && cmake --build build -j"${JOBS:-$(nproc)}" --target inzyght \
 && strip build/inzyght \
 && mkdir -p /out/opt/inzyght/sql /out/opt/inzyght/templates \
 && install -m 0755 build/inzyght /out/opt/inzyght/inzyght \
 && cp -r public /out/opt/inzyght/public \
 && install -m 0644 schema.sql schema_reorg_support.sql /out/opt/inzyght/sql/ \
 && install -m 0644 inzyght.conf.example config/drogon_config.json.example VERSION /out/opt/inzyght/templates/ \
 && echo "$INZYGHT_COMMIT" > /out/opt/inzyght/COMMIT \
 && (ldd build/inzyght | sort > /out/opt/inzyght/templates/ldd.txt)

FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
ARG INZYGHT_COMMIT
LABEL org.opencontainers.image.source="https://github.com/miodragpop/inzyght" \
      org.opencontainers.image.revision="${INZYGHT_COMMIT}" \
      org.opencontainers.image.description="Inzyght block explorer, unmodified, local build (no licence yet: do not publish)"
# libpq5 (the index), libssl3 (Drogon, curl), libjsoncpp, libuuid, zlib, c-ares (Drogon's resolver);
# postgresql-client applies the schema on first start (Inzyght's binary does not).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates libpq5 libssl3t64 libjsoncpp26 libuuid1 zlib1g libc-ares2 postgresql-client \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 2005 inzyght \
 && useradd --system --uid 2005 --gid 2005 --no-create-home --shell /usr/sbin/nologin inzyght
COPY --from=build /out/opt/inzyght /opt/inzyght
COPY entrypoint.sh /usr/local/bin/inzyght-entrypoint
# Inzyght reads ./inzyght.conf and ./config/drogon_config.json and serves ./public from its working
# directory, and writes ./inzyght.log and ./logs there. The entrypoint renders the configuration into
# INZYGHT_RUNDIR (a tmpfs in the stack, so the root filesystem can stay read-only) and links public/.
ENV INZYGHT_RUNDIR=/run/inzyght
USER 2005
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/inzyght-entrypoint"]
