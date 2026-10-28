"""
Empirical heuristic admissibility test.

For every game that declares has_heuristic=True in game_configs.py, and for
every level in that pack that has a gold path, this test replays the gold path
step by step and asserts:

    h(state_i) <= len(gold_path) - i   for all i in 0..len(gold_path)

An admissible heuristic must never overestimate the cost to reach the goal.
Since the gold path is a valid solution, len(gold_path) - i is an upper bound
on the true cost from state_i.  Any violation would mean h(state_i) exceeds a
known achievable cost — a clear admissibility failure.

This is not a formal proof but gives strong empirical evidence across all known
levels, especially those whose gold paths were verified by BFS or human play.

Run with:
    cd tools/solver && python -m pytest test_heuristic_admissibility.py -v
"""

from __future__ import annotations

import importlib
import json
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

from engine_adapter import gold_path_actions
from game_configs import GAME_CONFIGS

_SOLVER_DIR = Path(__file__).parent
_PACKS_DIR = _SOLVER_DIR.parent.parent / "packs"


def _parse_gold_actions(gold_raw: list, module: Any) -> list[str]:
    """
    Convert raw goldPath entries to a flat list of action strings.

    Use the same decoder as the solver, then adapt movement names for legacy
    simulators such as Box Builder. Every stored action must be replayed:
    dropping an unrecognized action invalidates the remaining-path bound.
    """
    valid = set(module.ACTIONS)
    actions: list[str] = []
    decoded = gold_path_actions({"solution": {"goldPath": gold_raw}})
    if len(decoded) != len(gold_raw):
        raise ValueError("Gold-path decoding dropped an action")
    for action in decoded:
        if action not in valid and action.startswith("move_"):
            action = action.removeprefix("move_")
        if action not in valid:
            raise ValueError(f"Unsupported gold-path action {action!r}")
        actions.append(action)
    return actions


@pytest.mark.parametrize("raw,valid,expected", [
    (["right", "clone", "left"],
     ["move_right", "move_left", "clone"], ["move_right", "clone", "move_left"]),
    ([{"direction": "left"}, {"action": "move", "direction": "right"}],
     ["left", "right"], ["left", "right"]),
])
def test_gold_actions_preserve_moves_and_non_moves(raw, valid, expected):
    assert _parse_gold_actions(raw, SimpleNamespace(ACTIONS=valid)) == expected


def test_gold_actions_reject_unknown_actions_instead_of_dropping_them():
    with pytest.raises(ValueError, match="Unsupported gold-path action"):
        _parse_gold_actions(["right", "unknown"], SimpleNamespace(ACTIONS=["move_right"]))


def _collect_cases() -> list:
    """
    Yield pytest.param tuples for all (game, level) pairs that have a heuristic
    and a non-empty gold path.
    """
    cases = []
    for game_key, config in GAME_CONFIGS.items():
        if not config.get("has_heuristic"):
            continue
        module_name = config.get("game_module")
        if not module_name:
            continue

        # Pack directory name matches game_key by convention
        levels_dir = _PACKS_DIR / game_key / "levels"
        if not levels_dir.exists():
            continue

        module = importlib.import_module(f"games.{module_name}")
        if not hasattr(module, "heuristic"):
            continue  # module opted out of heuristic despite config flag

        for level_file in sorted(levels_dir.glob("*.json")):
            level_json = json.loads(level_file.read_text())
            gold_raw = level_json.get("solution", {}).get("goldPath", [])
            if not gold_raw:
                continue
            gold_actions = _parse_gold_actions(gold_raw, module)
            cases.append(
                pytest.param(
                    game_key,
                    level_file.stem,
                    level_json,
                    module,
                    gold_actions,
                    id=f"{game_key}/{level_file.stem}",
                )
            )
    return cases


@pytest.mark.parametrize(
    "game_key,level_id,level_json,module,gold_actions",
    _collect_cases(),
)
def test_heuristic_admissibility(
    game_key: str,
    level_id: str,
    level_json: dict,
    module: Any,
    gold_actions: list[str],
) -> None:
    """
    h(state_i) must never exceed the number of remaining gold-path steps.

    Checked at every intermediate state, not just the initial state, for
    maximum coverage.
    """
    initial, info = module.load(level_json)
    heuristic = module.heuristic
    n = len(gold_actions)

    state = initial
    won = False
    for i, action in enumerate(gold_actions):
        remaining = n - i
        h = heuristic(state, info)
        assert h <= remaining, (
            f"{game_key}/{level_id}: at step {i} (action={action!r}), "
            f"h={h} > remaining={remaining} — heuristic is inadmissible here"
        )
        state, won, _events = module.apply(state, action, info)

    # At the goal state, the heuristic must return 0
    assert won, f"{game_key}/{level_id}: the complete gold path did not win"
    h_goal = heuristic(state, info)
    assert h_goal == 0.0, (
        f"{game_key}/{level_id}: h(goal state) = {h_goal}, expected 0.0"
    )
