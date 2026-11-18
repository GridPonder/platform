import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gridponder_app/src/screens/play_screen.dart';
import 'package:gridponder_app/src/services/pack_file_reader.dart';
import 'package:gridponder_app/src/services/pack_registry.dart';
import 'package:gridponder_app/src/services/pack_service.dart';
import 'package:gridponder_app/src/services/settings_service.dart';
import 'package:gridponder_app/src/widgets/balance_panel.dart';
import 'package:gridponder_app/src/widgets/catalog_panel.dart';
import 'package:gridponder_app/src/widgets/expandable_goal_preview.dart';
import 'package:gridponder_engine/engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> catalog() => {
  'inputs': {'a': {'name': 'Input A'}},
  'products': [{'name': 'Product B', 'inputs': ['a']}],
  'labels': {'hideGuide': 'Dismiss catalog', 'showGuide': 'Restore catalog'},
};

Future<PackService> packWith(Map<String, dynamic> config) =>
    PackService.loadFromEntry(PackEntry(
      id: 'catalog_test', isInstalled: true,
      reader: InMemoryPackFileReader({
        for (final entry in <String, Object>{
          'manifest.json': {
            'gameId': 'catalog_test', 'title': 'Catalog test',
            'dslVersion': '0.12', 'packVersion': 1, 'version': '1.0.0',
            'minEngineVersion': '0.12.0',
          },
          'game.json': {
            'layers': [{'id': 'objects', 'occupancy': 'zero_or_one'}],
            'entityKinds': {'marker': {'layer': 'objects', 'symbol': 'M'}},
            'ui': {
              'showGuide': true, 'showGoal': true, 'goalPreviewSize': 200,
              'readouts': [{'variable': 'budget', 'label': 'Budget'}],
            },
            'levelSequence': [{'type': 'level', 'ref': 'sample'}],
          },
          'levels/sample.json': {
            'id': 'sample', 'title': 'Sample', 'guide': 'Level-specific guide',
            'board': {'size': [2, 1], 'layers': {'objects': [['marker', null]]}},
            'state': {'variables': {'budget': 7}},
            'goals': [{
              'id': 'finish', 'type': 'board_match',
              'config': {'targetLayers': {'objects': [[null, 'marker']]}},
            }],
          },
          'theme.json': {'presentation': {'catalog': config}},
        }.entries)
          entry.key: Uint8List.fromList(utf8.encode(jsonEncode(entry.value))),
      }),
    ));

void main() {
  testWidgets('malformed catalog fields fall back to the board', (tester) async {
    final invalid = <Map<String, dynamic>>[
      {...catalog(), 'inputs': {'a': 3}},
      {...catalog(), 'inputs': {'a': {'image': 3}}},
      {...catalog(), 'products': [{'inputs': ['a'], 'image': 3}]},
      {...catalog(), 'products': [{'inputs': [3]}]},
      {...catalog(), 'products': [{'inputs': ['unknown']}]},
      {...catalog(), 'labels': {'title': 3}},
      {...catalog(), 'labels': []},
      {...catalog(), 'concealedDemandKinds': [3]},
      {...catalog(), 'panelColor': 3},
    ];
    for (final config in invalid) {
      final pack = await packWith(config);
      final state = TurnEngine(pack.game, pack.level('sample')).state;
      expect(CatalogBoardLayout.isValidCatalog(config), isFalse);
      await tester.pumpWidget(MaterialApp(theme: ThemeData(splashFactory: NoSplash.splashFactory), home: Scaffold(body: CatalogBoardLayout(
        pack: pack, state: state, board: const Text('Playable board'),
      ))));
      expect(find.text('Playable board'), findsOneWidget);
      expect(find.text('Catalog'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('catalog tolerates invalid colors and preserves board space', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pack = await packWith({...catalog(), 'panelColor': '#zzzzzz'});
    final state = TurnEngine(pack.game, pack.level('sample')).state;
    state.variables['remaining'] = 'invalid counter';
    const boardKey = ValueKey('board');
    await tester.pumpWidget(MaterialApp(theme: ThemeData(splashFactory: NoSplash.splashFactory), home: Scaffold(body: SizedBox(
      height: 100, child: CatalogBoardLayout(pack: pack, state: state,
        board: const SizedBox.expand(key: boardKey)),
    ))));
    expect(tester.getSize(find.byKey(boardKey)).height, greaterThan(50));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byTooltip('Dismiss catalog'));
    await tester.tap(find.byTooltip('Dismiss catalog'));
    await tester.pump();
    expect(find.text('Restore catalog'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hiding catalog preserves level goal, guide, readout and HUD', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final pack = await packWith(catalog());
    final settings = await SettingsService.create();
    await tester.pumpWidget(MaterialApp(theme: ThemeData(splashFactory: NoSplash.splashFactory), home: PlayScreen(
      packService: pack, settings: settings,
    )));
    await tester.pump();
    expect(find.text('Budget'), findsOneWidget);
    expect(find.byType(BalancePanel), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss catalog'));
    await tester.pump();
    expect(find.text('Budget'), findsOneWidget);
    expect(find.byType(BalancePanel), findsOneWidget);
    expect(find.byType(ExpandableGoalPreview), findsOneWidget);
    // The level guide remains available from the regular Guide panel.
    expect(find.text('Guide'), findsOneWidget);
    await tester.tap(find.text('Guide'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Level-specific guide'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [const Size(320, 568), const Size(568, 320)]) {
    testWidgets('goal preview expands and closes on $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(theme: ThemeData(splashFactory: NoSplash.splashFactory), home: Scaffold(body: Column(children: [
        const ExpandableGoalPreview(maxSize: 300,
          labels: {'enlargeGoalTarget': 'Open target', 'goalTarget': 'Target',
            'tapToEnlarge': 'Expand'},
          preview: SizedBox(width: 400, height: 400, child: Text('Reference'))),
        const Expanded(child: Text('Playable board')),
      ]))));
      expect(tester.getSize(find.byType(ExpandableGoalPreview)).height,
          lessThan(size.height * .3));
      await tester.tap(find.byTooltip('Open target'));
      await tester.pumpAndSettle();
      expect(find.text('Target'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
