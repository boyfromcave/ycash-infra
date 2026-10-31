# The faucet (images/faucet/README.md): Python's standard library only (JSON-RPC over HTTP to a node's
# RPC Service), the pages and their scripts beside it. FAUCET_MODE=regtest (the default) is the kind
# demo's faucet; FAUCET_MODE=testnet is a testnet's public faucet (charts/ycash-testnet). The kind
# chart's init container uses this same image to fetch the Sapling proving files (fetch-params.py).
FROM python:3.12-alpine@sha256:b658b05ce9c4eb97ec6fc19424818a1f31993659c2b505a532f470e83807815d
RUN adduser -D -u 2004 faucet
WORKDIR /app
COPY faucet.py fetch-params.py index.html app.js testnet.html testnet.js ./
USER faucet
EXPOSE 8080
ENTRYPOINT ["python3", "-I", "/app/faucet.py"]
