# yellowback-quote, the Yellowback pool quote agent (ycash6 contrib/yellowback/yellowback-quote), for
# the testnet pool host (infra/testnet-seeds/nodes with a network's `pool.quote`; README "The pool":
# "Pool quotes"). Built from the ycash6 tree at one commit (AGENTS.md rule 5): the build context is
# that tree, this file only says how.
#   docker build -f images/quote/Dockerfile <ycash6 tree>        (make image-quote; CI: quote-image.yml)
# The agent is Python (standard library only, tomllib: Python 3.11 or later; Debian 12 ships 3.11).
# Its price sources are the sample configuration's [[sources]] and [[btc_usd_sources]] tables, cut from
# the same tree at build time; the host supplies only [node] and [quote] (seedctl render_pool).
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 2005 --no-create-home --shell /usr/sbin/nologin quote
COPY contrib/yellowback/yellowback-quote contrib/yellowback/yellowback_price.py /usr/local/lib/yellowback-quote/
COPY contrib/yellowback/pool/yellowback-quote.toml.sample /usr/local/share/yellowback-quote/sample.toml
# sources.toml: everything from the sample's first array table on ([[sources]], [[btc_usd_sources]]).
# The build fails if the sample no longer ends with them, or if the agent cannot read the result.
RUN set -eu; d=/usr/local/share/yellowback-quote; \
    sed -n '/^\[\[/,$p' "$d/sample.toml" > "$d/sources.toml"; \
    grep -q '^\[\[sources\]\]' "$d/sources.toml"; ! grep -qE '^\[(node|quote)\]' "$d/sources.toml"; \
    chmod 0755 /usr/local/lib/yellowback-quote/yellowback-quote; \
    printf '[node]\nrpc_url = "http://127.0.0.1:1"\n' | cat - "$d/sources.toml" > /tmp/check.toml; \
    python3 -c 'import importlib.machinery as m, sys; sys.path.insert(0, "/usr/local/lib/yellowback-quote"); q = m.SourceFileLoader("q", "/usr/local/lib/yellowback-quote/yellowback-quote").load_module(); c = q.load_config("/tmp/check.toml"); assert c["sources"] and c["quote"]["poll_seconds"] == 75 and "min_move_bps" in c["quote"], c["quote"]'; \
    rm /tmp/check.toml
# The entrypoint joins the host's [node]/[quote] (mounted read-only at /etc/yellowback-quote/host.toml,
# mode 0400: it holds the node's RPC password) and the image's sources into one private file on the
# container's /tmp (a tmpfs; umask 077, so the agent's mode check passes) and runs the agent on it.
RUN printf '%s\n' '#!/bin/sh' 'set -eu' 'umask 077' \
      'cat /etc/yellowback-quote/host.toml /usr/local/share/yellowback-quote/sources.toml > /tmp/quote.toml' \
      'exec python3 /usr/local/lib/yellowback-quote/yellowback-quote --conf /tmp/quote.toml "$@"' \
      > /usr/local/bin/yellowback-quote-entrypoint \
 && chmod 0755 /usr/local/bin/yellowback-quote-entrypoint
USER 2005
ENTRYPOINT ["/usr/local/bin/yellowback-quote-entrypoint"]
