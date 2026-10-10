#!/usr/bin/env bash
# A certificate Chrome trusts for https://localhost, from mkcert's local CA, as a TLS Secret the
# gateway uses (gateway.tls.mode=existing, secretName). `mkcert -install` puts the CA into the
# system trust store (macOS: the System keychain, a sudo prompt) and Chrome trusts it at once;
# without it the certificate is issued but Chrome warns (see docs/try-it.md). Without mkcert the
# chart's self-signed issuer stays (nothing is created) and the script says so.
set -euo pipefail
CLUSTER=${1:-ycash}; NS=${2:-ycash}; RELEASE=${3:-ycash}; CTX="kind-$CLUSTER"
SECRET="${RELEASE}-tls-mkcert"
if ! command -v mkcert >/dev/null; then
  echo "kind-cert: mkcert is not installed (brew install mkcert); the self-signed certificate stays — Chrome will warn once"; exit 0
fi
if [ ! -s "$(mkcert -CAROOT)/rootCA.pem" ] || ! security find-certificate -c mkcert /Library/Keychains/System.keychain >/dev/null 2>&1; then
  echo "kind-cert: installing mkcert's CA into the system trust store (a password prompt; skip with Ctrl-C and Chrome will warn)"
  mkcert -install || echo "kind-cert: the CA is not trusted by the system yet: run 'mkcert -install' yourself once"
fi
DIR=$(mktemp -d); trap 'rm -rf "$DIR"' EXIT
mkcert -cert-file "$DIR/tls.crt" -key-file "$DIR/tls.key" localhost 127.0.0.1 ::1 >/dev/null 2>&1
kubectl --context "$CTX" -n "$NS" create secret tls "$SECRET" --cert="$DIR/tls.crt" --key="$DIR/tls.key" --dry-run=client -o yaml \
  | kubectl --context "$CTX" -n "$NS" apply -f - >/dev/null
echo "kind-cert: Secret $NS/$SECRET from mkcert (localhost, 127.0.0.1, ::1; CA $(mkcert -CAROOT)/rootCA.pem)"
