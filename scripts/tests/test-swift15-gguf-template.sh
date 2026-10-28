#!/usr/bin/env bash
# test-swift15-gguf-template — the vendored Swift-1.5 GGUF chat template is the GGUF's own
# template plus the effort mapping, and the compose serves it.
#
# WHY THIS TEST EXISTS
# --------------------
# The template embedded in UkisAI's Swift-1.5 GSQ-RCO GGUF raises on any reasoning effort
# outside xhigh / medium / low (it rejects `high` too, unlike unsloth's Qwen3.8 template), and
# llama-server turns that into HTTP 500 while /health stays 200. `high`, `minimal` and `max` are
# what OpenAI-compatible clients send. models/qwen3.8-27b/llama-cpp/patches/
# swift15-gguf-reasoning-effort-template/chat_template.jinja maps them, and is otherwise the
# GGUF's own template. The same four checks as test-qwen38-gguf-template:
#   1. a re-vendor drops the mapping block, or edits something else in the file
#      -> with the block removed, the file must hash to the recorded GGUF template;
#   2. the mapping stops rendering as xhigh / low, or changes low / medium / xhigh -> render
#      both files (needs jinja2);
#   3. a compose mounts the file but does not select it -> every compose that mounts it must
#      pass --chat-template-file with the mounted path;
#   4. UkisAI re-pushes the GGUF with a different template -> when MODEL_DIR is exported and the
#      GGUF is there, its embedded template must hash to the recorded one.
set -uo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import hashlib, os, pathlib, re, sys

root = pathlib.Path(sys.argv[1])
rel = "models/qwen3.8-27b/llama-cpp/patches/swift15-gguf-reasoning-effort-template/chat_template.jinja"
# sha256 of tokenizer.chat_template in Swift-1.5-Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf
# (ukisai/Swift-1.5-Qwen3.8-27B-GSQ-RCO-GGUF, read 2026-10-28). Change it only together with a re-vendor.
GGUF_TEMPLATE_SHA256 = "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"
fails, notes = [], []

def sha(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()

vendored = (root / rel).read_bytes().decode("utf-8")

# 1. exactly one club-3090 block, and nothing else differs from the GGUF's template
block = re.compile(r"    \{#- club-3090 PATCH:.*?-#\}\n"
                   r"    \{%- if resolved_reasoning_effort in \('high', 'max'\) %\}\n.*?    \{%- endif %\}\n", re.S)
found = block.findall(vendored)
stock = block.sub("", vendored)
if len(found) != 1:
    fails.append(f"expected exactly one club-3090 mapping block, found {len(found)}")
elif sha(stock) != GGUF_TEMPLATE_SHA256:
    fails.append("with the mapping block removed, the file no longer hashes to the GGUF's template: "
                 "something else in it changed")

# 2. the mapping renders as the real rungs; low / medium / xhigh exactly as stock
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
    msgs = [{"role": "user", "content": "q"}]

    def renderer(text):
        tpl = env.from_string(text)

        def render(**kw):
            try:
                return tpl.render(messages=msgs, add_generation_prompt=True, bos_token="", eos_token="", **kw)
            except jinja2.exceptions.TemplateError:
                return None
        return render

    patched, original = renderer(vendored), renderer(stock)
    low, xhigh, medium = patched(reasoning_effort="low"), patched(reasoning_effort="xhigh"), patched(reasoning_effort="medium")
    if None in (low, xhigh, medium) or len({low, xhigh, medium}) != 3:
        fails.append("low / medium / xhigh must each render, and differently")
    for e in ("low", "medium", "xhigh"):
        if patched(reasoning_effort=e) != original(reasoning_effort=e):
            fails.append(f"reasoning_effort '{e}' must render exactly as the stock template does")
    if patched() != original() or patched() != xhigh:
        fails.append("no effort must still render as stock, which defaults to xhigh")
    for e, want, name in (("high", xhigh, "xhigh"), ("max", xhigh, "xhigh"), ("minimal", low, "low")):
        if patched(reasoning_effort=e) != want:
            fails.append(f"reasoning_effort '{e}' must render as '{name}'")
        if original(reasoning_effort=e) is not None:
            notes.append(f"the stock template now accepts '{e}': the mapping may be droppable")
    if patched(reasoning_effort="bogus") is not None:
        fails.append("an unknown effort must still be rejected")

# 3. every compose that mounts the file selects it
mount = re.compile(r"swift15-gguf-reasoning-effort-template/chat_template\.jinja:([^:\s]+):ro")
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
if len(composes) < 1:
    fails.append("no compose mounts the template (expected the Swift-1.5 single-card one): "
                 "the glob or the mount pattern is stale")

# 4. the GGUF on disk still carries the template this file was made from
model_dir = os.environ.get("MODEL_DIR", "")
if not model_dir:
    notes.append("GGUF re-check skipped (export MODEL_DIR to run it)")
else:
    sys.path.insert(0, str(root / "scripts/lib/profiles"))
    from deriver import read_gguf_header
    seen = set()
    for f, s in composes:
        m = re.search(r"-m /models/\$\{GGUF_FILE:-([^}]+)\}", s)
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
                         "re-vendor it with the mapping block and update GGUF_TEMPLATE_SHA256")
        else:
            notes.append(f"{gguf.name}: embedded template unchanged")

for n in notes:
    print(f"  note: {n}")
for f in fails:
    print(f"✗ {f}", file=sys.stderr)
if not fails:
    print(f"test-swift15-gguf-template: ok (GGUF template + one mapping block, high/max→xhigh, minimal→low, "
          f"{len(composes)} compose(s) select it)")
sys.exit(1 if fails else 0)
PY
