# Qwen3.8-27B — Changelog

Dated history for Qwen3.8-27B configs in this repo.

## 2026-08-14 — Model landing: FP8 dual-max tier (experimental)

New model directory `models/qwen3.8-27b/` with one compose:
`vllm/qwen38-27b-dual-max` (`models/qwen3.8-27b/vllm/compose/dual/fp8/mtp.yml`)
— official Qwen3.8-27B FP8 weights (fine-grained block-128 E4M3 + BF16,
embedded MTP head + vision tower) + fp8/e4m3 KV + MTP n=3, TP=2 @262K.
Direct clone of the Qwen3.6-27B dual-max tier (`vllm/qwen-27b-dual-max`)
with these deltas: generation-config defaults per the model card
(temperature=1.0, top_p=0.95, top_k=20) and the froggeric chat-template
patch commented out pending Qwen3.8 validation (stock template in use).
The pr48375 MambaManager patch is reused via symlink to the Qwen3.6-27B
patch dir.

Status: 🧪 Experimental — unvalidated (pending rebench-full). Inherits the
sibling's vllm#50021 MTP × hybrid-GDN exposure on the v0.25.1 pin — see
the compose header and docs/UPSTREAM.md. Dual-only for now: the ~29 GB FP8
checkpoint does not fit a single 24 GB card.
