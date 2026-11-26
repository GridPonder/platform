"""Tests for support_collapse `switches` — load-operated cells.

A plate is pressed while a solid piece rests in its cell. While any plate of a
channel is pressed, every switched cell of that channel takes its pressed kind
(here a left chute becomes a right chute). Plates update after every removal and
after each falling piece lands, before the next piece moves.
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


def _kind(layer: str, tags: list[str], symbol: str) -> dict:
    return {"layer": layer, "tags": tags, "symbol": symbol}


def _game() -> GameDef:
    member = ["solid", "walkable", "supported"]
    return GameDef.from_dict(
        {
            "layers": [
                {"id": "marks", "occupancy": "zero_or_one"},
                {"id": "ground", "occupancy": "exactly_one", "default": "void"},
            ],
            "entityKinds": {
                "void": _kind("ground", [], " "),
                "anchor": _kind("ground", ["solid", "walkable", "support_root"], "A"),
                "hull": _kind("ground", member + ["severable"], "H"),
                "wreck": _kind("ground", ["solid"], "w"),
                "deck": _kind("ground", ["solid"], "="),
                "chute_l": _kind("ground", ["solid", "slope_left"], "<"),
                "chute_r": _kind("ground", ["solid", "slope_right"], ">"),
                "plate": _kind("marks", ["plate"], "_"),
                "clamp": _kind("ground", ["solid", "support_root"], "K"),
                "clamp_open": _kind("ground", ["solid"], "k"),
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
                        "settleTransform": {"hull": "wreck"},
                        "avatarFellVariable": "fell",
                        "deflect": {"slope_left": "left", "slope_right": "right"},
                        "switches": {
                            "plateLayer": "marks",
                            "pressed": {"chute_l": "chute_r", "clamp": "clamp_open"},
                        },
                    },
                },
            ],
            "defaults": {"maxCascadeDepth": 3},
        },
        id="support_switch_test",
    )


def _at(x: int, y: int, kind: str, **params) -> dict:
    return {"position": [x, y], "kind": kind, **params}


def _level(ground: list[dict], marks: list[dict], avatar: list[int]) -> dict:
    deck = [_at(x, 6, "deck") for x in range(7)]
    return {
        "id": "switch_test",
        "board": {
            "size": [7, 7],
            "layers": {
                "ground": {"format": "sparse", "entries": ground + deck},
                "marks": {"format": "sparse", "entries": marks},
            },
        },
        "state": {"variables": {}, "avatar": {"enabled": True, "position": avatar}},
        "goals": [],
        "rules": [],
        "solution": {"goldPath": []},
    }


# One cut at (2,1) frees two pieces: a low column over the plate at (1,5) and a
# single high cell over the chute at (3,5).
#   y=0:  . . A . . . .
#   y=1:  . H H H . . .
#   y=2:  . H . . . . .
#   y=3:  . H . . . . .
#   y=5:  . _ . < . . .     (plate at x=1 on the marks layer)
_FORK = [
    _at(2, 0, "anchor"),
    _at(1, 1, "hull"),
    _at(2, 1, "hull"),
    _at(3, 1, "hull"),
    _at(1, 2, "hull"),
    _at(1, 3, "hull"),
    _at(3, 5, "chute_l", channel=1),
]


class SupportSwitchTest(unittest.TestCase):
    def _kind(self, engine: TurnEngine, x: int, y: int) -> str:
        return engine.state.board.get_entity("ground", Pos(x, y)).kind

    def test_the_lower_piece_presses_the_plate_before_the_higher_one_moves(self):
        engine = TurnEngine(_game(), _level(_FORK, [_at(1, 5, "plate", channel=1)], [2, 0]))
        engine.execute_turn("cut", {"direction": "down"})
        self.assertEqual(self._kind(engine, 1, 5), "wreck")  # on the plate
        self.assertEqual(self._kind(engine, 3, 5), "chute_r")
        self.assertEqual(self._kind(engine, 4, 5), "wreck")  # deflected right
        self.assertEqual(self._kind(engine, 2, 5), "void")

    def test_without_the_plate_the_chute_keeps_its_way(self):
        engine = TurnEngine(_game(), _level(_FORK, [], [2, 0]))
        engine.execute_turn("cut", {"direction": "down"})
        self.assertEqual(self._kind(engine, 3, 5), "chute_l")
        self.assertEqual(self._kind(engine, 2, 5), "wreck")  # deflected left

    def test_a_plate_on_another_channel_does_nothing(self):
        engine = TurnEngine(_game(), _level(_FORK, [_at(1, 5, "plate", channel=2)], [2, 0]))
        engine.execute_turn("cut", {"direction": "down"})
        self.assertEqual(self._kind(engine, 3, 5), "chute_l")

    def test_removing_the_weight_resets_the_chute(self):
        # The hull at (1,5) hangs from (1,4) and rests on the plate.
        ground = [_at(1, 4, "anchor"), _at(1, 5, "hull"), _at(3, 5, "chute_r", channel=1)]
        engine = TurnEngine(_game(), _level(ground, [_at(1, 5, "plate", channel=1)], [0, 5]))
        engine.execute_turn("cut", {"direction": "right"})
        self.assertEqual(self._kind(engine, 1, 5), "void")
        self.assertEqual(self._kind(engine, 3, 5), "chute_l")

    def test_status_lines_name_plates_and_switched_cells(self):
        engine = TurnEngine(_game(), _level(_FORK, [_at(1, 5, "plate", channel=1)], [2, 0]))
        from engines.python._systems import instantiate_systems
        game = _game()
        system = instantiate_systems(game)[0]
        lines = system.observation_status_lines(engine.state, game, None)
        self.assertIn("(1,5): plate 1, empty", lines)
        self.assertIn("(3,5): chute l, channel 1", lines)


# A clamp is a support root that its channel's plates switch to a non-root kind.
#   y=0:  . A . . . . .
#   y=1:  . H . K . . .     cut (1,1) from the anchor; clamp (3,1) channel 1
#   y=2:  . H . H . . .
#   y=3:  . . . H . . .
#   y=5:  . _ . . . . .     plate channel 1 at (1,5)
_TRIP = [
    _at(1, 0, "anchor"), _at(1, 1, "hull"), _at(1, 2, "hull"),
    _at(3, 1, "clamp", channel=1), _at(3, 2, "hull"), _at(3, 3, "hull"),
]


class TripClampTest(unittest.TestCase):
    def _kind(self, engine: TurnEngine, x: int, y: int) -> str:
        return engine.state.board.get_entity("ground", Pos(x, y)).kind

    def test_a_landing_opens_a_clamp_and_its_load_falls_the_same_turn(self):
        engine = TurnEngine(_game(), _level(_TRIP, [_at(1, 5, "plate", channel=1)], [1, 0]))
        engine.execute_turn("cut", {"direction": "down"})
        self.assertEqual(self._kind(engine, 1, 5), "wreck")
        self.assertEqual(self._kind(engine, 3, 1), "clamp_open")
        self.assertEqual(self._kind(engine, 3, 5), "wreck")
        self.assertEqual(self._kind(engine, 3, 4), "wreck")
        self.assertEqual(self._kind(engine, 3, 2), "void")

    def test_without_the_plate_the_clamp_holds(self):
        engine = TurnEngine(_game(), _level(_TRIP, [], [1, 0]))
        engine.execute_turn("cut", {"direction": "down"})
        self.assertEqual(self._kind(engine, 3, 1), "clamp")
        self.assertEqual(self._kind(engine, 3, 2), "hull")

    def test_clamps_chain_within_one_turn(self):
        # The first clamp's load lands on a channel 2 plate, opening a second clamp.
        ground = _TRIP + [_at(5, 1, "clamp", channel=2), _at(5, 2, "hull")]
        marks = [_at(1, 5, "plate", channel=1), _at(3, 5, "plate", channel=2)]
        engine = TurnEngine(_game(), _level(ground, marks, [1, 0]))
        engine.execute_turn("cut", {"direction": "down"})
        self.assertEqual(self._kind(engine, 5, 1), "clamp_open")
        self.assertEqual(self._kind(engine, 5, 5), "wreck")
        self.assertEqual(self._kind(engine, 5, 2), "void")

    def test_a_released_plate_closes_its_clamp_and_what_hangs_stays(self):
        # Hull standing in the plate keeps the clamp open; the clamp holds nothing
        # alone because its column also hangs from the anchor at (4,2).
        ground = [_at(1, 4, "anchor"), _at(1, 5, "hull"),
                  _at(3, 1, "clamp_open", channel=1), _at(3, 2, "hull"), _at(4, 2, "anchor")]
        engine2 = TurnEngine(_game(), _level(ground, [_at(1, 5, "plate", channel=1)], [1, 4]))
        engine2.execute_turn("cut", {"direction": "down"})
        self.assertEqual(self._kind(engine2, 1, 5), "void")
        self.assertEqual(self._kind(engine2, 3, 1), "clamp")
        self.assertEqual(self._kind(engine2, 3, 2), "hull")

    def test_the_avatar_on_released_structure_rides_it_down_once(self):
        # The avatar stands on (3,2), held by the clamp and by the chain through (2,2).
        # Cutting (2,2) drops (2,3) onto the plate; the clamp opens and (3,2) falls.
        ground = [_at(2, 0, "anchor"), _at(2, 1, "hull"), _at(2, 2, "hull"), _at(2, 3, "hull"),
                  _at(3, 1, "clamp", channel=1), _at(3, 2, "hull")]
        engine = TurnEngine(_game(), _level(ground, [_at(2, 5, "plate", channel=1)], [3, 2]))
        engine.execute_turn("cut", {"direction": "left"})
        self.assertEqual(self._kind(engine, 2, 5), "wreck")
        self.assertEqual(engine.state.variables.get("fell"), 1)
        self.assertEqual(engine.state.avatar.position, Pos(3, 5))

    def test_preview_reports_the_whole_cascade(self):
        engine = TurnEngine(_game(), _level(_TRIP, [_at(1, 5, "plate", channel=1)], [1, 0]))
        before = engine.state.board.get_entity("ground", Pos(3, 2)).kind
        result = engine.preview_turn("cut", {"direction": "down"})
        board = result.new_state.board if hasattr(result, "new_state") else result.board
        self.assertEqual(board.get_entity("ground", Pos(3, 5)).kind, "wreck")
        self.assertEqual(engine.state.board.get_entity("ground", Pos(3, 2)).kind, before)


if __name__ == "__main__":
    unittest.main()
