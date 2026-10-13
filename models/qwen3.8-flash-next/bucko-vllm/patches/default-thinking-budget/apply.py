"""Server-side DEFAULT reasoning budget for bucko's vLLM (club-3090 local layer).

vLLM honours `thinking_token_budget` only per request, and its server defaults
(--override-generation-config) cover a fixed list that excludes it. This makes
SamplingParams fall back to $CLUB3090_DEFAULT_THINKING_TOKEN_BUDGET when a request
sets none, so every entrypoint gets it (chat completions, Responses, /v1/messages,
and agents that call from inside a sandbox). An explicit per-request value wins.
Unset, empty or -1 = no default (stock behaviour). Idempotent; anchor-checked.
"""
import pathlib, sys
import vllm

f = pathlib.Path(vllm.__file__).parent / "sampling_params.py"
t = f.read_text()
if "club3090-default-thinking-budget" in t:
    print("[thinking-budget-default] already applied"); sys.exit(0)
anchor = ("        self.thinking_token_budget = validate_thinking_token_budget(\n"
          "            self.thinking_token_budget\n"
          "        )\n")
if t.count(anchor) != 1:
    print("[thinking-budget-default] ANCHOR NOT FOUND in sampling_params.py — refusing to boot "
          "with a default that would silently not apply", file=sys.stderr)
    sys.exit(1)
inject = anchor + (
    "        # club3090-default-thinking-budget: server-side default when the request sets none\n"
    "        if self.thinking_token_budget is None:\n"
    "            import os as _os\n"
    "            _d = _os.environ.get('CLUB3090_DEFAULT_THINKING_TOKEN_BUDGET', '').strip()\n"
    "            if _d and _d != '-1':\n"
    "                self.thinking_token_budget = validate_thinking_token_budget(int(_d))\n")
f.write_text(t.replace(anchor, inject))
print("[thinking-budget-default] applied: requests without thinking_token_budget get "
      "CLUB3090_DEFAULT_THINKING_TOKEN_BUDGET")
