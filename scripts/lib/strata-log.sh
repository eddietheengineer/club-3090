# strata-log.sh — where Project Maya's engine log is, inside a Strata-kind container.
# Sourced by report.sh and verify-stress.sh; no side effects on source.
#
# Strata writes its engine log to a file inside the container, not to `docker logs`:
# /data/state/strata/launch/*.engine.log from 0.2 on, /opt/strata/strata-*.log before. Project
# Maya (engine strata-maya, the same kind) writes <data>/<quant>/maya.log instead — maya_prepare.py
# puts it in the quant's folder, and every quant's folder sits on the one /data mount (maya-s,
# maya-m, maya-l). Tailing Strata's paths in a Maya container found nothing: #1706 and #1752 both
# pasted "tail: cannot open '/opt/strata/strata-*.log'" where the engine log should be.
#
# strata_maya_log_path <container>
#   prints the newest /data/*/maya.log in that container (the running server's: it writes at every
#   start and request), or nothing when there is none — a Strata container, or no container. Found
#   by looking for the file, not by asking the server: the log matters most when the server is down.
strata_maya_log_path() {  # <container>
  [[ -n "${1:-}" && "$1" != "none" ]] || return 0
  docker exec "$1" sh -c 'ls -t /data/*/maya.log 2>/dev/null | head -1' 2>/dev/null || true
}
