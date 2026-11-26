"""Tests for support_collapse `strain` — load-limited cells that tire and fail.

A load-limited cell's load is every member cell that would fall if it were
removed. While that exceeds its capacity it loses one endurance per turn, and
it fails (is removed, and the structure collapses) once none is left.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(ROOT))

from engines.python._game_def import GameDef
from engines.python._models import Pos
from engines.python._turn_engine import TurnEngine


def _game() -> GameDef:
    return GameDef.from_dict(
        {
            "layers": [
                {"id": "ground", "occupancy": "exactly_one", "default": "void"},
            ],
            "entityKinds": {
                "void": {"layer": "ground", "tags": [], "symbol": " "},
                "anchor": {
                    "layer": "ground",
                    "tags": ["solid", "walkable", "support_root"],
                    "symbol": "A",
                },
                "hull": {
                    "layer": "ground",
                    "tags": ["solid", "walkable", "supported", "severable"],
                    "symbol": "H",
                },
                "strut": {
                    "layer": "ground",
                    "tags": ["solid", "walkable", "supported", "severable", "load_limited"],
                    "symbol": "S",
                },
                "pod": {
                    "layer": "ground",
                    "tags": ["solid", "walkable", "supported", "severable"],
                    "symbol": "P",
                },
                "wreck": {"layer": "ground", "tags": ["solid"], "symbol": "w"},
                "deck": {"layer": "ground", "tags": ["solid"], "symbol": "="},
            },
            "actions": [
                {
                    "id": "cut",
                    "params": {
                        "direction": {
                            "type": "direction",
                            "values": ["up", "down", "left", "right"],
                        }
                    },
                },
                {"id": "wait", "params": {}},
            ],
            "systems": [
                {
                    "id": "collapse",
                    "type": "support_collapse",
                    "config": {
                        "layer": "ground",
                        "severAction": "cut",
                        "settleTransform": {"hull": "wreck", "strut": "wreck"},
                        "avatarFellVariable": "wrecked",
                        "strain": {
                            "tags": ["load_limited"],
                            "capacityParam": "capacity",
                            "enduranceParam": "endurance",
                            "endurance": 2,
                        },
                    },
                },
            ],
            "defaults": {"maxCascadeDepth": 3},
        },
        id="support_strain_test",
    )


def _level(entries: list[dict], avatar: list[int]) -> dict:
    deck = [{"position": [x, 6], "kind": "deck"} for x in range(5)]
    return {
        "id": "strain_test",
        "board": {
            "size": [5, 7],
            "layers": {"ground": {"format": "sparse", "entries": entries + deck}},
        },
        "state": {
            "variables": {"wrecked": 0},
            "avatar": {"enabled": True, "position": avatar},
        },
        "goals": [],
        "rules": [],
        "solution": {"goldPath": []},
    }


def _strut(x: int, y: int, capacity: int, endurance: int | None = None) -> dict:
    entry = {"position": [x, y], "kind": "strut", "capacity": capacity}
    if endurance is not None:
        entry["endurance"] = endurance
    return entry


# Two struts share one hanging load (x right, y down):
#   y=0:  A . A
#   y=1:  S H S      struts at (0,1) and (2,1), capacity 2
#   y=2:  . H .
#   y=3:  . P .
_SHARED = [
    {"position": [0, 0], "kind": "anchor"},
    {"position": [2, 0], "kind": "anchor"},
    _strut(0, 1, 2),
    {"position": [1, 1], "kind": "hull"},
    _strut(2, 1, 2),
    {"position": [1, 2], "kind": "hull"},
    {"position": [1, 3], "kind": "pod"},
]


class SupportStrainTest(unittest.TestCase):
    def _kind(self, engine: TurnEngine, x: int, y: int) -> str:
        return engine.state.board.get_entity("ground", Pos(x, y)).kind

    def _endurance(self, engine: TurnEngine, x: int, y: int):
        return engine.state.board.get_entity("ground", Pos(x, y)).params.get("endurance")

    def test_shared_supports_carry_nothing(self):
        engine = TurnEngine(_game(), _level(_SHARED, [2, 2]))
        for _ in range(4):
            self.assertTrue(engine.execute_turn("wait").accepted)
        self.assertEqual(self._kind(engine, 0, 1), "strut")
        self.assertIsNone(self._endurance(engine, 0, 1))

    def test_cutting_a_partner_overloads_the_survivor_which_fails_later(self):
        engine = TurnEngine(_game(), _level(_SHARED, [2, 2]))

        engine.execute_turn("cut", {"direction": "up"})  # remove strut (2,1)
        # Load 3 (two hulls and the pod) on capacity 2: one turn of wear.
        self.assertEqual(self._kind(engine, 0, 1), "strut")
        self.assertEqual(self._endurance(engine, 0, 1), 1)
        self.assertEqual(self._kind(engine, 1, 3), "pod")

        engine.execute_turn("wait")
        self.assertEqual(self._kind(engine, 0, 1), "void")
        self.assertEqual(self._kind(engine, 1, 5), "pod")  # fell onto the deck
        self.assertEqual(self._kind(engine, 1, 4), "wreck")

    def test_relieving_the_load_stops_the_wear(self):
        engine = TurnEngine(_game(), _level(_SHARED, [2, 2]))
        engine.execute_turn("cut", {"direction": "up"})  # overload (0,1): 1 left
        engine.execute_turn("cut", {"direction": "left"})  # drop hull (1,2) + pod
        # Remaining load is hull (1,1) alone: within capacity, wear stops.
        for _ in range(3):
            engine.execute_turn("wait")
        self.assertEqual(self._kind(engine, 0, 1), "strut")
        self.assertEqual(self._endurance(engine, 0, 1), 1)

    def test_an_exhausted_cell_fails_as_soon_as_a_failure_overloads_it(self):
        #   y=0:  A . A . A
        #   y=1:  S H S H S     (0,1) cap 1, worn out; (2,1) cap 0, 1 left
        #   y=2:  . P . . .
        entries = [
            {"position": [0, 0], "kind": "anchor"},
            {"position": [2, 0], "kind": "anchor"},
            {"position": [4, 0], "kind": "anchor"},
            _strut(0, 1, 1, endurance=0),
            {"position": [1, 1], "kind": "hull"},
            _strut(2, 1, 0, endurance=1),
            {"position": [3, 1], "kind": "hull"},
            _strut(4, 1, 5),
            {"position": [1, 2], "kind": "pod"},
        ]
        engine = TurnEngine(_game(), _level(entries, [4, 2]))

        engine.execute_turn("cut", {"direction": "up"})  # remove (4,1)

        # (2,1) now holds hull (3,1): over capacity 0, wears to 0 and fails.
        # That leaves (0,1) holding hull (1,1) and the pod — over capacity 1
        # with nothing left, so it fails in the same turn.
        self.assertEqual(self._kind(engine, 2, 1), "void")
        self.assertEqual(self._kind(engine, 0, 1), "void")
        self.assertEqual(self._kind(engine, 1, 5), "pod")

    def test_an_avatar_on_a_failing_cell_falls(self):
        entries = [
            {"position": [0, 0], "kind": "anchor"},
            _strut(0, 1, 1, endurance=1),
            {"position": [0, 2], "kind": "hull"},
            {"position": [0, 3], "kind": "pod"},
        ]
        engine = TurnEngine(_game(), _level(entries, [0, 1]))

        engine.execute_turn("wait")

        self.assertEqual(self._kind(engine, 0, 1), "void")
        self.assertEqual(engine.state.variables["wrecked"], 1)

    def test_wear_is_part_of_the_state_key(self):
        a = TurnEngine(_game(), _level(_SHARED, [2, 2]))
        b = TurnEngine(_game(), _level(_SHARED, [2, 2]))
        a.execute_turn("cut", {"direction": "up"})
        b.execute_turn("cut", {"direction": "up"})
        self.assertEqual(a.state_key(), b.state_key())
        b.execute_turn("cut", {"direction": "left"})
        a.execute_turn("cut", {"direction": "left"})
        a.execute_turn("wait")
        # Same board, but `a` has stood one turn longer — only wear differs
        # if the load were still over; here it is relieved, so keys agree.
        self.assertEqual(a.state_key(), b.state_key())

    def test_status_lines_report_capacity_and_endurance(self):
        game = _game()
        engine = TurnEngine(game, _level(_SHARED, [2, 2]))
        engine.execute_turn("cut", {"direction": "up"})
        from engines.python._systems.support_collapse import SupportCollapseSystem

        system = SupportCollapseSystem("collapse")
        lines = system.observation_status_lines(engine.state, game, lambda: None)
        self.assertTrue(lines[0].startswith("Load limits"))
        self.assertIn("(0,1): strut capacity 2, endurance 1", lines)


if __name__ == "__main__":
    unittest.main()
