#!/bin/sh
# wait-for.sh <host> <port> [seconds]: used by init containers.
set -eu
for i in $(seq 1 "${3:-300}"); do nc -z "$1" "$2" 2>/dev/null && exit 0; sleep 1; done; echo "timeout waiting for $1:$2"; exit 1
