#!/bin/sh
ycash-cli -datadir="${DATADIR:-/var/lib/ycash}" getblockcount >/dev/null
