# The pinned pack/verify image for the Zcash-testnet prefix (FORMAT.md).
#
# In plain words: the prefix files must come out the same, byte for byte, wherever they are
# made. gzip's output depends on the gzip program's version, so the packing runs inside this
# image, whose base is pinned by digest: everyone who packs uses the very same gzip.
#
# The base is the only input that affects the bytes; it must equal harvest.PACK_IMAGE, which is
# recorded in manifest.json (a unit test checks the two agree). The script and the vendored
# Zebra checkpoints are copied in from this directory, so the image is a function of the commit.
#
# Build:  docker build -t ycash-prefix:local bundles/prefix
# Use:    docker run --rm --network none -v "$PWD/work:/work" ycash-prefix:local verify /work/out
FROM docker.io/library/python:3.13.18-slim-trixie@sha256:76baad6037690d6e8c4397fbcaef17bca6f19eecef822b708fe8fa3417d30bb5
COPY harvest.py /opt/prefix/harvest.py
COPY data/ /opt/prefix/data/
# fail the build if the base lost gzip (it is Essential in Debian, so this never should)
RUN gzip --version | head -1
USER 65534:65534
WORKDIR /work
ENTRYPOINT ["python3", "-I", "/opt/prefix/harvest.py"]
