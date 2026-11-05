// Parity mirror of engines/python/test_balance_supply.py — the supply-line
// half of `balance_unreachable` (`requireConnected`).
import 'package:gridponder_engine/engine.dart';
import 'package:gridponder_engine/src/engine/goal_evaluator.dart';
import 'package:test/test.dart';

GameDefinition _makeGame() {
  final data = {
    'id': 'com.gridponder.test_balance_supply',
    'layers': [
      {'id': 'ground', 'occupancy': 'exactly_one', 'default': 'empty'},
      {'id': 'territory', 'occupancy': 'zero_or_one'},
      {'id': 'actors', 'occupancy': 'zero_or_one'},
    ],
    'entityKinds': {
      'empty': {
        'layer': 'ground',
        'tags': ['walkable'],
        'symbol': '.'
      },
      'gate': {
        'layer': 'ground',
        'tags': ['solid'],
        'symbol': 'f'
      },
      'unit_a': {
        'layer': 'actors',
        'tags': ['actor'],
        'symbol': 'A'
      },
      'unit_b': {
        'layer': 'actors',
        'tags': ['actor'],
        'symbol': 'B'
      },
      'terr_a': {'layer': 'territory', 'tags': [], 'symbol': 'a'},
      'terr_b': {'layer': 'territory', 'tags': [], 'symbol': 'b'},
    },
    'actions': [
      {
        'id': 'move',
        'params': {
          'direction': {
            'type': 'direction',
            'values': ['up', 'down', 'left', 'right'],
          },
        },
      },
    ],
    'systems': [
      {
        'id': 'movement',
        'type': 'coupled_actors',
        'config': {
          'claim': {
            'layer': 'territory',
            'map': {'unit_a': 'terr_a', 'unit_b': 'terr_b'},
          },
        },
      },
    ],
  };
  return GameDefinition.fromJson(data, id: 'test_balance_supply');
}

typedef _Mark = (int, int, String);

/// 4x2 board: unit_a at (0,0), unit_b at (0,1).
Map<String, dynamic> _makeLevel(List<_Mark> terr,
        {List<_Mark> ground = const [],
        bool connected = true,
        Map<String, dynamic>? sources}) =>
    {
      'id': 'supply_level',
      'board': {
        'size': [4, 2],
        'layers': {
          'ground': {
            'format': 'sparse',
            'entries': [
              for (final (x, y, k) in ground)
                {
                  'position': [x, y],
                  'kind': k
                }
            ],
          },
          'territory': {
            'format': 'sparse',
            'entries': [
              for (final (x, y, k) in terr)
                {
                  'position': [x, y],
                  'kind': k
                }
            ],
          },
          'actors': {
            'format': 'sparse',
            'entries': [
              {
                'position': [0, 0],
                'kind': 'unit_a'
              },
              {
                'position': [0, 1],
                'kind': 'unit_b'
              },
            ],
          },
        },
      },
      'state': {},
      'goals': [
        {
          'id': 'balance_goal',
          'type': 'balance',
          'config': {
            'layer': 'territory',
            'owners': ['terr_a', 'terr_b'],
            'claimableLayer': 'ground',
            'claimableKind': ['empty', 'gate'],
            'requireConnected': connected,
            'connectionSources': sources ??
                {
                  'terr_a': [0, 0],
                  'terr_b': [0, 1]
                },
          },
        },
      ],
      'loseConditions': [
        {
          'type': 'balance_unreachable',
          'config': {'goalId': 'balance_goal'},
        },
      ],
    };

const List<_Mark> _cut = [
  (0, 0, 'terr_a'),
  (2, 0, 'terr_a'),
  (0, 1, 'terr_b'),
  (1, 0, 'terr_b'),
  (1, 1, 'terr_b'),
];
const List<_Mark> _open = [
  (0, 0, 'terr_a'),
  (2, 0, 'terr_a'),
  (0, 1, 'terr_b'),
  (1, 1, 'terr_b'),
];

void main() {
  final game = _makeGame();
  TurnEngine engineFor(Map<String, dynamic> json) =>
      TurnEngine(game, LevelDefinition.fromJson(json, game.layers));
  bool cut(Map<String, dynamic> json) {
    final cfg = ((json['goals'] as List).first as Map)['config']
        as Map<String, dynamic>;
    return balanceSupplyCut(cfg, engineFor(json).state);
  }

  group('balance supply lines', () {
    test('a cut island loses', () {
      final json = _makeLevel(_cut);
      expect(cut(json), isTrue);
      final result = engineFor(json)
          .executeTurn(GameAction('move', {'direction': 'right'}));
      expect(result.isLost, isTrue);
      expect(result.loseReason, equals('balance_unreachable'));
    });

    test('a reconnectable island is not cut', () {
      expect(cut(_makeLevel(_open)), isFalse);
    });

    test('a closed gate is not a cut', () {
      expect(cut(_makeLevel(_open, ground: const [(1, 0, 'gate')])), isFalse);
    });

    test('a source taken by another owner loses', () {
      expect(
          cut(_makeLevel(const [
            (0, 0, 'terr_b'),
            (2, 0, 'terr_a'),
            (0, 1, 'terr_b'),
          ])),
          isTrue);
    });

    test('without requireConnected it never fires', () {
      expect(cut(_makeLevel(_cut, connected: false)), isFalse);
    });

    test('a missing source never fires', () {
      expect(
          cut(_makeLevel(_cut, sources: {
            'terr_b': [0, 1]
          })),
          isFalse);
    });
  });
}
