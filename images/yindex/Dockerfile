FROM golang:1.26-alpine@sha256:27f2d3b83cfc5803c8078f8e730af0f7c431bf067afaec8f60a36fb763187cba AS builder
WORKDIR /src
COPY yindex/ .
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/yindex ./cmd/yindex
FROM alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f
RUN apk add --no-cache ca-certificates && adduser -D -u 2003 yindex
COPY --from=builder /out/yindex /usr/local/bin/yindex
USER yindex
EXPOSE 9070 9071
ENTRYPOINT ["yindex"]
