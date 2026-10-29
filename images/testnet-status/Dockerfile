# The testnet probe and status page (images/testnet-status/README.md): Python's standard library only.
# One image, two commands: probe.py (the default; JSON-RPC to the nodes, a P2P check of the seeds,
# /metrics and /status.json inside the cluster) and status.py (the public page, no secrets).
FROM python:3.12-alpine@sha256:b658b05ce9c4eb97ec6fc19424818a1f31993659c2b505a532f470e83807815d
RUN adduser -D -u 2005 status
WORKDIR /app
COPY probe.py status.py index.html status.js ./
USER status
EXPOSE 8080 9100
ENTRYPOINT ["python3", "-I"]
CMD ["/app/probe.py"]
