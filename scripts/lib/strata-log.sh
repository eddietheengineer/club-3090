# strata-log.sh — where Project Maya's engine log is, inside a Strata-kind container.
# Sourced by report.sh and verify-stress.sh; no side effects on source.
#
# Strata writes its engine log to a file inside the container, not to `docker logs`:
# /data/state/strata/launch/*.engine.log from 0.2 on, /opt/strata/strata-*.log before. Project
# Maya (engine strata-maya, the same kind) writes one into the quant's folder instead, named per
# engine: <data>/<quant>/maya.log (GLM), maya-ds4.log (DeepSeek), maya-mm3.log (MiniMax). Every
# quant's folder sits on the one /data mount, which all three engines' slugs share. Tailing Strata's
# paths in a Maya container found nothing: #1706 and #1752 both pasted "tail: cannot open
# '/opt/strata/strata-*.log'" where the engine log should be.
#
# strata_maya_log_path <container>
#   prints that container's Maya engine log, or nothing when there is none — a Strata container, or
#   no container:
#   1. the `log` of the run config the server's command line names (serve/server.py --config FILE,
#      process 1 once the entrypoint has exec'd it): the server's own log, as strata_metrics.py reads
#      it. A newer log of another engine on the shared /data is not this server's;
#   2. else the newest /data/*/maya.log, maya-ds4.log or maya-mm3.log (the server writes at every
#      start and request). Found by looking for the file, not by asking the server: the log matters
#      most when the server is down, and before the entrypoint execs it there is no --config to read.
#   Until 2026-10-29 it read only maya.log, so a DeepSeek or MiniMax container got GLM's (found
#   while scanning the logs of the v1.1.37 bump's DeepSeek boot, #1845).
strata_maya_log_path() {  # <container>
  [[ -n "${1:-}" && "$1" != "none" ]] || return 0
  # shellcheck disable=SC2016  # expanded by the container's sh
  docker exec "$1" sh -c '
    cfg=$(tr "\0" "\n" < /proc/1/cmdline 2>/dev/null | sed -n "/^--config\$/{n;p;q;}")
    log=""
    [ -n "$cfg" ] && [ -r "$cfg" ] \
      && log=$(sed -n "s/.*\"log\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$cfg" | head -1)
    if [ -n "$log" ] && [ -f "$log" ]; then echo "$log"
    else ls -t /data/*/maya.log /data/*/maya-ds4.log /data/*/maya-mm3.log 2>/dev/null | head -1; fi' 2>/dev/null || true
}
