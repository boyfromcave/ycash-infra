# The value-pools page of an explorer host (images/value-pools/README.md): Python's standard library
# only. It reads the node over JSON-RPC (three read-only calls), keeps its samples in /data and serves
# one self-contained page and a JSON API on 8080. It holds the node's RPC credential (its environment)
# and nothing else; it needs no route to the internet.
FROM python:3.12-alpine@sha256:b658b05ce9c4eb97ec6fc19424818a1f31993659c2b505a532f470e83807815d
RUN adduser -D -u 2007 pools && mkdir /data && chown pools:pools /data
WORKDIR /app
COPY pools.py index.html ./
USER pools
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD ["python3", "-I", "-c", "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/healthz', timeout=3)"]
ENTRYPOINT ["python3", "-I", "/app/pools.py"]
