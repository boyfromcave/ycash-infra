#!/bin/sh
# Writes explorer/.env on first use: fresh random passwords for the node's RPC user, the PostgreSQL
# superuser and Inzyght's database role, plus the settings from .env.example. An existing .env is
# left alone (the passwords are baked into the volumes at their first start). .env is gitignored.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
env="$dir/.env"
[ -f "$env" ] && exit 0
pw() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }
umask 077
{
  echo "# written by explorer/env-init.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ); local secrets, never commit"
  echo "RPC_USER=explorer"
  echo "RPC_PASSWORD=$(pw)"
  echo "PG_SUPERUSER_PASSWORD=$(pw)"
  echo "PG_PASSWORD=$(pw)"
  grep -v '^\(RPC_USER\|RPC_PASSWORD\|PG_SUPERUSER_PASSWORD\|PG_PASSWORD\)=' "$dir/.env.example"
} > "$env"
echo "explorer: wrote $env (new passwords)"
