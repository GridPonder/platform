"""Generic atomic parameter exchange, configured endpoints, and history."""
from copy import deepcopy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from engines.python._effects import execute
from engines.python._game_def import GameDef
from engines.python._models import Entity, Pos
from engines.python._turn_engine import TurnEngine


def fixture():
    data = {
        "layers": [{"id": "objects", "occupancy": "zero_or_one"},
                   {"id": "markers", "occupancy": "zero_or_one"}],
        "entityKinds": {
            "gauge": {"layer": "objects", "symbol": "G", "tags": ["solid"]},
            "control": {"layer": "markers", "symbol": "K", "tags": ["control"]},
            "spent": {"layer": "markers", "symbol": "s"},
        },
        "actions": [{"id": "move", "params": {"direction": {"type": "direction"}}}],
        "systems": [{"id": "nav", "type": "avatar_navigation", "config": {}}],
        "rules": [{"id": "activate", "on": "avatar_entered",
                   "where": {"position_has_tag": {"layer": "markers", "tag": "control"}},
                   "then": [{"exchange_parameters": {
                       "firstPosition": "$cell.markers.param.first",
                       "secondPosition": "$cell.markers.param.second",
                       "firstVariable": "$cell.markers.param.firstVar",
                       "secondVariable": "$cell.markers.param.secondVar"}},
                       {"transform": {"position": "$event.position", "layer": "markers",
                                      "fromKind": "control", "toKind": "spent"}}]}],
    }
    level = {
        "id": "generic", "board": {"size": [5, 3], "layers": {
            "objects": {"format": "sparse", "entries": [
                {"position": [1, 0], "kind": "gauge", "value": 2, "metadata": "keep"},
                {"position": [3, 0], "kind": "gauge", "value": 7},
                {"position": [4, 0], "kind": "gauge", "value": 99}]},
            "markers": {"format": "sparse", "entries": [
                {"position": [1, 1], "kind": "control", "first": [1, 0], "second": [3, 0],
                 "firstVar": "left", "secondVar": "right"},
                {"position": [3, 1], "kind": "control", "first": [3, 0], "second": [4, 0],
                 "firstVar": "right", "secondVar": "other"}]} }},
        "state": {"avatar": {"enabled": True, "position": [0, 1]},
                  "variables": {"left": 2, "right": 7, "other": 99, "done": 0}},
        "goals": [{"id": "pending", "type": "variable_threshold",
                   "config": {"variable": "done", "target": 1}}],
    }
    return GameDef.from_dict(data, id="generic"), level


class ExchangeParametersTest(unittest.TestCase):
    def test_atomic_snapshot_metadata_and_configured_pairs(self):
        game, level = fixture()
        engine = TurnEngine(game, level)
        result = engine.execute_turn("move", {"direction": "right"})
        event = next(e for e in result.events if e["type"] == "parameters_exchanged")
        self.assertEqual((event["firstValue"], event["secondValue"]), (2, 7))
        self.assertEqual((engine.state.variables["left"], engine.state.variables["right"]), (7, 2))
        self.assertEqual(engine.state.board.get_entity("objects", Pos(1, 0)).params,
                         {"value": 7, "metadata": "keep"})
        engine.execute_turn("move", {"direction": "left"})
        repeated = engine.execute_turn("move", {"direction": "right"})
        self.assertFalse(any(e["type"] == "parameters_exchanged" for e in repeated.events))
        engine.execute_turn("move", {"direction": "right"})
        engine.execute_turn("move", {"direction": "right"})
        self.assertEqual(engine.state.variables, {"left": 7, "right": 99, "other": 2, "done": 0})

    def test_undo_and_reset_restore_values_and_control(self):
        game, level = fixture()
        engine = TurnEngine(game, level)
        engine.execute_turn("move", {"direction": "right"})
        self.assertTrue(engine.undo())
        self.assertEqual(engine.state.variables["left"], 2)
        self.assertEqual(engine.state.board.get_entity("markers", Pos(1, 1)).kind, "control")
        engine.execute_turn("move", {"direction": "right"})
        engine.reset()
        self.assertEqual(engine.state.variables["right"], 7)
        self.assertEqual(engine.state.board.get_entity("markers", Pos(1, 1)).kind, "control")

    def test_missing_endpoint_or_parameter_has_no_partial_effect(self):
        game, level = fixture()
        engine = TurnEngine(game, level)
        for second in (Pos(2, 0), Pos(3, 0)):
            engine.state.board.set_entity("objects", Pos(3, 0), Entity("gauge", {"unrelated": 7}))
            before = deepcopy(engine.state.variables)
            events = execute({"exchange_parameters": {"firstPosition": [1, 0],
                "secondPosition": list(second), "firstVariable": "left", "secondVariable": "right"}},
                {}, engine.state, game)
            self.assertEqual(events, [])
            self.assertEqual(engine.state.variables, before)
            self.assertEqual(engine.state.board.get_entity("objects", Pos(1, 0)).params["value"], 2)

    def test_aliasing_variable_names_is_rejected_before_mutating(self):
        game, level = fixture()
        engine = TurnEngine(game, level)
        with self.assertRaises(ValueError):
            execute({"exchange_parameters": {"firstPosition": [1, 0], "secondPosition": [3, 0],
                "firstVariable": "left", "secondVariable": "left"}}, {}, engine.state, game)
        self.assertEqual(engine.state.variables["left"], 2)
        self.assertEqual(engine.state.board.get_entity("objects", Pos(1, 0)).params["value"], 2)


if __name__ == "__main__":
    unittest.main()
