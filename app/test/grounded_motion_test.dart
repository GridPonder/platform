import 'package:flutter_test/flutter_test.dart';
import 'package:gridponder_app/src/animation/motion_board.dart';
import 'package:gridponder_engine/engine.dart';

void main() {
  test('grounded walkers do not fall south; physical drops keep gravity', () {
    final walker = EntityKindDef.fromJson('walker', {
      'layer': 'patrols',
      'symbol': 'R',
      'motion': {'fallOnDown': false},
    });
    expect(
      isFallingMove(walker, const Position(0, 0), const Position(0, 1)),
      isFalse,
    );
    expect(
      isFallingMove(null, const Position(0, 0), const Position(0, 1)),
      isTrue,
    );
    expect(
      isFallingMove(null, const Position(0, 1), const Position(0, 0)),
      isFalse,
    );
  });

  test('group timing honours walker gait regardless of event order', () {
    final pawn = AnimationStep.entityMove(
      const Position(0, 0),
      const Position(1, 0),
      'pawn',
      'actors',
      durationMs: 110,
    );
    final walker = AnimationStep.entityMove(
      const Position(0, 1),
      const Position(1, 1),
      'walker',
      'patrols',
      durationMs: 160,
    );
    expect(groupMoveDuration([pawn, walker]), 160);
    expect(groupMoveDuration([walker, pawn]), 160);
  });

  test(
    'patrol and inverted mirror animate on their own layer without ghosts',
    () {
      final game = GameDefinition.fromJson({
        'layers': [
          {'id': 'ground', 'occupancy': 'exactly_one', 'default': 'floor'},
          {'id': 'actors', 'occupancy': 'zero_or_one'},
          {'id': 'patrols', 'occupancy': 'zero_or_one'},
        ],
        'entityKinds': {
          'floor': {
            'layer': 'ground',
            'symbol': '.',
            'tags': ['walkable'],
          },
          'pawn': {'layer': 'actors', 'symbol': 'B'},
          'patrol': {'layer': 'patrols', 'symbol': 'R'},
          'mirror': {'layer': 'patrols', 'symbol': 'Q'},
        },
        'actions': [
          {
            'id': 'move',
            'params': {
              'direction': {'type': 'direction'},
            },
          },
        ],
        'systems': [
          {
            'id': 'march',
            'type': 'coupled_actors',
            'config': {'actorLayer': 'actors'},
          },
          {
            'id': 'raid',
            'type': 'coupled_actors',
            'config': {
              'actorLayer': 'patrols',
              'directionTransforms': {'mirror': 'invert'},
            },
          },
        ],
      }, id: 'walker_motion');
      final level = LevelDefinition.fromJson({
        'id': 'motion',
        'board': {
          'size': [4, 2],
          'layers': {
            'actors': {
              'format': 'sparse',
              'entries': [
                {
                  'position': [0, 0],
                  'kind': 'pawn',
                },
              ],
            },
            'patrols': {
              'format': 'sparse',
              'entries': [
                {
                  'position': [0, 1],
                  'kind': 'patrol',
                },
                {
                  'position': [3, 1],
                  'kind': 'mirror',
                },
              ],
            },
          },
        },
        'goals': [],
        'loseConditions': [],
      }, game.layers);
      final engine = TurnEngine(game, level);
      final result = engine.executeTurn(
        const GameAction('move', {'direction': 'right'}),
      );
      expect(result.accepted, isTrue);
      final moves = result.animations
          .where((step) => step.type == 'entity_move')
          .toList();
      expect(moves.length, 3);
      for (final move in moves) {
        expect(
          move.extra['layer'],
          move.entityKind == 'pawn' ? 'actors' : 'patrols',
        );
      }
      final mirror = moves.singleWhere((move) => move.entityKind == 'mirror');
      expect(mirror.extra['from'], [3, 1]);
      expect(mirror.position, const Position(2, 1));
      final shown = boardDuringMotion(
        result.newState,
        inFlight: [
          for (final move in moves)
            TravellingEntity(
              from: Position.fromJson(move.extra['from']),
              to: move.position,
              layer: move.extra['layer'],
              entity: EntityInstance(move.entityKind!),
            ),
        ],
      );
      expect(shown.board.layers['actors']!.entries(), isEmpty);
      expect(shown.board.layers['patrols']!.entries(), isEmpty);
      expect(engine.state.board.layers['patrols']!.entries().length, 2);
    },
  );
}
