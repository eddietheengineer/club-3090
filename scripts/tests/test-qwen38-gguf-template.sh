#!/usr/bin/env bash
# test-qwen38-gguf-template — the vendored Qwen3.8 GGUF chat template is the GGUF's own
# template plus the effort clamps, and the mainline llama.cpp composes serve it.
#
# WHY THIS TEST EXISTS
# --------------------
# The template embedded in unsloth's Qwen3.8-27B GGUFs raises on any reasoning effort
# outside xhigh / medium / low (after mapping high -> xhigh itself), and llama-server
# turns that into HTTP 500 while /health stays 200. `minimal` and `max` are what
# OpenAI-compatible clients send. models/qwen3.8-27b/llama-cpp/patches/
# qwen38-gguf-reasoning-effort-template/chat_template.jinja clamps them, and is otherwise
# the GGUF's own template. Qwen3.8-Flash-Next's GGUF embeds the same template, so its
# moe-cache composes mount the file too. Four ways that silently breaks, one check each:
#   1. a re-vendor drops the clamp block, or edits something else in the file
#      -> with the block removed, the file must hash to the recorded GGUF template;
#   2. the clamps stop rendering as low / xhigh -> render them (needs jinja2);
#   3. a compose mounts the file but does not select it -> every compose that mounts it
#      must pass --chat-template-file with the mounted path (folded or list-form command);
#   4. unsloth re-pushes the GGUF with a different template -> when MODEL_DIR is exported
#      and the GGUFs are there, their embedded template must hash to the recorded one.
set -uo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import hashlib, os, pathlib, re, sys

root = pathlib.Path(sys.argv[1])
rel = "models/qwen3.8-27b/llama-cpp/patches/qwen38-gguf-reasoning-effort-template/chat_template.jinja"
# sha256 of tokenizer.chat_template in Qwen3.8-27B-UD-IQ4_XS.gguf and -UD-Q8_K_XL.gguf
# (unsloth/Qwen3.8-27B-GGUF, read 2026-10-20). Change it only together with a re-vendor.
GGUF_TEMPLATE_SHA256 = "12827f24b742ea4e80cdc12dbcf9622227056b9f797252a3149263d4f9aaadce"
fails, notes = [], []

def sha(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()

vendored = (root / rel).read_bytes().decode("utf-8")

# 1. exactly one club-3090 block, and nothing else differs from the GGUF's template
block = re.compile(r"    \{#- club-3090 PATCH:.*?-#\}\n"
                   r"    \{%- if resolved_reasoning_effort == 'minimal' %\}\n.*?    \{%- endif %\}\n", re.S)
found = block.findall(vendored)
if len(found) != 1:
    fails.append(f"expected exactly one club-3090 clamp block, found {len(found)}")
elif sha(block.sub("", vendored)) != GGUF_TEMPLATE_SHA256:
    fails.append("with the clamp block removed, the file no longer hashes to the GGUF's template: "
                 "something else in it changed")

# 2. the clamps render as their real rungs; everything else as before
try:
    import json
    import jinja2
    from jinja2.sandbox import ImmutableSandboxedEnvironment
except ImportError:
    notes.append("render checks skipped (no jinja2)")
else:
    def raise_exception(msg):
        raise jinja2.exceptions.TemplateError(msg)

    def tojson(x, ensure_ascii=False, indent=None, separators=None, sort_keys=False):
        return json.dumps(x, ensure_ascii=ensure_ascii, indent=indent, separators=separators, sort_keys=sort_keys)

    env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True, extensions=["jinja2.ext.loopcontrols"])
    env.filters["tojson"] = tojson
    env.globals["raise_exception"] = raise_exception
    tpl = env.from_string(vendored)
    msgs = [{"role": "user", "content": "q"}]

    def render(**kw):
        try:
            return tpl.render(messages=msgs, add_generation_prompt=True, bos_token="", eos_token="", **kw)
        except jinja2.exceptions.TemplateError:
            return None

    low, xhigh, medium = render(reasoning_effort="low"), render(reasoning_effort="xhigh"), render(reasoning_effort="medium")
    if None in (low, xhigh, medium) or len({low, xhigh, medium}) != 3:
        fails.append("low / medium / xhigh must each render, and differently")
    if render(reasoning_effort="minimal") != low:
        fails.append("reasoning_effort 'minimal' must render as 'low'")
    if render(reasoning_effort="max") != xhigh:
        fails.append("reasoning_effort 'max' must render as 'xhigh'")
    if render(reasoning_effort="high") != xhigh:
        fails.append("reasoning_effort 'high' must still render as 'xhigh' (the GGUF's own mapping)")
    if render(reasoning_effort="bogus") is not None:
        fails.append("an unknown effort must still be rejected")
    if render() != xhigh:
        fails.append("no effort must still default to xhigh")

# 3. every compose that mounts the file selects it. Folded `command: >-` puts the flag and
#    the path on one line; a list-form command puts each on its own `- '...'` item.
mount = re.compile(r"qwen38-gguf-reasoning-effort-template/chat_template\.jinja:([^:\s]+):ro")
composes = []
for f in sorted(root.glob("models/*/*/compose/**/*.yml")):
    if "_archive" in f.parts:
        continue
    s = f.read_text(encoding="utf-8")
    m = mount.search(s)
    if not m:
        continue
    composes.append((f, s))
    folded = r"\n\s*--chat-template-file " + re.escape(m.group(1)) + r"\n"
    listed = r"\n\s*- '--chat-template-file'\n\s*- '" + re.escape(m.group(1)) + r"'\n"
    if not (re.search(folded, s) or re.search(listed, s)):
        fails.append(f"{f.relative_to(root)}: mounts {m.group(1)} but does not pass it as --chat-template-file")
if len(composes) < 5:
    fails.append(f"only {len(composes)} composes mount the template (expected the 2 qwen3.8-27b + 3 "
                 "Flash-Next ones): the glob or the mount pattern is stale")

# 4. the GGUFs on disk still carry the template this file was made from
model_dir = os.environ.get("MODEL_DIR", "")
if not model_dir:
    notes.append("GGUF re-check skipped (export MODEL_DIR to run it)")
else:
    sys.path.insert(0, str(root / "scripts/lib/profiles"))
    from deriver import read_gguf_header
    seen = set()
    for f, s in composes:
        m = (re.search(r"-m /models/\$\{GGUF_FILE:-([^}]+)\}", s)
             or re.search(r"\n\s*- '-m'\n\s*- '/models/([^']+)'\n", s))
        if not m:
            fails.append(f"{f.relative_to(root)}: no `-m /models/...` model path to check")
            continue
        if m.group(1) in seen:
            continue
        seen.add(m.group(1))
        gguf = pathlib.Path(model_dir) / m.group(1)
        if not gguf.is_file():
            notes.append(f"GGUF re-check skipped for {gguf.name} (not downloaded)")
            continue
        header = read_gguf_header(str(gguf)) or {}
        embedded = (header.get("kv") or {}).get("tokenizer.chat_template")
        if embedded is None:
            fails.append(f"{gguf.name}: no tokenizer.chat_template in the header")
        elif sha(embedded) != GGUF_TEMPLATE_SHA256:
            fails.append(f"{gguf.name}: its embedded template changed (sha256 {sha(embedded)[:12]}…); "
                         "re-vendor it with the clamp block and update GGUF_TEMPLATE_SHA256")
        else:
            notes.append(f"{gguf.name}: embedded template unchanged")

for n in notes:
    print(f"  note: {n}")
for f in fails:
    print(f"✗ {f}", file=sys.stderr)
if not fails:
    print(f"test-qwen38-gguf-template: ok (GGUF template + one clamp block, minimal→low, max→xhigh, "
          f"{len(composes)} composes select it)")
sys.exit(1 if fails else 0)
PY
