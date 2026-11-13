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
# certificates). glibc is needed (both miners are glibc binaries), so not Alpine. Not an NVIDIA CUDA
# image: the miners bring their own GPU kernels and need only the driver's libraries, which the NVIDIA
# container runtime mounts from the host when NVIDIA_VISIBLE_DEVICES and NVIDIA_DRIVER_CAPABILITIES
# are set (below): `compute` mounts libcuda and the driver's OpenCL implementation
# (libnvidia-opencl.so.1), `utility` mounts nvidia-smi and libnvidia-ml.
#
# OpenCL (GPU burst 1, 2026-11-13: a rented RTX 3060 ran 76 minutes and never reached the pool).
# lolMiner 1.98a mines Equihash 192,7 on Nvidia with an OpenCL kernel only: its binary carries
# Equihash192_7_NV_Cl and an embedded __equihash_192_7_NV_cl_bin, and no CUDA 192,7 solver (its CUDA
# Equihash paths are Beam and Flux, release notes 1.56). It reaches OpenCL by dlopen("libOpenCL.so.1"),
# the Khronos ICD loader, which then reads /etc/OpenCL/vendors/*.icd to find the vendor's library. The
# NVIDIA runtime mounts the vendor library but not the loader, and an .icd file only where the host
# has one. So the image carries the loader (ocl-icd-libopencl1) and NVIDIA's .icd entry, as NVIDIA's
# own OpenCL images do; clinfo lets the entrypoint print the OpenCL platforms before mining.
#
# cl-probe (GPU burst 2, 2026-11-13: clinfo listed the RTX 3060 while lolMiner counted 0 OpenCL GPUs).
# Listing a device is not using it: a miner also creates a context, compiles a kernel from source and
# runs it, and on Nvidia the compile step loads the driver's compiler libraries. cl-probe (cl-probe.c,
# ours, built here) takes those steps one by one and prints each error, so the container log names the
# step and the library that fails. The build stage is thrown away; only the small binary is copied.
FROM buildpack-deps:noble-curl@sha256:a115b80bacdfad86050664accdf7e2d7be45edb87d98a3ba78b78f0f9a089c1a AS probe
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc=4:13.2.0-7ubuntu1 libc6-dev \
      ocl-icd-opencl-dev=2.3.2-1build1 opencl-c-headers=3.0~2023.12.14-1 \
 && rm -rf /var/lib/apt/lists/*
COPY cl-probe.c /src/cl-probe.c
RUN gcc -O2 -Wall -Wextra -o /src/cl-probe /src/cl-probe.c -lOpenCL

FROM buildpack-deps:noble-curl@sha256:a115b80bacdfad86050664accdf7e2d7be45edb87d98a3ba78b78f0f9a089c1a
RUN apt-get update \
 && apt-get install -y --no-install-recommends ocl-icd-libopencl1=2.3.2-1build1 clinfo=3.0.23.01.25-1build1 \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /etc/OpenCL/vendors \
 && echo libnvidia-opencl.so.1 > /etc/OpenCL/vendors/nvidia.icd
COPY --from=probe /src/cl-probe /usr/local/bin/cl-probe
COPY entrypoint.sh /usr/local/bin/ycash-miner
COPY miners.conf /opt/ycash-miner/miners.conf
RUN useradd --system --uid 2005 --user-group --create-home --home-dir /home/miner --shell /usr/sbin/nologin miner \
 && chmod 0755 /usr/local/bin/ycash-miner /usr/local/bin/cl-probe \
 && chmod 0644 /opt/ycash-miner/miners.conf
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    HOME=/home/miner
LABEL org.opencontainers.image.title="ycash-miner" \
      org.opencontainers.image.description="A GPU miner launcher for the Ycash testnets: downloads lolMiner or miniZ (once pinned) from its official release at start, checks its pinned SHA-256, and mines Equihash 192,7 with personalization ZcashPoW through a stratum pool. Contains no miner binary. Testnet use only."
WORKDIR /home/miner
USER 2005:2005
ENTRYPOINT ["/usr/local/bin/ycash-miner"]
