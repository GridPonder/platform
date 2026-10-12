"""Per-run metrics and tier classification.

Schema rejection measures interface compliance. A well-formed action rejected
by the current state is counted separately as legality feedback. Neither
counter alone explains why a run failed.

These functions perform no I/O.
"""
from __future__ import annotations

from typing import Any


def first_divergence(
    agent_moves: list[dict[str, Any]],
    gold_path: list[dict[str, Any]],
) -> int | None:
    """Index where the agent's first attempt leaves the gold-path prefix.

    Returns None when the agent's moves are a prefix of the gold path (i.e. it
    never diverged), including when it made no moves at all.
    """
    for i, move in enumerate(agent_moves):
        if i >= len(gold_path) or move != gold_path[i]:
            return i
    return None


def efficiency(actions_total: int, gold_path_length: int) -> float | None:
    """Actions taken per gold-path action. None when gold length is unknown."""
    if not gold_path_length:
        return None
    return actions_total / gold_path_length


def completion(run: dict[str, Any]) -> str:
    """How the run stopped, in one phrase.

    The supervisor already records `reached_terminal`, `agent_exit_code` and
    `agent_reported_error`, and until now nothing read any of them — so a run
    killed at the timeout and a run the level genuinely beat printed the same
    row. This is what lets the report tell them apart.
    """
    if run.get("solved"):
        return "solved"
    if run.get("reached_terminal", True):
        return "the game ended the run"
    code = run.get("agent_exit_code")
    # subprocess.TimeoutExpired is recorded as -1 by the supervisor, which is
    # the one non-zero code that means "we stopped it", not "it broke".
    if code == -1:
        return "the agent was stopped at the timeout"
    if code not in (0, None):
        return f"the agent exited {code}"
    if run.get("agent_reported_error"):
        return "the agent reported an error"
    return "the agent stopped without finishing"


def classify(run: dict[str, Any], thresholds: dict[str, Any]) -> str:
    """Sort one tier-1 run into trivial | borderline | hard | friction | incomplete.

    Reads `rejected_schema` only. `rejected_illegal` is carried on the run for
    reporting but deliberately does not feed the friction test — a solved run
    is never friction just because the agent probed the geometry on its way.

    `hard` is a claim about the level, so it is reserved for runs the *game*
    ended. An agent killed at the timeout, crashed, or rate-limited into
    silence supports no claim about difficulty at all; calling that `hard`
    quietly credits the level with beating an agent that never finished
    playing it. Those become `incomplete`, and the report keeps them out of the
    solve rate.

    Two orderings matter. A solve is never incomplete — reaching the win *is*
    reaching a terminal, whatever the agent process did afterwards. And
    friction still wins, because five malformed payloads is a fact about the
    rules text whether or not the run got to finish.

    A run dict with no `reached_terminal` is treated as finished, so results
    written before this existed keep classifying the way they did.
    """
    if run["rejected_schema"] >= thresholds["rejected_friction_min"]:
        return "friction"
    if not run["solved"]:
        return "incomplete" if not run.get("reached_terminal", True) else "hard"
    eff = efficiency(run["actions_total"], run["gold_path_length"])
    wandered = eff is not None and eff > thresholds["efficiency_trivial_max"]
    if run["attempts"] > 1 or wandered:
        return "borderline"
    return "trivial"
