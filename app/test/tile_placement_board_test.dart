import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gridponder_engine/engine.dart';
import 'package:gridponder_app/src/widgets/tile_placement_board.dart';
import 'package:gridponder_app/src/widgets/balance_panel.dart';
import 'package:gridponder_app/src/screens/play_screen.dart';
import 'package:gridponder_app/src/services/pack_service.dart';
import 'package:gridponder_app/src/services/pack_registry.dart';
import 'package:gridponder_app/src/services/pack_file_reader.dart';
import 'package:gridponder_app/src/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> config() => {
  'size': [2, 2],
  'targetLabels': [],
  'pieces': [
    for (final id in ['a', 'b'])
      {
        'id': id,
        'kind': 'tile',
        'color': '#336699',
        'cells': [
          [0, 0],
          [1, 0],
        ],
      },
  ],
  'targets': [
    [
      [0, 0],
      [1, 0],
      [0, 1],
      [1, 1],
    ],
  ],
};
Map<String, dynamic> game({bool enabled = true}) => {
  'layers': [
    {'id': 'pieces', 'occupancy': 'zero_or_one'},
  ],
  'entityKinds': {
    'tile': {'layer': 'pieces', 'symbol': 'T'},
  },
  'actions': [
    for (final id in ['place_piece', 'remove_piece', 'next_target']) {'id': id},
  ],
  'systems': [
    {
      'id': 'tiles',
      'type': 'tile_placement',
      'enabled': enabled,
      'config': config(),
    },
  ],
  'ui': {
    'showGoal': true,
    'showGuide': true,
    'readouts': [
      {'variable': 'budget', 'label': 'Budget'},
    ],
  },
  'goalDescriptions': {'finish': 'Fill the target'},
  'levelSequence': [
    {'type': 'level', 'ref': 'sample'},
  ],
};
Map<String, dynamic> level() => {
  'id': 'sample',
  'title': 'Sample',
  'guide': 'Level-specific guide',
  'board': {
    'size': [2, 2],
    'layers': <String, dynamic>{},
  },
  'state': {
    'variables': {'budget': 9},
  },
  'goals': [
    {
      'id': 'finish',
      'type': 'variable_threshold',
      'config': {'variable': 'tiles.complete', 'target': 1, 'comparison': 'eq'},
    },
  ],
};

void main() {
  for (final viewport in [
    const Size(320, 568),
    const Size(568, 320),
    const Size(1024, 768),
  ]) {
    testWidgets('placement and target dialog fit $viewport', (tester) async {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final definition = GameDefinition.fromJson(game());
      final engine = TurnEngine(
        definition,
        LevelDefinition.fromJson(level(), definition.layers),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => TilePlacementBoard(
                systemId: 'tiles',
                config: config(),
                state: engine.state,
                palette: const {
                  'placementPrimary': '#123456',
                  'placementBorder': 'invalid',
                },
                labels: const {
                  'Target': 'Reference',
                  'Close': 'Dismiss',
                  'Shape': 7,
                },
                onAction: (action) => update(() {
                  expect(engine.executeTurn(action).accepted, isTrue);
                }),
                onReset: engine.reset,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final target = find.byKey(const ValueKey('tile-view-target'));
      expect(
        tester.widget<TextButton>(target).style!.foregroundColor!.resolve({}),
        const Color(0xff123456),
      );
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      final piece = find.byKey(const ValueKey('tile-piece-a'));
      await tester.ensureVisible(piece);
      await tester.tap(piece);
      await tester.pump();
      final board = find.byKey(const ValueKey('tile-placement-board'));
      await tester.ensureVisible(board);
      await tester.tapAt(tester.getTopLeft(board) + const Offset(10, 10));
      await tester.pump();
      expect(
        (engine.state.variables['tiles.placements'] as Map).containsKey('a'),
        isTrue,
      );
      expect(find.text('1 left · 2 shapes'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tile screen preserves guide, goal, counter and other HUD', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsService.create();
    for (final enabled in [true, false]) {
      final pack = await PackService.loadFromEntry(
        PackEntry(
          id: 'placement_test',
          isInstalled: true,
          reader: InMemoryPackFileReader({
            for (final entry in <String, Object>{
              'manifest.json': {
                'gameId': 'placement_test',
                'title': 'Placement test',
                'dslVersion': '0.12',
                'packVersion': 1,
                'version': '1.0.0',
                'minEngineVersion': '0.12.0',
              },
              'game.json': game(enabled: enabled),
              'levels/sample.json': level(),
              'theme.json': {
                'presentation': {
                  'tilePlacement': {'labels': []},
                },
              },
            }.entries)
              entry.key: Uint8List.fromList(
                utf8.encode(jsonEncode(entry.value)),
              ),
          }),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: PlayScreen(packService: pack, settings: settings),
        ),
      );
      await tester.pump();
      expect(
        find.byType(TilePlacementBoard),
        enabled ? findsOneWidget : findsNothing,
      );
      expect(find.text('Budget'), findsOneWidget);
      expect(find.text('Fill the target'), findsOneWidget);
      expect(find.byType(BalancePanel), findsOneWidget);
      await tester.tap(find.text('Guide'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Level-specific guide'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });
}
