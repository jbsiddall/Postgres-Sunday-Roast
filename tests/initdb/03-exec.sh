#!/usr/bin/env bash
# Executable, so the entrypoint runs it rather than sourcing it. Its `exit`
# must not stop the scripts after it.
set -eu
psql -v ON_ERROR_STOP=1 -X -q -c "insert into init_log values ('executed', current_user)"
exit 0
