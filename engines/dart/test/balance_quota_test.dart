// Parity mirror of engines/python/test_balance_quotas.py — `quotas` on the
// `balance` goal and the matching `balance_unreachable` checks.
import 'package:gridponder_engine/engine.dart';
import 'package:test/test.dart';

GameDefinition _makeGame() {
  final data = {
    'id': 'com.gridponder.test_balance_quotas',
    'layers': [
      {'id': 'ground', 'occupancy': 'exactly_one', 'default': 'empty'},
      {'id': 'markers', 'occupancy': 'zero_or_one'},
      {'id': 'territory', 'occupancy': 'zero_or_one'},
      {'id': 'actors', 'occupancy': 'zero_or_one'},
    ],
    'entityKinds': {
      'empty': {
        'layer': 'ground',
        'tags': ['walkable'],
        'symbol': '.'
      },
      'site': {'layer': 'markers', 'tags': [], 'symbol': 'c', 'uiName': 'Site'},
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
      'blighted': {'layer': 'territory', 'tags': [], 'symbol': 'x'},
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
  return GameDefinition.fromJson(data, id: 'test_balance_quotas');
}

/// 4x2 board: unit_a starts at (0,0), unit_b at (0,1), each on its own
/// pre-claimed cell. Moving right three times fills both rows 4/4.
Map<String, dynamic> _makeLevel(List<List<int>> sites, {bool lose = true}) => {
      'id': 'quota_level',
      'board': {
        'size': [4, 2],
        'layers': {
          'ground': {'format': 'sparse', 'entries': []},
          'markers': {
            'format': 'sparse',
            'entries': [
              for (final c in sites)
                {
                  'position': [c[0], c[1]],
                  'kind': 'site'
                }
            ],
          },
          'territory': {
            'format': 'sparse',
            'entries': [
              {
                'position': [0, 0],
                'kind': 'terr_a'
              },
              {
                'position': [0, 1],
                'kind': 'terr_b'
              },
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
            'claimableKind': 'empty',
            'quotas': [
              {'layer': 'markers', 'kind': 'site', 'count': 1}
            ],
          },
        },
      ],
      'loseConditions': [
        if (lose)
          {
            'type': 'balance_unreachable',
            'config': {'goalId': 'balance_goal'},
          },
      ],
    };

TurnResult _right(TurnEngine engine, int n) {
  late TurnResult result;
  for (var i = 0; i < n; i++) {
    result = engine.executeTurn(GameAction('move', {'direction': 'right'}));
  }
  return result;
}

void main() {
  final game = _makeGame();
  TurnEngine engineFor(Map<String, dynamic> json) =>
      TurnEngine(game, LevelDefinition.fromJson(json, game.layers));

  group('balance quotas', () {
    test('quota met wins', () {
      final engine = engineFor(_makeLevel([
        [1, 0],
        [2, 1]
      ]));
      expect(_right(engine, 3).isWon, isTrue);
    });

    test('quota unmet blocks the win', () {
      final engine = engineFor(_makeLevel([
        [1, 0],
        [2, 0]
      ], lose: false));
      final result = _right(engine, 3);
      expect(result.isWon, isFalse);
      expect(result.isLost, isFalse);
    });

    test('over quota loses at once', () {
      final engine = engineFor(_makeLevel([
        [1, 0],
        [2, 0]
      ]));
      expect(_right(engine, 1).isLost, isFalse);
      final second = _right(engine, 1);
      expect(second.isLost, isTrue);
      expect(second.loseReason, equals('balance_unreachable'));
    });

    test('shortfall beyond unowned sites loses', () {
      final engine = engineFor(_makeLevel([
        [3, 0]
      ]));
      final result = _right(engine, 1);
      expect(result.isLost, isTrue);
      expect(result.loseReason, equals('balance_unreachable'));
    });

    test('a foreign mark on claimable land loses', () {
      final json = _makeLevel([
        [1, 0],
        [2, 1]
      ]);
      ((json['board']['layers']['territory'] as Map)['entries'] as List).add({
        'position': [3, 0],
        'kind': 'blighted',
      });
      final result = _right(engineFor(json), 1);
      expect(result.isLost, isTrue);
      expect(result.loseReason, equals('balance_unreachable'));
    });

    test('no foreign mark, no loss', () {
      final engine = engineFor(_makeLevel([
        [1, 0],
        [2, 1]
      ]));
      expect(_right(engine, 1).isLost, isFalse);
    });

    test('goal text states the quota', () {
      final json = _makeLevel([
        [1, 0],
        [2, 1]
      ]);
      final level = LevelDefinition.fromJson(json, game.layers);
      final engine = TurnEngine(game, level);
      _right(engine, 1);
      final text = LlmAgent.describeGoals(level, engine.state, game);
      expect(text, contains('exactly 1 Site cell'));
      expect(text, contains('need 1 each'));
    });
  });
}
