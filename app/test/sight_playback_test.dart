import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gridponder_app/src/screens/play_screen.dart';
import 'package:gridponder_app/src/services/pack_file_reader.dart';
import 'package:gridponder_app/src/services/pack_registry.dart';
import 'package:gridponder_app/src/services/pack_service.dart';
import 'package:gridponder_app/src/services/settings_service.dart';
import 'package:gridponder_app/src/widgets/board_renderer.dart';
import 'package:gridponder_engine/engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<PackService> _pack({
  int sensorX = 5,
  bool sightPulse = true,
  bool syncMotion = false,
}) => PackService.loadFromEntry(
  PackEntry(
    id: 'sight_playback_test',
    isInstalled: true,
    reader: InMemoryPackFileReader({
      for (final entry in <String, Object>{
        'manifest.json': {
          'dslVersion': '1.0',
          'packVersion': 1,
          'gameId': 'sight_playback_test',
          'title': 'Sight playback',
          'version': '1.0.0',
          'minEngineVersion': '1.0.0',
        },
        'game.json': {
          'layers': [
            {'id': 'ground', 'occupancy': 'exactly_one', 'default': 'floor'},
            {'id': 'actors', 'occupancy': 'zero_or_one'},
          ],
          'entityKinds': {
            'floor': {
              'layer': 'ground',
              'tags': ['walkable'],
              'symbol': '.',
            },
            if (syncMotion)
              'cart': {
                'layer': 'actors',
                'tags': ['npc'],
                'symbol': 'c',
                'display': {
                  'type': 'label',
                  'label': 'C',
                  'moveWithAvatar': true,
                },
              },
            'sensor': {
              'layer': 'actors',
              'tags': ['npc'],
              'symbol': 's',
              'display': {'type': 'label', 'label': 'S'},
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
            {'id': 'navigation', 'type': 'avatar_navigation'},
            {
              'id': 'followers',
              'type': 'follower_npcs',
              'config': {
                'behaviors': {
                  if (syncMotion) 'travel': {'type': 'patrol'},
                  'seek': {
                    'type': 'toward_avatar',
                    'requiresLineOfSight': true,
                  },
                },
              },
            },
          ],
          'levelSequence': [
            {'type': 'level', 'ref': 'level'},
          ],
        },
        'theme.json': {
          'avatar': {'visible': false, if (sightPulse) 'sightPulse': true},
        },
        'levels/level.json': {
          'id': 'level',
          'board': {
            'size': [7, 4],
            'layers': {
              'actors': {
                'format': 'sparse',
                'entries': [
                  if (syncMotion)
                    {
                      'position': [0, 0],
                      'kind': 'cart',
                      'behavior': 'travel',
                      'facing': 'right',
                    },
                  {
                    'position': [sensorX, 2],
                    'kind': 'sensor',
                    'behavior': 'seek',
                  },
                ],
              },
            },
          },
          'state': {
            'avatar': {
              'enabled': true,
              'position': [2, 1],
            },
          },
        },
      }.entries)
        entry.key: Uint8List.fromList(utf8.encode(jsonEncode(entry.value))),
    }),
  ),
);

void main() {
  testWidgets(
    'new sight flashes after avatar movement and before actor motion',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final pack = await _pack();
      final settings = await SettingsService.create();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayScreen(
            packService: pack,
            settings: settings,
            startLevelId: 'level',
          ),
        ),
      );
      await tester.pump();

      BoardRenderer board() =>
          tester.widget<BoardRenderer>(find.byType(BoardRenderer));
      Future<void> settle() async {
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      var sawPulse = false;
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        final current = board();
        if (current.lineOfSightFeedbacks.isEmpty) continue;
        sawPulse = true;
        final pulse = current.lineOfSightFeedbacks.single;
        expect(pulse.source, const Position(5, 2));
        expect(pulse.target, const Position(2, 2));
        expect(current.state.avatar.position, const Position(2, 2));
        expect(
          current.state.board.getEntity('actors', const Position(5, 2))?.kind,
          'sensor',
        );
        expect(current.movingSprites?.value, isEmpty);
        break;
      }
      expect(sawPulse, isTrue);
      await settle();
      expect(board().lineOfSightFeedbacks, isEmpty);
      expect(
        board().state.board.getEntity('actors', const Position(4, 2))?.kind,
        'sensor',
      );

      // Continuous sight does not produce another pulse while the actor moves.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(board().lineOfSightFeedbacks, isEmpty);
      }
      expect(
        board().state.board.getEntity('actors', const Position(3, 2))?.kind,
        'sensor',
      );

      // Breaking sight and entering it again re-arms the pulse.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await settle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      sawPulse = false;
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (board().lineOfSightFeedbacks.isNotEmpty) {
          sawPulse = true;
          expect(
            board().lineOfSightFeedbacks.single.source,
            const Position(3, 2),
          );
          break;
        }
      }
      expect(sawPulse, isTrue);
      await settle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('opted-in movement overlaps a single avatar step', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final pack = await _pack(syncMotion: true);
    final settings = await SettingsService.create();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayScreen(
          packService: pack,
          settings: settings,
          startLevelId: 'level',
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final board = tester.widget<BoardRenderer>(find.byType(BoardRenderer));
    expect(board.avatarMotion?.value, isNotNull);
    expect(board.movingSprites?.value, hasLength(1));
    expect(board.lineOfSightFeedbacks, isEmpty);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  });

  testWidgets('default sight feedback plays after motion on every detection', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final pack = await _pack(sightPulse: false);
    final settings = await SettingsService.create();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayScreen(
          packService: pack,
          settings: settings,
          startLevelId: 'level',
        ),
      ),
    );
    await tester.pump();

    for (final (key, source) in [
      (LogicalKeyboardKey.arrowDown, const Position(4, 2)),
      (LogicalKeyboardKey.arrowLeft, const Position(3, 2)),
    ]) {
      await tester.sendKeyEvent(key);
      var sawFeedback = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        final board = tester.widget<BoardRenderer>(find.byType(BoardRenderer));
        if (board.lineOfSightFeedbacks.isEmpty) continue;
        expect(board.lineOfSightFeedbacks.single.source, source);
        expect(board.movingSprites?.value, isEmpty);
        sawFeedback = true;
      }
      expect(sawFeedback, isTrue);
    }
  });

  testWidgets('a stationary observer does not leave the board held', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final pack = await _pack(sensorX: 3);
    final settings = await SettingsService.create();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayScreen(
          packService: pack,
          settings: settings,
          startLevelId: 'level',
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    var sawPulse = false;
    for (var i = 0; i < 35; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      final board = tester.widget<BoardRenderer>(find.byType(BoardRenderer));
      if (board.lineOfSightFeedbacks.isNotEmpty) {
        sawPulse = true;
        expect(board.lineOfSightFeedbacks.single.source, const Position(3, 2));
      }
    }
    expect(sawPulse, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    for (var i = 0; i < 35; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final board = tester.widget<BoardRenderer>(find.byType(BoardRenderer));
    expect(board.state.avatar.position, const Position(2, 1));
    expect(board.lineOfSightFeedbacks, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('entity detections keep their original line and target glow', (
    tester,
  ) async {
    final pack = await _pack();
    final defaultPack = await _pack(sightPulse: false);
    final state = LevelState(
      board: Board.fromJson({
        'size': [4, 3],
      }, pack.game.layers),
      avatar: const AvatarState(enabled: true, position: Position(0, 0)),
      variables: {},
    );

    Future<void> show(String kind, PackService service) => tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 280,
          height: 210,
          child: BoardRenderer(
            state: state,
            game: service.game,
            packService: service,
            lineOfSightFeedbacks: [
              LineOfSightFeedback(
                source: const Position(0, 1),
                target: const Position(3, 1),
                kind: kind,
              ),
            ],
          ),
        ),
      ),
    );

    CustomPainter sightPainter() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<CustomPainter>()
        .firstWhere(
          (painter) =>
              painter.runtimeType.toString() == '_LineOfSightFeedbackPainter',
        );

    await show('avatar', defaultPack);
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    expect(
      (Canvas canvas) => sightPainter().paint(canvas, const Size(280, 210)),
      paints
        ..line(color: const Color(0xFFFFF176).withValues(alpha: 0.32))
        ..line(color: const Color(0xFFFFD54F).withValues(alpha: 0.9)),
    );

    await show('sensor', pack);
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    expect(
      (Canvas canvas) => sightPainter().paint(canvas, const Size(280, 210)),
      paints
        ..line(color: const Color(0xFFFFF176).withValues(alpha: 0.32))
        ..line(color: const Color(0xFFFFD54F).withValues(alpha: 0.9)),
    );

    await show('avatar', pack);
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
    expect(
      (Canvas canvas) => sightPainter().paint(canvas, const Size(280, 210)),
      paints..line(color: const Color(0xFFFF3030).withValues(alpha: 0.9)),
    );
  });
}
