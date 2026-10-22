"""Required target values must remain visible independently of grid symbols."""
from __future__ import annotations

import unittest

from engines.python._game_def import GameDef
from engines.python._models import Board, GameState
from engines.python.goal_renderer import render_goals


def target_text(rank=2, *, symbol_param=False, anon=False, override=False,
                extra=None, lower=None, match=True):
    game = GameDef.from_dict({
        "layers": [{"id": "objects", "occupancy": "zero_or_one"},
                   {"id": "actors", "occupancy": "zero_or_one"}],
        "entityKinds": {
            "cell": {"layer": "objects", "symbol": "C",
                     **({"symbolParam": "rank"} if symbol_param else {})},
            "marker": {"layer": "actors", "symbol": "M"},
        },
        "actions": [], "systems": [],
    })
    values = {"rank": rank, **(extra or {})}
    config = {"targetLayers": {"objects": [[{"kind": "cell", **values}]]}}
    if match:
        config["matchParams"] = list(values)
    if lower is not None:
        config["targetLayers"]["actors"] = [[{"kind": "marker", **lower}]]
    if override:
        game.goal_descriptions["target"] = "Match the required values."
    board = Board.from_json({"size": [1, 1], "layers": {}}, game.layers)
    state = GameState.from_json({}, board, game.defaults)
    return render_goals(
        {"goals": [{"id": "target", "type": "board_match", "config": config}]},
        state, game, anonymize=anon,
        kind_to_label={"cell": "A", "marker": "B"} if anon else None,
    )


class TargetParameterVisibilityTests(unittest.TestCase):
    def test_non_symbol_parameters_distinguish_targets(self):
        for anon in (False, True):
            a, b = target_text(2, anon=anon), target_text(9, anon=anon)
            self.assertNotEqual(a, b)
            self.assertIn('"rank": 2', a)
            self.assertIn('"rank": 9', b)

    def test_multi_character_values_do_not_collapse_to_n(self):
        for anon in (False, True):
            a = target_text(12, symbol_param=True, anon=anon)
            b = target_text(19, symbol_param=True, anon=anon)
            self.assertNotEqual(a, b)
            self.assertIn('"rank": 12', a)
            self.assertIn('"rank": 19', b)

    def test_all_required_parameters_preserve_full_json_values(self):
        text = target_text(extra={"mode": "two words", "active": False,
                                  "optional": None, "path": [1, 12]})
        self.assertIn('{"active": false, "mode": "two words", "optional": null, '
                      '"path": [1, 12], "rank": 2}', text)
        self.assertNotEqual(target_text(2), target_text("2"))

    def test_overrides_keep_required_values(self):
        text = target_text(12, override=True)
        self.assertTrue(text.startswith("Match the required values.\n"))
        self.assertIn('"rank": 12', text)

    def test_every_layer_at_a_coordinate_has_its_own_values(self):
        for anon in (False, True):
            text = target_text(2, lower={"rank": 9}, anon=anon)
            self.assertIn('"rank": 2', text)
            self.assertIn('"rank": 9', text)
            if anon:
                self.assertNotIn("objects", text)
                self.assertNotIn("actors", text)
                self.assertIn("layer 1", text)
                self.assertIn("layer 2", text)
                self.assertIn('Target parameters: (0,0) layer 1 B {"rank": 9}; '
                              '(0,0) layer 2 A {"rank": 2}', text)
            else:
                self.assertIn("objects", text)
                self.assertIn("actors", text)
                self.assertIn('Target parameters: (0,0) actors M {"rank": 9}; '
                              '(0,0) objects C {"rank": 2}', text)

    def test_missing_required_values_are_distinct_from_explicit_null(self):
        text = target_text(None, lower={})
        self.assertIn('(0,0) actors M {} (missing required: ["rank"])', text)
        self.assertIn('(0,0) objects C {"rank": null}', text)

    def test_unmatched_parameters_are_not_reported_as_requirements(self):
        self.assertEqual(target_text(2, match=False), target_text(9, match=False))
        self.assertNotIn("Target parameters:", target_text(match=False))


if __name__ == "__main__":
    unittest.main()
