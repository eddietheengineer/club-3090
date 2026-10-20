# qwen38-gguf-reasoning-effort-template

The chat template embedded in unsloth's Qwen3.8-27B GGUFs, served from a file, with one
change: the reasoning efforts `minimal` and `max` are clamped to `low` and `xhigh` instead
of raising. Mounted by the two mainline llama.cpp slugs,
`llamacpp/qwen38-27b-single-iq4xs` and `llamacpp/qwen38-27b-dual-q8kxl`.

## The defect

The GGUF's template knows three rungs, `low < medium < xhigh`, and maps `high` onto
`xhigh` itself. Anything else raises:

```jinja
{%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}
    {{- raise_exception('Unexpected reasoning effort ' ~ reasoning_effort ~ '. ...') }}
```

llama-server turns that into **HTTP 500**, while `/health` and `/v1/models` stay 200.
`minimal` and `max` are part of the wider OpenAI-compatible vocabulary (Hermes Agent,
OpenRouter-shaped clients), and llama-server's own `--reasoning-effort` help lists both.

Measured on `llamacpp/qwen38-27b-single-iq4xs`, 2026-10-20, stock template:

| effort | top-level `reasoning_effort` | in `chat_template_kwargs` |
|---|---|---|
| `high`, `medium`, `xhigh`, `low` | 200 | 200 |
| `max` | **500** | **500** |
| `minimal` | **500** | **500** |
| `none` | 200, but runs at **xhigh** (see below) | **500** |

The pinned mainline image has no effort allow-list. PrismML's
`--reasoning-effort-allow` is a fork flag, so the fix has to be the template.

## The change

One block, inserted after the GGUF's own `high` -> `xhigh` mapping and before the raise:

```jinja
    {%- if resolved_reasoning_effort == 'minimal' %}
        {%- set resolved_reasoning_effort = 'low' %}
    {%- elif resolved_reasoning_effort == 'max' %}
        {%- set resolved_reasoning_effort = 'xhigh' %}
    {%- endif %}
```

plus its `{#- club-3090 PATCH … -#}` comment. These are the clamps the vLLM and SGLang
slugs' template already carries (`models/qwen3.8-27b/vllm/patches/qwen38-reasoning-effort-template`),
so the mainline slugs now accept the same effort vocabulary.

Unchanged: `low`, `medium`, `xhigh` and `high` render byte for byte as before; a request
with no effort still defaults to the server's `LLAMA_ARG_CHAT_TEMPLATE_KWARGS`
(`medium`), and a template call with none at all to `xhigh`; an unknown value is still
rejected. `none` inside `chat_template_kwargs` still raises, as it does on the vLLM
template.

## `none` does not turn thinking off on this engine

Measured on the patched single slug, 2026-10-20, through `POST /apply-template`: a
request with top-level `reasoning_effort: "none"` renders byte for byte the same prompt as
`xhigh`, thinking open, and the reply carries `reasoning_content`; a request with no
effort renders the compose's `medium`. So llama-server does not pass `none` to the
template (it would raise on it, as the kwargs form shows), and what renders is the
template's own `xhigh` default. The clamp block does not touch that path, so the stock
template behaves the same, and no template change can fix it. Turn thinking off per
request with `chat_template_kwargs: {"enable_thinking": false}` (the prompt then closes
the think block), or server-wide with `INSTRUCT=1`.

## Measured with the patch

`llamacpp/qwen38-27b-single-iq4xs`, 2026-10-20, booted with `switch.sh`:

| check | result |
|---|---|
| `GET /props` `chat_template` | the vendored file (club-3090 PATCH marker present) |
| `supports_tools` / `supports_tool_calls` / `supports_parallel_tool_calls` | all true |
| `high` `max` `minimal` `medium` `xhigh` `low`, top-level and in kwargs | 200 |
| `bogus`, both forms; `none` in kwargs | 500, as before |
| `POST /apply-template`, both forms | `minimal` = `low`; `max` = `high` = `xhigh`, byte for byte |
| `verify-full.sh` | 9/9 |

## Why not reuse the vLLM template

It is built from Qwen's safetensors `chat_template.jinja`, which differs from the GGUF's:
the GGUF's merges every system and developer message into one leading system turn, and
renders tools and raises differently. Serving it here would change how every prompt on
these slugs is built, not just the effort handling.

## Base

`tokenizer.chat_template` from `unsloth/Qwen3.8-27B-GGUF`, read 2026-10-20:

| GGUF | template sha256 |
|---|---|
| `Qwen3.8-27B-UD-IQ4_XS.gguf` | `12827f24b742ea4e80cdc12dbcf9622227056b9f797252a3149263d4f9aaadce` |
| `Qwen3.8-27B-UD-Q8_K_XL.gguf` | `12827f24b742ea4e80cdc12dbcf9622227056b9f797252a3149263d4f9aaadce` |

9,993 bytes, no trailing newline. `scripts/tests/test-qwen38-gguf-template.sh` removes the
club-3090 block and checks the rest still hashes to this, so nothing else can change
unnoticed. With `MODEL_DIR` exported it also reads each GGUF's header and checks the
embedded template is still this one. That is how a re-pushed GGUF gets caught.

## Regenerating

If unsloth re-pushes the GGUFs with a different template, extract it with the repo's own
GGUF header reader, re-insert the block, and update `GGUF_TEMPLATE_SHA256` in the test:

```bash
PYTHONPATH=scripts/lib/profiles python3 -c '
import sys; from deriver import read_gguf_header
sys.stdout.write(read_gguf_header(sys.argv[1])["kv"]["tokenizer.chat_template"])' \
  "${MODEL_DIR}/qwen3.8-27b-gguf/unsloth-iq4xs/Qwen3.8-27B-UD-IQ4_XS.gguf" > /path/to/new-base.jinja
MODEL_DIR=... bash scripts/tests/test-qwen38-gguf-template.sh
```

Write the file without adding a trailing newline; the base has none.
