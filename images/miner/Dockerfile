# The Ycash testnet GPU miner (images/miner/README.md): lolMiner, unmodified, at a pinned release whose
# archive is checked against the SHA-256 below, mining Equihash 192,7 with Ycash's personalization
# "ZcashPoW" (ycash6 src/crypto/equihash.cpp: "ZcashPoW" || le32(N) || le32(K)) through a stratum pool
# (yolo). The entrypoint takes a pool address, a worker name and an optional payout address, nothing
# else: the container runs on rented machines whose owners can read it, so it never holds a key, a
# password or a token.
#
# Base: plain Ubuntu, not an NVIDIA CUDA image. lolMiner ships its own GPU kernels and needs only the
# driver's libcuda / libnvidia-ml, which the NVIDIA container runtime mounts from the host when
# NVIDIA_VISIBLE_DEVICES and NVIDIA_DRIVER_CAPABILITIES are set (below). A CUDA runtime image would add
# about 1 GB of libraries the miner never loads, and their CVEs. glibc is needed (lolMiner is a glibc
# binary), so not Alpine for the final stage. Alpine is used only to download and check the archive
# (busybox wget and sha256sum, no package installs).
# Bump: a new LOLMINER_VERSION with its SHA-256 (download the release archive and `sha256sum` it, and
# compare with the digest GitHub shows on the release page), then the miner-image workflow.
FROM alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f AS fetch
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
ARG LOLMINER_VERSION=1.98a
ARG LOLMINER_SHA256=0b8078299654a12846e4967f1db3506409cfb8b1031687a910965d1a99c6f270
WORKDIR /fetch
RUN wget -q -O lolminer.tar.gz \
      "https://github.com/Lolliedieb/lolMiner-releases/releases/download/${LOLMINER_VERSION}/lolMiner_v${LOLMINER_VERSION}_Lin64.tar.gz" \
 && echo "${LOLMINER_SHA256}  lolminer.tar.gz" | sha256sum -c - \
 && mkdir out \
 && tar -xzf lolminer.tar.gz -C out --strip-components=1 \
 && test -x out/lolMiner && test -f out/license.txt \
 && rm lolminer.tar.gz

FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
ARG LOLMINER_VERSION=1.98a
# CA certificates for the miner's own TLS connections (its developer-fee pool), without apt
COPY --from=fetch /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
# the executable and its licence, unmodified (licence point 3 allows redistribution only so)
COPY --from=fetch /fetch/out/lolMiner /fetch/out/license.txt /opt/lolminer/
COPY entrypoint.sh /usr/local/bin/ycash-miner
RUN useradd --system --uid 2005 --user-group --create-home --home-dir /home/miner --shell /usr/sbin/nologin miner \
 && chmod 0755 /usr/local/bin/ycash-miner /opt/lolminer/lolMiner \
 && chmod 0644 /opt/lolminer/license.txt
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    LOLMINER_VERSION=${LOLMINER_VERSION}
LABEL org.opencontainers.image.title="ycash-miner" \
      org.opencontainers.image.description="A GPU miner for the Ycash testnets: lolMiner (unmodified, 1% developer fee) at Equihash 192,7 with personalization ZcashPoW, through a stratum pool. Testnet use only." \
      org.opencontainers.image.licenses="LicenseRef-lolMiner"
WORKDIR /home/miner
USER 2005:2005
ENTRYPOINT ["/usr/local/bin/ycash-miner"]
