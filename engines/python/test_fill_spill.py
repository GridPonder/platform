"""
Tests for the `fill_spill` system.

Run from the repo root:  python3 engines/python/test_fill_spill.py
Mirrored by engines/dart/test/fill_spill_system_test.dart.
"""
from __future__ import annotations
import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(ROOT))

from engines.python._game_def import GameDef
from engines.python._turn_engine import TurnEngine

CONFIG = {
    "heights": {f"h{n}": n for n in range(6)},
    "waterKinds": ["water_1", "water_2", "water_3"],
    "barriers": {"layer": "objects", "kinds": ["gate_shut"]},
    "gates": [{"layer": "objects", "closed": "gate_shut", "open": "gate_open"}],
    "markers": {"layer": "objects", "pairs": [{"dry": "basin", "wet": "basin_full"}]},
    "flood": {"variable": "flooded", "layer": "objects", "kinds": ["basin_full"], "avatar": True},
}


def _make_game(config: dict | None = None) -> GameDef:
    kinds = {"bank": {"layer": "ground", "tags": ["solid"], "symbol": "#"}}
    for n in range(6):
        kinds[f"h{n}"] = {"layer": "ground", "tags": ["walkable"], "symbol": str(n)}
    for n in range(1, 4):
        kinds[f"water_{n}"] = {"layer": "water", "tags": ["solid"], "symbol": f"w{n}"}
    kinds["gate_shut"] = {"layer": "objects", "tags": ["solid"], "symbol": "|"}
    kinds["gate_open"] = {"layer": "objects", "tags": ["solid"], "symbol": "="}
    kinds["seep"] = {"layer": "objects", "tags": ["solid"], "symbol": "~"}
    kinds["basin"] = {"layer": "objects", "tags": [], "symbol": "f"}
    kinds["basin_full"] = {"layer": "objects", "tags": [], "symbol": "F"}
    data = {
        "id": "com.gridponder.test_fill_spill",
        "layers": [
            {"id": "ground", "occupancy": "exactly_one", "default": "bank"},
            {"id": "water", "occupancy": "zero_or_one"},
            {"id": "objects", "occupancy": "zero_or_one"},
        ],
        "entityKinds": kinds,
        "actions": [{"id": "move", "params": {"direction": {
            "type": "direction", "values": ["up", "down", "left", "right"]}}}],
        "systems": [
            {"id": "water", "type": "fill_spill",
             "config": CONFIG if config is None else config},
            {"id": "walk", "type": "avatar_navigation",
             "config": {"solidHandling": "block", "groundLayer": "ground",
                        "validGroundTags": ["walkable"],
                        "solidLayers": ["objects", "water"]}},
        ],
    }
    return GameDef.from_dict(data, id="test_fill_spill")


def _level(rows: list[str], water: list, objects: list | None = None,
           avatar: list | None = None) -> dict:
    """rows: '#' bank, digit n ground height n."""
    ground = [["bank" if ch == "#" else f"h{ch}" for ch in row] for row in rows]
    return {
        "id": "t",
        "board": {"size": [len(rows[0]), len(rows)], "layers": {
            "ground": ground,
            "water": {"format": "sparse", "entries": [
                {"position": [x, y], "kind": "water_1", "units": u} for x, y, u in water]},
            "objects": {"format": "sparse", "entries": [
                {"position": [x, y], "kind": k} for x, y, k in (objects or [])]},
        }},
        "state": {"avatar": {"enabled": avatar is not None,
                             "position": avatar or [0, 0]},
                  "variables": {"flooded": 0}},
        "goals": [],
    }


def _water(engine: TurnEngine) -> dict:
    return {(p.x, p.y): (e.kind, e.params.get("units"))
            for p, e in engine.state.board.layers["water"].entries()}


def test_water_stops_at_the_lip_and_spills_the_rest():
    # Two hollows split by a ridge of 2: the first holds 4 below the ridge, the
    # fifth unit pours over into the second hollow.
    eng = TurnEngine(_make_game(), _level(["#######", "#00200#", "#######"], [(1, 1, 5)]))
    w = _water(eng)
    assert set(w) == {(1, 1), (2, 1), (4, 1), (5, 1)}
    assert w[(1, 1)] == ("water_2", 4)      # level 2, depth 2, lowest cell holds the count
    assert w[(2, 1)] == ("water_2", None)
    assert w[(4, 1)] == ("water_1", 1)      # level 1/2
    assert (3, 1) not in w                  # the ridge is exactly at the brim: dry


def test_pools_over_a_ridge_become_one():
    eng = TurnEngine(_make_game(), _level(["#######", "#00200#", "#######"], [(1, 1, 9)]))
    w = _water(eng)
    assert set(w) == {(1, 1), (2, 1), (3, 1), (4, 1), (5, 1)}
    assert [v for v in w.values() if v[1]] == [("water_3", 9)]   # level 11/5 over ground 0
    assert w[(3, 1)] == ("water_1", None)   # level 11/5 over ground 2


def test_open_gate_passes_only_water_above_the_sill():
    rows = ["#########", "#0001000#", "####3####", "#########"]
    eng = TurnEngine(_make_game(), _level(rows, [(1, 1, 6)],
                                          [(4, 1, "gate_shut")], [4, 2]))
    eng.execute_turn("move", {"direction": "up"})     # lift the board
    w = _water(eng)
    assert w[(1, 1)] == ("water_1", 3)      # upstream keeps everything below the sill
    assert w[(5, 1)] == ("water_1", 3)      # 3 units over 3 cells downstream
    assert (4, 1) not in w                  # the sill is exactly at the brim
    eng.execute_turn("move", {"direction": "up"})     # dry sill: the board drops
    assert eng.state.board.get_entity("objects", _pos(4, 1)).kind == "gate_shut"


def test_board_cannot_drop_against_standing_water():
    rows = ["#########", "#0000000#", "####3####", "#########"]
    eng = TurnEngine(_make_game(), _level(rows, [(1, 1, 6)],
                                          [(4, 1, "gate_shut")], [4, 2]))
    eng.execute_turn("move", {"direction": "up"})
    assert (4, 1) in _water(eng)
    eng.execute_turn("move", {"direction": "up"})
    assert eng.state.board.get_entity("objects", _pos(4, 1)).kind == "gate_open"


def test_water_reaching_the_avatar_floods_it():
    rows = ["#######", "#00000#", "#######"]
    eng = TurnEngine(_make_game(), _level(rows, [(1, 1, 4)],
                                          [(3, 1, "gate_shut")], [4, 1]))
    eng.execute_turn("move", {"direction": "left"})   # opened from the low side
    assert eng.state.variables["flooded"] == 1


def test_markers_follow_the_water_and_count_as_flooded():
    rows = ["#######", "#00000#", "###4###", "#######"]
    eng = TurnEngine(_make_game(), _level(rows, [(1, 1, 4)],
                                          [(3, 1, "gate_shut"), (5, 1, "basin")], [3, 2]))
    assert eng.state.board.get_entity("objects", _pos(5, 1)).kind == "basin"
    eng.execute_turn("move", {"direction": "up"})
    assert eng.state.board.get_entity("objects", _pos(5, 1)).kind == "basin_full"
    assert eng.state.variables["flooded"] == 1


def test_volume_is_conserved_across_every_turn():
    rows = ["#########", "#0012100#", "#####4###", "#########"]
    eng = TurnEngine(_make_game(), _level(rows, [(1, 1, 7)],
                                          [(5, 1, "gate_shut")], [5, 2]))
    assert sum(v[1] or 0 for v in _water(eng).values()) == 7
    eng.execute_turn("move", {"direction": "up"})
    assert sum(v[1] or 0 for v in _water(eng).values()) == 7


def test_missing_heights_make_the_system_inert():
    eng = TurnEngine(_make_game({"waterKinds": ["water_1"]}),
                     _level(["#####", "#000#", "#####"], [(1, 1, 3)]))
    assert _water(eng) == {(1, 1): ("water_1", 3)}


SEEP_CONFIG = {**CONFIG, "seeps": {"layer": "objects", "kinds": ["seep"], "rate": 1}}
SEEP_ROWS = ["######", "#0000#", "###4##", "######"]


def test_a_seep_holds_at_load_and_leaks_one_unit_per_turn():
    eng = TurnEngine(_make_game(SEEP_CONFIG),
                     _level(SEEP_ROWS, [(1, 1, 3)], [(2, 1, "seep")], [3, 2]))
    assert _water(eng) == {(1, 1): ("water_3", 3)}
    eng.execute_turn("move", {"direction": "down"})  # bump the bank: a turn passes
    assert _water(eng) == {(1, 1): ("water_2", 2), (3, 1): ("water_1", 1),
                           (4, 1): ("water_1", None)}
    eng.execute_turn("move", {"direction": "down"})
    eng.execute_turn("move", {"direction": "down"})
    # Level 1 on both sides after the second turn: the third moves nothing.
    assert _water(eng) == {(1, 1): ("water_1", 1), (3, 1): ("water_1", 2),
                           (4, 1): ("water_1", None)}


def test_a_seep_passes_only_water_above_its_sill():
    rows = ["######", "#0200#", "###4##", "######"]
    eng = TurnEngine(_make_game(SEEP_CONFIG),
                     _level(rows, [(1, 1, 3)], [(2, 1, "seep")], [3, 2]))
    for _ in range(3):
        eng.execute_turn("move", {"direction": "down"})
    assert _water(eng) == {(1, 1): ("water_2", 2), (3, 1): ("water_1", 1),
                           (4, 1): ("water_1", None)}


def test_without_seeps_config_a_seep_kind_is_plain_ground():
    eng = TurnEngine(_make_game(),
                     _level(SEEP_ROWS, [(1, 1, 3)], [(2, 1, "seep")], [3, 2]))
    assert (2, 1) in _water(eng)


def _pos(x, y):
    from engines.python._models import Pos
    return Pos(x, y)


if __name__ == "__main__":
    tests = [v for k, v in dict(globals()).items() if k.startswith("test_")]
    for t in tests:
        t()
        print(f"PASS {t.__name__}")
    print(f"\n{len(tests)} passed")
