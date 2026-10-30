-- Runs after 03-exec.sh exits, proving later scripts still run.
insert into init_log values ('after', current_user);
