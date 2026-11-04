"""Parity scenarios for proximity effects, fragile terrain, and terminal goals."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from engines.python._game_def import GameDef
from engines.python._models import Pos
from engines.python._turn_engine import TurnEngine


def game() -> GameDef:
    return GameDef.from_dict({
        "layers": [
            {"id": "ground", "occupancy": "exactly_one", "default": "floor"},
            {"id": "objects", "occupancy": "zero_or_one"},
            {"id": "markers", "occupancy": "zero_or_one"},
        ],
        "entityKinds": {
            "floor": {"layer": "ground", "tags": ["walkable"], "symbol": "."},
            "fragile": {"layer": "ground", "tags": ["walkable", "fragile"], "symbol": "F"},
            "void": {"layer": "ground", "tags": ["solid"], "symbol": "#"},
            "witness": {"layer": "objects", "tags": ["solid", "witness"], "symbol": "W"},
            "bomb": {"layer": "objects", "tags": ["solid", "bomb"], "symbol": "B"},
            "hazard": {"layer": "objects", "tags": ["solid", "hazard"], "symbol": "H"},
            "exit": {"layer": "markers", "tags": ["exit"], "symbol": "E"},
        },
        "actions": [{"id": "move", "params": {"direction": {
            "type": "direction", "values": ["up", "down", "left", "right"]
        }}}],
        "systems": [
            {"id": "nav", "type": "avatar_navigation", "config": {}},
            {"id": "near", "type": "proximity_effects", "config": {
                "layer": "objects",
                "reactions": [
                    {"tag": "witness", "effect": "cycle", "param": "count", "modulus": 3},
                    {"tag": "bomb", "effect": "threshold", "param": "count",
                     "thresholdParam": "threshold", "triggerVariable": "dead"},
                    {"tag": "hazard", "effect": "damage", "variable": "hp",
                     "amount": 1, "triggerVariable": "dead"},
                ],
            }},
        ],
        "rules": [{
            "id": "collapse_on_exit", "on": "avatar_exited",
            "where": {"position_has_tag": {"layer": "ground", "tag": "fragile"}},
            "then": [{"transform": {"position": "$event.position", "layer": "ground",
                                    "fromKind": "fragile", "toKind": "void"}}],
        }],
        "defaults": {"maxCascadeDepth": 3},
    }, id="proximity_test")


def level(*, hp=3, threshold=3, terminal=False) -> dict:
    return {
        "id": "near_test",
        "board": {"size": [4, 3], "layers": {
            "ground": {"format": "sparse", "entries": [
                {"position": [1, 1], "kind": "fragile"}]},
            "objects": {"format": "sparse", "entries": [
                {"position": [2, 1], "kind": "witness", "count": 0},
                {"position": [1, 0], "kind": "bomb", "count": 0,
                 "threshold": threshold},
                {"position": [1, 2], "kind": "hazard"},
            ]},
            "markers": {"format": "sparse", "entries": [
                {"position": [1, 1], "kind": "exit"}]},
        }},
        "state": {"avatar": {"enabled": True, "position": [0, 1]},
                  "variables": {"hp": hp, "dead": 0, "phase": 0}},
        "goals": ([
            {"id": "exit", "type": "reach_target", "config": {"targetKind": "exit"}},
            {"id": "witness", "type": "param_match", "config": {
                "markerLayer": "objects", "markerKind": "witness",
                "checkLayer": "objects", "checkKind": "witness",
                "checkParam": "count", "checkValue": 1}},
            {"id": "alive", "type": "variable_threshold", "config": {
                "variable": "dead", "comparison": "eq", "target": 0}},
        ] if terminal else []),
        "loseConditions": [{"type": "variable_threshold", "config": {
            "variable": "dead", "comparison": "gte", "target": 1}}],
    }


class ProximityEffectsTest(unittest.TestCase):
    def test_arrival_cycles_a_variable_and_blocked_move_does_not(self):
        game_def = game()
        game_def.rules.append({
            "id": "advance_phase", "on": "avatar_entered",
            "then": [{"cycle_variable": {"name": "phase", "modulus": 3}}],
        })
        layout = level(hp=8, threshold=99)
        layout["board"]["layers"]["ground"]["entries"] = []
        engine = TurnEngine(game_def, layout)
        for direction, expected in (
            ("right", 1), ("left", 2), ("right", 0),
        ):
            engine.execute_turn("move", {"direction": direction})
            self.assertEqual(engine.state.variables["phase"], expected)
        engine.undo()
        self.assertEqual(engine.state.variables["phase"], 2)
        engine.execute_turn("move", {"direction": "left"})
        self.assertEqual(engine.state.variables["phase"], 2)

    def test_one_arrival_triggers_all_neighbors_then_fragile_blocks_return(self):
        engine = TurnEngine(game(), level())
        self.assertEqual(engine.state.board.get_entity("objects", Pos(2, 1)).params["count"], 0)
        result = engine.execute_turn("move", {"direction": "right"})
        self.assertEqual(len([e for e in result.events if e["type"] == "proximity_triggered"]), 3)
        damage = next(e for e in result.events if e.get("effect") == "damage")
        self.assertEqual(damage["avatarPosition"], Pos(1, 1))
        self.assertEqual(damage["delta"], -1)
        self.assertEqual(engine.state.board.get_entity("objects", Pos(2, 1)).params["count"], 1)
        self.assertEqual(engine.state.board.get_entity("objects", Pos(1, 0)).params["count"], 1)
        self.assertEqual(engine.state.variables["hp"], 2)
        engine.execute_turn("move", {"direction": "left"})
        self.assertEqual(engine.state.board.get_entity("ground", Pos(1, 1)).kind, "void")
        engine.execute_turn("move", {"direction": "right"})
        self.assertEqual(engine.state.avatar.position, Pos(0, 1))
        self.assertEqual(engine.state.board.get_entity("objects", Pos(2, 1)).params["count"], 1)

    def test_death_on_exit_cannot_win(self):
        for hp, threshold in ((1, 3), (3, 1)):
            with self.subTest(hp=hp, threshold=threshold):
                engine = TurnEngine(game(), level(hp=hp, threshold=threshold, terminal=True))
                result = engine.execute_turn("move", {"direction": "right"})
                self.assertTrue(result.is_lost)
                self.assertFalse(result.is_won)
                self.assertEqual(engine.state.variables["dead"], 1)

    def test_witness_wraps_after_three_arrivals(self):
        layout = level(hp=9, threshold=9)
        layout["board"]["layers"]["ground"]["entries"] = []
        engine = TurnEngine(game(), layout)
        for direction in ("right", "left", "right", "left", "right"):
            engine.execute_turn("move", {"direction": direction})
        self.assertEqual(engine.state.board.get_entity("objects", Pos(2, 1)).params["count"], 0)

    def test_safe_arrival_wins_and_undo_restores_counters(self):
        engine = TurnEngine(game(), level(terminal=True))
        result = engine.execute_turn("move", {"direction": "right"})
        self.assertTrue(result.is_won)
        engine.undo()
        self.assertEqual(engine.state.board.get_entity("objects", Pos(2, 1)).params["count"], 0)
        self.assertEqual(engine.state.variables["hp"], 3)


if __name__ == "__main__":
    unittest.main()
