# Inzyght, the Ycash block explorer (https://github.com/miodragpop/inzyght), for the explorer stack
# (explorer/README.md). Built from the author's repository at one commit: the build stage clones that
# commit itself, so no Inzyght source is copied into this repository and there is no patch file
# (AGENTS.md rule 5; workspace docs/plans/explorer/explorer-plan.md, E2). The build then makes a few
# one-line edits to the clone, each located by a short anchor that must occur exactly once (the
# "edits" step below; images/inzyght/README.md, "What the build changes").
#   docker build -t ycash/inzyght:local images/inzyght           (make image-inzyght)
#
# Inzyght has no licence file yet: build and run this image locally only. Do not push it to a
# registry until the author has answered (explorer plan §3.2, EX-2).
#
# INZYGHT_COMMIT is a full 40-hex SHA. Inzyght's CMakeLists.txt fetches four dependencies by tag
# (FetchContent, GIT_TAG); a tag can move, so the build stage clones each one itself at the full
# commit SHA the tag resolved to (2026-11-14, `git ls-remote`, peeled), checks `git rev-parse HEAD`,
# and hands the trees to CMake with FETCHCONTENT_SOURCE_DIR_<NAME>. The CMake step then runs with no
# network at all, so nothing else can be fetched. Bumping INZYGHT_COMMIT means re-resolving the tags
# its CMakeLists.txt names and updating these four (five with trantor) together.
# INZYGHT_REPO is the repository to clone (https://github.com/<owner>/<repo>; the author's by default,
# a fork once there is one). The explorer host builds this file itself with INZYGHT_REPO and
# INZYGHT_COMMIT from its module config (infra/testnet-seeds/README.md, "The explorer").
ARG INZYGHT_REPO=https://github.com/miodragpop/inzyght
ARG INZYGHT_COMMIT=17f505f273c053247b59d20270e4d6a7b74994fb
# curl-8_18_0
ARG CURL_COMMIT=2eebc58c4b8d68c98c8344381a9f6df4cca838fd
# libzmq v4.3.5
ARG ZEROMQ_COMMIT=622fc6dde99ee172ebaa9c8628d85a7a1995a21d
# glaze v7.7.0
ARG GLAZE_COMMIT=dc90e3a31ef9b93e53efb8320aae1a36f7abd80f
# drogon v1.9.13, and its trantor submodule at the commit drogon v1.9.13 records
ARG DROGON_COMMIT=4c5430757ea5451a7c38fbbef4b4bef7dbb47f2f
ARG TRANTOR_COMMIT=63a4e5e164e219dc3bf30cdbfa1462ae5602fa97

# Debian 13: GCC 14 for C++23 (glaze 7 needs GCC 13 or later), CMake 3.31, libpq 17.
FROM debian:trixie@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6 AS build
ARG INZYGHT_REPO
ARG INZYGHT_COMMIT
ARG CURL_COMMIT
ARG ZEROMQ_COMMIT
ARG GLAZE_COMMIT
ARG DROGON_COMMIT
ARG TRANTOR_COMMIT
ARG JOBS=
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates git cmake make g++ pkg-config \
      libssl-dev libpq-dev zlib1g-dev uuid-dev libjsoncpp-dev libc-ares-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN echo "$INZYGHT_COMMIT" | grep -qxE '[0-9a-f]{40}' || { echo "INZYGHT_COMMIT must be a full 40-hex SHA" >&2; exit 1; } \
 && echo "$INZYGHT_REPO" | grep -qxE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' || { echo "INZYGHT_REPO must be https://github.com/<owner>/<repo>" >&2; exit 1; } \
 && git init -q . \
 && git remote add origin "$INZYGHT_REPO" \
 && git fetch -q --depth 1 origin "$INZYGHT_COMMIT" \
 && git checkout -q FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "$INZYGHT_COMMIT"
# The edits (images/inzyght/README.md, "What the build changes"): edit FILE ANCHOR REPLACEMENT, plain
# strings. The anchor must occur in the file exactly once, or the build stops: a later Inzyght commit
# that moves or fixes a line can never drop an edit silently. Inzyght has no licence, so this file
# holds no more of its text than the anchors. The edits made are listed in /opt/inzyght/EDITS.
RUN set -eu; \
    edit() { \
      n=$(A="$2" perl -0777 -ne '$n = () = /\Q$ENV{A}\E/g; print $n' "$1") || n=unreadable; \
      [ "$n" = 1 ] || { echo "inzyght edit: the anchor '$2' occurs $n times in $1, not exactly once: Inzyght changed there; review the edit (images/inzyght/README.md)" >&2; exit 1; }; \
      A="$2" B="$3" perl -0777 -pi -e 's/\Q$ENV{A}\E/$ENV{B}/' "$1"; \
      echo "$1: '$2' -> '$3'" >> /src/EDITS; echo "edit $1: '$2' -> '$3'"; \
    }; \
    : "1. a block's miner: room for any address the node prints (a post-quantum address is 53 characters)"; \
    edit schema.sql 'miner_address       character varying(50)' 'miner_address       character varying(128)'; \
    edit src/services/BlockIndexer.cc 'miner_address.size() > 50) miner_address.resize(50)' 'miner_address.size() > 128) miner_address.resize(128)'; \
    : "2. the search box: testnet (sm, s2) and post-quantum (sq., tq.) addresses are addresses too"; \
    edit public/js/main.js '(s[13]|t[13]|ys1|zs1)' '(s[13]|t[13]|ys1|zs1|sm|s2|[st]q)'; \
    : "3. coinbase maturity is a rule for a coinbase's transparent outputs only (post-quantum ones included)"; \
    edit public/js/transaction.js 'isCoinbase && confirmations < 100' 'isCoinbase && (tx.vout || []).length > 0 && confirmations < 100'; \
    edit public/js/transaction.js 'Coinbase outputs are' '${saplingOutputs > 0 ? "Transparent coinbase" : "Coinbase"} outputs are'
# The dependencies, each at its verified commit (fetch DIR URL SHA). libzmq gets the one-line edit
# Inzyght's CMakeLists.txt applies to it as its FetchContent PATCH_COMMAND (a source dir given with
# FETCHCONTENT_SOURCE_DIR_* skips that step).
RUN set -eu; \
    fetch() { \
      echo "$3" | grep -qxE '[0-9a-f]{40}' || { echo "$1: $3 is not a full 40-hex SHA" >&2; exit 1; }; \
      git init -q "$1" && git -C "$1" fetch -q --depth 1 "$2" "$3" && git -C "$1" checkout -q FETCH_HEAD \
      && test "$(git -C "$1" rev-parse HEAD)" = "$3" || { echo "$1: HEAD is not $3" >&2; exit 1; }; \
      echo "dep $1 $3"; \
    }; \
    fetch /deps/curl    https://github.com/curl/curl              "$CURL_COMMIT"; \
    fetch /deps/zeromq  https://github.com/zeromq/libzmq          "$ZEROMQ_COMMIT"; \
    fetch /deps/glaze   https://github.com/stephenberry/glaze     "$GLAZE_COMMIT"; \
    fetch /deps/drogon  https://github.com/drogonframework/drogon "$DROGON_COMMIT"; \
    want=$(git -C /deps/drogon ls-tree HEAD trantor | awk '$2 == "commit" { print $3 }'); \
    [ "$want" = "$TRANTOR_COMMIT" ] || { echo "drogon records trantor $want, not $TRANTOR_COMMIT" >&2; exit 1; }; \
    rmdir /deps/drogon/trantor 2>/dev/null || true; \
    fetch /deps/drogon/trantor https://github.com/an-tao/trantor  "$TRANTOR_COMMIT"; \
    sed -i "s/cmake_minimum_required(VERSION 2.8.12)/cmake_minimum_required(VERSION 3.15...3.28)/" /deps/zeromq/CMakeLists.txt
RUN --network=none cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DFETCHCONTENT_QUIET=ON \
      -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
      -DFETCHCONTENT_SOURCE_DIR_CURL=/deps/curl -DFETCHCONTENT_SOURCE_DIR_ZEROMQ=/deps/zeromq \
      -DFETCHCONTENT_SOURCE_DIR_GLAZE=/deps/glaze -DFETCHCONTENT_SOURCE_DIR_DROGON=/deps/drogon \
 && cmake --build build -j"${JOBS:-$(nproc)}" --target inzyght \
 && strip build/inzyght \
 && mkdir -p /out/opt/inzyght/sql /out/opt/inzyght/templates \
 && install -m 0755 build/inzyght /out/opt/inzyght/inzyght \
 && cp -r public /out/opt/inzyght/public \
 && install -m 0644 schema.sql schema_reorg_support.sql /out/opt/inzyght/sql/ \
 && install -m 0644 inzyght.conf.example config/drogon_config.json.example VERSION /out/opt/inzyght/templates/ \
 && install -m 0644 EDITS /out/opt/inzyght/EDITS \
 && echo "$INZYGHT_COMMIT" > /out/opt/inzyght/COMMIT \
 && printf 'curl %s\nlibzmq %s\nglaze %s\ndrogon %s\ntrantor %s\n' "$CURL_COMMIT" "$ZEROMQ_COMMIT" "$GLAZE_COMMIT" "$DROGON_COMMIT" "$TRANTOR_COMMIT" > /out/opt/inzyght/DEPENDENCIES \
 && (ldd build/inzyght | sort > /out/opt/inzyght/templates/ldd.txt)

FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
ARG INZYGHT_REPO
ARG INZYGHT_COMMIT
LABEL org.opencontainers.image.source="${INZYGHT_REPO}" \
      org.opencontainers.image.revision="${INZYGHT_COMMIT}" \
      org.opencontainers.image.description="Inzyght block explorer with the build edits in /opt/inzyght/EDITS, local build (no licence yet: do not publish)"
# libpq5 (the index), libssl3 (Drogon, curl), libjsoncpp, libuuid, zlib, c-ares (Drogon's resolver);
# postgresql-client applies and checks the schema on every start (Inzyght's binary does not).
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
