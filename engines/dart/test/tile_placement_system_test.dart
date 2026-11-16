import 'package:gridponder_engine/engine.dart';
import 'package:gridponder_engine/src/systems/tile_placement_constraints.dart';
import 'package:test/test.dart';

TurnEngine engine([Map<String, dynamic> extra = const {}]) {
  final config = <String, dynamic>{
    'size': [2, 2],
    'targets': [
      [
        [0, 0],
        [1, 0],
        [0, 1],
        [1, 1]
      ]
    ],
    'pieces': [
      {
        'id': 'x',
        'kind': 'tile',
        'color': '#aa0000',
        'cells': [
          [0, 0],
          [1, 0]
        ],
        'pulse': [0, 0]
      },
      {
        'id': 'y',
        'kind': 'tile',
        'color': '#0000aa',
        'cells': [
          [0, 0],
          [1, 0]
        ]
      }
    ],
    ...extra
  };
  final game = GameDefinition.fromJson({
    'layers': [
      {'id': 'ground', 'occupancy': 'exactly_one', 'default': 'floor'},
      {'id': 'pieces', 'occupancy': 'zero_or_one'}
    ],
    'entityKinds': {
      'floor': {'layer': 'ground', 'symbol': '.'},
      'tile': {'layer': 'pieces', 'symbol': 'T'}
    },
    'actions': [
      for (final a in [
        'place_piece',
        'remove_piece',
        'next_target',
        'change_piece',
        'turn_piece',
        'rotate_piece',
        'swap_echo',
      ])
        {'id': a, 'params': <String, dynamic>{}}
    ],
    'systems': [
      {'id': 'tiles', 'type': 'tile_placement', 'config': config}
    ],
    'rules': []
  }, id: 'placement_test');
  return TurnEngine(
      game,
      LevelDefinition.fromJson({
        'id': 'test',
        'board': {'size': config['size'], 'layers': <String, dynamic>{}},
        'state': {
          'avatar': {'enabled': false}
        },
        'goals': [
          {
            'id': 'done',
            'type': 'variable_threshold',
            'config': {
              'variable': 'tiles.complete',
              'target': 1,
              'comparison': 'eq'
            }
          }
        ]
      }, game.layers));
}

bool place(TurnEngine e,
        [dynamic key = 'x', int x = 0, int y = 0, int r = 0]) =>
    e
        .executeTurn(GameAction('place_piece', {
          'piece': key,
          'position': [x, y],
          'rotation': r
        }))
        .accepted;
bool remove(TurnEngine e, String key) =>
    e.executeTurn(GameAction('remove_piece', {'piece': key})).accepted;

TurnEngine transferEngine({bool keepEdges = false}) {
  final tiles = [
    {
      'id': 'x',
      'kind': 'tile',
      'color': '#aa0000',
      'cells': [
        [0, 0],
        [1, 0]
      ]
    },
    {
      'id': 'y',
      'kind': 'tile',
      'color': '#0000aa',
      'cells': [
        [0, 0]
      ]
    },
    {
      'id': 'z',
      'kind': 'tile',
      'color': '#00aa00',
      'cells': [
        [0, 0]
      ]
    },
  ];
  if (keepEdges) {
    tiles[0]['edges'] = [
      {
        'cell': [1, 0],
        'direction': 1,
        'symbol': '1'
      }
    ];
    tiles[1]['edges'] = [
      {
        'cell': [0, 0],
        'direction': 3,
        'symbol': '1'
      }
    ];
  }
  final e = engine({
    'size': [6, 3],
    'pieces': tiles,
    'targets': [
      [
        for (var x = 0; x < 4; x++) [x, 1]
      ],
      [
        [0, 0],
        [1, 0],
        [3, 0],
        [4, 0]
      ],
    ],
    'transfer': {
      'area': [
        for (var y = 0; y < 3; y++)
          for (var x = 0; x < 6; x++)
            if (x != 2 || y != 0) [x, y]
      ],
      'maxSteps': 8,
      'maxRemovals': 1,
      'trayCapacity': 1,
      'slideOnly': true,
      'keepEdges': keepEdges,
    },
  });
  expect(place(e, 'x', 0, 1), true);
  expect(place(e, 'y', 2, 1), true);
  expect(place(e, 'z', 3, 1), true);
  expect(e.executeTurn(const GameAction('next_target', {})).accepted, true);
  return e;
}

TurnEngine insertionEngine() => engine({
      'size': [5, 4],
      'targets': [
        [
          [3, 2],
          [4, 2],
          [1, 2],
          [4, 3]
        ]
      ],
      'pieces': [
        {
          'id': 'x',
          'kind': 'tile',
          'color': '#aa0000',
          'cells': [
            [0, 0],
            [1, 0]
          ],
          'entrySide': 3
        },
        {
          'id': 'y',
          'kind': 'tile',
          'color': '#0000aa',
          'cells': [
            [0, 0]
          ],
          'entrySide': 0
        },
        {
          'id': 'z',
          'kind': 'tile',
          'color': '#00aa00',
          'cells': [
            [0, 0]
          ],
          'entrySide': 1
        },
      ],
      'insertion': {
        'area': [
          for (var y = 0; y < 4; y++)
            for (var x = 0; x < 5; x++)
              if (x != 2 || y != 0) [x, y]
        ],
      },
    });

void main() {
  test('paired turns are atomic and tray pieces retain their orientation', () {
    final e = engine({
      'size': [6, 4],
      'targets': [
        [
          [0, 0],
          [1, 0],
          [3, 0],
          [4, 0],
          [5, 3]
        ]
      ],
      'pieces': [
        for (final k in ['x', 'y', 'z'])
          {
            'id': k,
            'kind': 'tile',
            'color': '#aa0000',
            'cells': k == 'z'
                ? [
                    [0, 0]
                  ]
                : [
                    [0, 0],
                    [1, 0]
                  ]
          }
      ],
      'playArea': [
        for (var y = 0; y < 4; y++)
          for (var x = 0; x < 6; x++) [x, y]
      ],
      'rotationLinks': [
        ['x', 'y']
      ],
      'requirePairedTurn': true,
    });
    bool turn(String key) =>
        e.executeTurn(GameAction('turn_piece', {'piece': key})).accepted;
    expect(place(e, 'x', 0, 0), true);
    expect(place(e, 'y', 3, 0), true);
    expect(turn('x'), true);
    expect((e.state.variables['tiles.placements'] as Map)['y'], [3, 0, 1]);
    expect(place(e, 'z', 4, 0), true);
    final before = e.state.copy(), depth = e.undoDepth;
    expect(turn('x'), false);
    expect(e.state.variables, before.variables);
    expect(e.undoDepth, depth);
    expect(remove(e, 'z'), true);
    expect(remove(e, 'y'), true);
    expect((e.state.variables['tiles.orientations'] as Map)['y'], 1);
    expect(turn('y'), true);
    expect((e.state.variables['tiles.placements'] as Map)['x'], [0, 0, 2]);
    expect(place(e, 'y', 3, 0, 0), false);
    expect(place(e, 'y', 3, 0, 2), true);
    expect(place(e, 'z', 5, 3), true);
    expect(e.isWon, true);
    e.reset();
    expect((e.state.variables['tiles.orientations'] as Map)['x'], 0);
    expect(e.state.variables['tiles.pairedTurned'], 0);
  });
  test('linked rotation normalizes a non-square selected piece', () {
    final c = <String, dynamic>{
      'pieces': [
        {
          'id': 'x',
          'cells': [
            [0, 0],
            [0, 1],
            [1, 1]
          ],
          'edges': [
            {
              'cell': [0, 0],
              'direction': 1,
              'symbol': '1'
            }
          ]
        },
        {
          'id': 'y',
          'cells': [
            [0, 0],
            [1, 0]
          ],
          'edges': [
            {
              'cell': [0, 0],
              'direction': 3,
              'symbol': '1'
            }
          ]
        },
      ],
      'linkedMovement': {'releaseCells': []},
    };
    expect(
        TilePlacementSystem.linkedPlacements(
            c,
            {
              'x': [2, 1, 0],
              'y': [3, 1, 0]
            },
            'x',
            [1, 2, 1]),
        {
          'x': [1, 2, 1],
          'y': [2, 3, 1]
        });
  });
  test('linked pieces rotate atomically and separate on a release cell', () {
    final e = engine({
      'size': [5, 4],
      'targets': [
        [
          [0, 0],
          [1, 0],
          [4, 3]
        ]
      ],
      'pieces': [
        {
          'id': 'x',
          'kind': 'tile',
          'color': '#aa0000',
          'cells': [
            [0, 0]
          ],
          'edges': [
            {
              'cell': [0, 0],
              'direction': 1,
              'symbol': '1'
            }
          ]
        },
        {
          'id': 'y',
          'kind': 'tile',
          'color': '#0000aa',
          'cells': [
            [0, 0]
          ],
          'edges': [
            {
              'cell': [0, 0],
              'direction': 3,
              'symbol': '1'
            }
          ]
        },
        {
          'id': 'z',
          'kind': 'tile',
          'color': '#00aa00',
          'cells': [
            [0, 0]
          ]
        },
      ],
      'playArea': [
        for (var y = 0; y < 4; y++)
          for (var x = 0; x < 5; x++) [x, y]
      ],
      'linkedMovement': {
        'releaseCells': [
          [2, 2]
        ],
        'requireMove': true,
        'requireRelease': true
      },
    });
    expect(place(e, 'x', 0, 0), true);
    expect(place(e, 'y', 1, 0), true);
    expect(remove(e, 'x'), false);
    expect(place(e, 'x', 1, 1, 1), true);
    expect((e.state.variables['tiles.placements'] as Map)['y'], [1, 2, 1]);
    final before = e.state.copy();
    expect(place(e, 'x', 4, 3, 1), false);
    expect(e.state.variables, before.variables);
    expect(place(e, 'x', 2, 2, 0), true);
    expect(e.state.variables['tiles.linkReleased'], 1);
    expect(remove(e, 'x'), true);
    e.undo();
    e.undo();
    expect(e.state.variables['tiles.linkReleased'], 0);
  });
  test(
      'workshop changes geometry; blocked changes roll back; Return resets form',
      () {
    final e = engine({
      'size': [5, 3],
      'targets': [
        [
          [2, 2],
          [3, 2],
          [4, 2],
          [4, 0]
        ]
      ],
      'pieces': [
        {
          'id': 'x',
          'kind': 'tile',
          'color': '#aa0000',
          'cells': [
            [0, 0],
            [0, 1],
            [1, 1]
          ],
          'variants': [
            {
              'cells': [
                [0, 0],
                [0, 1],
                [1, 1]
              ]
            },
            {
              'cells': [
                [0, 0],
                [1, 0],
                [2, 0]
              ]
            }
          ],
          'requiredVariant': 1
        },
        {
          'id': 'y',
          'kind': 'tile',
          'color': '#0000aa',
          'cells': [
            [0, 0]
          ]
        },
      ],
      'playArea': [
        for (var y = 0; y < 3; y++)
          for (var x = 0; x < 5; x++) [x, y]
      ],
      'variantCells': [
        [0, 0]
      ],
    });
    bool change() => e
        .executeTurn(const GameAction('change_piece', {'piece': 'x'}))
        .accepted;
    expect(place(e, 'x', 2, 0), true);
    expect(change(), false);
    expect(place(e, 'x', 0, 0), true);
    expect(place(e, 'y', 2, 0), true);
    final before = e.state.copy();
    expect(change(), false);
    expect(e.state.variables, before.variables);
    expect(remove(e, 'y'), true);
    expect(change(), true);
    expect((e.state.variables['tiles.forms'] as Map)['x'], 1);
    expect(remove(e, 'x'), true);
    expect((e.state.variables['tiles.forms'] as Map)['x'], 0);
    expect(place(e, 'x', 0, 0), true);
    expect(change(), true);
    expect(place(e, 'x', 2, 2), true);
    expect(place(e, 'y', 4, 0), true);
    expect(e.isWon, true);
  });
  test('placements and removals cannot seal disconnected empty pockets', () {
    final e = engine({
      'size': [5, 5],
      'targets': [
        [
          [2, 1],
          [1, 2],
          [3, 2],
          [2, 3],
          [2, 2],
          [4, 4]
        ]
      ],
      'pieces': [
        for (final key in ['a', 'b', 'c', 'd', 'e', 'f'])
          {
            'id': key,
            'kind': 'tile',
            'color': '#aa0000',
            'cells': [
              [0, 0]
            ]
          }
      ],
      'playArea': [
        for (var y = 0; y < 5; y++)
          for (var x = 0; x < 5; x++) [x, y]
      ],
      'freeSpace': true,
    });
    expect(place(e, 'a', 2, 1), true);
    expect(place(e, 'b', 1, 2), true);
    expect(place(e, 'c', 3, 2), true);
    final before = e.state.copy();
    expect(place(e, 'd', 2, 3), false);
    expect(e.state.variables, before.variables);
    expect(place(e, 'e', 2, 2), true);
    expect(place(e, 'd', 2, 3), true);
    expect(remove(e, 'e'), false);
    expect(place(e, 'f', 4, 4), true);
    expect(e.isWon, true);
    expect(e.state.variables['tiles.freeRegions'], 1);
  });
  test('side entry enforces clear routes and reversible extraction', () {
    final e = insertionEngine();
    expect(place(e, 'y', 2, 2), false);
    expect(place(e, 'y', 1, 2), true);
    final before = e.state.copy(), depth = e.undoDepth;
    expect(place(e, 'x', 3, 2), false);
    expect(e.state.variables, before.variables);
    expect(e.undoDepth, depth);
    expect(place(e, 'x', 0, 1), true);
    expect(remove(e, 'y'), false);
    expect(place(e, 'x', 0, 1, 1), false);
    expect(place(e, 'x', 3, 3), false);
    expect(remove(e, 'x'), true);
    expect(remove(e, 'y'), true);
    expect(place(e, 'x', 3, 2), true);
    expect(place(e, 'y', 1, 2), true);
    expect(remove(e, 'x'), false);
    expect(place(e, 'z', 4, 3), true);
    expect(e.isWon, true);
    expect(e.undo(), true);
    expect(e.isWon, false);
    e.reset();
    expect(e.state.variables['tiles.placements'] as Map? ?? {}, isEmpty);
  });
  test('column sums are required even when a complete board matches every row',
      () {
    final e = engine({
      'pieces': [
        for (var i = 0; i < 4; i++)
          {
            'id': ['a', 'b', 'c', 'd'][i],
            'kind': 'tile',
            'color': '#aa0000',
            'value': i.isEven ? 1 : 2,
            'cells': [
              [0, 0]
            ],
          },
      ],
      'rowTotals': [3, 3],
      'columnTotals': [3, 3],
    });
    expect(place(e, 'a', 0, 0), true);
    expect(place(e, 'b', 1, 0), true);
    expect(place(e, 'c', 0, 1), true);
    expect(place(e, 'd', 1, 1), true);
    expect(e.state.variables['tiles.rowErrors'], 0);
    expect(e.state.variables['tiles.columnSums'], [2, 4]);
    expect(e.state.variables['tiles.columnErrors'], 2);
    expect(e.isWon, false);
    expect(remove(e, 'c'), true);
    expect(place(e, 'd', 0, 1), true);
    expect(place(e, 'c', 1, 1), true);
    expect(e.state.variables['tiles.columnSums'], [3, 3]);
    expect(e.isWon, true);
    expect(e.undo(), true);
    expect(e.isWon, false);
    e.reset();
    expect(e.state.variables['tiles.columnSums'], [0, 0]);
  });
  test('transfer limits enforce swept slides, tray replacement and undo', () {
    final e = transferEngine();
    var before = e.state.copy();
    final depth = e.undoDepth;
    expect(place(e, 'x', 4, 1), false);
    expect(place(e, 'x', 4, 0), false);
    expect(place(e, 'x', 0, 1, 1), false);
    expect(e.state.variables, before.variables);
    expect(e.undoDepth, depth);
    expect(place(e, 'x', 0, 2), true);
    expect(place(e, 'x', 2, 2), true);
    expect(e.state.variables['tiles.transferSteps'], 3);
    expect(remove(e, 'y'), true);
    before = e.state.copy();
    expect(remove(e, 'z'), false);
    expect(place(e, 'y', 2, 0), false);
    expect(e.state.variables, before.variables);
    expect(place(e, 'y', 0, 2), true);
    expect(remove(e, 'z'), false);
    expect(place(e, 'z', 4, 1), true);
    expect(place(e, 'z', 5, 1), true);
    expect(place(e, 'z', 5, 2), true);
    expect(e.state.variables['tiles.transferSteps'], 8);
    before = e.state.copy();
    expect(place(e, 'x', 3, 2), false);
    expect(e.state.variables, before.variables);
    expect(e.undo(), true);
    expect(e.state.variables['tiles.transferSteps'], 7);
    expect(e.state.variables['tiles.removalsUsed'], 1);
  });
  test('transfer connections remain joined and undo restores allowances', () {
    final e = transferEngine(keepEdges: true), before = e.state.copy();
    expect(place(e, 'x', 0, 2), false);
    expect(remove(e, 'x'), false);
    expect(e.state.variables, before.variables);
    expect(remove(e, 'z'), true);
    expect(e.state.variables['tiles.removalsUsed'], 1);
    expect(e.undo(), true);
    expect(e.state.variables['tiles.removalsUsed'], 0);
    expect(e.state.variables['tiles.transferSteps'], 0);
    e.reset();
    expect(e.state.variables['tiles.transferSteps'], 0);
  });
  test('numeric row goals prevent winning with a full but wrong tiling', () {
    final tiles = [
      for (var i = 0; i < 2; i++)
        {
          'id': ['x', 'y'][i],
          'kind': 'tile',
          'color': '#aa0000',
          'value': [2, 5][i],
          'cells': [
            [0, 0],
            [1, 0]
          ]
        }
    ];
    final e = engine({
      'pieces': tiles,
      'rowTotals': [4, 10]
    });
    for (var x = 0; x < 2; x++) {
      expect(place(e, ['x', 'y'][x], x, 0, 1), true);
    }
    expect(e.state.variables['tiles.rowSums'], [7, 7]);
    expect(e.isWon, false);
    e.reset();
    place(e);
    place(e, 'y', 0, 1);
    expect(e.state.variables['tiles.rowSums'], [4, 10]);
    expect(e.isWon, true);
    e.undo();
    expect(e.isWon, false);
  });
  test(
      'unsupported placement and support removal leave state and history unchanged',
      () {
    final tiles = [
      for (final id in ['x', 'y', 'z'])
        {
          'id': id,
          'kind': 'tile',
          'color': '#aa0000',
          'cells': [
            [0, 0],
            [1, 0]
          ]
        }
    ];
    final e = engine({
      'size': [2, 3],
      'pieces': tiles,
      'targets': [
        [
          for (var y = 0; y < 3; y++)
            for (var x = 0; x < 2; x++) [x, y]
        ]
      ],
      'support': true
    });
    expect(place(e), false);
    expect(place(e, 'x', 0, 2), true);
    expect(place(e, 'y', 0, 1), true);
    final before = e.state.copy(), depth = e.undoDepth;
    expect(remove(e, 'x'), false);
    expect(place(e, 'x', 0, 0), false);
    expect(e.state.variables, before.variables);
    expect(e.undoDepth, depth);
    expect(remove(e, 'y'), true);
    e.undo();
    expect(place(e, 'z', 0, 0), true);
    expect(e.isWon, true);
  });
  test('support allows rigid overhangs but not ungrounded cycles', () {
    expect(
        unsupportedTiles({
          const Position(0, 2): 'x',
          const Position(0, 1): 'y',
          const Position(1, 1): 'y'
        }, 2),
        []);
    expect(
        unsupportedTiles({
          const Position(0, 0): 'x',
          const Position(0, 1): 'y',
          const Position(1, 0): 'y',
          const Position(1, 1): 'x'
        }, 2),
        ['x', 'y']);
  });
  test(
      'overlapping pulse contributions cancel; removing one restores the other',
      () {
    final e = engine({
      'pieces': [
        for (final id in ['x', 'y'])
          {
            'id': id,
            'kind': 'tile',
            'color': '#aa0000',
            'cells': [
              [0, 0],
              [1, 0]
            ],
            'pulse': [0, 0]
          }
      ],
      'lights': {
        'initial': [],
        'target': [
          [0, 0]
        ]
      }
    });
    place(e);
    place(e, 'y', 0, 1, 2);
    expect(e.state.variables['tiles.lights'], []);
    expect(remove(e, 'y'), true);
    expect(e.state.variables['tiles.lights'], [
      [0, 1],
      [1, 0]
    ]);
  });
  test('rotation transforms edge location and direction', () {
    final p = {
      'cells': [
        [0, 0],
        [1, 0]
      ],
      'edges': [
        {
          'cell': [1, 0],
          'direction': 1,
          'symbol': 'o'
        }
      ]
    };
    expect(TilePlacementSystem.cells(p, [0, 0, 1]),
        [const Position(0, 0), const Position(0, 1)]);
    expect(TilePlacementSystem.edges(p, [0, 0, 1]), [
      {'position': const Position(0, 1), 'direction': 2, 'symbol': 'o'}
    ]);
  });
  test('invalid actions preserve state and undo history', () {
    final e = engine();
    expect(place(e, 'x', 1), false);
    expect(place(e, 'x', 0, 0, 4), false);
    expect(place(e, []), false);
    expect(place(e), true);
    expect(place(e, 'y'), false);
    expect(e.undoDepth, 1);
    expect(e.undo(), true);
    expect(e.state.variables['tiles.filled'], 0);
  });
  test('light effects reverse on removal, undo and reset', () {
    final e = engine({
      'lights': {
        'initial': [],
        'target': [
          [1, 0],
          [0, 1]
        ]
      }
    });
    expect(place(e), true);
    expect(e.state.variables['tiles.lightErrors'], 0);
    expect(remove(e, 'x'), true);
    expect(e.state.variables['tiles.lights'], []);
    e.undo();
    expect(e.state.variables['tiles.lightErrors'], 0);
    expect(place(e, 'y', 0, 1), true);
    expect(e.isWon, true);
    e.reset();
    expect(e.isWon, false);
    expect(e.state.variables['tiles.filled'], 0);
  });
  test('colour clues reject wrong piece', () {
    final e = engine({
      'markers': [
        {
          'position': [0, 0],
          'color': '#0000aa'
        }
      ]
    });
    expect(place(e), false);
    expect(place(e, 'y'), true);
  });
  test(
      'stage transition carries pieces; distinct-piece budget includes removals',
      () {
    final target = [
      [0, 0],
      [1, 0],
      [0, 1],
      [1, 1]
    ];
    final e = engine({
      'size': [2, 3],
      'targets': [
        target,
        [
          [0, 1],
          [1, 1],
          [0, 2],
          [1, 2]
        ]
      ],
      'maxMoved': 1
    });
    expect(e.executeTurn(GameAction('next_target')).accepted, false);
    place(e);
    place(e, 'y', 0, 1);
    expect(e.isWon, false);
    expect(e.executeTurn(GameAction('next_target')).accepted, true);
    expect((e.state.variables['tiles.placements'] as Map).length, 2);
    expect(remove(e, 'x'), true);
    expect(remove(e, 'y'), false);
    expect(place(e, 'x', 0, 2), true);
    expect(e.isWon, true);
    e.undo();
    e.undo();
    expect(e.state.variables['tiles.moved'], []);
  });
  test('contact web counts distinct neighbors and rejects wrong full fits', () {
    final e = engine({
      'size': [2, 3],
      'pieces': [
        for (final k in ['x', 'y', 'z'])
          {
            'id': k,
            'kind': 'tile',
            'cells': [
              [0, 0],
              [1, 0]
            ]
          }
      ],
      'targets': [
        [
          for (var y = 0; y < 3; y++)
            for (var x = 0; x < 2; x++) [x, y]
        ]
      ],
      'neighborCounts': {'x': 1, 'y': 2, 'z': 1},
      'forbiddenContacts': [
        ['x', 'z']
      ]
    });
    expect(place(e, 'x', 0, 0), true);
    expect(place(e, 'z', 0, 1), true);
    expect(place(e, 'y', 0, 2), true);
    expect(e.isWon, false);
    expect(e.state.variables['tiles.contactErrors'], 3);
    expect(e.state.variables['tiles.neighborCounts'], {'x': 1, 'y': 1, 'z': 2});
    e.undo();
    e.undo();
    expect(place(e, 'y', 0, 1), true);
    expect(place(e, 'z', 0, 2), true);
    expect(e.isWon, true);
    expect(e.state.variables['tiles.contactErrors'], 0);
    e.reset();
    expect(e.state.variables['tiles.neighborCounts'], {'x': 0, 'y': 0, 'z': 0});
  });
  test('contact web ignores corners', () {
    final e = engine({
      'pieces': [
        for (final k in ['x', 'y'])
          {
            'id': k,
            'kind': 'tile',
            'cells': [
              [0, 0]
            ]
          }
      ],
      'targets': [
        [
          [0, 0],
          [1, 1]
        ]
      ],
      'neighborCounts': {'x': 0, 'y': 0},
      'forbiddenContacts': [
        ['x', 'y']
      ]
    });
    expect(place(e), true);
    expect(place(e, 'y', 1, 1), true);
    expect(e.isWon, true);
  });
  test('transfer sweeps every linked member and keeps matching edges', () {
    final e = engine({
      'size': [5, 2],
      'pieces': [
        {
          'id': 'x',
          'kind': 'tile',
          'cells': [
            [0, 0]
          ],
          'edges': [
            {
              'cell': [0, 0],
              'direction': 2,
              'symbol': '1'
            }
          ]
        },
        {
          'id': 'y',
          'kind': 'tile',
          'cells': [
            [0, 0]
          ],
          'edges': [
            {
              'cell': [0, 0],
              'direction': 0,
              'symbol': '1'
            }
          ]
        },
        {
          'id': 'z',
          'kind': 'tile',
          'cells': [
            [0, 0]
          ]
        }
      ],
      'targets': [
        [
          [0, 0],
          [0, 1],
          [1, 1]
        ],
        [
          [2, 0],
          [2, 1],
          [4, 1]
        ]
      ],
      'linkedMovement': <String, dynamic>{},
      'transfer': {
        'area': [
          for (var y = 0; y < 2; y++)
            for (var x = 0; x < 5; x++) [x, y]
        ],
        'maxSteps': 8,
        'maxRemovals': 1,
        'trayCapacity': 1,
        'slideOnly': true,
        'keepEdges': true
      }
    });
    expect(place(e), true);
    expect(place(e, 'y', 0, 1), true);
    expect(place(e, 'z', 1, 1), true);
    expect(e.executeTurn(GameAction('next_target')).accepted, true);
    final before = e.state.copy();
    final depth = e.undoDepth;
    expect(place(e, 'x', 2, 0), false);
    expect(e.state.variables, before.variables);
    expect(e.undoDepth, depth);
    expect(place(e, 'z', 4, 1), true);
    expect(place(e, 'x', 2, 0), true);
    expect((e.state.variables['tiles.placements'] as Map)['y'], [2, 1, 0]);
    expect(e.state.variables['tiles.edgeErrors'], 0);
    expect(e.state.variables['tiles.transferSteps'], 5);
    expect(e.isWon, true);
    e.undo();
    expect((e.state.variables['tiles.placements'] as Map)['y'], [0, 1, 0]);
    expect(e.state.variables['tiles.transferSteps'], 3);
  });
  test('echo translation opposite turns and partner failures are atomic', () {
    final e = engine({
      'size': [7, 5],
      'pieces': [
        {
          'id': 'x',
          'kind': 'tile',
          'cells': [
            [0, 0],
            [0, 1],
            [1, 1]
          ]
        },
        {
          'id': 'y',
          'kind': 'tile',
          'cells': [
            [0, 0],
            [1, 0]
          ]
        },
        {
          'id': 'z',
          'kind': 'tile',
          'cells': [
            [0, 0]
          ]
        }
      ],
      'playArea': [
        for (var y = 0; y < 5; y++)
          for (var x = 0; x < 7; x++) [x, y]
      ],
      'echoLinks': [
        ['x', 'y']
      ]
    });
    expect(place(e, 'x', 0, 1), true);
    expect(place(e, 'y', 4, 1), true);
    expect(place(e, 'x', 1, 2, 1), true);
    expect(e.state.variables['tiles.placements'], {
      'x': [1, 2, 1],
      'y': [5, 2, 3]
    });
    expect(place(e, 'y', 4, 1, 0), true);
    expect(e.state.variables['tiles.placements'], {
      'x': [0, 1, 0],
      'y': [4, 1, 0]
    });
    final before = e.state.copy();
    final depth = e.undoDepth;
    expect(place(e, 'x', 3, 1), false);
    expect(e.state.variables, before.variables);
    expect(e.undoDepth, depth);
    expect(remove(e, 'y'), false);
    expect(e.state.variables, before.variables);
    expect(place(e, 'z', 5, 2), true);
    final blocked = e.state.copy();
    expect(place(e, 'x', 1, 1, 1), false);
    expect(e.state.variables, blocked.variables);
    e.undo();
    e.undo();
    expect(e.state.variables['tiles.placements'], {
      'x': [1, 2, 1],
      'y': [5, 2, 3]
    });
    e.reset();
    expect(e.state.variables['tiles.placements'], isNull);
  });
  test('echo partners cannot overlap after opposite turns', () {
    final e = engine({
      'size': [7, 5],
      'pieces': [
        for (final k in ['x', 'y'])
          {
            'id': k,
            'kind': 'tile',
            'cells': [
              [0, 0],
              [1, 0],
              [2, 0]
            ]
          }
      ],
      'playArea': [
        for (var y = 0; y < 5; y++)
          for (var x = 0; x < 7; x++) [x, y]
      ],
      'echoLinks': [
        ['x', 'y']
      ]
    });
    expect(place(e, 'x', 0, 0, 1), true);
    expect(place(e, 'y', 2, 0, 1), true);
    final before = e.state.copy();
    final depth = e.undoDepth;
    expect(place(e, 'x', 0, 0, 2), false);
    expect(e.state.variables, before.variables);
    expect(e.undoDepth, depth);
  });
  test(
      'action budgets charge Rotate presses, reject bypasses and undo correctly',
      () {
    final e = engine({
      'limits': {'moves': 1, 'rotations': 1}
    });
    expect(
        e
            .executeTurn(const GameAction('rotate_piece', {'piece': 'x'}))
            .accepted,
        true);
    expect(e.state.variables['tiles.rotationsUsed'], 1);
    final before = e.state.copy();
    final depth = e.undoDepth;
    expect(
        e
            .executeTurn(const GameAction('rotate_piece', {'piece': 'x'}))
            .accepted,
        false);
    expect(e.state.variables, before.variables);
    expect(e.undoDepth, depth);
    expect(place(e, 'x', 0, 0, 0), false);
    expect(e.state.variables, before.variables);
    expect(place(e, 'x', 0, 0, 1), true);
    expect(e.state.variables['tiles.movesUsed'], 1);
    final committed = e.state.copy();
    expect(place(e, 'y', 1, 0, 1), false);
    expect(e.state.variables, committed.variables);
    e.undo();
    expect(e.state.variables['tiles.movesUsed'], 0);
    expect(e.state.variables['tiles.rotationsUsed'], 1);
    e.undo();
    expect(e.state.variables['tiles.rotationsUsed'], 0);
    expect((e.state.variables['tiles.previewRotations'] as Map)['x'], 0);
    e.reset();
    expect(e.state.variables['tiles.movesUsed'], 0);
  });
  test(
      'unused inventory accepts any valid subset rather than tagged required pieces',
      () {
    final e = engine({
      'pieces': [
        {
          'id': 'x',
          'kind': 'tile',
          'cells': [
            [0, 0],
            [1, 0]
          ]
        },
        {
          'id': 'y',
          'kind': 'tile',
          'cells': [
            [0, 0],
            [1, 0]
          ]
        },
        {
          'id': 'z',
          'kind': 'tile',
          'cells': [
            [0, 0]
          ]
        },
        {
          'id': 'w',
          'kind': 'tile',
          'cells': [
            [0, 0]
          ]
        }
      ],
      'allowUnused': true,
      'limits': {'moves': 3, 'rotations': 2}
    });
    expect(place(e), true);
    expect(place(e, 'z', 0, 1), true);
    expect(place(e, 'w', 1, 1), true);
    expect(e.isWon, true);
    expect(
        (e.state.variables['tiles.placements'] as Map).containsKey('y'), false);
    expect(e.state.variables['tiles.movesUsed'], 3);
  });
  test('unused inventory cannot bypass displayed port or echo requirements',
      () {
    for (final mode in ['ports', 'echo']) {
      final tiles = [
        for (final k in ['x', 'y', 'z', 'w'])
          <String, dynamic>{
            'id': k,
            'kind': 'tile',
            'cells': [
              [0, 0]
            ]
          }
      ];
      final config = <String, dynamic>{
        'pieces': tiles,
        'allowUnused': true,
        'targets': [
          [
            [0, 0],
            [1, 0]
          ]
        ]
      };
      if (mode == 'ports') {
        tiles[0]['edges'] = [
          {
            'cell': [0, 0],
            'direction': 1,
            'symbol': '1'
          }
        ];
        tiles[1]['edges'] = [
          {
            'cell': [0, 0],
            'direction': 3,
            'symbol': '1'
          }
        ];
      } else {
        config['echoLinks'] = [
          ['x', 'y']
        ];
      }
      final e = engine(config);
      expect(place(e, 'z'), true);
      expect(place(e, 'w', 1, 0), true);
      expect(e.isWon, false);
      e.undo();
      e.undo();
      expect(place(e), true);
      expect(place(e, 'y', 1, 0), true);
      expect(e.isWon, true);
    }
  });
  test('unused inventory does not consume the transfer tray slot', () {
    final e = engine({
      'size': [3, 2],
      'pieces': [
        for (final k in ['x', 'y'])
          {
            'id': k,
            'kind': 'tile',
            'cells': [
              [0, 0],
              [1, 0]
            ]
          },
        {
          'id': 'z',
          'kind': 'tile',
          'cells': [
            [0, 0],
            [0, 1],
            [1, 1]
          ]
        }
      ],
      'allowUnused': true,
      'targets': [
        [
          [0, 0],
          [1, 0],
          [0, 1],
          [1, 1]
        ],
        [
          [1, 0],
          [2, 0],
          [1, 1],
          [2, 1]
        ]
      ],
      'transfer': {
        'area': [
          for (var y = 0; y < 2; y++)
            for (var x = 0; x < 3; x++) [x, y]
        ],
        'maxSteps': 8,
        'maxRemovals': 1,
        'trayCapacity': 1,
        'slideOnly': true
      }
    });
    expect(place(e), true);
    expect(place(e, 'y', 0, 1), true);
    expect(e.executeTurn(const GameAction('next_target')).accepted, true);
    expect(e.state.variables['tiles.transferRoster'], ['x', 'y']);
    expect(remove(e, 'x'), true);
    final before = e.state.copy();
    expect(remove(e, 'y'), false);
    expect(e.state.variables, before.variables);
    expect(place(e, 'x', 1, 0), true);
    expect(place(e, 'y', 1, 1), true);
    expect(e.isWon, true);
    expect(e.state.variables['tiles.transferSteps'], 3);
  });
  test('echo swap commits previews, costs one move and restores on Undo', () {
    final e = engine({
      'size': [7, 4],
      'pieces': [
        {
          'id': 'x',
          'kind': 'tile',
          'cells': [
            [0, 0],
            [0, 1],
            [1, 1]
          ]
        },
        {
          'id': 'y',
          'kind': 'tile',
          'cells': [
            [0, 0],
            [1, 0]
          ]
        }
      ],
      'playArea': [
        for (var y = 0; y < 4; y++)
          for (var x = 0; x < 7; x++) [x, y]
      ],
      'echoLinks': [
        ['x', 'y']
      ],
      'echoSwap': true,
      'limits': {'moves': 3, 'rotations': 2}
    });
    expect(place(e), true);
    expect(place(e, 'y', 4, 1), true);
    expect(
        e
            .executeTurn(const GameAction('rotate_piece', {'piece': 'x'}))
            .accepted,
        true);
    expect(
        e.executeTurn(const GameAction('swap_echo', {'piece': 'x'})).accepted,
        true);
    expect(e.state.variables['tiles.placements'], {
      'x': [4, 1, 1],
      'y': [0, 0, 3]
    });
    expect(e.state.variables['tiles.movesUsed'], 3);
    expect(e.state.variables['tiles.rotationsUsed'], 1);
    expect(e.state.variables['tiles.echoSwaps'], 1);
    final before = e.state.copy();
    final depth = e.undoDepth;
    expect(
        e.executeTurn(const GameAction('swap_echo', {'piece': 'y'})).accepted,
        false);
    expect(e.state.variables, before.variables);
    expect(e.undoDepth, depth);
    e.undo();
    expect(e.state.variables['tiles.placements'], {
      'x': [0, 0, 0],
      'y': [4, 1, 0]
    });
    expect(e.state.variables['tiles.echoSwaps'], 0);
    expect(e.state.variables['tiles.rotationsUsed'], 1);
    e.reset();
    expect(e.state.variables['tiles.echoSwaps'], 0);
  });
  test('echo swap rejects a blocked partner without changing state', () {
    final e = engine({
      'size': [6, 3],
      'pieces': [
        {
          'id': 'x',
          'kind': 'tile',
          'cells': [
            [0, 0],
            [1, 0]
          ]
        },
        {
          'id': 'y',
          'kind': 'tile',
          'cells': [
            [0, 0]
          ]
        }
      ],
      'playArea': [
        for (var y = 0; y < 3; y++)
          for (var x = 0; x < 6; x++) [x, y]
      ],
      'echoLinks': [
        ['x', 'y']
      ],
      'echoSwap': true
    });
    expect(place(e), true);
    expect(place(e, 'y', 5, 1), true);
    final before = e.state.copy();
    final depth = e.undoDepth;
    expect(
        e.executeTurn(const GameAction('swap_echo', {'piece': 'x'})).accepted,
        false);
    expect(e.state.variables, before.variables);
    expect(e.undoDepth, depth);
  });
}
