# Sourced by the entrypoint with "${psql[@]}" ready to use. It relies on the
# default POSTGRES_USER being exported.
"${psql[@]}" -c "create role reader; grant select on items to reader" \
  -c "create table init_log (step text, by_user text)" \
  -c "insert into init_log values ('sourced', '$POSTGRES_USER')"
# Sourced scripts may parse their own arguments. This must not reach the
# server's command line, or the final server fails to start.
set -- not-a-server-argument
