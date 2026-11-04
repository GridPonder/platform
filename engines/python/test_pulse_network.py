"""Focused movement-trigger compatibility tests for pulse networks."""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from engines.python._game_def import GameDef
from engines.python._models import Pos, Entity
from engines.python._systems.pulse_network import PulseNetworkSystem
from engines.python._turn_engine import TurnEngine
from engines.python import _events as ev

ROOT = Path(__file__).parent / '_fixtures/pulse_network_smoke'


class MovedRelayTest(unittest.TestCase):
    def test_moved_relay_only_forwards_on_activation_and_when_enabled(self):
        for enabled in (False, True):
            for old in ('dark', 'lit'):
                for new in ('dark', 'lit'):
                    with self.subTest(enabled=enabled, old=old, new=new):
                        data = json.loads((ROOT / 'game.json').read_text())
                        data['systems'][1]['config']['activateMovedRelays'] = enabled
                        game = GameDef(data)
                        level = json.loads((ROOT / 'levels/relay_on.json').read_text())
                        state = TurnEngine(game, level).state
                        state.board.set_entity('objects', Pos(0, 0), Entity('wait'))
                        state.board.set_entity('lights', Pos(0, 0), Entity(old))
                        state.board.set_entity('lights', Pos(1, 0), Entity(new))
                        state.board.set_entity('controls', Pos(0, 0), Entity('pressed'))
                        PulseNetworkSystem('network').execute_cascade_resolution([
                            ev.tile_moved(Pos(0, 0), Pos(1, 0), new, layer='lights'),
                            ev.tile_moved(Pos(1, 0), Pos(0, 0), old, layer='lights'),
                            ev.cell_transformed(Pos(0, 0), 'ready', 'pressed', 'controls'),
                        ], state, game)
                        expected = 'lit' if enabled and old == 'dark' and new == 'lit' else 'dark'
                        self.assertEqual(state.board.get_entity('lights', Pos(2, 0)).kind, expected)
                        self.assertEqual(state.board.get_entity('lights', Pos(1, 0)).kind, new)

    def test_existing_fixture_solutions(self):
        game = GameDef(json.loads((ROOT / 'game.json').read_text()))
        for path in (ROOT / 'levels').glob('*.json'):
            with self.subTest(level=path.stem):
                level = json.loads(path.read_text())
                engine = TurnEngine(game, level)
                for action in level['solution']['goldPath']:
                    self.assertTrue(engine.execute_turn(action['action'], {'position': action['position']}).accepted)
                self.assertTrue(engine.is_won)


if __name__ == '__main__':
    unittest.main()
