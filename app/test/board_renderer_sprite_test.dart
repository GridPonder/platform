import 'dart:ui' show Rect;

import 'package:flutter/material.dart'
    show AssetImage, CustomPaint, Image, MaterialApp, SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:gridponder_app/src/services/pack_service.dart';
import 'package:gridponder_app/src/widgets/board_renderer.dart';
import 'package:gridponder_engine/engine.dart';

EntityKindDef _actorKind() => EntityKindDef.fromJson('test_actor', {
  'layer': 'actors',
  'tags': ['actor'],
  'symbol': 'W',
  'sprite': 'assets/actors/test_actor/idle_down.png',
  'motion': {
    'sprites': {
      'idle': {
        'up': 'assets/actors/test_actor/idle_up.png',
        'down': 'assets/actors/test_actor/idle_down.png',
        'left': 'assets/actors/test_actor/idle_left.png',
        'right': 'assets/actors/test_actor/idle_right.png',
      },
      'walk': {
        'right': [
          'assets/actors/test_actor/walk_right_1.png',
          'assets/actors/test_actor/walk_right_2.png',
        ],
      },
    },
  },
});

void main() {
  testWidgets('renders a switch frame over a solid and pulses on release', (
    tester,
  ) async {
    final pack = (await tester.runAsync(
      () => PackService.load('carrot_quest'),
    ))!;
    final game = GameDefinition.fromJson({
      'layers': [
        {'id': 'ground', 'occupancy': 'zero_or_one'},
        {'id': 'objects', 'occupancy': 'zero_or_one'},
      ],
      'entityKinds': {
        'plate': {
          'layer': 'ground',
          'symbol': '_',
          'tags': ['plate'],
          'sprite': 'assets/sprites/grass.png',
          'display': {'pressedSprite': 'assets/sprites/water{channel}.png'},
        },
        'hull': {
          'layer': 'objects',
          'symbol': 'H',
          'tags': ['solid'],
          'sprite': 'assets/sprites/rock.png',
        },
        'diverter': {'layer': 'objects', 'symbol': '<'},
        'diverter_right': {'layer': 'objects', 'symbol': '>'},
      },
      'systems': [
        {
          'id': 'collapse',
          'type': 'support_collapse',
          'config': {
            'layer': 'objects',
            'switches': {
              'plateLayer': 'ground',
              'pressed': {'diverter': 'diverter_right'},
            },
          },
        },
      ],
    });
    const plate = Position(0, 0);
    final state = LevelState.fromJson(
      {
        'avatar': {'enabled': false},
      },
      Board.fromJson({
        'size': [2, 1],
      }, game.layers),
    );
    state.board.setEntity(
      'ground',
      plate,
      const EntityInstance('plate', {'channel': 4}),
    );
    state.board.setEntity('objects', plate, const EntityInstance('hull'));
    state.board.setEntity(
      'objects',
      const Position(1, 0),
      const EntityInstance('diverter', {'channel': 4}),
    );

    Future<void> show(LevelState boardState) => tester.pumpWidget(
      MaterialApp(
        home: BoardRenderer(state: boardState, game: game, packService: pack),
      ),
    );
    List<String> spriteNames() => tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => (image.image as AssetImage).assetName)
        .where((path) => path.startsWith('assets/packs/carrot_quest/'))
        .map((path) => path.split('/').last)
        .toList();

    await show(state);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);

    await show(state);
    await tester.pumpAndSettle();
    expect(spriteNames(), ['rock.png', 'water4.png']);
    expect(tester.binding.transientCallbackCount, 0);
    final initialPaintCount = find.byType(CustomPaint).evaluate().length;

    final released = state.copy()..actionCount = 1;
    released.board.setEntity('objects', plate, null);
    await show(released);
    expect(spriteNames(), ['grass.png']);
    expect(find.byType(CustomPaint), findsNWidgets(initialPaintCount + 1));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });

  test('resolves static sprite when no motion sprites are active', () {
    final kind = EntityKindDef.fromJson('wall', {
      'layer': 'ground',
      'tags': ['solid'],
      'symbol': '#',
      'sprite': 'assets/wall.png',
    });

    expect(
      resolveEntitySpritePath(kind, const EntityInstance('wall')),
      'assets/wall.png',
    );
  });

  test('resolves idle sprite from remembered facing direction', () {
    expect(
      resolveEntitySpritePath(
        _actorKind(),
        const EntityInstance('test_actor'),
        facingDirection: 'right',
      ),
      'assets/actors/test_actor/idle_right.png',
    );
  });

  test('resolves walk frame from temporary movement params', () {
    expect(
      resolveEntitySpritePath(
        _actorKind(),
        const EntityInstance('test_actor', {
          '_motionDirection': 'right',
          '_motionFrame': 1,
        }),
      ),
      'assets/actors/test_actor/walk_right_2.png',
    );
  });

  test('uses elapsed time for motion frames when configured', () {
    final kind = EntityKindDef.fromJson('cinder', {
      'layer': 'actors',
      'tags': ['npc'],
      'symbol': '&',
      'sprite': 'assets/cinder.png',
      'motion': {'frameDurationMs': 100},
    });

    expect(resolveEntityMotionFrame(kind, 0, 0), 0);
    expect(resolveEntityMotionFrame(kind, 99, 0.25), 0);
    expect(resolveEntityMotionFrame(kind, 100, 0.25), 1);
    expect(resolveEntityMotionFrame(kind, 399, 0.99), 3);
    expect(resolveEntityMotionFrame(kind, 400, 1), 4);
  });

  test('motion frames retain the legacy per-cell fallback', () {
    final kind = EntityKindDef.fromJson('crate', {
      'layer': 'objects',
      'tags': ['solid'],
      'symbol': 'C',
      'sprite': 'assets/crate.png',
    });

    expect(resolveEntityMotionFrame(kind, 399, 2.75), 2);
  });

  test('resolves a pack-local avatar fallback sprite', () {
    final theme = AvatarThemeDef.fromJson({
      'visible': true,
      'sprite': 'assets/sprites/unit.png',
    });

    expect(resolveAvatarSpriteChoice(theme, 'right'), (
      visible: true,
      path: 'assets/sprites/unit.png',
      mirrorHorizontally: false,
    ));
  });

  test('honors hidden and mirrored avatar theme entries', () {
    final hidden = AvatarThemeDef.fromJson({'visible': false});
    expect(resolveAvatarSpriteChoice(hidden, 'left'), (
      visible: false,
      path: null,
      mirrorHorizontally: false,
    ));

    final mirrored = AvatarThemeDef.fromJson({
      'sprites': {
        'idle': {
          'right': 'assets/sprites/alien_right.png',
          'left': {'mirror': 'right'},
        },
      },
    });
    expect(resolveAvatarSpriteChoice(mirrored, 'left'), (
      visible: true,
      path: 'assets/sprites/alien_right.png',
      mirrorHorizontally: true,
    ));
  });

  test('selects directional avatar walk frames while moving', () {
    final theme = AvatarThemeDef.fromJson({
      'sprites': {
        'idle': {'right': 'assets/avatar/idle_right.png'},
        'walk': {
          'right': {
            'frames': [
              'assets/avatar/walk_right_1.png',
              'assets/avatar/walk_right_2.png',
            ],
            'duration': 220,
            'mode': 'loop',
          },
        },
      },
    });

    expect(
      resolveAvatarSpriteChoice(theme, 'right', moving: true, progress: 0.2),
      (
        visible: true,
        path: 'assets/avatar/walk_right_1.png',
        mirrorHorizontally: false,
      ),
    );
    expect(
      resolveAvatarSpriteChoice(theme, 'right', moving: true, progress: 0.8),
      (
        visible: true,
        path: 'assets/avatar/walk_right_2.png',
        mirrorHorizontally: false,
      ),
    );
    expect(resolveAvatarSpriteChoice(theme, 'right'), (
      visible: true,
      path: 'assets/avatar/idle_right.png',
      mirrorHorizontally: false,
    ));
  });

  test('a cell state swaps the resting sprite and falls back to idle', () {
    final theme = AvatarThemeDef.fromJson({
      'cellStates': {'water_1': 'wading'},
      'sprites': {
        'idle': {
          'right': 'assets/avatar/idle_right.png',
          'up': 'assets/avatar/idle_up.png',
        },
        'wading': {'right': 'assets/avatar/wading_right.png'},
      },
    });

    expect(theme.cellStates, {'water_1': 'wading'});
    expect(resolveAvatarSpriteChoice(theme, 'right', cellState: 'wading'), (
      visible: true,
      path: 'assets/avatar/wading_right.png',
      mirrorHorizontally: false,
    ));
    expect(resolveAvatarSpriteChoice(theme, 'up', cellState: 'wading'), (
      visible: true,
      path: 'assets/avatar/idle_up.png',
      mirrorHorizontally: false,
    ));
  });

  test('renders board layers in the order declared by the pack', () {
    final game = GameDefinition.fromJson({
      'layers': [
        {'id': 'ground', 'occupancy': 'exactly_one', 'default': 'floor'},
        {'id': 'territory', 'occupancy': 'zero_or_one'},
        {'id': 'markers', 'occupancy': 'zero_or_one'},
        {'id': 'objects', 'occupancy': 'zero_or_one'},
      ],
    });

    expect(resolveBoardLayerOrder(game), [
      'ground',
      'territory',
      'markers',
      'objects',
    ]);
  });

  test('resolves param-driven display connections to emitter vectors', () {
    final display = <String, dynamic>{
      'connections': '@param:kernel',
      'connectionMap': {
        'h': [
          [-1, 0],
          [1, 0],
        ],
        'x': [
          [-2, -2],
          [2, 2],
        ],
      },
    };

    expect(
      resolveDisplayConnectionVectors(
        display,
        const EntityInstance('cell', {'kernel': 'h'}),
      ),
      const [Offset(-1, 0), Offset(1, 0)],
    );
    expect(
      resolveDisplayConnectionVectors(
        display,
        const EntityInstance('cell', {'kernel': 'x'}),
      ),
      const [Offset(-1, -1), Offset(1, 1)],
    );
  });

  test('resolves optional visual link target from an entity parameter', () {
    const display = <String, dynamic>{'linkTarget': '@param:switchTarget'};
    expect(
      resolveDisplayLinkTarget(
        display,
        const EntityInstance('cell', {
          'switchTarget': [2, 1],
        }),
      ),
      const Position(2, 1),
    );
    expect(
      resolveDisplayLinkTarget(display, const EntityInstance('cell')),
      isNull,
    );
  });

  test('stringifies numeric parameters for display-map keys', () {
    expect(
      resolveDisplayMapKey(
        '@param:threshold',
        const EntityInstance('cell', {'threshold': 5}),
      ),
      '5',
    );
    expect(
      resolveDisplayMapKey('fixed', const EntityInstance('cell')),
      'fixed',
    );
  });

  test('ignores malformed or missing display connections', () {
    final display = <String, dynamic>{
      'connections': '@param:kernel',
      'connectionMap': {
        'bad': [
          [0, 0],
          [1],
          ['right', 0],
        ],
      },
    };

    expect(
      resolveDisplayConnectionVectors(
        display,
        const EntityInstance('cell', {'kernel': 'bad'}),
      ),
      isEmpty,
    );
    expect(
      resolveDisplayConnectionVectors(
        display,
        const EntityInstance('cell', {'kernel': 'missing'}),
      ),
      isEmpty,
    );
  });

  test('resolves param-driven procedural display sizes', () {
    final display = <String, dynamic>{
      'size': '@param:threshold',
      'sizeMap': {'4': 0.6, '5': 0.7},
    };

    expect(
      resolveDisplaySizeFactor(
        display,
        const EntityInstance('cell', {'threshold': 4}),
        fallback: 0.5,
      ),
      0.6,
    );
    expect(
      resolveDisplaySizeFactor(
        display,
        const EntityInstance('cell', {'threshold': 5}),
        fallback: 0.5,
      ),
      0.7,
    );
    expect(
      resolveDisplaySizeFactor(
        display,
        const EntityInstance('cell', {'threshold': 6}),
        fallback: 0.5,
      ),
      0.5,
    );
  });

  test('elastic face reaches a crate before the crate starts moving', () {
    expect(
      elasticPushObjectTravel(
        blockTravel: 1.5,
        totalBlockDistance: 4,
        objectDistance: 2,
      ),
      0,
    );
    expect(
      elasticPushObjectTravel(
        blockTravel: 2.5,
        totalBlockDistance: 4,
        objectDistance: 2,
      ),
      0.5,
    );
    expect(
      elasticPushObjectTravel(
        blockTravel: 4,
        totalBlockDistance: 4,
        objectDistance: 2,
      ),
      2,
    );
  });

  test('elastic block grows only its leading edge', () {
    const start = Rect.fromLTRB(2, 3, 4, 5);

    expect(
      elasticBlockRect(start, 'right', 1.25),
      const Rect.fromLTRB(2, 3, 5.25, 5),
    );
    expect(
      elasticBlockRect(start, 'up', 0.75),
      const Rect.fromLTRB(2, 2.25, 4, 5),
    );
  });

  test('elastic block collapse interpolates the trailing edge', () {
    const start = Rect.fromLTRB(1, 2, 7, 5);
    const end = Rect.fromLTRB(6, 2, 7, 5);

    expect(
      elasticBlockRectTween(start, end, 0.5),
      const Rect.fromLTRB(3.5, 2, 7, 5),
    );
    expect(elasticBlockRectTween(start, end, 1), end);
  });
}
