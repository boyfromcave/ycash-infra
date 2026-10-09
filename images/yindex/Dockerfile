FROM golang:1.24-alpine AS builder
WORKDIR /src
COPY yindex/ .
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/yindex ./cmd/yindex
FROM alpine:3.22
RUN apk add --no-cache ca-certificates && adduser -D -u 2003 yindex
COPY --from=builder /out/yindex /usr/local/bin/yindex
USER yindex
EXPOSE 9070 9071
ENTRYPOINT ["yindex"]
