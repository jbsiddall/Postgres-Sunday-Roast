# Sourced by the entrypoint with "${psql[@]}" ready to use.
"${psql[@]}" -d "$POSTGRES_DB" -c "create role reader; grant select on items to reader"
