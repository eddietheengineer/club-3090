#!/usr/bin/env bash
# test-compose-entrypoint-env-declared.sh — an entrypoint may only read env vars
# that docker actually forwards.
#
# THE CLASS: docker forwards ONLY what `environment:` declares. An entrypoint that
# branches on `$${FOO}` when FOO is undeclared reads an ALWAYS-EMPTY value, so the
# knob is inert while the compose still documents it. Nothing errors; the surface
# looks correct. Five instances found (THREADS, -np/NPARALLEL, shmem_enabled,
# VLLM_ENFORCE_EAGER, MMPROJ) — see club-3090-todo.md 2026-08-30/31. All fixed.
#
# ⚠️ Declaring it as `- FOO=${FOO:-}` does NOT fix it: that sets FOO to the EMPTY
# STRING, which differs from unset and, for numeric knobs, atoi("") == 0 silently
# DISABLES the feature. Use the bare form `- FOO`.
#
# A map-form `environment:` (`FOO: "${FOO:-3}"`) declares FOO as well. Until
# 2026-10-20 this guard read only the list form and failed the two bucko composes'
# MTP_DEPTH, which always reached the container.
set -euo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
export PYTHONUTF8="${PYTHONUTF8:-1}"

python3 - <<'PY'
import io,re,subprocess,sys

# Known-broken, tracked, NOT yet fixed. This is a DEBT REGISTER, not an excuse
# list: each entry must name the bug. Shrink it; never grow it silently.
KNOWN = {
    # EMPTY — and it must stay that way. Every occurrence found on 2026-08-31 was
    # fixed rather than registered: THREADS (6 GLM), VLLM_ENFORCE_EAGER (18 vLLM),
    # MMPROJ (6 GLM). If you are about to add an entry here, fix the compose
    # instead; a register with entries means a documented knob is inert in prod.
}
RUNTIME = {"PATH","HOME","HOSTNAME","LD_LIBRARY_PATH","PWD","IFS"}

# Tracked AND not-yet-committed composes (--others): a new compose is checked before
# its first commit, which is when its knobs are written. Gitignored files stay out.
files=[f for f in subprocess.run(['git','ls-files','--cached','--others','--exclude-standard',
       'models/'],capture_output=True,text=True,encoding='utf-8').stdout.split()
       if f.endswith('.yml') and '/_archive/' not in f]
fails=[]; debt=0; scanned=0
for f in files:
    raw=io.open(f,encoding='utf-8').read()
    if 'entrypoint:' not in raw: continue
    scanned+=1
    # Strip comment-only lines first: compose headers discuss `$${VAR:-x}` as
    # prose, and scanning them invents knobs that no code ever reads.
    t='\n'.join(l for l in raw.split('\n') if not l.lstrip().startswith('#'))
    read=set(re.findall(r'\$\$\{([A-Z][A-Z0-9_]{2,})[:\-\}]', t))
    env=set(re.findall(r'^\s+-\s+([A-Z][A-Z0-9_]*)(?:=|\s*$)', t, re.M))
    # `environment:` can also be a map (`FOO: "${FOO:-3}"`, the bucko composes): its keys
    # are declared too. Counted only inside an environment: block, so an uppercase key
    # elsewhere (a build arg, say, which never reaches the container) isn't credited.
    lines=t.split('\n')
    for i,l in enumerate(lines):
        m=re.match(r'^(\s*)environment:\s*$', l)
        if not m: continue
        for l2 in lines[i+1:]:
            if not l2.strip(): continue
            if len(l2)-len(l2.lstrip()) <= len(m.group(1)): break
            k=re.match(r'^\s+([A-Z][A-Z0-9_]*):(?:\s|$)', l2)
            if k: env.add(k.group(1))
    assigned=set(re.findall(r'^\s*([A-Z][A-Z0-9_]*)=', t, re.M)) | \
             set(re.findall(r'export\s+([A-Z][A-Z0-9_]*)=', t))
    missing = read - env - assigned - RUNTIME
    for v in sorted(missing):
        if v in KNOWN: debt+=1
        else: fails.append((f,v))

if scanned == 0:
    print("FAIL: scanned no composes with entrypoints — the search is wrong, not the tree", file=sys.stderr)
    raise SystemExit(1)
for f,v in fails:
    bare = "- " + v
    trap = "- " + v + "=${" + v + ":-}"
    print("FAIL: " + f + " entrypoint reads $" + v + " but it is not declared in environment: "
          "- docker will never forward it, so the knob is inert. "
          "Add the BARE form `" + bare + "` (never `" + trap + "`, which sets it EMPTY).", file=sys.stderr)
if fails:
    print(f"{len(fails)} undeclared entrypoint env var(s)", file=sys.stderr)
    raise SystemExit(1)
print(f"PASS: {scanned} composes with entrypoints; every env var they read is declared "
      f"({debt} known-broken occurrence(s) still on the debt register)")
PY
