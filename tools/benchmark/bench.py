#!/usr/bin/env python3
"""GridPonder AI Benchmark Orchestrator.

Drives the compiled Dart game-loop runner as a subprocess and calls LLMs
(local via Ollama or cloud via API) to play levels. Results are written as
JSONL to results/run/<timestamp>/.

Inference modes:
  single   — one action per LLM call (default, backwards-compatible)
  fixed-n  — up to --step-size actions per call; model may output fewer
  flex-n   — 1 to --max-n actions per call, model chooses; extra steps
             are penalised at --flex-penalty per step beyond the first
  full     — all actions in one call; no intermediate feedback

Usage examples:
  python bench.py --suite curated --model qwen3-4b
  python bench.py --all --model gemma4-e2b --action-timeout 60
  python bench.py --pack number_cells --level nc_001 --model claude-sonnet
  python bench.py --suite curated --mode fixed-n --step-size 3
  python bench.py --suite curated --mode flex-n --max-n 5
  python bench.py --level box_builder bb_001 --mode full --model claude-sonnet
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import termios
import threading
import time
import tty
import uuid
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

import yaml
from dotenv import load_dotenv
from tqdm import tqdm

from agent_client import call_llm, extract_action, extract_action_lenient, extract_actions_list

# Opt-in parse tolerance (default off so existing scores are unchanged):
#   GRIDPONDER_LENIENT_PARSE=1  last action object wins, missing closing braces repaired
#   GRIDPONDER_PARSE_RETRIES=N  re-ask up to N times on an unparseable single-mode reply
#                               instead of sending give_up (which resets the level)
LENIENT_PARSE = os.environ.get("GRIDPONDER_LENIENT_PARSE", "") not in ("", "0")
PARSE_RETRIES = int(os.environ.get("GRIDPONDER_PARSE_RETRIES", "0") or 0)
from connector_api import estimate_cost
from instructions import (
    InstructionPayload,
    compose_study_prompt,
    sha256_text,
)
from run_manifest import source_snapshot

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent.resolve()
RUNNER_BIN = SCRIPT_DIR / "runner" / "runner"
PACKS_DIR = SCRIPT_DIR.parent.parent / "packs"
MODELS_FILE = SCRIPT_DIR / "models.yaml"
SUITE_FILE = SCRIPT_DIR / "suite.yaml"
RESULTS_BASE = SCRIPT_DIR / "results" / "run"

# Max consecutive rejected actions before forcing a give_up.
MAX_CONSECUTIVE_REJECTIONS = 3


def load_models() -> list[dict]:
    with open(MODELS_FILE) as f:
        base = yaml.safe_load(f)["models"]
    local_file = MODELS_FILE.with_suffix(".local.yaml")
    if local_file.exists():
        with open(local_file) as f:
            local = yaml.safe_load(f).get("models", [])
        local_ids = {m["id"] for m in local}
        base = [m for m in base if m["id"] not in local_ids]
        base.extend(local)
    return base


def load_suite() -> dict[str, list[str]]:
    with open(SUITE_FILE) as f:
        return yaml.safe_load(f)["levels"]


def all_pack_levels(
    packs_dir: Path = PACKS_DIR,
    excluded_packs: set[str] | frozenset[str] = frozenset(),
) -> dict[str, list[str]]:
    """Discover all levels for all packs by reading game.json files."""
    result: dict[str, list[str]] = {}
    for pack_dir in sorted(packs_dir.iterdir()):
        if not pack_dir.is_dir() or pack_dir.name in excluded_packs:
            continue
        game_json = pack_dir / "game.json"
        if not game_json.exists():
            continue
        try:
            game = json.loads(game_json.read_text())
            levels = [
                e["ref"]
                for e in game.get("levelSequence", [])
                if e.get("type") == "level" and "ref" in e
            ]
            if levels:
                result[pack_dir.name] = levels
        except Exception:
            pass
    return result


def expand_model_variants(
    models: list[dict], selected_ids: list[str] | None
) -> list[tuple[dict, dict]]:
    """Return (model, variant) pairs, filtered by selected_ids if given.

    selected_ids must be full variant ids (e.g. "gemma4-e2b" for the no-think
    variant, "gemma4-e2b-think" for the think variant). Passing a bare model id
    like "gemma4-e2b" only matches the variant whose suffix is "", not all
    variants of that model. None means all models and all variants.
    """
    pairs: list[tuple[dict, dict]] = []
    for model in models:
        for variant in model["variants"]:
            full_id = f"{model['id']}{variant.get('suffix', '')}"
            if selected_ids is None or full_id in selected_ids:
                pairs.append((model, variant))
    return pairs


# ── Level runner ───────────────────────────────────────────────────────────────

# Opt-in per-call log (GRIDPONDER_CALL_LOG_DIR=<dir>): one JSON line per model
# call, written as soon as the call returns (prompt, full reasoning, reply), so
# levels cut off by a job time limit keep their traces for analysis.
_CALL_LOG_DIR = os.environ.get("GRIDPONDER_CALL_LOG_DIR", "")
_CALL_LOG_LOCK = threading.Lock()


def _append_call_log(pack_id: str, level_id: str, model: dict, variant: dict,
                     mode: str, record: dict) -> None:
    if not _CALL_LOG_DIR:
        return
    try:
        d = Path(_CALL_LOG_DIR)
        d.mkdir(parents=True, exist_ok=True)
        mid = f"{model.get('id', '')}{variant.get('suffix', '')}"
        rec = {"ts": datetime.now(timezone.utc).isoformat(), "pack_id": pack_id,
               "level_id": level_id, "model_id": mid, "mode": mode, **record}
        line = json.dumps(rec, ensure_ascii=False) + "\n"
        with _CALL_LOG_LOCK, open(d / f"{mid}_{mode}__{pack_id}__{level_id}.jsonl", "a") as f:
            f.write(line)
    except Exception as exc:  # never let logging break a run
        print(f"call log write failed: {exc}", file=sys.stderr)


def run_level(
    pack_id: str,
    level_id: str,
    model: dict,
    variant: dict,
    attempt_multiplier: int,
    total_multiplier: int,
    action_timeout: int | None = None,
    mode: str = "single",
    step_size: int = 1,
    max_n: int = 5,
    flex_penalty: float = 0.5,
    anon: bool = False,
    single_attempt: bool = False,
    no_rules: bool = False,
    max_attempts: int | None = None,
    full_attempts: bool = False,
    runner: str = "auto",
    input_mode: str = "text",
    packs_dir: Path = PACKS_DIR,
    progress_callback: Callable[[dict[str, Any]], None] | None = None,
    instruction_payload: InstructionPayload | None = None,
    game_notebook: str = "",
    result_context: dict[str, Any] | None = None,
    observation_interval: int = 1,
    board_legend: str = "normal",
    legend_seed: int = 0,
    legend_quiz: bool = False,
) -> dict[str, Any]:
    """Run one level with one model variant. Returns a result dict.

    Args:
        action_timeout:  Hard wall-clock timeout per LLM call in seconds.
        mode:            Inference mode: single | fixed-n | flex-n | full.
        step_size:       Max actions per call for fixed-n mode.
        max_n:           Max actions per call for flex-n mode.
        flex_penalty:    Cost per extra step beyond the first (flex-n only).
        runner:          'dart' | 'python' | 'auto' (auto-detects by binary presence).
        progress_callback: Optional telemetry sink called with live counters.
        instruction_payload: Optional authored instruction stream for study runs.
        game_notebook: Bounded cross-level notebook; ignored by legacy runs.
        result_context: Additional immutable study provenance copied to the result.
    """
    if game_notebook and instruction_payload is None:
        raise ValueError("game_notebook requires instruction_payload")
    if instruction_payload is not None and anon:
        raise ValueError("Authored curriculum instructions do not support anon mode")
    # Image input requires the PIL renderer which only exists in the Python
    # runner — force python regardless of the requested runner choice.
    validate_observation_interval(observation_interval, mode, anon, runner)
    validate_board_legend(board_legend, anon, no_rules, input_mode, runner)
    if legend_quiz and board_legend == "normal":
        raise ValueError("--legend-quiz requires a shown or hidden board legend")
    if input_mode != "text" or no_rules or observation_interval > 1 or board_legend != "normal":
        use_python = True
    else:
        use_python = runner == "python" or (runner == "auto" and not RUNNER_BIN.exists())
        if not use_python and not RUNNER_BIN.exists():
            sys.exit(
                f"Runner binary not found: {RUNNER_BIN}\n"
                "Build it first: make benchmark-build"
            )

    # max_tokens scales with expected output size.
    if mode == "flex-n" and max_n is None:
        max_tokens = 4096  # uncapped — model may output full solution
    else:
        max_tokens = {
            "single": 1024,
            "fixed-n": min(1024 * max(step_size, 1), 4096),
            "flex-n": min(1024 * max(max_n or 1, 1), 4096),
            "full": 4096,
        }.get(mode, 1024)

    runner_script = SCRIPT_DIR / "runner.py"
    runner_cmd = (
        [sys.executable, str(runner_script)]
        if use_python
        else [str(RUNNER_BIN)]
    )
    cmd = [
        *runner_cmd,
        "--pack", pack_id,
        "--level", level_id,
        "--packs-dir", str(packs_dir),
        "--attempt-multiplier", str(attempt_multiplier),
        "--total-multiplier", str(total_multiplier),
        "--mode", mode,
    ]
    if mode == "fixed-n":
        cmd += ["--step-size", str(step_size)]
    elif mode == "flex-n" and max_n is not None:
        cmd += ["--max-n", str(max_n)]
    if anon:
        cmd += ["--anon"]
    if single_attempt:
        cmd += ["--single-attempt"]
    if no_rules:
        cmd += ["--no-rules"]
    if max_attempts is not None:
        cmd += ["--max-attempts", str(max_attempts)]
    if full_attempts:
        cmd += ["--full-attempts"]
    if observation_interval > 1:
        cmd += ["--observation-interval", str(observation_interval)]
    if board_legend != "normal":
        cmd += ["--board-legend", board_legend, "--legend-seed", str(legend_seed)]
    if legend_quiz:
        cmd += ["--legend-quiz"]
    if input_mode != "text":
        cmd += ["--input", input_mode]

    connector = model.get("connector", "litellm")
    connector_model = model.get("model") or model.get("litellm_model")
    if not connector_model:
        raise ValueError(
            f"Model {model.get('id', '<unknown>')!r} has neither model nor litellm_model"
        )
    extra_params: dict = dict(variant.get("params") or {})
    full_model_id = f"{model['id']}{variant.get('suffix', '')}"

    latencies: list[float] = []
    input_tokens_total = 0
    thinking_tokens_total = 0
    output_tokens_total = 0
    cost_total = 0.0
    cost_complete = True
    cost_sources: set[str] = set()
    resets = 0
    voluntary_resets = 0
    parse_retries_total = 0
    llm_calls = 0
    total_rejections = 0
    consecutive_rejections = 0
    consecutive_timeouts = 0
    final_event: dict | None = None
    llm_log: list[dict] = []
    llm_attempts = 0
    last_call_latency_ms: float | None = None
    last_model_error_type: str | None = None
    model_error: str | None = None
    last_state: dict[str, Any] = {}
    initial_base_prompt_digest: str | None = None
    initial_prompt_digest: str | None = None
    legend_opening_prompt = ""
    progress_warning_emitted = False
    started_at = datetime.now(timezone.utc)
    started_monotonic = time.monotonic()

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    def report_progress(
        phase: str,
        *,
        status: str = "running",
        event: dict[str, Any] | None = None,
        **extra: Any,
    ) -> None:
        nonlocal progress_warning_emitted
        if event is not None:
            for key in (
                "actions_this_attempt",
                "actions_total",
                "action_limit_per_attempt",
                "action_limit",
                "attempt",
                "gold_path_length",
            ):
                if key in event:
                    last_state[key] = event[key]
        if progress_callback is None:
            return
        snapshot = {
            "status": status,
            "phase": phase,
            "model_id": full_model_id,
            "pack_id": pack_id,
            "level_id": level_id,
            "inference_mode": mode,
            "anon": anon,
            "input_mode": input_mode,
            "started_at": started_at.isoformat(),
            "updated_at": datetime.now(timezone.utc).isoformat(),
            "elapsed_seconds": time.monotonic() - started_monotonic,
            "runner_pid": proc.pid,
            "llm_calls": llm_calls,
            "llm_attempts": llm_attempts,
            "resets": resets,
            "voluntary_resets": voluntary_resets,
            "parse_retries": parse_retries_total,
            "rejections": total_rejections,
            "latency_ms_total": sum(latencies),
            "last_call_latency_ms": last_call_latency_ms,
            "last_model_error_type": last_model_error_type,
            "consecutive_timeouts": consecutive_timeouts,
            "input_tokens_total": input_tokens_total,
            "thinking_tokens_total": thinking_tokens_total,
            "output_tokens_total": output_tokens_total,
            "cost_usd": round(cost_total, 6) if cost_complete else None,
            "instruction_digest": (
                instruction_payload.digest if instruction_payload else None
            ),
            "notebook_before_digest": (
                sha256_text(game_notebook.strip())
                if instruction_payload is not None
                else None
            ),
            "notebook_before_chars": (
                len(game_notebook.strip())
                if instruction_payload is not None
                else None
            ),
            **last_state,
            **(result_context or {}),
            **extra,
        }
        try:
            progress_callback(snapshot)
        except Exception as exc:
            if not progress_warning_emitted:
                print(
                    f"Live progress callback failed: {exc}",
                    file=sys.stderr,
                )
                progress_warning_emitted = True

    def send(payload: dict) -> None:
        line = json.dumps(payload) + "\n"
        proc.stdin.write(line)  # type: ignore[union-attr]
        proc.stdin.flush()  # type: ignore[union-attr]

    report_progress("starting")

    try:
        for raw_line in proc.stdout:  # type: ignore[union-attr]
            line = raw_line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            etype = event.get("event")

            if etype == "state":
                base_prompt: str = event["prompt"]
                prompt = (
                    compose_study_prompt(
                        base_prompt,
                        instruction_payload,
                        game_notebook,
                    )
                    if instruction_payload is not None
                    else base_prompt
                )
                if initial_prompt_digest is None:
                    initial_base_prompt_digest = sha256_text(base_prompt)
                    initial_prompt_digest = sha256_text(prompt)
                    if legend_quiz:
                        legend_opening_prompt = prompt
                image_b64: str | None = event.get("image_b64")
                parse_tries_left = PARSE_RETRIES
                stop_run = False
                while True:
                    llm_ok = False
                    for _retry in range(3):
                        llm_attempts += 1
                        report_progress(
                            "waiting_for_model" if _retry == 0 else "retrying_model",
                            event=event,
                            request_attempt=_retry + 1,
                        )
                        try:
                            (
                                response_text,
                                latency_ms,
                                in_tok,
                                think_tok,
                                out_tok,
                                call_cost,
                                reasoning_text,
                            ) = call_llm(
                                prompt, connector_model, extra_params,
                                max_tokens=max_tokens,
                                request_timeout=action_timeout,
                                image_b64=image_b64,
                                connector=connector,
                            )
                            llm_ok = True
                            break
                        except Exception as exc:
                            last_exc = exc
                            last_model_error_type = type(exc).__name__
                            if getattr(exc, "status_code", None) in (400, 401, 403, 404, 422):
                                break
                            if _retry < 2:
                                time.sleep(2 ** _retry)
                    if not llm_ok:
                        message = str(last_exc)
                        for name, value in os.environ.items():
                            if len(value) >= 8 and any(word in name.upper() for word in ("KEY", "TOKEN", "SECRET")):
                                message = message.replace(value, "[REDACTED]")
                        model_error = f"LLM request failed ({last_model_error_type}): {message[:2000]}"
                        cost_complete = False
                        # Transport failures are not gameplay decisions. Do not
                        # turn them into give_up/reset actions and failed puzzles.
                        report_progress("error", status="error", error=model_error)
                        stop_run = True
                        break

                    consecutive_timeouts = 0
                    last_model_error_type = None
                    latencies.append(latency_ms)
                    last_call_latency_ms = latency_ms
                    input_tokens_total += in_tok
                    thinking_tokens_total += think_tok
                    output_tokens_total += out_tok
                    cost_source = "connector"
                    if call_cost is None:
                        call_cost = estimate_cost(
                            in_tok,
                            out_tok,
                            model.get("pricing"),
                        )
                        cost_source = (
                            "configured_estimate"
                            if call_cost is not None
                            else "unavailable"
                        )
                    if call_cost is None:
                        cost_complete = False
                    else:
                        cost_total += call_cost
                    cost_sources.add(cost_source)
                    llm_calls += 1
                    llm_entry: dict[str, Any] = {
                        "latency_ms": round(latency_ms),
                        "input_tokens": in_tok,
                        "output_tokens": out_tok,
                        "thinking_tokens": think_tok,
                        "cost_usd": (
                            round(call_cost, 6) if call_cost is not None else None
                        ),
                        "cost_source": cost_source,
                        "response": response_text,
                    }
                    if reasoning_text:
                        llm_entry["reasoning"] = reasoning_text
                    if "observation_fresh" in event:
                        llm_entry["observation_fresh"] = event["observation_fresh"]
                    llm_log.append(llm_entry)
                    _append_call_log(pack_id, level_id, model, variant, mode, {
                        "call": llm_calls,
                        "attempt": event.get("attempt"),
                        "actions_total": event.get("actions_total"),
                        "prompt": prompt,
                        **llm_entry,
                    })

                    if mode == "single":
                        action = (
                            extract_action_lenient(response_text)
                            if LENIENT_PARSE
                            else extract_action(response_text)
                        )
                        if action is None and parse_tries_left > 0:
                            parse_tries_left -= 1
                            parse_retries_total += 1
                            llm_entry["parse_failed_retry"] = True
                            continue
                        if action is None:
                            action = {
                                "action": "give_up",
                                "memory": "Could not parse a valid action from response.",
                            }
                        send(action)
                    else:
                        cap = step_size if mode == "fixed-n" else (max_n if mode == "flex-n" else None)
                        actions, memory = extract_actions_list(response_text, max_n=cap)
                        if not actions:
                            _send_give_up(send, mode, "Could not parse valid actions from response.")
                        else:
                            payload: dict[str, Any] = {"actions": actions}
                            if memory:
                                payload["memory"] = memory
                            send(payload)

                    break
                if stop_run:
                    break

                consecutive_rejections = 0

            elif etype == "rejected":
                total_rejections += 1
                # full mode: runner will emit lost automatically; nothing to send.
                if mode == "full":
                    continue
                consecutive_rejections += 1
                if consecutive_rejections >= MAX_CONSECUTIVE_REJECTIONS:
                    _send_give_up(send, mode, "Too many rejected actions.")
                    consecutive_rejections = 0

            elif etype == "reset":
                resets += 1
                if event.get("reason") == "voluntary":
                    voluntary_resets += 1
                report_progress("resetting", event=event)

            elif etype in ("won", "lost"):
                final_event = event
                report_progress("finalizing", event=event)
                break

    finally:
        try:
            proc.stdin.close()  # type: ignore[union-attr]
        except Exception:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()

    runner_error: str | None = None
    if final_event is None:
        # Runner subprocess died (crash, hang, killed) before emitting a
        # won/lost event. Don't fabricate a gold_path_length — record the
        # failure so aggregation can drop the row cleanly.
        runner_error = model_error or "runner exited without won/lost event"
        final_event = {"event": "lost", **last_state}

    success = final_event["event"] == "won"
    actions_total: int = final_event.get("actions_total", len(latencies))
    gold_path_length: int | None = final_event.get("gold_path_length")
    attempts: int = final_event.get("attempts", 1)
    repeated_states: int | None = final_event.get("repeated_states")

    gpl_pos = gold_path_length if (gold_path_length and gold_path_length > 0) else 0
    efficiency: float | None = (
        gpl_pos / actions_total
        if (success and actions_total > 0 and gpl_pos > 0)
        else None
    )

    # flex-n: penalise extra steps beyond the first in each LLM call.
    # adjusted = actions_total * (1 + f) - llm_calls * f
    efficiency_flex: float | None = None
    if mode == "flex-n" and success and actions_total > 0 and gpl_pos > 0 and llm_calls > 0:
        adjusted = actions_total * (1 + flex_penalty) - llm_calls * flex_penalty
        efficiency_flex = gpl_pos / adjusted if adjusted > 0 else None

    # Aggregate score: 50% success (binary) + 50% efficiency (normalised 0–1).
    eff_for_score = efficiency_flex if mode == "flex-n" else efficiency
    aggregate_score = 0.5 * float(success) + 0.5 * (eff_for_score or 0.0)

    sorted_lat = sorted(latencies)
    n = len(sorted_lat)

    result: dict[str, Any] = {
        "type": "level",
        "model_id": full_model_id,
        "pack_id": pack_id,
        "level_id": level_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "local": model.get("local", True),
        "reasoning": variant.get("reasoning", False),
        "inference_mode": mode,
        "anon": anon,
        **({"no_rules": True} if no_rules else {}),
        **({"observation_interval": observation_interval} if observation_interval > 1 else {}),
        **legend_metadata(board_legend, legend_seed),
        "input_mode": input_mode,
        "runner": "python" if use_python else "dart",
        "success": success,
        "actions_total": actions_total,
        "gold_path_length": gold_path_length,
        "efficiency": efficiency,
        "aggregate_score": aggregate_score,
        "attempts": attempts,
        "resets": resets,
        "voluntary_resets": voluntary_resets,
        "parse_retries": parse_retries_total,
        "repeated_states": repeated_states,
        "llm_calls": llm_calls,
        "rejections": total_rejections,
        "latency_ms": {
            "mean": sum(sorted_lat) / n if n else 0,
            "median": sorted_lat[n // 2] if n else 0,
            "p95": sorted_lat[int(n * 0.95)] if n else 0,
            "total": sum(sorted_lat),
        },
        "input_tokens_total": input_tokens_total,
        "thinking_tokens_total": thinking_tokens_total,
        "output_tokens_total": output_tokens_total,
        "cost_usd": round(cost_total, 6) if cost_complete else None,
        "cost_sources": sorted(cost_sources),
        "llm_log": llm_log,
    }
    if instruction_payload is not None:
        result.update(
            {
                "instruction_policy": instruction_payload.policy,
                "instruction_digest": instruction_payload.digest,
                "instruction_stage_index": instruction_payload.stage_index,
                "sequence_index": instruction_payload.sequence_index,
                "instruction_level_index": instruction_payload.level_index,
                "omitted_instruction_media": list(
                    instruction_payload.omitted_media
                ),
                "notebook_before_digest": sha256_text(game_notebook.strip()),
                "notebook_before_chars": len(game_notebook.strip()),
                "initial_base_prompt_digest": initial_base_prompt_digest,
                "initial_prompt_digest": initial_prompt_digest,
            }
        )
    if result_context:
        result.update(result_context)

    if mode == "fixed-n":
        result["step_size"] = step_size
    elif mode == "flex-n":
        result["max_n"] = max_n
        result["flex_penalty"] = flex_penalty
        result["efficiency_flex"] = efficiency_flex

    if runner_error is not None:
        result["error"] = runner_error
    if model_error is not None:
        result["model_error_type"] = last_model_error_type
        result["llm_attempts"] = llm_attempts
    if legend_quiz and final_event.get("legend_answers"):
        result["legend_quiz"] = run_legend_quiz(
            legend_opening_prompt, final_event["legend_memory"], final_event["legend_answers"],
            connector_model, extra_params, connector, action_timeout,
        )

    report_progress(
        "completed" if runner_error is None else "error",
        status="completed" if runner_error is None else "error",
        event=final_event,
        success=success,
    )
    return result


def run_legend_quiz(
    opening_prompt: str, memory: str, answers: dict[str, str],
    model: str, params: dict, connector: str, timeout: int | None,
) -> dict:
    """Score identification after gameplay, without changing its score or call count."""
    prompt = (
        f"{opening_prompt}\n\nThe episode is over. The instructions below replace the gameplay instructions. "
        "Your final notes from play follow.\n"
        f"{memory or '(no notes)'}\n\n"
        f"Identify these opening-board symbols: {', '.join(sorted(answers))}. "
        "Use the exact piece names from the piece guide. Return only a JSON object "
        "with one key per listed symbol and a piece name or null as each value."
    )
    try:
        response, latency, in_tokens, think_tokens, out_tokens, cost, _ = call_llm(
            prompt, model, params, max_tokens=1024, request_timeout=timeout,
            image_b64=None, connector=connector,
        )
        guesses = json.loads(response)
        if not isinstance(guesses, dict):
            raise ValueError("legend quiz response must be a JSON object")
    except Exception as exc:
        return {"total": len(answers), "error": str(exc)}
    correct = sum(
        isinstance(guess := guesses.get(symbol), str)
        and guess.strip().casefold() == name.casefold()
        for symbol, name in answers.items()
    )
    return {
        "correct": correct, "total": len(answers), "guesses": guesses,
        "expected": answers, "latency_ms": round(latency),
        "input_tokens": in_tokens, "thinking_tokens": think_tokens,
        "output_tokens": out_tokens, "cost_usd": cost,
    }


def _send_give_up(send: Any, mode: str, memory: str) -> None:
    """Send a give_up in the appropriate format for the current mode."""
    if mode == "single":
        send({"action": "give_up", "memory": memory})
    else:
        send({"actions": [{"action": "give_up"}], "memory": memory})


# ── Resume helpers ─────────────────────────────────────────────────────────────

def load_completed(
    results_base: Path, mode: str, anon: bool, scan_dir: Path | None = None,
    input_mode: str = "text", no_rules: bool = False, observation_interval: int = 1,
    board_legend: str = "normal", legend_seed: int = 0,
    legend_quiz: bool = False,
) -> set[tuple[str, str, str]]:
    """Scan JSONL runs and return (model_id, pack_id, level_id) triples
    that already have a successful (non-error) result for the given
    (mode, anon, input_mode) combination.

    When *scan_dir* is given, only that directory is scanned (non-recursive).
    Otherwise all subdirectories under *results_base* are scanned.
    """
    done: set[tuple[str, str, str]] = set()
    base = scan_dir or results_base
    if not base.exists():
        return done
    glob_pattern = "*.jsonl" if scan_dir else "**/*.jsonl"
    for jsonl_file in sorted(base.glob(glob_pattern)):
        file_mode: str | None = None
        file_anon: bool = False
        file_input: str = "text"
        file_no_rules: bool = False
        file_observation_interval = 1
        file_legend: dict = {}
        file_legend_quiz = False
        with open(jsonl_file) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("type") == "run_meta":
                    file_mode = rec.get("inference_mode", "single")
                    file_anon = rec.get("anon", False)
                    file_input = rec.get("input_mode", "text")
                    file_no_rules = rec.get("no_rules", False)
                    file_observation_interval = rec.get("observation_interval", 1)
                    file_legend = legend_metadata(rec.get("board_legend", "normal"),
                                                  rec.get("legend_seed", 0))
                    file_legend_quiz = rec.get("legend_quiz", False)
                elif (rec.get("type") == "level"
                      and file_mode == mode
                      and file_anon == anon
                      and file_no_rules == no_rules
                      and file_observation_interval == observation_interval
                      and file_legend == legend_metadata(board_legend, legend_seed)
                      and file_legend_quiz == legend_quiz
                      and file_input == input_mode):
                    if "error" not in rec:
                        done.add((rec["model_id"], rec["pack_id"], rec["level_id"]))
    return done


# ── Pause/resume ───────────────────────────────────────────────────────────────

_running = threading.Event()
_running.set()  # starts unpaused


def _keyboard_listener() -> None:
    """Daemon thread: read raw keypresses to pause/resume the benchmark.

    'p' pauses after the current level finishes.
    'c' resumes.
    Ctrl+C / 'q' sends SIGINT to the main process.
    """
    import signal as _signal

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        while True:
            ch = sys.stdin.read(1)
            if ch.lower() == "p" and _running.is_set():
                _running.clear()
                tqdm.write("\n⏸  Paused — will stop after this level. Press 'c' to resume.")
            elif ch.lower() == "c" and not _running.is_set():
                _running.set()
                tqdm.write("▶  Resumed.")
            elif ch in ("\x03", "\x04", "q"):  # Ctrl+C, Ctrl+D, q
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
                _signal.raise_signal(_signal.SIGINT)
                break
    except Exception:
        pass
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def _wait_if_paused() -> None:
    """Block between levels while paused; returns immediately when running."""
    _running.wait()


# ── Main ───────────────────────────────────────────────────────────────────────

def validate_observation_interval(interval: int, mode: str, anon: bool, runner: str) -> None:
    if interval < 1:
        raise ValueError("--observation-interval must be at least 1")
    if interval > 1 and (mode != "single" or anon or runner == "dart"):
        raise ValueError("delayed observations require single mode and the named Python runner")


def validate_board_legend(legend: str, anon: bool, no_rules: bool, input_mode: str, runner: str) -> None:
    if legend not in ("normal", "shown", "hidden"):
        raise ValueError("board legend must be normal, shown or hidden")
    if legend != "normal" and (anon or no_rules or input_mode != "text" or runner == "dart"):
        raise ValueError("randomized board symbols require rules-given text and the Python runner")


def legend_metadata(legend: str, seed: int) -> dict:
    return {"board_legend": legend, "legend_seed": seed} if legend != "normal" else {}


def main() -> None:
    load_dotenv()

    # Keyboard listener for pause/resume (only when stdin is a real terminal).
    if sys.stdin.isatty():
        t = threading.Thread(target=_keyboard_listener, daemon=True)
        t.start()

    parser = argparse.ArgumentParser(
        description="GridPonder AI Benchmark",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    # What to run
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--suite", choices=["curated"], help="Run a predefined level suite")
    scope.add_argument("--all", action="store_true", help="Run all packs and all levels")
    scope.add_argument("--pack", help="Run all levels in one pack")
    scope.add_argument("--level", nargs=2, metavar=("PACK", "LEVEL"),
                       help="Run a single level: --level <pack_id> <level_id>")

    # Which models
    parser.add_argument("--model", action="append", dest="models",
                        help="Model or variant ID to run (repeatable); default: all in models.yaml")

    # Limits
    parser.add_argument("--attempt-multiplier", type=int, default=2,
                        help="action_limit_per_attempt = M × gold_path_length (default: 2)")
    parser.add_argument("--total-multiplier", type=int, default=3,
                        help="action_limit = M × gold_path_length, give_up costs 1 (default: 3)")

    # Repetitions
    parser.add_argument("--runs", type=int, default=1,
                        help="Repetitions per (model, level) pair (default: 1)")

    # Per-call hard timeout
    parser.add_argument("--action-timeout", type=int, default=None, metavar="SECONDS",
                        help="Hard wall-clock timeout per LLM call in seconds (default: none).")

    # Inference mode
    parser.add_argument("--mode", choices=["single", "fixed-n", "flex-n", "full"],
                        default="single",
                        help="Inference mode (default: single)")
    parser.add_argument("--step-size", type=int, default=3,
                        help="Max actions per LLM call for fixed-n mode (default: 3)")
    parser.add_argument("--max-n", type=int, default=None,
                        help="Max actions per LLM call for flex-n mode (default: unlimited)")
    parser.add_argument("--flex-penalty", type=float, default=0.5,
                        help="Efficiency penalty per extra step beyond first in flex-n (default: 0.5)")
    parser.add_argument("--observation-interval", type=int, default=1, metavar="N",
                        help="Reveal the board every N submitted actions in single mode (default: 1).")
    parser.add_argument("--board-legend", choices=["normal", "shown", "hidden"], default="normal",
                        help="Randomize the board symbols and show or hide their legend.")
    parser.add_argument("--legend-seed", type=int, default=0,
                        help="Use the same seed for a paired shown and hidden run.")
    parser.add_argument("--legend-quiz", action="store_true",
                        help="Ask for an opening-board symbol mapping after the game and score it separately.")
    parser.add_argument("--single-attempt", action="store_true",
                        help="Exactly one attempt: give_up ends the run as a loss instead of "
                             "resetting, and the prompt says so (Python runner only)")
    parser.add_argument("--anon", action="store_true",
                        help="Anonymise entity kinds and action IDs (ARC-AGI style)")
    parser.add_argument("--max-attempts", type=int, default=None,
                        help="Attempts per run: a loss resets the board until this many "
                             "attempts are used (runner default when omitted: 1, a loss "
                             "ends the run)")
    parser.add_argument("--full-attempts", action="store_true",
                        help="Each attempt gets the level's own move limit and the run's "
                             "total is their sum (instead of gold-path multipliers)")
    parser.add_argument("--no-rules", action="store_true",
                        help="Real board, symbols, kind names and actions, but no rule "
                             "text (game description, kind descriptions, goal prose, "
                             "status-header prose). Not combinable with --anon; text "
                             "input and Python runner only")
    parser.add_argument("--input", choices=["text", "image", "text+image"],
                        default="text",
                        help="What the model sees: text grid, board image, or both. "
                             "Image and text+image require the Python runner. Anon mode "
                             "always forces text (image carries no anonymisation).")
    parser.add_argument("--runner", choices=["auto", "dart", "python"], default="auto",
                        help="Game-loop runner: dart (compiled binary), python, or auto "
                             "(uses Dart if binary exists, else Python; default: auto)")
    parser.add_argument("--resume", action="store_true",
                        help="Skip levels already completed in any previous run for this mode+anon")
    parser.add_argument("--run-dir", type=str, default=None,
                        help="Shared output directory (skip creating a new timestamped dir). "
                             "Used by the parallel launcher.")
    parser.add_argument("--no-caffeinate", action="store_true",
                        help="Don't spawn caffeinate (launcher handles it)")
    parser.add_argument(
        "--packs-dir",
        type=Path,
        default=PACKS_DIR,
        help=f"Pack root to benchmark (default: {PACKS_DIR})",
    )

    args = parser.parse_args()
    run_id = str(uuid.uuid4())

    # Prevent macOS from sleeping during a long benchmark run.
    _caffeinate = None
    if not args.no_caffeinate:
        _caffeinate = subprocess.Popen(
            ["caffeinate", "-i"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    # ── Resolve level scope ──────────────────────────────────────────────────
    if args.level:
        pack_id, level_id = args.level
        levels_by_pack: dict[str, list[str]] = {pack_id: [level_id]}
    elif args.pack:
        all_levels = all_pack_levels(args.packs_dir)
        if args.pack not in all_levels:
            sys.exit(f"Pack not found: {args.pack}")
        levels_by_pack = {args.pack: all_levels[args.pack]}
    elif args.suite == "curated":
        levels_by_pack = load_suite()
    elif args.all:
        levels_by_pack = all_pack_levels(args.packs_dir)
    else:
        parser.print_help()
        sys.exit(0)

    # ── Resolve model variants ────────────────────────────────────────────────
    all_models = load_models()
    model_variants = expand_model_variants(all_models, args.models)
    if not model_variants:
        sys.exit(f"No matching model variants found for: {args.models}")

    # ── Build work list ───────────────────────────────────────────────────────
    work: list[tuple[str, str, dict, dict]] = []
    for pack_id, level_ids in levels_by_pack.items():
        for level_id in level_ids:
            for model, variant in model_variants:
                for _ in range(args.runs):
                    work.append((pack_id, level_id, model, variant))

    # Anon + image is silently downgraded to text by the runner; mirror that here.
    if args.anon and args.input != "text":
        args.input = "text"
    if args.no_rules and args.anon:
        sys.exit("--no-rules and --anon are separate modes; pick one")
    if args.no_rules and args.input != "text":
        sys.exit("--no-rules supports text input only (an image would show the pack's sprites)")
    try:
        validate_observation_interval(args.observation_interval, args.mode, args.anon, args.runner)
        validate_board_legend(args.board_legend, args.anon, args.no_rules, args.input, args.runner)
        if args.legend_quiz and args.board_legend == "normal":
            parser.error("--legend-quiz requires a shown or hidden board legend")
    except ValueError as exc:
        parser.error(str(exc))

    if args.resume:
        completed = load_completed(RESULTS_BASE, args.mode, args.anon, input_mode=args.input,
                                   no_rules=args.no_rules, observation_interval=args.observation_interval,
                                   board_legend=args.board_legend, legend_seed=args.legend_seed,
                                   legend_quiz=args.legend_quiz)
        if completed:
            before = len(work)
            work = [
                (p, l, m, v) for p, l, m, v in work
                if (f"{m['id']}{v.get('suffix', '')}", p, l) not in completed
            ]
            print(f"  Resuming: skipping {before - len(work)} already-completed level(s), "
                  f"{len(work)} remaining.")

    total = len(work)
    mode_label = args.mode
    if args.mode == "fixed-n":
        mode_label = f"fixed-{args.step_size}"
    elif args.mode == "flex-n":
        mode_label = f"flex-{args.max_n}(f={args.flex_penalty})"
    observation_tag = ""
    if args.observation_interval > 1:
        mode_label += f", observations every {args.observation_interval} actions"
        observation_tag = f"_obs{args.observation_interval}"
    if args.board_legend != "normal":
        mode_label += f", board legend {args.board_legend}"
        observation_tag += f"_legend-{args.board_legend}-{args.legend_seed}"
    if args.legend_quiz:
        observation_tag += "_quiz"
    anon_label = " [anon]" if args.anon else (" [no-rules]" if args.no_rules else "")
    input_label = "" if args.input == "text" else f" [{args.input}]"
    print(f"Benchmark [{mode_label}]{anon_label}{input_label}: {total} run(s) — "
          f"{len(model_variants)} model variant(s) × "
          f"{sum(len(v) for v in levels_by_pack.values())} level(s)"
          f"{f' × {args.runs} runs' if args.runs > 1 else ''}")
    if sys.stdin.isatty():
        print("  Controls: p = pause after current level  |  c = continue  |  q = quit")

    # ── Output directory for this run ─────────────────────────────────────────
    if args.run_dir:
        RESULTS_DIR = Path(args.run_dir)
    else:
        ts = datetime.now().strftime("%Y-%m-%d_%H%M%S")
        RESULTS_DIR = RESULTS_BASE / ts
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    # Write meta capturing CLI args. When using --run-dir (parallel mode),
    # each worker writes its own meta file to avoid races.
    run_config = {
        "schema_version": 2,
        "run_id": run_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "suite": args.suite,
        "pack": args.pack,
        "level": args.level,
        "models": args.models,
        "attempt_multiplier": args.attempt_multiplier,
        "total_multiplier": args.total_multiplier,
        "runs_per_level": args.runs,
        "action_timeout": args.action_timeout,
        "inference_mode": args.mode,
        "observation_interval": args.observation_interval,
        **legend_metadata(args.board_legend, args.legend_seed),
        **({"legend_quiz": True} if args.legend_quiz else {}),
        "step_size": args.step_size if args.mode == "fixed-n" else None,
        "max_n": args.max_n if args.mode == "flex-n" else None,
        "flex_penalty": args.flex_penalty if args.mode == "flex-n" else None,
        "input_mode": args.input,
        "packs_dir": str(args.packs_dir.resolve()),
        "levels_by_pack": {p: lvls for p, lvls in levels_by_pack.items()},
        "total_work_items": total,
        "source": source_snapshot(SCRIPT_DIR.parent.parent, args.packs_dir),
    }
    # File-name suffix that uniquely identifies this (mode, anon, input) bucket.
    _input_tag = "" if args.input == "text" else f"_{args.input.replace('+', '-')}"
    if args.run_dir:
        _mode_tag = args.mode
        if args.mode == "flex-n":
            _mode_tag = f"flex-{args.max_n}" if args.max_n else "flex-n"
        _anon_tag = "_anon" if args.anon else ("_norules" if args.no_rules else "")
        _model_tag = (args.models[0] if args.models else "all")
        meta_file = RESULTS_DIR / f"meta_{_model_tag}_{_mode_tag}{_anon_tag}{_input_tag}{observation_tag}.json"
    else:
        meta_file = RESULTS_DIR / "meta.json"
    with open(meta_file, "w") as f:
        json.dump(run_config, f, indent=2)

    # Group work by model variant so we write one file per variant.
    # Pre-populate in model_variants order so --resume doesn't reorder models
    # when some levels are already filtered out for a partially-done model.
    by_variant: dict[str, list[tuple[str, str, dict, dict]]] = {
        f"{m['id']}{v.get('suffix', '')}": []
        for m, v in model_variants
    }
    for item in work:
        pack_id, level_id, model, variant = item
        full_id = f"{model['id']}{variant.get('suffix', '')}"
        by_variant[full_id].append(item)
    # Drop models with no remaining work (fully skipped by --resume)
    by_variant = {k: v for k, v in by_variant.items() if v}

    # ── Run ───────────────────────────────────────────────────────────────────
    # Build a file-name suffix from mode+anon+input so parallel workers don't collide.
    mode_tag = args.mode
    if args.mode == "flex-n":
        mode_tag = f"flex-{args.max_n}" if args.max_n else "flex-n"
    anon_tag = "_anon" if args.anon else ("_norules" if args.no_rules else "")
    input_tag = "" if args.input == "text" else f"_{args.input.replace('+', '-')}"

    for full_id, items in by_variant.items():
        out_file = RESULTS_DIR / f"{full_id}_{mode_tag}{anon_tag}{input_tag}{observation_tag}.jsonl"
        model_cfg = items[0][2]
        variant_cfg = items[0][3]

        run_meta = {
            "type": "run_meta",
            "model_id": full_id,
            "display_name": model_cfg["display_name"],
            "litellm_model": model_cfg.get("litellm_model"),
            "connector": model_cfg.get("connector", "litellm"),
            "model": model_cfg.get("model", model_cfg.get("litellm_model")),
            "concurrency_group": model_cfg.get("concurrency_group", "default"),
            "model_params": variant_cfg.get("params") or {},
            "pricing": model_cfg.get("pricing"),
            "local": model_cfg.get("local", True),
            "reasoning": variant_cfg.get("reasoning", False),
            "inference_mode": args.mode,
            "observation_interval": args.observation_interval,
            **legend_metadata(args.board_legend, args.legend_seed),
            **({"legend_quiz": True} if args.legend_quiz else {}),
            "anon": args.anon,
            **({"no_rules": True} if args.no_rules else {}),
            **({"max_attempts": args.max_attempts} if args.max_attempts is not None else {}),
            **({"full_attempts": True} if args.full_attempts else {}),
            "single_attempt": args.single_attempt,
            "input_mode": args.input,
            "attempt_multiplier": args.attempt_multiplier,
            "total_multiplier": args.total_multiplier,
            "runs_per_level": args.runs,
            "action_timeout": args.action_timeout,
            "run_id": run_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        if args.mode == "fixed-n":
            run_meta["step_size"] = args.step_size
        elif args.mode == "flex-n":
            run_meta["max_n"] = args.max_n
            run_meta["flex_penalty"] = args.flex_penalty

        with open(out_file, "w") as fout:
            fout.write(json.dumps(run_meta) + "\n")

            pbar = tqdm(items, desc=full_id, unit="level")
            for pack_id, level_id, model, variant in pbar:
                _wait_if_paused()
                pbar.set_postfix(pack=pack_id, level=level_id)
                try:
                    result = run_level(
                        pack_id, level_id, model, variant,
                        args.attempt_multiplier, args.total_multiplier,
                        action_timeout=args.action_timeout,
                        mode=args.mode,
                        step_size=args.step_size,
                        max_n=args.max_n,
                        flex_penalty=args.flex_penalty,
                        anon=args.anon,
                        single_attempt=args.single_attempt,
                        no_rules=args.no_rules,
                        max_attempts=args.max_attempts,
                        full_attempts=args.full_attempts,
                        observation_interval=args.observation_interval,
                        board_legend=args.board_legend,
                        legend_seed=args.legend_seed,
                        legend_quiz=args.legend_quiz,
                        runner=args.runner,
                        input_mode=args.input,
                        packs_dir=args.packs_dir,
                    )
                except Exception as exc:
                    result = {
                        "type": "level",
                        "model_id": full_id,
                        "pack_id": pack_id,
                        "level_id": level_id,
                        "inference_mode": args.mode,
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                        "error": str(exc),
                        "success": False,
                    }
                fout.write(json.dumps(result) + "\n")
                fout.flush()

                status = "ERROR" if result.get("error") else ("ok  " if result.get("success") else "FAIL")
                actions = result.get("actions_total", "?")
                gold = result.get("gold_path_length", "?")
                calls = result.get("llm_calls", "?")
                rejections = result.get("rejections", 0)
                lat = result.get("latency_ms", {})
                lat_total = lat.get("total")
                lat_mean = lat.get("mean")
                total_str = f"{lat_total/1000:6.1f}s" if lat_total is not None else "     ?s"
                mean_str = f"{lat_mean/1000:5.1f}s" if lat_mean is not None else "    ?s"
                level_col = f"{pack_id}/{level_id}"
                calls_col = f"  calls={calls:>3}" if args.mode != "single" else ""
                tqdm.write(
                    f"  {status}  {full_id:22s}  {level_col:28s}"
                    f"  actions={actions:>3}/{gold:<3}  rej={rejections:<3}{calls_col}"
                    f"  avg={mean_str}  total={total_str}"
                )
                if result.get("error"):
                    tqdm.write(f"  {result['error']}")
                if result.get("model_error_type") and result.get("llm_calls") == 0:
                    tqdm.write("  Stopping this model: no successful model calls. Fix the request error before running more levels.")
                    break

        print(f"  → {out_file}")

    print(f"\nDone. Run 'python aggregate.py' to update leaderboard.json.")
    if _caffeinate:
        _caffeinate.terminate()


if __name__ == "__main__":
    main()
