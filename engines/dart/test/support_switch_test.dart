// Mirrors engines/python/test_support_switch.py — support_collapse `switches`.
import 'package:gridponder_engine/src/systems/support_collapse_system.dart';
import 'package:gridponder_engine/engine.dart';
import 'package:test/test.dart';

Map<String, dynamic> _kind(String layer, List<String> tags, String symbol) =>
    {'layer': layer, 'tags': tags, 'symbol': symbol};

GameDefinition _game() {
  const member = ['solid', 'walkable', 'supported'];
  return GameDefinition.fromJson({
    'layers': [
      {'id': 'marks', 'occupancy': 'zero_or_one'},
      {'id': 'ground', 'occupancy': 'exactly_one', 'default': 'void'},
    ],
    'entityKinds': {
      'void': _kind('ground', [], ' '),
      'anchor': _kind('ground', ['solid', 'walkable', 'support_root'], 'A'),
      'hull': _kind('ground', [...member, 'severable'], 'H'),
      'wreck': _kind('ground', ['solid'], 'w'),
      'deck': _kind('ground', ['solid'], '='),
      'chute_l': _kind('ground', ['solid', 'slope_left'], '<'),
      'chute_r': _kind('ground', ['solid', 'slope_right'], '>'),
      'plate': _kind('marks', ['plate'], '_'),
      'clamp': _kind('ground', ['solid', 'support_root'], 'K'),
      'clamp_open': _kind('ground', ['solid'], 'k'),
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
          'settleTransform': {'hull': 'wreck'},
          'avatarFellVariable': 'fell',
          'deflect': {'slope_left': 'left', 'slope_right': 'right'},
          'switches': {
            'plateLayer': 'marks',
            'pressed': {'chute_l': 'chute_r', 'clamp': 'clamp_open'},
          },
        },
      },
    ],
    'defaults': {'maxCascadeDepth': 3},
  }, id: 'support_switch_test');
}

Map<String, dynamic> _at(int x, int y, String kind,
        [Map<String, dynamic> params = const {}]) =>
    {
      'position': [x, y],
      'kind': kind,
      ...params,
    };

LevelDefinition _level(
  GameDefinition game,
  List<Map<String, dynamic>> ground,
  List<Map<String, dynamic>> marks,
  List<int> avatar,
) {
  return LevelDefinition.fromJson({
    'id': 'switch_test',
    'board': {
      'size': [7, 7],
      'layers': {
        'ground': {
          'format': 'sparse',
          'entries': [
            ...ground,
            for (var x = 0; x < 7; x++) _at(x, 6, 'deck'),
          ],
        },
        'marks': {'format': 'sparse', 'entries': marks},
      },
    },
    'state': {
      'variables': <String, dynamic>{},
      'avatar': {'enabled': true, 'position': avatar},
    },
    'goals': <Map<String, dynamic>>[],
    'rules': <Map<String, dynamic>>[],
    'solution': {'goldPath': <Map<String, dynamic>>[]},
  }, game.layers);
}

final _fork = [
  _at(2, 0, 'anchor'),
  _at(1, 1, 'hull'),
  _at(2, 1, 'hull'),
  _at(3, 1, 'hull'),
  _at(1, 2, 'hull'),
  _at(1, 3, 'hull'),
  _at(3, 5, 'chute_l', {'channel': 1}),
];

// A clamp is a support root that its channel's plates switch to a non-root kind.
final _trip = [
  _at(1, 0, 'anchor'),
  _at(1, 1, 'hull'),
  _at(1, 2, 'hull'),
  _at(3, 1, 'clamp', {'channel': 1}),
  _at(3, 2, 'hull'),
  _at(3, 3, 'hull'),
];

GameAction _cut(String dir) => GameAction('cut', {'direction': dir});

void main() {
  late GameDefinition game;
  setUp(() => game = _game());

  String? kind(TurnEngine e, int x, int y) =>
      e.state.board.getEntity('ground', Position(x, y))?.kind;

  test('the lower piece presses the plate before the higher one moves', () {
    final engine = TurnEngine(
        game,
        _level(game, _fork, [
          _at(1, 5, 'plate', {'channel': 1})
        ], [
          2,
          0
        ]));
    engine.executeTurn(_cut('down'));
    expect(kind(engine, 1, 5), 'wreck');
    expect(kind(engine, 3, 5), 'chute_r');
    expect(kind(engine, 4, 5), 'wreck');
    expect(kind(engine, 2, 5), 'void');
  });

  test('without the plate the chute keeps its way', () {
    final engine = TurnEngine(game, _level(game, _fork, [], [2, 0]));
    engine.executeTurn(_cut('down'));
    expect(kind(engine, 3, 5), 'chute_l');
    expect(kind(engine, 2, 5), 'wreck');
  });

  test('a plate on another channel does nothing', () {
    final engine = TurnEngine(
        game,
        _level(game, _fork, [
          _at(1, 5, 'plate', {'channel': 2})
        ], [
          2,
          0
        ]));
    engine.executeTurn(_cut('down'));
    expect(kind(engine, 3, 5), 'chute_l');
  });

  test('removing the weight resets the chute', () {
    final ground = [
      _at(1, 4, 'anchor'),
      _at(1, 5, 'hull'),
      _at(3, 5, 'chute_r', {'channel': 1}),
    ];
    final engine = TurnEngine(
        game,
        _level(game, ground, [
          _at(1, 5, 'plate', {'channel': 1})
        ], [
          0,
          5
        ]));
    engine.executeTurn(_cut('right'));
    expect(kind(engine, 1, 5), 'void');
    expect(kind(engine, 3, 5), 'chute_l');
  });

  test('status lines name plates and switched cells', () {
    final engine = TurnEngine(
        game,
        _level(game, _fork, [
          _at(1, 5, 'plate', {'channel': 1})
        ], [
          2,
          0
        ]));
    const system = SupportCollapseSystem(id: 'collapse');
    final lines =
        system.observationStatusLines(engine.state, game, engine.state.board);
    expect(lines, contains('(1,5): plate 1, empty'));
    expect(lines, contains('(3,5): chute l, channel 1'));
  });

  group('trip clamps', () {
    test('a landing opens a clamp and its load falls the same turn', () {
      final engine = TurnEngine(game,
          _level(game, _trip, [_at(1, 5, 'plate', {'channel': 1})], [1, 0]));
      engine.executeTurn(_cut('down'));
      expect(kind(engine, 1, 5), 'wreck');
      expect(kind(engine, 3, 1), 'clamp_open');
      expect(kind(engine, 3, 5), 'wreck');
      expect(kind(engine, 3, 4), 'wreck');
      expect(kind(engine, 3, 2), 'void');
    });

    test('without the plate the clamp holds', () {
      final engine = TurnEngine(game, _level(game, _trip, [], [1, 0]));
      engine.executeTurn(_cut('down'));
      expect(kind(engine, 3, 1), 'clamp');
      expect(kind(engine, 3, 2), 'hull');
    });

    test('clamps chain within one turn', () {
      final ground = [
        ..._trip,
        _at(5, 1, 'clamp', {'channel': 2}),
        _at(5, 2, 'hull'),
      ];
      final engine = TurnEngine(
          game,
          _level(game, ground, [
            _at(1, 5, 'plate', {'channel': 1}),
            _at(3, 5, 'plate', {'channel': 2}),
          ], [1, 0]));
      engine.executeTurn(_cut('down'));
      expect(kind(engine, 5, 1), 'clamp_open');
      expect(kind(engine, 5, 5), 'wreck');
      expect(kind(engine, 5, 2), 'void');
    });

    test('a released plate closes its clamp and what hangs stays', () {
      final ground = [
        _at(1, 4, 'anchor'),
        _at(1, 5, 'hull'),
        _at(3, 1, 'clamp_open', {'channel': 1}),
        _at(3, 2, 'hull'),
        _at(4, 2, 'anchor'),
      ];
      final engine = TurnEngine(game,
          _level(game, ground, [_at(1, 5, 'plate', {'channel': 1})], [1, 4]));
      engine.executeTurn(_cut('down'));
      expect(kind(engine, 1, 5), 'void');
      expect(kind(engine, 3, 1), 'clamp');
      expect(kind(engine, 3, 2), 'hull');
    });

    test('the avatar on released structure rides it down once', () {
      final ground = [
        _at(2, 0, 'anchor'),
        _at(2, 1, 'hull'),
        _at(2, 2, 'hull'),
        _at(2, 3, 'hull'),
        _at(3, 1, 'clamp', {'channel': 1}),
        _at(3, 2, 'hull'),
      ];
      final engine = TurnEngine(game,
          _level(game, ground, [_at(2, 5, 'plate', {'channel': 1})], [3, 2]));
      engine.executeTurn(_cut('left'));
      expect(kind(engine, 2, 5), 'wreck');
      expect(engine.state.variables['fell'], 1);
      expect(engine.state.avatar.position, const Position(3, 5));
    });

    test('preview reports the whole cascade', () {
      final engine = TurnEngine(game,
          _level(game, _trip, [_at(1, 5, 'plate', {'channel': 1})], [1, 0]));
      final result = engine.previewTurn(_cut('down'));
      expect(result.newState.board.getEntity('ground', const Position(3, 5))?.kind,
          'wreck');
      expect(kind(engine, 3, 2), 'hull');
    });
  });
}
