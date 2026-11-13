# yolo, the Ycash stratum pool (https://github.com/boyfromcave/yolo), for the testnet pool host
# (infra/testnet-seeds/nodes with a network's `pool`; README "The pool"). Built from the yolo tree at
# one commit (AGENTS.md rule 5): the build context is that tree, this file only says how.
#   docker build -f images/yolo/Dockerfile <yolo tree>          (make image-yolo; CI: yolo-image.yml)
# The toolchain is the one yolo pins (rust-toolchain.toml, 1.91.0); --locked builds its Cargo.lock.
FROM rust:1.91-bookworm@sha256:c1e5f19e773b7878c3f7a805dd00a495e747acbdc76fb2337a4ebf0418896b33 AS build
WORKDIR /src
COPY . .
RUN cargo build --release --locked && mkdir -p /out && install -m 0755 target/release/yolo /out/yolo

# glibc (the build stage's Debian 12), no OpenSSL (yolo's HTTP client is rustls), no shell use at run time.
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
RUN useradd --system --uid 2004 --no-create-home --shell /usr/sbin/nologin yolo
COPY --from=build /out/yolo /usr/local/bin/yolo
USER 2004
EXPOSE 3333
ENTRYPOINT ["/usr/local/bin/yolo"]
CMD ["--help"]
