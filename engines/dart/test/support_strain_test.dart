// Mirrors engines/python/test_support_strain.py — support_collapse `strain`.
import 'package:gridponder_engine/src/systems/support_collapse_system.dart';
import 'package:gridponder_engine/engine.dart';
import 'package:test/test.dart';

GameDefinition _game() {
  return GameDefinition.fromJson({
    'layers': [
      {'id': 'ground', 'occupancy': 'exactly_one', 'default': 'void'},
    ],
    'entityKinds': {
      'void': {'layer': 'ground', 'tags': <String>[], 'symbol': ' '},
      'anchor': {
        'layer': 'ground',
        'tags': ['solid', 'walkable', 'support_root'],
        'symbol': 'A',
      },
      'hull': {
        'layer': 'ground',
        'tags': ['solid', 'walkable', 'supported', 'severable'],
        'symbol': 'H',
      },
      'strut': {
        'layer': 'ground',
        'tags': ['solid', 'walkable', 'supported', 'severable', 'load_limited'],
        'symbol': 'S',
      },
      'pod': {
        'layer': 'ground',
        'tags': ['solid', 'walkable', 'supported', 'severable'],
        'symbol': 'P',
      },
      'wreck': {
        'layer': 'ground',
        'tags': ['solid'],
        'symbol': 'w',
      },
      'deck': {
        'layer': 'ground',
        'tags': ['solid'],
        'symbol': '=',
      },
    },
    'actions': [
      {
        'id': 'cut',
        'params': {
          'direction': {
            'type': 'direction',
            'values': ['up', 'down', 'left', 'right'],
          },
        },
      },
      {'id': 'wait', 'params': <String, dynamic>{}},
    ],
    'systems': [
      {
        'id': 'collapse',
        'type': 'support_collapse',
        'config': {
          'layer': 'ground',
          'severAction': 'cut',
          'settleTransform': {'hull': 'wreck', 'strut': 'wreck'},
          'avatarFellVariable': 'wrecked',
          'strain': {
            'tags': ['load_limited'],
            'capacityParam': 'capacity',
            'enduranceParam': 'endurance',
            'endurance': 2,
          },
        },
      },
    ],
    'defaults': {'maxCascadeDepth': 3},
  }, id: 'support_strain_test');
}

LevelDefinition _level(
  GameDefinition game,
  List<Map<String, dynamic>> entries,
  List<int> avatar,
) {
  return LevelDefinition.fromJson({
    'id': 'strain_test',
    'board': {
      'size': [5, 7],
      'layers': {
        'ground': {
          'format': 'sparse',
          'entries': [
            ...entries,
            for (var x = 0; x < 5; x++)
              {
                'position': [x, 6],
                'kind': 'deck',
              },
          ],
        },
      },
    },
    'state': {
      'variables': {'wrecked': 0},
      'avatar': {'enabled': true, 'position': avatar},
    },
    'goals': <Map<String, dynamic>>[],
    'rules': <Map<String, dynamic>>[],
    'solution': {'goldPath': <Map<String, dynamic>>[]},
  }, game.layers);
}

Map<String, dynamic> _strut(int x, int y, int capacity, [int? endurance]) => {
  'position': [x, y],
  'kind': 'strut',
  'capacity': capacity,
  if (endurance != null) 'endurance': endurance,
};

Map<String, dynamic> _at(int x, int y, String kind) => {
  'position': [x, y],
  'kind': kind,
};

// Two struts share one hanging load (x right, y down):
//   y=0:  A . A
//   y=1:  S H S      struts at (0,1) and (2,1), capacity 2
//   y=2:  . H .
//   y=3:  . P .
final _shared = [
  _at(0, 0, 'anchor'),
  _at(2, 0, 'anchor'),
  _strut(0, 1, 2),
  _at(1, 1, 'hull'),
  _strut(2, 1, 2),
  _at(1, 2, 'hull'),
  _at(1, 3, 'pod'),
];

GameAction _cut(String dir) => GameAction('cut', {'direction': dir});
const _wait = GameAction('wait', {});

void main() {
  late GameDefinition game;
  setUp(() => game = _game());

  String? kind(TurnEngine e, int x, int y) =>
      e.state.board.getEntity('ground', Position(x, y))?.kind;
  dynamic endurance(TurnEngine e, int x, int y) =>
      e.state.board.getEntity('ground', Position(x, y))?.param('endurance');

  test('shared supports carry nothing', () {
    final engine = TurnEngine(game, _level(game, _shared, [2, 2]));
    for (var i = 0; i < 4; i++) {
      expect(engine.executeTurn(_wait).accepted, isTrue);
    }
    expect(kind(engine, 0, 1), 'strut');
    expect(endurance(engine, 0, 1), isNull);
  });

  test('cutting a partner overloads the survivor, which fails later', () {
    final engine = TurnEngine(game, _level(game, _shared, [2, 2]));
    engine.executeTurn(_cut('up'));
    expect(kind(engine, 0, 1), 'strut');
    expect(endurance(engine, 0, 1), 1);
    expect(kind(engine, 1, 3), 'pod');

    engine.executeTurn(_wait);
    expect(kind(engine, 0, 1), 'void');
    expect(kind(engine, 1, 5), 'pod');
    expect(kind(engine, 1, 4), 'wreck');
  });

  test('relieving the load stops the wear', () {
    final engine = TurnEngine(game, _level(game, _shared, [2, 2]));
    engine.executeTurn(_cut('up'));
    engine.executeTurn(_cut('left'));
    for (var i = 0; i < 3; i++) {
      engine.executeTurn(_wait);
    }
    expect(kind(engine, 0, 1), 'strut');
    expect(endurance(engine, 0, 1), 1);
  });

  test('an exhausted cell fails as soon as a failure overloads it', () {
    final entries = [
      _at(0, 0, 'anchor'),
      _at(2, 0, 'anchor'),
      _at(4, 0, 'anchor'),
      _strut(0, 1, 1, 0),
      _at(1, 1, 'hull'),
      _strut(2, 1, 0, 1),
      _at(3, 1, 'hull'),
      _strut(4, 1, 5),
      _at(1, 2, 'pod'),
    ];
    final engine = TurnEngine(game, _level(game, entries, [4, 2]));
    engine.executeTurn(_cut('up'));
    expect(kind(engine, 2, 1), 'void');
    expect(kind(engine, 0, 1), 'void');
    expect(kind(engine, 1, 5), 'pod');
  });

  test('an avatar on a failing cell falls', () {
    final entries = [
      _at(0, 0, 'anchor'),
      _strut(0, 1, 1, 1),
      _at(0, 2, 'hull'),
      _at(0, 3, 'pod'),
    ];
    final engine = TurnEngine(game, _level(game, entries, [0, 1]));
    engine.executeTurn(_wait);
    expect(kind(engine, 0, 1), 'void');
    expect(engine.state.variables['wrecked'], 1);
  });

  test('status lines report capacity and endurance', () {
    final engine = TurnEngine(game, _level(game, _shared, [2, 2]));
    engine.executeTurn(_cut('up'));
    const system = SupportCollapseSystem(id: 'collapse');
    final lines = system.observationStatusLines(
      engine.state,
      game,
      engine.state.board,
    );
    expect(lines.first, startsWith('Load limits'));
    expect(lines, contains('(0,1): strut capacity 2, endurance 1'));
  });
}
