# The regtest faucet of the kind demo: Python's standard library only (JSON-RPC over HTTP to the
# node's RPC Service), the page and its script beside it. The chart's init container uses this same
# image to fetch the Sapling proving files into the params PVC (fetch-params.py).
FROM python:3.12-alpine@sha256:b658b05ce9c4eb97ec6fc19424818a1f31993659c2b505a532f470e83807815d
RUN adduser -D -u 2004 faucet
WORKDIR /app
COPY faucet.py fetch-params.py index.html app.js ./
USER faucet
EXPOSE 8080
ENTRYPOINT ["python3", "-I", "/app/faucet.py"]
