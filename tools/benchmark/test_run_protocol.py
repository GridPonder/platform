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
