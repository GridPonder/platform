#!/usr/bin/env python3
"""Cross-check all node operations over exhaustive short generic control traces."""
import argparse
import copy
import itertools
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from engines.python._game_def import GameDef
from engines.python._turn_engine import TurnEngine


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    args = parser.parse_args()
    fixture = json.loads((ROOT/'engines/python/_fixtures/state_network.json').read_text())
    cases = []
    variants = [(op, False) for op in
                ['copy', 'toggle', 'not', 'and', 'or', 'xor', 'counter2', 'counter3', 'latch']]
    variants += [('counter2', True), ('counter3', True)]
    for op, park in variants:
        for actions in itertools.product(['on', 'off', 'mask', 'unmask', 'sample', 'send'], repeat=3):
            g, level = copy.deepcopy(fixture['game']), copy.deepcopy(fixture['level'])
            config = g['systems'][0]['config']
            node = config['nodes'][0]
            node['op'] = op
            if op in ['and', 'or', 'xor', 'latch']:
                node['inputs'] = ['p', 'm']
            if park:
                config['parkCounters'] = True
            engine = TurnEngine(GameDef(g), level)
            used, expected = [], []
            for action in actions:
                result = engine.execute_turn(action)
                if not result.accepted:
                    break
                used.append({'action': action})
                v = engine.state.variables
                expected.append({
                    'public': {k: value for k, value in v.items() if not k.startswith('__network_')},
                    'runtime': copy.deepcopy(v['__network_net']),
                    'won': engine.is_won, 'lost': engine.is_lost,
                })
                if engine.is_won or engine.is_lost:
                    break
            cases.append({'game': g, 'level': level, 'actions': used, 'expected': expected})
    return subprocess.run([args.dart, 'run', 'tool/check_network_traces.dart'],
                          input=json.dumps(cases), text=True, cwd=ROOT/'engines/dart').returncode


if __name__ == '__main__':
    raise SystemExit(main())
