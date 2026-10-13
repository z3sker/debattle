#!/bin/sh
set -eu
mkdir -p /data
chown node:node /data
chmod 700 /data
umask 077
exec su-exec node "$@"
