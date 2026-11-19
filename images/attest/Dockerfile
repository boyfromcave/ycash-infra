# yellowback-attest, the Yellowback price attestor agent (ycash6 contrib/yellowback/attest), for the
# testnet attestor hosts (infra/testnet-seeds/nodes with a network's `attestors`; README "The
# attestors"). Built from the ycash6 tree at one commit (AGENTS.md rule 5): the build context is that
# tree, this file only says how.
#   docker build -f images/attest/Dockerfile <ycash6 tree>        (make image-attest; CI: attest-image.yml)
# The agent is one Rust binary (its own toolchain pin, rust-toolchain.toml, 1.91.0; exact `=` crate
# pins, built --locked). Its price sources are the sample configuration's [[sources]] and
# [[btc_usd_sources]] tables, cut from the same tree at build time; the host supplies only [node],
# [attest], [transport], [subscribe] and [cancel] (seedctl-attest render_attestors).
FROM rust:1.91-bookworm@sha256:c1e5f19e773b7878c3f7a805dd00a495e747acbdc76fb2337a4ebf0418896b33 AS build
WORKDIR /src
COPY contrib/yellowback/attest /src
RUN cargo build --locked --release && strip target/release/yellowback-attest
# sources.toml: the sample's [[sources]] and [[btc_usd_sources]] tables, from its first array table up
# to the next plain table ([transport]). The build fails if the sample no longer has them there, or if
# the agent does not accept the result beside a host part shaped like the one seedctl renders.
RUN set -eu; \
    awk '/^\[\[/ { on = 1 } on && /^\[[a-z]/ { exit } on { print }' attest.toml.sample > sources.toml; \
    grep -q '^\[\[sources\]\]' sources.toml; grep -q '^\[\[btc_usd_sources\]\]' sources.toml; \
    ! grep -qE '^\[(node|attest|transport|subscribe|cancel)\]' sources.toml; \
    printf '[node]\nrpc_url = "http://127.0.0.1:1"\nrpc_user = "u"\nrpc_password = "p"\n\n[attest]\nseq = 1\n\n[transport]\nkind = "dir"\npath = "/tmp/bus"\n\n' \
      | cat - sources.toml > /tmp/check.toml; \
    chmod 0600 /tmp/check.toml; \
    target/release/yellowback-attest check-config --conf /tmp/check.toml; \
    rm /tmp/check.toml

FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 2006 --no-create-home --shell /usr/sbin/nologin attest
COPY --from=build /src/target/release/yellowback-attest /usr/local/bin/yellowback-attest
COPY --from=build /src/sources.toml /usr/local/share/yellowback-attest/sources.toml
# The entrypoint joins the host's part (mounted read-only at /etc/yellowback-attest/host.toml, mode
# 0400: it holds the node's RPC password) and the image's sources into one private file on the
# container's /tmp (a tmpfs; umask 077, so the agent's mode check passes) and runs the agent on it:
#   <image> attest [--mock-price FILE]     one seat (the host part names its seq)
#   <image> subscribe                      beside a node: the topic into yed_addattestation
#   <image> check-config                   the joined file, checked (exit 2 when the agent refuses it)
RUN printf '%s\n' '#!/bin/sh' 'set -eu' 'umask 077' \
      'cat /etc/yellowback-attest/host.toml /usr/local/share/yellowback-attest/sources.toml > /tmp/attest.toml' \
      'mode=${1:-attest}; [ $# -gt 0 ] && shift' \
      'exec /usr/local/bin/yellowback-attest "$mode" --conf /tmp/attest.toml "$@"' \
      > /usr/local/bin/yellowback-attest-entrypoint \
 && chmod 0755 /usr/local/bin/yellowback-attest-entrypoint
USER 2006
ENTRYPOINT ["/usr/local/bin/yellowback-attest-entrypoint"]
