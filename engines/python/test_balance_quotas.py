"""
Tests for `quotas` on the `balance` goal and the matching
`balance_unreachable` checks.

Run from engines/python/:  python test_balance_quotas.py
"""
from __future__ import annotations
import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(ROOT))

from engines.python._game_def import GameDef
from engines.python._turn_engine import TurnEngine
from engines.python.goal_renderer import render_goals


def _make_game() -> GameDef:
    data = {
        "id": "com.gridponder.test_balance_quotas",
        "layers": [
            {"id": "ground", "occupancy": "exactly_one", "default": "empty"},
            {"id": "markers", "occupancy": "zero_or_one"},
            {"id": "territory", "occupancy": "zero_or_one"},
            {"id": "actors", "occupancy": "zero_or_one"},
        ],
        "entityKinds": {
            "empty": {"layer": "ground", "tags": ["walkable"]},
            "site": {"layer": "markers", "tags": [], "uiName": "Site"},
            "unit_a": {"layer": "actors", "tags": ["actor"]},
            "unit_b": {"layer": "actors", "tags": ["actor"]},
            "terr_a": {"layer": "territory", "tags": []},
            "terr_b": {"layer": "territory", "tags": []},
            "blighted": {"layer": "territory", "tags": []},
        },
        "actions": [
            {"id": "move", "params": {"direction": {"type": "direction", "values": ["up", "down", "left", "right"]}}},
        ],
        "systems": [
            {"id": "movement", "type": "coupled_actors", "config": {
                "claim": {"layer": "territory",
                          "map": {"unit_a": "terr_a", "unit_b": "terr_b"}}}},
        ],
    }
    return GameDef.from_dict(data, id="test_balance_quotas")


def _make_level(sites, lose=True, count=1) -> dict:
    """4x2 board: unit_a starts at (0,0), unit_b at (0,1), each on its own
    pre-claimed cell. Moving right three times fills both rows 4/4."""
    return {
        "id": "quota_level",
        "board": {
            "size": [4, 2],
            "layers": {
                "ground": {"format": "sparse", "entries": []},
                "markers": {"format": "sparse", "entries": [
                    {"position": [x, y], "kind": "site"} for x, y in sites]},
                "territory": {"format": "sparse", "entries": [
                    {"position": [0, 0], "kind": "terr_a"},
                    {"position": [0, 1], "kind": "terr_b"}]},
                "actors": {"format": "sparse", "entries": [
                    {"position": [0, 0], "kind": "unit_a"},
                    {"position": [0, 1], "kind": "unit_b"}]},
            },
        },
        "state": {},
        "goals": [{"id": "balance_goal", "type": "balance", "config": {
            "layer": "territory", "owners": ["terr_a", "terr_b"],
            "claimableLayer": "ground", "claimableKind": "empty",
            "quotas": [{"layer": "markers", "kind": "site", "count": count}]}}],
        "loseConditions": ([{"type": "balance_unreachable",
                             "config": {"goalId": "balance_goal"}}] if lose else []),
    }


def _right(engine, n):
    result = None
    for _ in range(n):
        result = engine.execute_turn("move", {"direction": "right"})
    return result


def test_quota_met_wins() -> None:
    engine = TurnEngine(_make_game(), _make_level([(1, 0), (2, 1)]))
    result = _right(engine, 3)
    assert result.is_won, "equal, complete and one site each must win"
    print("  OK  quota_met_wins")


def test_quota_unmet_blocks_the_win() -> None:
    """Equal and complete, but one owner holds both sites: not a win."""
    engine = TurnEngine(_make_game(), _make_level([(1, 0), (2, 0)], lose=False))
    result = _right(engine, 3)
    assert not result.is_won
    assert not result.is_lost
    print("  OK  quota_unmet_blocks_the_win")


def test_over_quota_loses_at_once() -> None:
    engine = TurnEngine(_make_game(), _make_level([(1, 0), (2, 0)]))
    first = _right(engine, 1)
    assert not first.is_lost, "one site each is still possible"
    second = _right(engine, 1)
    assert second.is_lost and second.lose_reason == "balance_unreachable", \
        "a second site for one owner can never be undone"
    print("  OK  over_quota_loses_at_once")


def test_shortfall_beyond_unowned_sites_loses() -> None:
    """One site on the board, quota one each: the owners need two."""
    engine = TurnEngine(_make_game(), _make_level([(3, 0)]))
    result = _right(engine, 1)
    assert result.is_lost and result.lose_reason == "balance_unreachable"
    print("  OK  shortfall_beyond_unowned_sites_loses")


def test_goal_text_states_the_quota() -> None:
    game = _make_game()
    level = _make_level([(1, 0), (2, 1)])
    engine = TurnEngine(game, level)
    _right(engine, 1)
    text = render_goals(level, engine.state, game)
    assert "exactly 1 Site cell" in text, text
    assert "need 1 each" in text, text
    print("  OK  goal_text_states_the_quota")


def test_goal_text_states_the_scored_count() -> None:
    """A count the evaluator reads as 1 must also be shown as 1."""
    game = _make_game()
    level = _make_level([(1, 0), (2, 1)])
    level["goals"][0]["config"]["quotas"][0]["count"] = 2.0
    engine = TurnEngine(game, level)
    text = render_goals(level, engine.state, game)
    assert "exactly 1 Site cell" in text and "need 1 each" in text, text
    print("  OK  goal_text_states_the_scored_count")


def test_foreign_mark_on_claimable_land_loses() -> None:
    """A territory mark that belongs to no owner can never be claimed."""
    level = _make_level([(1, 0), (2, 1)])
    level["board"]["layers"]["territory"]["entries"].append(
        {"position": [3, 0], "kind": "blighted"})
    engine = TurnEngine(_make_game(), level)
    result = _right(engine, 1)
    assert result.is_lost and result.lose_reason == "balance_unreachable"
    print("  OK  foreign_mark_on_claimable_land_loses")


def test_no_foreign_mark_no_loss() -> None:
    engine = TurnEngine(_make_game(), _make_level([(1, 0), (2, 1)]))
    assert not _right(engine, 1).is_lost
    print("  OK  no_foreign_mark_no_loss")


def run_all() -> bool:
    tests = [
        test_quota_met_wins,
        test_quota_unmet_blocks_the_win,
        test_over_quota_loses_at_once,
        test_shortfall_beyond_unowned_sites_loses,
        test_goal_text_states_the_quota,
        test_goal_text_states_the_scored_count,
        test_foreign_mark_on_claimable_land_loses,
        test_no_foreign_mark_no_loss,
    ]
    failed = 0
    for test in tests:
        try:
            test()
        except AssertionError as exc:
            print(f"  FAIL {test.__name__}: {exc}")
            failed += 1
        except Exception as exc:
            import traceback
            print(f"  ERROR {test.__name__}: {exc}")
            traceback.print_exc()
            failed += 1
    print(f"\n{'='*50}")
    print(f"Results: {len(tests) - failed} passed, {failed} failed")
    return failed == 0


if __name__ == "__main__":
    sys.exit(0 if run_all() else 1)
