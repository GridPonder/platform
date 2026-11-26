"""The settings that define what a benchmark run measures.

This is the single list used by bench.py and run_queue.py (`--resume`) and by
aggregate.py (leaderboard grouping). Results produced under different
settings must never stand in for each other: a resumed run only skips levels
finished under the same protocol, and the leaderboard never pools them.

Result files written before a setting existed do not record it. A missing
value means the setting's default, which is how those runs were played.
"""
from __future__ import annotations

from typing import Any

# Settings that change the measured condition. The leaderboard groups by these.
CONDITION_DEFAULTS: dict[str, Any] = {
    "inference_mode": "single",
    "anon": False,
    "input_mode": "text",
    "no_rules": False,
    "observation_interval": 1,
    "board_legend": "normal",
    "single_attempt": False,
    "max_attempts": 1,
    "full_attempts": False,
    "give_up_uses_attempt": False,
}

# Settings a resumed run must also match. The seed pairs a shown-legend run
# with a hidden-legend run, and the quiz adds a scored call after play, but
# runs that differ only in these measure the same condition.
RESUME_ONLY_DEFAULTS: dict[str, Any] = {
    "legend_seed": 0,
    "legend_quiz": False,
}


def _normalised(meta: dict, defaults: dict[str, Any]) -> dict[str, Any]:
    values = {}
    for name, default in defaults.items():
        value = meta.get(name)
        values[name] = default if value is None else value
    return values


def run_condition(meta: dict) -> dict[str, Any]:
    """The measured condition of a run, from its run_meta record."""
    return _normalised(meta, CONDITION_DEFAULTS)


def run_protocol(meta: dict) -> dict[str, Any]:
    """Everything a resumed run must match, from a run_meta record."""
    protocol = {**run_condition(meta), **_normalised(meta, RESUME_ONLY_DEFAULTS)}
    if protocol["board_legend"] == "normal":
        # The seed only matters when symbols are randomized.
        protocol["legend_seed"] = RESUME_ONLY_DEFAULTS["legend_seed"]
    return protocol

