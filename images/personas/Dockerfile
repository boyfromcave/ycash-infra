# The in-cluster Yellowback personas (plan K0c-ii, a SKELETON: not built, not wired into the chart).
# One image carrying what scripts/kind-personas.py runs on the host: the node tree's
# contrib/yellowback (yellowback-quote + yellowback_price.py), the Rust yellowback-attest, and the
# personas driver itself. A regtest-only Deployment per role (`regtest.personas.enabled`) would run
#   personas quote      yellowback-quote --mock-price /shared/price-quote        (beside the node Service)
#   personas attest N   yellowback-attest attest --mock-price /shared/price-N    (one per seq)
#   personas subscribe  yellowback-attest subscribe                               (the bus: an emptyDir shared
#                                                                                 by one Pod of all agents, or
#                                                                                 the iroh transport across Pods)
#   personas arm        the one-shot driver: payout, quote, windows, registrations, ARMED, poolFresh
#   personas walk       the price walk writing /shared/price-*
# Open design points before building it: the agents refuse plain-http RPC credentials to a host other
# than loopback (`allow_insecure_rpc = true` in the generated TOML, or run them in the node's Pod as
# sidecars sharing its network namespace, which also makes the dir bus a plain emptyDir); the registration
# step needs the node's wallet (RPC) and nothing else; a Job's immutability means the driver is a
# Deployment that exits into `sleep infinity` once armed, or a revisioned Job as arm.yaml.
# Build context: the workspace root (rule 5: images are built from the workspace trees, never copies).
#   docker build -f ycash-infra/images/personas/Dockerfile -t ycash/personas:local ..
FROM rust:1.91-bookworm AS attest
WORKDIR /src
COPY ycash6/contrib/yellowback/attest /src
RUN cargo build --locked --release

FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl jq && rm -rf /var/lib/apt/lists/*
COPY --from=attest /src/target/release/yellowback-attest /usr/local/bin/
COPY ycash6/contrib/yellowback/yellowback-quote ycash6/contrib/yellowback/yellowback_price.py /opt/yellowback/
COPY ycash-infra/scripts/kind-personas.py /opt/yellowback/personas.py
ENV YCASH6=/opt/ycash6 YELLOWBACK_ATTEST_BIN=/usr/local/bin/yellowback-attest YCASH_PERSONAS_DIR=/shared
# personas.py expects $YCASH6/contrib/yellowback/yellowback-quote: mirror the path
RUN mkdir -p /opt/ycash6/contrib/yellowback && ln -s /opt/yellowback/yellowback-quote /opt/yellowback/yellowback_price.py /opt/ycash6/contrib/yellowback/
ENTRYPOINT ["python3", "/opt/yellowback/personas.py"]
