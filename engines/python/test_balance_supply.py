"""
Tests for the supply-line half of `balance_unreachable`: with
`requireConnected`, an owned cell that can no longer reach its owner's
connection source (through that owner's cells or unclaimed claimable cells)
makes the level unwinnable at once.

Run from engines/python/:  python test_balance_supply.py
"""
from __future__ import annotations
import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(ROOT))

from engines.python._game_def import GameDef
from engines.python._turn_engine import TurnEngine
from engines.python._goal import balance_supply_cut


def _make_game() -> GameDef:
    data = {
        "id": "com.gridponder.test_balance_supply",
        "layers": [
            {"id": "ground", "occupancy": "exactly_one", "default": "empty"},
            {"id": "territory", "occupancy": "zero_or_one"},
            {"id": "actors", "occupancy": "zero_or_one"},
        ],
        "entityKinds": {
            "empty": {"layer": "ground", "tags": ["walkable"]},
            "gate": {"layer": "ground", "tags": ["solid"]},
            "unit_a": {"layer": "actors", "tags": ["actor"]},
            "unit_b": {"layer": "actors", "tags": ["actor"]},
            "terr_a": {"layer": "territory", "tags": []},
            "terr_b": {"layer": "territory", "tags": []},
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
    return GameDef.from_dict(data, id="test_balance_supply")


def _make_level(terr, ground=(), connected=True, sources=None) -> dict:
    """4x2 board: unit_a at (0,0), unit_b at (0,1); `terr` is a list of
    ((x, y), kind) territory marks, `ground` a list of ((x, y), kind)."""
    if sources is None:
        sources = {"terr_a": [0, 0], "terr_b": [0, 1]}
    return {
        "id": "supply_level",
        "board": {
            "size": [4, 2],
            "layers": {
                "ground": {"format": "sparse", "entries": [
                    {"position": [x, y], "kind": k} for (x, y), k in ground]},
                "territory": {"format": "sparse", "entries": [
                    {"position": [x, y], "kind": k} for (x, y), k in terr]},
                "actors": {"format": "sparse", "entries": [
                    {"position": [0, 0], "kind": "unit_a"},
                    {"position": [0, 1], "kind": "unit_b"}]},
            },
        },
        "state": {},
        "goals": [{"id": "balance_goal", "type": "balance", "config": {
            "layer": "territory", "owners": ["terr_a", "terr_b"],
            "claimableLayer": "ground", "claimableKind": ["empty", "gate"],
            "requireConnected": connected, "connectionSources": sources}}],
        "loseConditions": [{"type": "balance_unreachable",
                            "config": {"goalId": "balance_goal"}}],
    }


CUT = [((0, 0), "terr_a"), ((2, 0), "terr_a"),
       ((0, 1), "terr_b"), ((1, 0), "terr_b"), ((1, 1), "terr_b")]
OPEN = [((0, 0), "terr_a"), ((2, 0), "terr_a"),
        ((0, 1), "terr_b"), ((1, 1), "terr_b")]


def _cut(level) -> bool:
    engine = TurnEngine(_make_game(), level)
    return balance_supply_cut(level["goals"][0]["config"], engine.state)


def test_cut_island_loses() -> None:
    level = _make_level(CUT)
    assert _cut(level), "(2,0) reaches (0,0) only through B's column"
    result = TurnEngine(_make_game(), level).execute_turn(
        "move", {"direction": "right"})
    assert result.is_lost and result.lose_reason == "balance_unreachable"
    print("  OK  cut_island_loses")


def test_reconnectable_island_is_not_cut() -> None:
    assert not _cut(_make_level(OPEN)), "(1,0) is unclaimed, the line can mend"
    print("  OK  reconnectable_island_is_not_cut")


def test_closed_gate_is_not_a_cut() -> None:
    level = _make_level(OPEN, ground=[((1, 0), "gate")])
    assert not _cut(level), "a gate is claimable land even while it blocks"
    print("  OK  closed_gate_is_not_a_cut")


def test_source_taken_loses() -> None:
    level = _make_level([((0, 0), "terr_b"), ((2, 0), "terr_a"),
                         ((0, 1), "terr_b")])
    assert _cut(level), "A's source belongs to B, so A's land is cut off"
    print("  OK  source_taken_loses")


def test_no_require_connected_never_fires() -> None:
    assert not _cut(_make_level(CUT, connected=False))
    print("  OK  no_require_connected_never_fires")


def test_missing_source_never_fires() -> None:
    assert not _cut(_make_level(CUT, sources={"terr_b": [0, 1]}))
    print("  OK  missing_source_never_fires")


def run_all() -> bool:
    tests = [
        test_cut_island_loses,
        test_reconnectable_island_is_not_cut,
        test_closed_gate_is_not_a_cut,
        test_source_taken_loses,
        test_no_require_connected_never_fires,
        test_missing_source_never_fires,
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
