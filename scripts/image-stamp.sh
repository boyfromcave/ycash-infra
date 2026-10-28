#!/usr/bin/env bash
# Copyright (c) 2026 The Ycash developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or https://www.opensource.org/licenses/mit-license.php .
#
# The image stamp: one sha256 over the files an image is built from that the chart depends on (its
# Dockerfile, and the entrypoint / config files it copies in; the Makefile's STAMP_* lists them).
# `make image-*` writes it as the label org.ycash.infra.stamp; `make kind-load` (so kind-up and demo)
# compares each :local image's label with the files in the tree now, because the cluster reuses any
# :local image and a chart change can need a rebuilt one (the read-only root filesystem of #5 needed
# images/web's pid file in /tmp: an older web:local crash-looped).
# The node and lightwalletd Dockerfiles live in their own repos; they are hashed in place, never edited.
#   scripts/image-stamp.sh hash FILE...                 print the stamp
#   scripts/image-stamp.sh check IMAGE TARGET FILE...   exit 1 when IMAGE's label differs (TARGET: the make target to run)
#   ALLOW_STALE_IMAGES=1 (every image) or =ycashd,web (by name): warn and go on instead
set -euo pipefail
LABEL=org.ycash.infra.stamp

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

stamp() {
  local f
  for f in "$@"; do [ -f "$f" ] || { echo "image-stamp: $f missing" >&2; return 1; }; done
  for f in "$@"; do sha < "$f"; done | sha
}

case "${1:-}" in
  hash)
    shift; stamp "$@" ;;
  check)
    image=$2 target=$3; shift 3
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      echo "image-stamp: $image not built (make $target)"; exit 0
    fi
    want=$(stamp "$@")
    got=$(docker image inspect -f "{{ with .Config.Labels }}{{ index . \"$LABEL\" }}{{ end }}" "$image")
    if [ "$got" != "$want" ]; then
      echo "image-stamp: $image is stale: its stamp ${got:-(none: built before stamps)} is not ${want:0:12}…, the stamp of $* as they are now; run: make $target" >&2
      name=${image##*/}; name=${name%%:*}
      case ",${ALLOW_STALE_IMAGES:-}," in
        ,1,|*,"$name",*) echo "image-stamp: ALLOW_STALE_IMAGES=$ALLOW_STALE_IMAGES: going on with $image as it is" >&2; exit 0 ;;
      esac
      exit 1
    fi
    echo "image-stamp: $image matches $(basename "$1")" ;;
  *)
    sed -n 's/^#   //p' "$0" >&2; exit 2 ;;
esac
