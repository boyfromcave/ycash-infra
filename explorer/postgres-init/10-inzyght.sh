#!/bin/sh
# Runs once, when the PostgreSQL volume is first initialised (docker-entrypoint-initdb.d): the
# database Inzyght indexes into, owned by a role without superuser rights. Inzyght's entrypoint
# applies its schema as that role (images/inzyght/entrypoint.sh).
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v db="$INZYGHT_DB" -v role="$INZYGHT_DB_USER" -v pass="$INZYGHT_DB_PASSWORD" <<'SQL'
CREATE ROLE :"role" LOGIN PASSWORD :'pass' NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE DATABASE :"db" OWNER :"role" ENCODING 'UTF8';
SQL
