# The prefix restore image (images/prefix-frame/README.md): both prefix init containers of
# charts/ycash-testnet run it. `fetch` downloads the prefix bundle (format ycash-prefix/1), checks
# SHA256SUMS against the pinned sha256 and its minisign signature against the Ycash release key,
# then every file; `frame` turns the verified chunks into -loadblock files (frame.py).
# Build context: the repository root (make image-prefix-frame).
FROM python:3.12-alpine@sha256:b658b05ce9c4eb97ec6fc19424818a1f31993659c2b505a532f470e83807815d
RUN apk add --no-cache curl jq coreutils minisign
WORKDIR /opt/prefix
COPY charts/ycash-testnet/files/prefix-restore.sh bundles/prefix/import/frame.py images/prefix-frame/prefix.sh ./
# the public key only (keys/README.md, key id 02C923A6C593AF18); nothing secret is in this image
COPY keys/ycash-release.pub ./ycash-release.pub
RUN chmod 0555 prefix.sh prefix-restore.sh && chmod 0444 frame.py ycash-release.pub
USER 2001:2001
ENTRYPOINT ["sh", "/opt/prefix/prefix.sh"]
CMD ["help"]
