import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gridponder_app/src/services/pack_file_reader.dart';
import 'package:gridponder_app/src/services/pack_registry.dart';
import 'package:gridponder_app/src/services/pack_service.dart';
import 'package:gridponder_app/src/widgets/board_renderer.dart';
import 'package:gridponder_engine/engine.dart';

void main() {
  testWidgets('exchanged values travel in opposite arcs and clear at the end', (
    tester,
  ) async {
    final files = <String, Object>{
      'manifest.json': {
        'dslVersion': '0.9',
        'packVersion': 1,
        'gameId': 'generic',
        'title': 'Generic',
        'version': '1.0.0',
        'minEngineVersion': '0.9.0',
      },
      'game.json': {
        'layers': [
          {'id': 'ground', 'occupancy': 'exactly_one', 'default': 'floor'},
        ],
        'entityKinds': {
          'floor': {'layer': 'ground', 'symbol': '.'},
        },
        'actions': [],
        'systems': [],
        'levelSequence': [
          {'type': 'level', 'ref': 'sample'},
        ],
      },
      'theme.json': {
        'avatar': {'visible': false},
      },
      'levels/sample.json': {
        'id': 'sample',
        'board': {
          'size': [4, 3],
          'layers': {},
        },
        'state': {
          'avatar': {'enabled': false},
        },
        'goals': [],
      },
    };
    final reader = InMemoryPackFileReader({
      for (final entry in files.entries)
        entry.key: Uint8List.fromList(utf8.encode(jsonEncode(entry.value))),
    });
    final pack = await PackService.loadFromEntry(
      PackEntry(id: 'generic', isInstalled: true, reader: reader),
    );
    final state = pack.level('sample').initialState();
    final effects = ValueNotifier<List<CellEffectPlayback>>([]);
    const def = CellEffectDef(
      sheet: '',
      animation: 'exchange',
      frames: 11,
      color: 'teal',
    );
    void frame(int index) => effects.value = [
      CellEffectPlayback(
        position: const Position(0, 1),
        targetPosition: const Position(3, 1),
        firstValue: 2,
        secondValue: 7,
        def: def,
        frameIndex: index,
      ),
    ];
    frame(0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: BoardRenderer(
                state: state,
                game: pack.game,
                packService: pack,
                cellEffects: effects,
              ),
            ),
          ),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byType(BoardRenderer));
    final cell = BoardRenderer.cellSizeFor(
      const BoxConstraints.tightFor(width: 400, height: 300),
      4,
      3,
    );
    final first = find.byKey(const ValueKey('exchange-first-value'));
    final second = find.byKey(const ValueKey('exchange-second-value'));
    expect(tester.getCenter(first), origin + Offset(cell * .5, cell * 1.5));
    expect(tester.getCenter(second), origin + Offset(cell * 3.5, cell * 1.5));
    expect(
      find.descendant(of: first, matching: find.text('2')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: second, matching: find.text('7')),
      findsOneWidget,
    );
    frame(5);
    await tester.pump();
    expect(tester.getCenter(first).dx, closeTo(origin.dx + cell * 2, 0.01));
    expect(tester.getCenter(second).dx, closeTo(origin.dx + cell * 2, 0.01));
    expect(tester.getCenter(first).dy, greaterThan(origin.dy + cell * 1.5));
    expect(tester.getCenter(second).dy, lessThan(origin.dy + cell * 1.5));
    frame(10);
    await tester.pump();
    expect(tester.getCenter(first).dx, closeTo(origin.dx + cell * 3.5, 0.01));
    expect(tester.getCenter(second).dx, closeTo(origin.dx + cell * .5, 0.01));
    effects.value = [];
    await tester.pump();
    expect(first, findsNothing);
    expect(second, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    effects.dispose();
  });
}
