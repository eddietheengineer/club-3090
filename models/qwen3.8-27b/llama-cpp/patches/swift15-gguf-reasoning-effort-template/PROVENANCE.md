# swift15-gguf-reasoning-effort-template

The chat template that `llamacpp/qwen38-27b-swift15-iq3s-mtp` serves: UkisAI's Swift-1.5 GGUF template,
plus one block that maps the reasoning efforts it would otherwise reject.

## Why

Swift-1.5's embedded template accepts exactly three efforts, `xhigh`, `medium` and `low`, and
`raise_exception()`s on anything else. llama-server turns that into HTTP 500, while `/health` and
`/v1/models` stay 200. Clients send more than three:
- `high` comes from the OpenAI vocabulary;
- `minimal` and `max` come from Hermes Agent, OpenRouter-shaped clients and llama-server's own
  `--reasoning-effort` list.

The pinned mainline image has no effort allow-list, so the fix has to be the template.

The block maps `high` and `max` to `xhigh`, and `minimal` to `low` (never to "off": thinking off is
`enable_thinking=false`). That is the same mapping the Qwen3.8 GGUF slugs get from
`qwen38-gguf-reasoning-effort-template`, whose base maps `high` itself. `low`, `medium`, `xhigh` and no
effort render exactly as the stock template does, and an unknown value is still rejected.

**Not the Qwen3.8 template.** `qwen38-gguf-reasoning-effort-template` is built from unsloth's
Qwen3.8-27B GGUF template (sha256 `12827f24…aadce`, 9,993 bytes). Swift-1.5's is different (8,952
bytes, below):
- it reads only `messages[0]` as the system message, where unsloth's merges several leading ones;
- it rejects `high`.

Mounting the Qwen3.8 file here would change how every prompt on this slug is built.

## Base

`tokenizer.chat_template` from `ukisai/Swift-1.5-Qwen3.8-27B-GSQ-RCO-GGUF`, read 2026-10-28 from the
file's header (a 40 MiB HTTP range request; the template sits in the GGUF's metadata):

| GGUF | template sha256 |
|---|---|
| `Swift-1.5-Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf` | `c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041` |

8,952 bytes, no trailing newline. `scripts/tests/test-swift15-gguf-template.sh` removes the club-3090
block and checks that the rest still hashes to this, so nothing else can change unnoticed. With
`MODEL_DIR` exported and the GGUF downloaded, it also reads the GGUF's header and checks that the
embedded template is still this one. That is how a re-pushed GGUF gets caught.

## Regenerating

If UkisAI re-pushes the GGUF with a different template, extract it with the repo's own GGUF header
reader, re-insert the block right after the `resolved_reasoning_effort = reasoning_effort|default('xhigh')`
line, and update `GGUF_TEMPLATE_SHA256` in the test and the hash above:

```bash
PYTHONPATH=scripts/lib/profiles python3 -c '
import sys; from deriver import read_gguf_header
sys.stdout.write(read_gguf_header(sys.argv[1])["kv"]["tokenizer.chat_template"])' \
  "${MODEL_DIR}/swift-1.5-qwen3.8-27b-gsq-rco/Swift-1.5-Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf" > /path/to/new-base.jinja
MODEL_DIR=... bash scripts/tests/test-swift15-gguf-template.sh
```

Write the file without adding a trailing newline; the base has none.

## Drop when

Swift-1.5's GGUF template accepts `high`, `minimal` and `max`, or stops raising on unknown efforts, or the
pinned mainline llama-server gains an effort allow-list.
