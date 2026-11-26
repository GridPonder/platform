"""Tests for support_collapse `fuse` — cells that burn away on a delay.

Severing a fuse cell lights it instead of removing it. A lit cell counts down
its delay, then burns away (and the structure collapses), lighting the fuse
cells touching it, which burn one turn later.
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


def _kind(tags: list[str], symbol: str) -> dict:
    return {"layer": "ground", "tags": tags, "symbol": symbol}


def _game() -> GameDef:
    member = ["solid", "walkable", "supported"]
    return GameDef.from_dict(
        {
            "layers": [
                {"id": "ground", "occupancy": "exactly_one", "default": "void"},
            ],
            "entityKinds": {
                "void": _kind([], " "),
                "anchor": _kind(["solid", "walkable", "support_root"], "A"),
                "hull": _kind(member + ["severable"], "H"),
                "strut": _kind(member + ["load_limited"], "S"),
                "fuse": _kind(member + ["severable"], "F"),
                "fuse_lit": _kind(member, "f"),
                "pod": _kind(member + ["severable"], "P"),
                "wreck": _kind(["solid"], "w"),
                "deck": _kind(["solid"], "="),
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
                        "settleTransform": {
                            "hull": "wreck",
                            "strut": "wreck",
                            "fuse": "wreck",
                            "fuse_lit": "wreck",
                        },
                        "avatarFellVariable": "wrecked",
                        "fuse": {"ignite": {"fuse": "fuse_lit"}},
                        "strain": {"tags": ["load_limited"], "endurance": 2},
                    },
                },
            ],
            "defaults": {"maxCascadeDepth": 3},
        },
        id="support_fuse_test",
    )


def _level(entries: list[dict], avatar: list[int]) -> dict:
    deck = [{"position": [x, 6], "kind": "deck"} for x in range(5)]
    return {
        "id": "fuse_test",
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


def _at(x: int, y: int, kind: str, **params) -> dict:
    return {"position": [x, y], "kind": kind, **params}


# A pod hanging from a one-cell fuse under a clamp:
#   y=0:  A A
#   y=1:  . F
#   y=2:  . P
_HANGING = [_at(0, 0, "anchor"), _at(1, 0, "anchor"), _at(1, 1, "fuse"), _at(1, 2, "pod")]

# A fuse run of three, held at both ends, so nothing falls while it burns:
#   y=0:  A . . . A
#   y=1:  F F F H H
_RUN = [
    _at(0, 0, "anchor"),
    _at(4, 0, "anchor"),
    _at(0, 1, "fuse"),
    _at(1, 1, "fuse"),
    _at(2, 1, "fuse"),
    _at(3, 1, "hull"),
    _at(4, 1, "hull"),
]


class SupportFuseTest(unittest.TestCase):
    def _kind(self, engine: TurnEngine, x: int, y: int) -> str:
        return engine.state.board.get_entity("ground", Pos(x, y)).kind

    def test_cutting_a_fuse_lights_it_instead_of_removing_it(self):
        engine = TurnEngine(_game(), _level(_HANGING, [1, 0]))
        engine.execute_turn("cut", {"direction": "down"})
        self.assertEqual(self._kind(engine, 1, 1), "fuse_lit")
        self.assertEqual(self._kind(engine, 1, 2), "pod")

        engine.execute_turn("wait")  # burns at the end of the next turn
        self.assertEqual(self._kind(engine, 1, 1), "void")
        self.assertEqual(self._kind(engine, 1, 5), "pod")
        self.assertEqual(engine.state.variables["wrecked"], 0)

    def test_a_run_burns_one_cell_per_turn(self):
        engine = TurnEngine(_game(), _level(_RUN, [0, 0]))
        engine.execute_turn("cut", {"direction": "down"})
        expected = [
            ["fuse_lit", "fuse", "fuse"],  # after the cut
            ["void", "fuse_lit", "fuse"],
            ["void", "void", "fuse_lit"],
            ["void", "void", "void"],
        ]
        self.assertEqual([self._kind(engine, x, 1) for x in range(3)], expected[0])
        for row in expected[1:]:
            engine.execute_turn("wait")
            self.assertEqual([self._kind(engine, x, 1) for x in range(3)], row)
        self.assertEqual(self._kind(engine, 3, 1), "hull")  # still held at (4,0)

    def test_a_fork_burns_both_branches_together(self):
        #   y=0:  A . A . A
        #   y=1:  H F F F H     light the middle, both ends burn on one turn
        entries = [
            _at(0, 0, "anchor"),
            _at(2, 0, "anchor"),
            _at(4, 0, "anchor"),
            _at(0, 1, "hull"),
            _at(1, 1, "fuse"),
            _at(2, 1, "fuse"),
            _at(3, 1, "fuse"),
            _at(4, 1, "hull"),
        ]
        engine = TurnEngine(_game(), _level(entries, [2, 0]))
        engine.execute_turn("cut", {"direction": "down"})
        engine.execute_turn("wait")
        self.assertEqual(
            [self._kind(engine, x, 1) for x in range(5)],
            ["hull", "fuse_lit", "void", "fuse_lit", "hull"],
        )
        engine.execute_turn("wait")
        self.assertEqual(
            [self._kind(engine, x, 1) for x in range(5)],
            ["hull", "void", "void", "void", "hull"],
        )

    def test_an_avatar_on_a_burning_cell_falls(self):
        engine = TurnEngine(_game(), _level(_RUN, [1, 1]))  # standing on fuse
        engine.execute_turn("cut", {"direction": "left"})
        engine.execute_turn("wait")  # (0,1) burns and lights the avatar's cell
        self.assertEqual(engine.state.variables["wrecked"], 0)
        engine.execute_turn("wait")
        self.assertEqual(engine.state.variables["wrecked"], 1)

    def test_a_falling_lit_cell_stops_burning(self):
        #   y=0:  A A
        #   y=1:  . F     the clamp-side cell is lit, the cell below hangs off it
        #   y=2:  . F
        entries = [_at(0, 0, "anchor"), _at(1, 0, "anchor"), _at(1, 1, "fuse"), _at(1, 2, "fuse")]
        engine = TurnEngine(_game(), _level(entries, [1, 0]))
        engine.execute_turn("cut", {"direction": "down"})
        engine.execute_turn("wait")
        # (1,1) burned and lit (1,2), which fell as one piece and settled.
        self.assertEqual(self._kind(engine, 1, 5), "wreck")
        engine.execute_turn("wait")
        self.assertEqual(self._kind(engine, 1, 5), "wreck")

    def test_a_burn_hands_the_load_to_a_strut(self):
        #   y=0:  A . A
        #   y=1:  F H S      fuse and strut share the span; strut capacity 1
        #   y=2:  . H .
        entries = [
            _at(0, 0, "anchor"),
            _at(2, 0, "anchor"),
            _at(0, 1, "fuse"),
            _at(1, 1, "hull"),
            _at(2, 1, "strut", capacity=1),
            _at(1, 2, "hull"),
        ]
        engine = TurnEngine(_game(), _level(entries, [0, 0]))
        engine.execute_turn("cut", {"direction": "down"})
        engine.execute_turn("wait")  # fuse burns: the strut carries 2 now
        strut = engine.state.board.get_entity("ground", Pos(2, 1))
        self.assertEqual(strut.params.get("endurance"), 1)
        engine.execute_turn("wait")
        self.assertEqual(self._kind(engine, 2, 1), "void")
        self.assertEqual(self._kind(engine, 1, 5), "wreck")

    def test_status_lines_report_burning_cells(self):
        game = _game()
        engine = TurnEngine(game, _level(_RUN, [0, 0]))
        engine.execute_turn("cut", {"direction": "down"})
        from engines.python._systems.support_collapse import SupportCollapseSystem

        system = SupportCollapseSystem("collapse")
        lines = system.observation_status_lines(engine.state, game, lambda: None)
        self.assertTrue(lines[0].startswith("Burning fuses"))
        self.assertIn("(0,1): fuse lit burns away in 1 turn", lines)


if __name__ == "__main__":
    unittest.main()
