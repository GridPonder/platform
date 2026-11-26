// Mirrors engines/python/test_support_fuse.py — support_collapse `fuse`.
import 'package:gridponder_engine/src/systems/support_collapse_system.dart';
import 'package:gridponder_engine/engine.dart';
import 'package:test/test.dart';

Map<String, dynamic> _kind(List<String> tags, String symbol) =>
    {'layer': 'ground', 'tags': tags, 'symbol': symbol};

GameDefinition _game() {
  const member = ['solid', 'walkable', 'supported'];
  return GameDefinition.fromJson({
    'layers': [
      {'id': 'ground', 'occupancy': 'exactly_one', 'default': 'void'},
    ],
    'entityKinds': {
      'void': _kind([], ' '),
      'anchor': _kind(['solid', 'walkable', 'support_root'], 'A'),
      'hull': _kind([...member, 'severable'], 'H'),
      'strut': _kind([...member, 'load_limited'], 'S'),
      'fuse': _kind([...member, 'severable'], 'F'),
      'fuse_lit': _kind(member, 'f'),
      'pod': _kind([...member, 'severable'], 'P'),
      'wreck': _kind(['solid'], 'w'),
      'deck': _kind(['solid'], '='),
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
          'settleTransform': {
            'hull': 'wreck',
            'strut': 'wreck',
            'fuse': 'wreck',
            'fuse_lit': 'wreck',
          },
          'avatarFellVariable': 'wrecked',
          'fuse': {
            'ignite': {'fuse': 'fuse_lit'},
          },
          'strain': {
            'tags': ['load_limited'],
            'endurance': 2,
          },
        },
      },
    ],
    'defaults': {'maxCascadeDepth': 3},
  }, id: 'support_fuse_test');
}

LevelDefinition _level(
  GameDefinition game,
  List<Map<String, dynamic>> entries,
  List<int> avatar,
) {
  return LevelDefinition.fromJson({
    'id': 'fuse_test',
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

Map<String, dynamic> _at(int x, int y, String kind,
        [Map<String, dynamic> params = const {}]) =>
    {
      'position': [x, y],
      'kind': kind,
      ...params,
    };

final _hanging = [
  _at(0, 0, 'anchor'),
  _at(1, 0, 'anchor'),
  _at(1, 1, 'fuse'),
  _at(1, 2, 'pod'),
];

final _run = [
  _at(0, 0, 'anchor'),
  _at(4, 0, 'anchor'),
  _at(0, 1, 'fuse'),
  _at(1, 1, 'fuse'),
  _at(2, 1, 'fuse'),
  _at(3, 1, 'hull'),
  _at(4, 1, 'hull'),
];

GameAction _cut(String dir) => GameAction('cut', {'direction': dir});
const _wait = GameAction('wait', {});

void main() {
  late GameDefinition game;
  setUp(() => game = _game());

  String? kind(TurnEngine e, int x, int y) =>
      e.state.board.getEntity('ground', Position(x, y))?.kind;
  List<String?> row(TurnEngine e, int y, int n) =>
      [for (var x = 0; x < n; x++) kind(e, x, y)];

  test('cutting a fuse lights it instead of removing it', () {
    final engine = TurnEngine(game, _level(game, _hanging, [1, 0]));
    engine.executeTurn(_cut('down'));
    expect(kind(engine, 1, 1), 'fuse_lit');
    expect(kind(engine, 1, 2), 'pod');
    engine.executeTurn(_wait);
    expect(kind(engine, 1, 1), 'void');
    expect(kind(engine, 1, 5), 'pod');
    expect(engine.state.variables['wrecked'], 0);
  });

  test('a run burns one cell per turn', () {
    final engine = TurnEngine(game, _level(game, _run, [0, 0]));
    engine.executeTurn(_cut('down'));
    expect(row(engine, 1, 3), ['fuse_lit', 'fuse', 'fuse']);
    engine.executeTurn(_wait);
    expect(row(engine, 1, 3), ['void', 'fuse_lit', 'fuse']);
    engine.executeTurn(_wait);
    expect(row(engine, 1, 3), ['void', 'void', 'fuse_lit']);
    engine.executeTurn(_wait);
    expect(row(engine, 1, 3), ['void', 'void', 'void']);
    expect(kind(engine, 3, 1), 'hull');
  });

  test('a fork burns both branches together', () {
    final entries = [
      _at(0, 0, 'anchor'),
      _at(2, 0, 'anchor'),
      _at(4, 0, 'anchor'),
      _at(0, 1, 'hull'),
      _at(1, 1, 'fuse'),
      _at(2, 1, 'fuse'),
      _at(3, 1, 'fuse'),
      _at(4, 1, 'hull'),
    ];
    final engine = TurnEngine(game, _level(game, entries, [2, 0]));
    engine.executeTurn(_cut('down'));
    engine.executeTurn(_wait);
    expect(row(engine, 1, 5), ['hull', 'fuse_lit', 'void', 'fuse_lit', 'hull']);
    engine.executeTurn(_wait);
    expect(row(engine, 1, 5), ['hull', 'void', 'void', 'void', 'hull']);
  });

  test('an avatar on a burning cell falls', () {
    final engine = TurnEngine(game, _level(game, _run, [1, 1]));
    engine.executeTurn(_cut('left'));
    engine.executeTurn(_wait);
    expect(engine.state.variables['wrecked'], 0);
    engine.executeTurn(_wait);
    expect(engine.state.variables['wrecked'], 1);
  });

  test('a falling lit cell stops burning', () {
    final entries = [
      _at(0, 0, 'anchor'),
      _at(1, 0, 'anchor'),
      _at(1, 1, 'fuse'),
      _at(1, 2, 'fuse'),
    ];
    final engine = TurnEngine(game, _level(game, entries, [1, 0]));
    engine.executeTurn(_cut('down'));
    engine.executeTurn(_wait);
    expect(kind(engine, 1, 5), 'wreck');
    engine.executeTurn(_wait);
    expect(kind(engine, 1, 5), 'wreck');
  });

  test('a burn hands the load to a strut', () {
    final entries = [
      _at(0, 0, 'anchor'),
      _at(2, 0, 'anchor'),
      _at(0, 1, 'fuse'),
      _at(1, 1, 'hull'),
      _at(2, 1, 'strut', {'capacity': 1}),
      _at(1, 2, 'hull'),
    ];
    final engine = TurnEngine(game, _level(game, entries, [0, 0]));
    engine.executeTurn(_cut('down'));
    engine.executeTurn(_wait);
    expect(
        engine.state.board
            .getEntity('ground', const Position(2, 1))
            ?.param('endurance'),
        1);
    engine.executeTurn(_wait);
    expect(kind(engine, 2, 1), 'void');
    expect(kind(engine, 1, 5), 'wreck');
  });

  test('status lines report burning cells', () {
    final engine = TurnEngine(game, _level(game, _run, [0, 0]));
    engine.executeTurn(_cut('down'));
    const system = SupportCollapseSystem(id: 'collapse');
    final lines =
        system.observationStatusLines(engine.state, game, engine.state.board);
    expect(lines.first, startsWith('Burning fuses'));
    expect(lines, contains('(0,1): fuse lit burns away in 1 turn'));
  });
}
