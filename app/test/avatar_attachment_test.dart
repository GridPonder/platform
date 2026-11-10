import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gridponder_app/src/services/pack_file_reader.dart';
import 'package:gridponder_app/src/services/pack_registry.dart';
import 'package:gridponder_app/src/services/pack_service.dart';
import 'package:gridponder_app/src/widgets/board_renderer.dart';
import 'package:gridponder_engine/engine.dart';

Future<PackService> _pack() => PackService.loadFromEntry(
  PackEntry(
    id: 'attachment_test',
    isInstalled: true,
    reader: InMemoryPackFileReader({
      for (final entry in <String, Object>{
        'manifest.json': {
          'dslVersion': '1.0',
          'packVersion': 1,
          'gameId': 'attachment_test',
          'title': 'Attachment test',
          'version': '1.0.0',
          'minEngineVersion': '1.0.0',
        },
        'game.json': {
          'layers': [
            {'id': 'markers', 'occupancy': 'zero_or_one'},
          ],
          'entityKinds': {
            'badge': {
              'layer': 'markers',
              'tags': [],
              'symbol': 'a',
              'display': {'type': 'label', 'label': 'A', 'followAvatar': true},
            },
            'tile': {
              'layer': 'markers',
              'tags': [],
              'symbol': 'g',
              'display': {'type': 'label', 'label': 'G'},
            },
          },
        },
        'theme.json': {
          'avatar': {'visible': false},
        },
      }.entries)
        entry.key: Uint8List.fromList(utf8.encode(jsonEncode(entry.value))),
    }),
  ),
);

void main() {
  testWidgets('only attachments follow the avatar at intermediate positions', (
    tester,
  ) async {
    final pack = await _pack();
    final state = LevelState(
      board: Board.fromJson({
        'size': [4, 3],
        'layers': {
          'markers': {
            'format': 'sparse',
            'entries': [
              {
                'position': [2, 2],
                'kind': 'badge',
              },
              {
                'position': [0, 0],
                'kind': 'tile',
              },
            ],
          },
        },
      }, pack.game.layers),
      avatar: const AvatarState(enabled: true, position: Position(1, 1)),
      variables: {},
    );
    final motion = ValueNotifier<AvatarMotion?>(null);
    addTearDown(motion.dispose);

    Future<void> show({
      List<EntityInstance>? attachments,
      Position? override,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 280,
            height: 210,
            child: BoardRenderer(
              state: state,
              game: pack.game,
              packService: pack,
              avatarMotion: motion,
              avatarAttachmentsOverride: attachments,
              avatarPositionOverride: override,
            ),
          ),
        ),
      ),
    );

    await show();
    final boardOrigin = tester.getTopLeft(find.byType(BoardRenderer));
    Offset center(double x, double y) =>
        boardOrigin + Offset((x + 0.5) * 70, (y + 0.5) * 70);
    expect(find.text('A'), findsOneWidget);
    expect(tester.getCenter(find.text('A')), center(1, 1));
    expect(tester.getCenter(find.text('G')), center(0, 0));

    motion.value = (x: 1.25, y: 1.0, progress: 0.25);
    await tester.pump();
    expect(tester.getCenter(find.text('A')), center(1.25, 1));
    expect(tester.getCenter(find.text('G')), center(0, 0));
    motion.value = (x: 1.75, y: 1.0, progress: 0.75);
    await tester.pump();
    expect(tester.getCenter(find.text('A')), center(1.75, 1));

    // A new attachment cannot appear ahead of the avatar during its step.
    await show(attachments: const []);
    expect(find.text('A'), findsNothing);
    expect(find.text('G'), findsOneWidget);

    // Keep an old attachment through motion even if the logical mark is gone.
    state.board.setEntity('markers', const Position(2, 2), null);
    await show(attachments: const [EntityInstance('badge')]);
    expect(tester.getCenter(find.text('A')), center(1.75, 1));
    motion.value = null;
    await show(
      override: const Position(3, 1),
      attachments: const [EntityInstance('badge')],
    );
    expect(tester.getCenter(find.text('A')), center(3, 1));
    await show();
    expect(find.text('A'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
