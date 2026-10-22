"""Visible guides and HUD state must reach the agent without hidden variables."""
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from engines.python._game_def import GameDef
from engines.python._turn_engine import TurnEngine
from engines.python.observation import build_prompt


def fixture():
    game = GameDef.from_dict({
        'layers': [{'id': 'ground', 'occupancy': 'exactly_one', 'default': 'floor'}],
        'entityKinds': {'floor': {'layer': 'ground', 'symbol': '.'}},
        'actions': [{'id': 'move', 'params': {'direction': {'type': 'direction'}}}],
        'systems': [],
        'ui': {'showGuide': True, 'readouts': [{'variable': 'capacity', 'label': 'Energy', 'maxVariable': 'maximum'},
                            {'variable': 'signal', 'label': 'Signal', 'blankWhen': -1}]},
    }, title='Synthetic example', description='Public authored rules.')
    level = {
        'id': 'example', 'guide': 'Public local instructions.',
        'board': {'size': [2, 1], 'layers': {}},
        'state': {'avatar': {'enabled': True, 'position': [0, 0]},
                  'variables': {'capacity': 2, 'maximum': 7, 'signal': -1,
                                'hidden_solution_marker': 'NEVER_SHOW'}},
        'goals': [], 'loseConditions': [{'type': 'max_actions', 'config': {'limit': 11}}],
        'metadata': {'description': 'HIDDEN_SOLUTION_TEXT'},
    }
    return game, level, TurnEngine(game, level).state


class VisiblePromptTest(unittest.TestCase):
    def test_visible_instructions_and_live_capacity_in_all_modes(self):
        game, level, state = fixture()
        for mode in ('single', 'fixed-n', 'flex-n', 'full'):
            for text_board, image in ((True, False), (False, True), (True, True)):
                prompt = build_prompt(game, level, state, inference_mode=mode,
                                      text_board=text_board, attach_image=image)
                self.assertIn('Public authored rules.', prompt)
                self.assertIn('CURRENT LEVEL GUIDE:\nPublic local instructions.', prompt)
                self.assertIn('Energy: 2/7', prompt)
                self.assertIn('Signal: -', prompt)
                self.assertIn('Moves this attempt: 0 of 11 allowed', prompt)
                self.assertNotIn('NEVER_SHOW', prompt)
                self.assertNotIn('HIDDEN_SOLUTION_TEXT', prompt)
        state.variables['capacity'] = 4
        state.variables['maximum'] = 9
        state.action_count = 5
        prompt = build_prompt(game, level, state, last_action={'action': 'move', 'direction': 'right'},
                              previous_board_text='..')
        self.assertIn('Energy: 4/9', prompt)
        self.assertIn('Moves this attempt: 5 of 11 allowed', prompt)

    def test_hidden_guide_is_not_disclosed(self):
        game, level, state = fixture()
        game.ui_show_guide = False
        self.assertNotIn('Public local instructions.', build_prompt(game, level, state))

    def test_anonymous_discovery_omits_authored_rules_and_names(self):
        game, level, state = fixture()
        prompt = build_prompt(game, level, state, anonymize=True)
        for hidden in ('Public authored rules.', 'Public local instructions.', 'Energy:', 'Signal:', 'NEVER_SHOW'):
            self.assertNotIn(hidden, prompt)
        self.assertIn('Readout 1: 2/7', prompt)
        self.assertIn('Moves this attempt: 0 of 11 allowed', prompt)


if __name__ == '__main__':
    unittest.main()
