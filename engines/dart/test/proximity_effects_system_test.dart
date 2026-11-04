import 'package:gridponder_engine/engine.dart';
import 'package:test/test.dart';

GameDefinition game() => GameDefinition.fromJson({
      'layers': [
        {'id': 'ground', 'occupancy': 'exactly_one', 'default': 'floor'},
        {'id': 'objects', 'occupancy': 'zero_or_one'},
        {'id': 'markers', 'occupancy': 'zero_or_one'},
      ],
      'entityKinds': {
        'floor': {
          'layer': 'ground',
          'tags': ['walkable'],
          'symbol': '.',
        },
        'fragile': {
          'layer': 'ground',
          'tags': ['walkable', 'fragile'],
          'symbol': 'F',
        },
        'void': {
          'layer': 'ground',
          'tags': ['solid'],
          'symbol': '#',
        },
        'witness': {
          'layer': 'objects',
          'tags': ['solid', 'witness'],
          'symbol': 'W',
        },
        'bomb': {
          'layer': 'objects',
          'tags': ['solid', 'bomb'],
          'symbol': 'B',
        },
        'hazard': {
          'layer': 'objects',
          'tags': ['solid', 'hazard'],
          'symbol': 'H',
        },
        'exit': {
          'layer': 'markers',
          'tags': ['exit'],
          'symbol': 'E',
        },
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
          'id': 'nav',
          'type': 'avatar_navigation',
          'config': <String, dynamic>{}
        },
        {
          'id': 'near',
          'type': 'proximity_effects',
          'config': {
            'layer': 'objects',
            'reactions': [
              {
                'tag': 'witness',
                'effect': 'cycle',
                'param': 'count',
                'modulus': 3
              },
              {
                'tag': 'bomb',
                'effect': 'threshold',
                'param': 'count',
                'thresholdParam': 'threshold',
                'triggerVariable': 'dead',
              },
              {
                'tag': 'hazard',
                'effect': 'damage',
                'variable': 'hp',
                'amount': 1,
                'triggerVariable': 'dead',
              },
            ],
          },
        },
      ],
      'rules': [
        {
          'id': 'collapse_on_exit',
          'on': 'avatar_exited',
          'where': {
            'position_has_tag': {'layer': 'ground', 'tag': 'fragile'},
          },
          'then': [
            {
              'transform': {
                'position': r'$event.position',
                'layer': 'ground',
                'fromKind': 'fragile',
                'toKind': 'void',
              },
            },
          ],
        },
      ],
      'defaults': {'maxCascadeDepth': 3},
    }, id: 'proximity_test');

LevelDefinition level(
  GameDefinition game, {
  int hp = 3,
  int threshold = 3,
  bool terminal = false,
  bool fragile = true,
}) {
  return LevelDefinition.fromJson({
    'id': 'near_test',
    'board': {
      'size': [4, 3],
      'layers': {
        'ground': {
          'format': 'sparse',
          'entries': fragile
              ? [
                  {
                    'position': [1, 1],
                    'kind': 'fragile',
                  },
                ]
              : <Map<String, dynamic>>[],
        },
        'objects': {
          'format': 'sparse',
          'entries': [
            {
              'position': [2, 1],
              'kind': 'witness',
              'count': 0,
            },
            {
              'position': [1, 0],
              'kind': 'bomb',
              'count': 0,
              'threshold': threshold,
            },
            {
              'position': [1, 2],
              'kind': 'hazard',
            },
          ],
        },
        'markers': {
          'format': 'sparse',
          'entries': [
            {
              'position': [1, 1],
              'kind': 'exit',
            },
          ],
        },
      },
    },
    'state': {
      'avatar': {
        'enabled': true,
        'position': [0, 1],
      },
      'variables': {'hp': hp, 'dead': 0, 'phase': 0},
    },
    'goals': terminal
        ? [
            {
              'id': 'exit',
              'type': 'reach_target',
              'config': {'targetKind': 'exit'},
            },
            {
              'id': 'witness',
              'type': 'param_match',
              'config': {
                'markerLayer': 'objects',
                'markerKind': 'witness',
                'checkLayer': 'objects',
                'checkKind': 'witness',
                'checkParam': 'count',
                'checkValue': 1,
              },
            },
            {
              'id': 'alive',
              'type': 'variable_threshold',
              'config': {'variable': 'dead', 'comparison': 'eq', 'target': 0},
            },
          ]
        : <Map<String, dynamic>>[],
    'loseConditions': [
      {
        'type': 'variable_threshold',
        'config': {'variable': 'dead', 'comparison': 'gte', 'target': 1},
      },
    ],
    'solution': {'goldPath': <Map<String, dynamic>>[]},
  }, game.layers);
}

GameAction move(String direction) =>
    GameAction('move', {'direction': direction});

void main() {
  test('arrival cycles a variable and blocked move does not', () {
    final g = game();
    g.rules.add(RuleDef.fromJson({
      'id': 'advance_phase',
      'on': 'avatar_entered',
      'then': [
        {
          'cycle_variable': {'name': 'phase', 'modulus': 3}
        }
      ],
    }));
    final engine = TurnEngine(g, level(g, hp: 8, threshold: 99, fragile: false));
    for (final (direction, expected) in [
      ('right', 1), ('left', 2), ('right', 0),
    ]) {
      engine.executeTurn(move(direction));
      expect(engine.state.variables['phase'], expected);
    }
    engine.undo();
    expect(engine.state.variables['phase'], 2);
    engine.executeTurn(move('left'));
    expect(engine.state.variables['phase'], 2);
  });

  test('arrival affects all neighbors and fragile floor blocks return', () {
    final g = game();
    final engine = TurnEngine(g, level(g));
    expect(
      engine.state.board
          .getEntity('objects', const Position(2, 1))!
          .params['count'],
      0,
    );
    final result = engine.executeTurn(move('right'));
    expect(
      result.events.where((e) => e.type == 'proximity_triggered').length,
      3,
    );
    final damage = result.events.firstWhere((e) => e['effect'] == 'damage');
    expect(damage['avatarPosition'], const Position(1, 1));
    expect(damage['delta'], -1);
    expect(
      engine.state.board
          .getEntity('objects', const Position(2, 1))!
          .params['count'],
      1,
    );
    expect(
      engine.state.board
          .getEntity('objects', const Position(1, 0))!
          .params['count'],
      1,
    );
    expect(engine.state.variables['hp'], 2);
    engine.executeTurn(move('left'));
    expect(
      engine.state.board.getEntity('ground', const Position(1, 1))!.kind,
      'void',
    );
    engine.executeTurn(move('right'));
    expect(engine.state.avatar.position, const Position(0, 1));
    expect(
      engine.state.board
          .getEntity('objects', const Position(2, 1))!
          .params['count'],
      1,
    );
  });

  test('death on exit cannot win', () {
    for (final (hp, threshold) in [(1, 3), (3, 1)]) {
      final g = game();
      final engine =
          TurnEngine(g, level(g, hp: hp, threshold: threshold, terminal: true));
      final result = engine.executeTurn(move('right'));
      expect(result.isLost, isTrue);
      expect(result.isWon, isFalse);
      expect(engine.state.variables['dead'], 1);
    }
  });

  test('witness wraps after three arrivals', () {
    final g = game();
    final engine = TurnEngine(g, level(g, hp: 9, threshold: 9, fragile: false));
    for (final direction in ['right', 'left', 'right', 'left', 'right']) {
      engine.executeTurn(move(direction));
    }
    expect(
        engine.state.board
            .getEntity('objects', const Position(2, 1))!
            .params['count'],
        0);
  });

  test('safe arrival wins and undo restores counters', () {
    final g = game();
    final engine = TurnEngine(g, level(g, terminal: true));
    expect(engine.executeTurn(move('right')).isWon, isTrue);
    engine.undo();
    expect(
      engine.state.board
          .getEntity('objects', const Position(2, 1))!
          .params['count'],
      0,
    );
    expect(engine.state.variables['hp'], 3);
  });
}
