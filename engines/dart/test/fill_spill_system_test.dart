// Parity mirror of engines/python/test_fill_spill.py — behavioural cases for
// the `fill_spill` system.
import 'package:gridponder_engine/engine.dart';
import 'package:test/test.dart';

final _config = <String, dynamic>{
  'heights': {for (var n = 0; n < 6; n++) 'h$n': n},
  'waterKinds': ['water_1', 'water_2', 'water_3'],
  'barriers': {
    'layer': 'objects',
    'kinds': ['gate_shut'],
  },
  'gates': [
    {'layer': 'objects', 'closed': 'gate_shut', 'open': 'gate_open'},
  ],
  'markers': {
    'layer': 'objects',
    'pairs': [
      {'dry': 'basin', 'wet': 'basin_full'},
    ],
  },
  'flood': {
    'variable': 'flooded',
    'layer': 'objects',
    'kinds': ['basin_full'],
    'avatar': true,
  },
};

GameDefinition _makeGame([Map<String, dynamic>? config]) {
  final kinds = <String, dynamic>{
    'bank': {
      'layer': 'ground',
      'tags': ['solid'],
      'symbol': '#',
    },
    for (var n = 0; n < 6; n++)
      'h$n': {
        'layer': 'ground',
        'tags': ['walkable'],
        'symbol': '$n',
      },
    for (var n = 1; n < 4; n++)
      'water_$n': {
        'layer': 'water',
        'tags': ['solid'],
        'symbol': 'w$n',
      },
    'gate_shut': {
      'layer': 'objects',
      'tags': ['solid'],
      'symbol': '|',
    },
    'gate_open': {
      'layer': 'objects',
      'tags': ['solid'],
      'symbol': '=',
    },
    'seep': {
      'layer': 'objects',
      'tags': ['solid'],
      'symbol': '~',
    },
    'basin': {'layer': 'objects', 'tags': <String>[], 'symbol': 'f'},
    'basin_full': {'layer': 'objects', 'tags': <String>[], 'symbol': 'F'},
  };
  final data = {
    'id': 'com.gridponder.test_fill_spill',
    'layers': [
      {'id': 'ground', 'occupancy': 'exactly_one', 'default': 'bank'},
      {'id': 'water', 'occupancy': 'zero_or_one'},
      {'id': 'objects', 'occupancy': 'zero_or_one'},
    ],
    'entityKinds': kinds,
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
      {'id': 'water', 'type': 'fill_spill', 'config': config ?? _config},
      {
        'id': 'walk',
        'type': 'avatar_navigation',
        'config': {
          'solidHandling': 'block',
          'groundLayer': 'ground',
          'validGroundTags': ['walkable'],
          'solidLayers': ['objects', 'water'],
        },
      },
    ],
  };
  return GameDefinition.fromJson(data, id: 'test_fill_spill');
}

/// rows: '#' bank, digit n ground height n.
Map<String, dynamic> _level(
  List<String> rows,
  List<List<int>> water, {
  List<List<Object>> objects = const [],
  List<int>? avatar,
}) =>
    {
      'id': 't',
      'board': {
        'size': [rows[0].length, rows.length],
        'layers': {
          'ground': [
            for (final row in rows)
              [for (final ch in row.split('')) ch == '#' ? 'bank' : 'h$ch'],
          ],
          'water': {
            'format': 'sparse',
            'entries': [
              for (final w in water)
                {
                  'position': [w[0], w[1]],
                  'kind': 'water_1',
                  'units': w[2],
                },
            ],
          },
          'objects': {
            'format': 'sparse',
            'entries': [
              for (final o in objects)
                {
                  'position': [o[0], o[1]],
                  'kind': o[2],
                },
            ],
          },
        },
      },
      'state': {
        'avatar': {
          'enabled': avatar != null,
          'position': avatar ?? [0, 0],
        },
        'variables': {'flooded': 0},
      },
      'goals': <dynamic>[],
    };

TurnEngine _engineFor(GameDefinition game, Map<String, dynamic> levelJson) =>
    TurnEngine(game, LevelDefinition.fromJson(levelJson, game.layers));

GameAction _move(String dir) => GameAction('move', {'direction': dir});

/// Water cells as `x,y` -> `kind/units`.
Map<String, String> _water(TurnEngine engine) => {
      for (final e in engine.state.board.layers['water']!.entries())
        '${e.key.x},${e.key.y}': '${e.value.kind}/${e.value.params['units']}',
    };

String? _object(TurnEngine engine, int x, int y) =>
    engine.state.board.getEntity('objects', Position(x, y))?.kind;

void main() {
  group('fill_spill', () {
    test('water stops at the lip and spills the rest', () {
      // Two hollows split by a ridge of 2: the first holds 4 below the ridge,
      // the fifth unit pours over into the second hollow.
      final engine = _engineFor(
          _makeGame(),
          _level([
            '#######',
            '#00200#',
            '#######'
          ], [
            [1, 1, 5]
          ]));
      final w = _water(engine);
      expect(w.keys.toSet(), {'1,1', '2,1', '4,1', '5,1'});
      expect(w['1,1'], 'water_2/4');
      expect(w['2,1'], 'water_2/null');
      expect(w['4,1'], 'water_1/1');
      expect(w.containsKey('3,1'), isFalse);
    });

    test('pools over a ridge become one', () {
      final engine = _engineFor(
          _makeGame(),
          _level([
            '#######',
            '#00200#',
            '#######'
          ], [
            [1, 1, 9]
          ]));
      final w = _water(engine);
      expect(w.keys.toSet(), {'1,1', '2,1', '3,1', '4,1', '5,1'});
      expect(
          w.values.where((v) => !v.endsWith('/null')).toList(), ['water_3/9']);
      expect(w['3,1'], 'water_1/null');
    });

    test('an open gate passes only water above the sill', () {
      final engine = _engineFor(
          _makeGame(),
          _level([
            '#########',
            '#0001000#',
            '####3####',
            '#########'
          ], [
            [1, 1, 6]
          ], objects: [
            [4, 1, 'gate_shut'],
          ], avatar: [
            4,
            2
          ]));
      engine.executeTurn(_move('up'));
      final w = _water(engine);
      expect(w['1,1'], 'water_1/3');
      expect(w['5,1'], 'water_1/3');
      expect(w.containsKey('4,1'), isFalse);
      engine.executeTurn(_move('up'));
      expect(_object(engine, 4, 1), 'gate_shut');
    });

    test('a board cannot drop against standing water', () {
      final engine = _engineFor(
          _makeGame(),
          _level([
            '#########',
            '#0000000#',
            '####3####',
            '#########'
          ], [
            [1, 1, 6]
          ], objects: [
            [4, 1, 'gate_shut'],
          ], avatar: [
            4,
            2
          ]));
      engine.executeTurn(_move('up'));
      expect(_water(engine).containsKey('4,1'), isTrue);
      engine.executeTurn(_move('up'));
      expect(_object(engine, 4, 1), 'gate_open');
    });

    test('water reaching the avatar floods it', () {
      final engine = _engineFor(
          _makeGame(),
          _level([
            '#######',
            '#00000#',
            '#######'
          ], [
            [1, 1, 4]
          ], objects: [
            [3, 1, 'gate_shut'],
          ], avatar: [
            4,
            1
          ]));
      engine.executeTurn(_move('left'));
      expect(engine.state.variables['flooded'], 1);
    });

    test('markers follow the water and count as flooded', () {
      final engine = _engineFor(
          _makeGame(),
          _level([
            '#######',
            '#00000#',
            '###4###',
            '#######'
          ], [
            [1, 1, 4]
          ], objects: [
            [3, 1, 'gate_shut'],
            [5, 1, 'basin'],
          ], avatar: [
            3,
            2
          ]));
      expect(_object(engine, 5, 1), 'basin');
      engine.executeTurn(_move('up'));
      expect(_object(engine, 5, 1), 'basin_full');
      expect(engine.state.variables['flooded'], 1);
    });

    test('volume is conserved across every turn', () {
      final engine = _engineFor(
          _makeGame(),
          _level([
            '#########',
            '#0012100#',
            '#####4###',
            '#########'
          ], [
            [1, 1, 7]
          ], objects: [
            [5, 1, 'gate_shut'],
          ], avatar: [
            5,
            2
          ]));
      engine.executeTurn(_move('up'));
      var total = 0;
      for (final e in engine.state.board.layers['water']!.entries()) {
        final u = e.value.params['units'];
        if (u is int) total += u;
      }
      expect(total, 7);
    });

    test('missing heights make the system inert', () {
      final engine = _engineFor(
          _makeGame({
            'waterKinds': ['water_1'],
          }),
          _level([
            '#####',
            '#000#',
            '#####'
          ], [
            [1, 1, 3]
          ]));
      expect(_water(engine), {'1,1': 'water_1/3'});
    });

    final seepConfig = <String, dynamic>{
      ..._config,
      'seeps': {
        'layer': 'objects',
        'kinds': ['seep'],
        'rate': 1,
      },
    };
    const seepRows = ['######', '#0000#', '###4##', '######'];

    test('a seep holds at load and leaks one unit per turn', () {
      final engine = _engineFor(
          _makeGame(seepConfig),
          _level(seepRows, [
            [1, 1, 3]
          ], objects: [
            [2, 1, 'seep'],
          ], avatar: [
            3,
            2
          ]));
      expect(_water(engine), {'1,1': 'water_3/3'});
      engine.executeTurn(_move('down')); // bump the bank: a turn passes
      expect(_water(engine),
          {'1,1': 'water_2/2', '3,1': 'water_1/1', '4,1': 'water_1/null'});
      engine.executeTurn(_move('down'));
      engine.executeTurn(_move('down'));
      // Level 1 on both sides after the second turn: the third moves nothing.
      expect(_water(engine),
          {'1,1': 'water_1/1', '3,1': 'water_1/2', '4,1': 'water_1/null'});
    });

    test('a seep passes only water above its sill', () {
      final engine = _engineFor(
          _makeGame(seepConfig),
          _level([
            '######',
            '#0200#',
            '###4##',
            '######'
          ], [
            [1, 1, 3]
          ], objects: [
            [2, 1, 'seep'],
          ], avatar: [
            3,
            2
          ]));
      for (var i = 0; i < 3; i++) {
        engine.executeTurn(_move('down'));
      }
      expect(_water(engine),
          {'1,1': 'water_2/2', '3,1': 'water_1/1', '4,1': 'water_1/null'});
    });

    test('without seeps config a seep kind is plain ground', () {
      final engine = _engineFor(
          _makeGame(),
          _level(seepRows, [
            [1, 1, 3]
          ], objects: [
            [2, 1, 'seep'],
          ], avatar: [
            3,
            2
          ]));
      expect(_water(engine).containsKey('2,1'), isTrue);
    });
  });
}
