# The Ycash testnet GPU miner (images/miner/README.md). The image holds only our start-up script and a
# small manifest (miners.conf): it contains NO miner binary. At container start the entrypoint
# downloads the selected miner (lolMiner by default; miniZ only when pinned) from its official
# release URL, checks it against the SHA-256 pinned in miners.conf and refuses to run on a mismatch,
# then mines Equihash 192,7 with Ycash's personalization "ZcashPoW" (ycash6 src/crypto/equihash.cpp:
# "ZcashPoW" || le32(N) || le32(K)) through a stratum pool (yolo). The container takes a pool address,
# a worker name and an optional payout address, nothing else: it runs on rented machines whose owners
# can read it, so it never holds a key, a password or a token.
#
# Base: buildpack-deps:noble-curl (Docker's official Ubuntu 24.04 image with curl, wget and CA
# certificates), so nothing is installed with apt. glibc is needed (both miners are glibc binaries),
# so not Alpine. Not an NVIDIA CUDA image: the miners bring their own GPU kernels and need only the
# driver's libcuda / libnvidia-ml, which the NVIDIA container runtime mounts from the host when
# NVIDIA_VISIBLE_DEVICES and NVIDIA_DRIVER_CAPABILITIES are set (below).
FROM buildpack-deps:noble-curl@sha256:a115b80bacdfad86050664accdf7e2d7be45edb87d98a3ba78b78f0f9a089c1a
COPY entrypoint.sh /usr/local/bin/ycash-miner
COPY miners.conf /opt/ycash-miner/miners.conf
RUN useradd --system --uid 2005 --user-group --create-home --home-dir /home/miner --shell /usr/sbin/nologin miner \
 && chmod 0755 /usr/local/bin/ycash-miner \
 && chmod 0644 /opt/ycash-miner/miners.conf
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    HOME=/home/miner
LABEL org.opencontainers.image.title="ycash-miner" \
      org.opencontainers.image.description="A GPU miner launcher for the Ycash testnets: downloads lolMiner (or, once pinned, miniZ) from its official release at start, checks its pinned SHA-256, and mines Equihash 192,7 with personalization ZcashPoW through a stratum pool. Contains no miner binary. Testnet use only."
WORKDIR /home/miner
USER 2005:2005
ENTRYPOINT ["/usr/local/bin/ycash-miner"]
