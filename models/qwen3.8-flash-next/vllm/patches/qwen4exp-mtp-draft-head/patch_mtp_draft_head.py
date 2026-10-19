#!/usr/bin/env python3
"""Overlay `qwen4exp-mtp-draft-head`: an INT4 lm_head for the MTP drafter only.

    patch_mtp_draft_head.py patch    apply (marker-gated; a second run is a verified no-op)
    patch_mtp_draft_head.py verify   check the installed result

Every MTP draft step projects onto the full 248,320 x 2,560 vocabulary. Stock vLLM shares
the target's BF16 head with the drafter (v1/worker/gpu/spec_decode/eagle/utils.py), so each
draft step reads ~1.27 GiB. With VLLM_MTP_DRAFT_HEAD_PATH naming a packed W4A16 copy
(int4, group 128, symmetric, GPTQ layout; see quantize_lm_head.py), the drafter builds its
own Marlin W4A16 head, fills it from that file, and keeps it instead of adopting the
target's. The verify pass still uses the target's head, so the draft head only changes
acceptance, never which tokens are accepted.

Port of AlexBrandes/vllm commit 14457f89e ("[Qwen4Exp][Spec Decode] Optional W4A16
draft-only lm_head for MTP", Apache-2.0) to stock v0.31.0's V2 model runner. The V1
proposer path (v1/spec_decode/llm_base_proposer.py) is not patched: under V1 the drafter
shares the target's head as stock does.

Unset VLLM_MTP_DRAFT_HEAD_PATH: the patched code behaves exactly like stock. Each anchor
must appear exactly once. Missing or not unique -> exit 1. Stdlib only.
"""
from __future__ import annotations

import importlib.util
import py_compile
import sys
from pathlib import Path

TAG = "[qwen4exp-mtp-draft-head]"
MARKER = "# [club3090 qwen4exp-mtp-draft-head]"

MTP = Path("models/qwen4_exp/nvidia/mtp.py")
EAGLE = Path("v1/worker/gpu/spec_decode/eagle/utils.py")

MTP_EDITS = [
    # 1. Quant config for the head, before the first helper.
    (
        "\n\ndef _remap_ignored_layers(\n",
        f"""

{MARKER} W4A16 GPTQ-Marlin config for the drafter's own lm_head.
import os as _club_os

from vllm.logger import init_logger as _club_init_logger
from vllm.model_executor.layers.quantization import QuantizationConfig as _ClubQC
from vllm.model_executor.layers.quantization.auto_gptq import (
    AutoGPTQConfig as _ClubAutoGPTQConfig,
    AutoGPTQLinearMethod as _ClubAutoGPTQLinearMethod,
)

_club_logger = _club_init_logger(__name__)
_CLUB_DRAFT_HEAD_GROUP = 128


class _ClubDraftHeadQuantConfig(_ClubQC):
    def get_name(self) -> str:
        return "auto_gptq"

    def get_supported_act_dtypes(self) -> list[torch.dtype]:
        return [torch.half, torch.bfloat16]

    @classmethod
    def get_min_capability(cls) -> int:
        return 75

    @classmethod
    def get_config_filenames(cls) -> list[str]:
        return []

    @classmethod
    def from_config(cls, config: dict) -> "_ClubDraftHeadQuantConfig":
        raise RuntimeError("_ClubDraftHeadQuantConfig is instantiated directly")

    def get_quant_method(self, layer, prefix):
        return _ClubAutoGPTQLinearMethod(
            _ClubAutoGPTQConfig(
                weight_bits=4,
                group_size=_CLUB_DRAFT_HEAD_GROUP,
                desc_act=False,
                is_sym=True,
                lm_head_quantized=True,
                dynamic={{}},
                full_config={{}},
            )
        )


def _remap_ignored_layers(
""",
    ),
    # 2. Build the quantized head when the env var is set.
    (
        "        if get_pp_group().is_last_rank:\n"
        "            if config.tie_word_embeddings:\n"
        "                self.lm_head = self.model.embed_tokens\n"
        "            else:\n",
        f"        self.draft_head_quantized = False  {MARKER}\n"
        "        if get_pp_group().is_last_rank:\n"
        "            if config.tie_word_embeddings:\n"
        "                self.lm_head = self.model.embed_tokens\n"
        "            elif _club_os.environ.get(\"VLLM_MTP_DRAFT_HEAD_PATH\"):\n"
        "                self.lm_head = ColumnParallelLinear(\n"
        "                    config.hidden_size,\n"
        "                    config.vocab_size,\n"
        "                    bias=False,\n"
        "                    return_bias=False,\n"
        "                    quant_config=_ClubDraftHeadQuantConfig(),\n"
        "                    prefix=maybe_prefix(prefix, \"lm_head\"),\n"
        "                )\n"
        "                self.draft_head_quantized = True\n"
        "                _club_logger.info(\"MTP draft lm_head: W4A16 Marlin from %s\",\n"
        "                                  _club_os.environ[\"VLLM_MTP_DRAFT_HEAD_PATH\"])\n"
        "            else:\n",
    ),
    # 3. Drop the checkpoint's head tensors and load the packed file instead.
    (
        "    def load_weights(self, weights: Iterable[tuple[str, torch.Tensor]]) -> set[str]:\n"
        "        def remap_weight_names():\n"
        "            for name, weight in weights:\n"
        "                remapped_name = _remap_mtp_weight_name(name)\n"
        "                if remapped_name is not None:\n"
        "                    yield remapped_name, weight\n",
        "    def _club_load_draft_head(self, path: str) -> None:\n"
        f"        {MARKER} fill the W4A16 head from the packed GPTQ file\n"
        "        from safetensors import safe_open\n"
        "\n"
        "        if getattr(self.lm_head, \"tp_size\", 1) != 1:\n"
        "            raise NotImplementedError(\"VLLM_MTP_DRAFT_HEAD_PATH supports TP=1 only\")\n"
        "        k, n = self.config.hidden_size, self.config.vocab_size\n"
        "        g = _CLUB_DRAFT_HEAD_GROUP\n"
        "        expected = {\"qweight\": (k // 8, n), \"scales\": (k // g, n),\n"
        "                    \"qzeros\": (k // g, n // 8)}\n"
        "        with safe_open(path, framework=\"pt\", device=\"cpu\") as f:\n"
        "            for name, shape in expected.items():\n"
        "                t = f.get_tensor(f\"lm_head.{name}\")\n"
        "                if tuple(t.shape) != shape:\n"
        "                    raise ValueError(f\"{path}: lm_head.{name} is {tuple(t.shape)}, \"\n"
        "                                     f\"expected {shape}\")\n"
        "                p = getattr(self.lm_head, name)\n"
        "                p.data.copy_(t.to(dtype=p.dtype, device=p.device))\n"
        "\n"
        "    def load_weights(self, weights: Iterable[tuple[str, torch.Tensor]]) -> set[str]:\n"
        "        drop_head = self.draft_head_quantized\n"
        "\n"
        "        def remap_weight_names():\n"
        "            for name, weight in weights:\n"
        "                remapped_name = _remap_mtp_weight_name(name)\n"
        "                if remapped_name is None:\n"
        "                    continue\n"
        "                if drop_head and remapped_name.startswith(\"lm_head.\"):\n"
        "                    continue\n"
        "                yield remapped_name, weight\n",
    ),
    (
        "        return loader.load_weights(remap_weight_names(), mapper=mapper)\n"
        "\n"
        "\n"
        "__all__ = [",
        "        loaded = loader.load_weights(remap_weight_names(), mapper=mapper)\n"
        "        if drop_head:\n"
        "            self._club_load_draft_head(_club_os.environ[\"VLLM_MTP_DRAFT_HEAD_PATH\"])\n"
        "            # The loader checks that every parameter was loaded.\n"
        "            loaded |= {n for n, _ in self.named_parameters() if n.startswith(\"lm_head.\")}\n"
        "        return loaded\n"
        "\n"
        "\n"
        "__all__ = [",
    ),
]

EAGLE_EDITS = [
    (
        "    if target_lm_head is not None and _should_share(\n"
        "        eagle_model, \"has_own_lm_head\", draft_lm_head, target_lm_head\n"
        "    ):\n",
        f"    {MARKER} keep the drafter's own W4A16 head\n"
        "    if (\n"
        "        target_lm_head is not None\n"
        "        and not getattr(eagle_model, \"draft_head_quantized\", False)\n"
        "        and _should_share(\n"
        "            eagle_model, \"has_own_lm_head\", draft_lm_head, target_lm_head\n"
        "        )\n"
        "    ):\n",
    ),
]


def die(msg: str) -> None:
    print(f"{TAG} REFUSE: {msg}", file=sys.stderr)
    print(f"{TAG} Fix: re-anchor for this vLLM version "
          "(models/qwen3.8-flash-next/vllm/patches/qwen4exp-mtp-draft-head/README.md).",
          file=sys.stderr)
    sys.exit(1)


def apply(path: Path, edits, mode: str) -> None:
    text = path.read_text()
    if MARKER in text:
        for _, new in edits:
            if new not in text:
                die(f"{path.name} carries the marker but not the expected edit")
        return
    if mode == "verify":
        die(f"{path.name} is not patched")
    for old, new in edits:
        n = text.count(old)
        if n != 1:
            die(f"anchor in {path.name} found {n} times, expected 1: {old.splitlines()[0]!r}")
        text = text.replace(old, new)
    path.write_text(text)
    py_compile.compile(str(path), doraise=True)


def main(mode: str) -> None:
    spec = importlib.util.find_spec("vllm")
    if spec is None or not spec.origin:
        die("the vllm package is not importable")
    root = Path(spec.origin).resolve().parent
    for rel, edits in ((MTP, MTP_EDITS), (EAGLE, EAGLE_EDITS)):
        p = root / rel
        if not p.is_file():
            die(f"{rel} not found")
        apply(p, edits, mode)
    print(f"{TAG} {'verified' if mode == 'verify' else 'applied'}: MTP drafter keeps a "
          "W4A16 lm_head when VLLM_MTP_DRAFT_HEAD_PATH is set", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("patch", "verify"):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1])
