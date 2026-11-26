"""Results from different run protocols must not stand in for each other.

Covers the leaderboard grouping (aggregate.py) and the --resume check
(bench.load_completed), which both use run_protocol.py.
"""
from __future__ import annotations

import json
from pathlib import Path

import aggregate
from bench import load_completed
from run_protocol import run_condition, run_protocol


def _write_run(path: Path, meta: dict, success: bool) -> None:
    run_meta = {"type": "run_meta", "model_id": "m1", "inference_mode": "single",
                "anon": False, "input_mode": "text", **meta}
    level = {"type": "level", "model_id": "m1", "pack_id": "carrot_quest",
             "level_id": "fw_001", "success": success, "gold_path_length": 4,
             "efficiency": 1.0 if success else None}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(run_meta) + "\n" + json.dumps(level) + "\n")


def test_missing_settings_mean_their_defaults():
    old = {"inference_mode": "single", "anon": False}
    explicit = {"inference_mode": "single", "anon": False, "no_rules": False,
                "max_attempts": 1, "give_up_uses_attempt": False,
                "board_legend": "normal", "legend_seed": 7}
    assert run_protocol(old) == run_protocol(explicit)
    assert run_condition({"max_attempts": None})["max_attempts"] == 1


def test_leaderboard_keeps_rules_and_no_rules_runs_apart(tmp_path):
    _write_run(tmp_path / "a" / "rules.jsonl", {}, success=True)
    _write_run(tmp_path / "b" / "norules.jsonl", {"no_rules": True}, success=False)

    board = aggregate.build_leaderboard(aggregate.load_results(tmp_path))
    rows = {row["no_rules"]: row["overall"]["success_rate"] for row in board["models"]}
    assert rows == {False: 1.0, True: 0.0}

    column = board["level_results_columns"].index("no_rules")
    assert sorted(r[column] for r in board["level_results"]) == [False, True]


def test_leaderboard_keeps_give_up_policies_apart(tmp_path):
    _write_run(tmp_path / "a.jsonl", {"max_attempts": 3}, success=True)
    _write_run(tmp_path / "b.jsonl", {"max_attempts": 3, "give_up_uses_attempt": True},
               success=False)
    board = aggregate.build_leaderboard(aggregate.load_results(tmp_path))
    assert len(board["models"]) == 2


def test_resume_does_not_reuse_a_result_from_another_give_up_policy(tmp_path):
    # An older default-policy file does not record the setting at all.
    _write_run(tmp_path / "old" / "run.jsonl", {"max_attempts": 3}, success=True)
    done = ("m1", "carrot_quest", "fw_001")

    default = {"inference_mode": "single", "anon": False, "input_mode": "text",
               "max_attempts": 3}
    assert load_completed(tmp_path, default) == {done}
    assert load_completed(tmp_path, {**default, "give_up_uses_attempt": True}) == set()
    assert load_completed(tmp_path, {**default, "no_rules": True}) == set()
    assert load_completed(tmp_path, {**default, "max_attempts": 1}) == set()


def test_flex_n_caps_are_part_of_the_protocol(tmp_path):
    flex = {"inference_mode": "flex-n", "anon": False, "input_mode": "text"}
    _write_run(tmp_path / "cap2.jsonl", {**flex, "max_n": 2, "flex_penalty": 0.5}, success=True)
    done = ("m1", "carrot_quest", "fw_001")

    assert load_completed(tmp_path, {**flex, "max_n": 2}) == {done}
    assert load_completed(tmp_path, {**flex, "max_n": 5}) == set()
    assert load_completed(tmp_path, {**flex, "max_n": 2, "flex_penalty": 0.25}) == set()

    _write_run(tmp_path / "cap5.jsonl", {**flex, "max_n": 5, "flex_penalty": 0.5}, success=False)
    board = aggregate.build_leaderboard(aggregate.load_results(tmp_path))
    assert sorted((m["max_n"], m["overall"]["success_rate"]) for m in board["models"]) == [
        (2, 1.0), (5, 0.0)]


def test_batch_settings_only_count_for_their_own_mode():
    # A stray flex-n value on a single-mode run does not split it off.
    assert run_condition({"inference_mode": "single", "max_n": 4}) == run_condition({})
    assert run_condition({"inference_mode": "fixed-n"})["step_size"] == 3
    assert run_condition({"inference_mode": "flex-n"})["flex_penalty"] == 0.5


def test_run_queue_records_the_batch_settings_it_resumes_on(tmp_path):
    from types import SimpleNamespace
    from run_queue import build_run_meta, filter_completed

    item = SimpleNamespace(full_variant_id="m1", model={"display_name": "M"}, variant={},
                           connector="litellm", connector_model="x", concurrency_group="g",
                           mode="flex-n", anon=False, input_mode="text", max_n=2,
                           pack_id="carrot_quest", level_id="fw_001")
    args = SimpleNamespace(attempt_multiplier=2, total_multiplier=4, action_timeout=None,
                           run_id="r", flex_penalty=0.5)
    meta = build_run_meta(item, args)
    assert (meta["max_n"], meta["flex_penalty"]) == (2, 0.5)

    _write_run(tmp_path / "run.jsonl", {k: v for k, v in meta.items() if k != "type"},
               success=True)
    assert filter_completed([item], scan_dir=tmp_path) == []
    item5 = SimpleNamespace(**{**vars(item), "max_n": 5})
    assert filter_completed([item5], scan_dir=tmp_path) == [item5]
