import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gridponder_app/src/widgets/expandable_goal_preview.dart';
import 'package:gridponder_app/src/widgets/controls_widget.dart';
import 'package:gridponder_engine/engine.dart';

void main() {
  testWidgets('control wrapping is opt-in and preserves the default layout', (tester) async {
    for (final size in [null, 160]) {
      final game = GameDefinition.fromJson({
        'layers': [], 'entityKinds': <String, dynamic>{},
        'ui': <String, dynamic>{if (size != null) 'goalPreviewSize': size},
      });
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ControlsWidget(
        game: game, canUndo: false, onAction: (_) {},
        onUndo: () {}, onReset: () {}, onExit: () {},
      ))));
      expect(find.descendant(of: find.byType(ControlsWidget),
          matching: find.byType(Wrap)), size == null ? findsNothing : findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
  for (final size in [const Size(320, 568), const Size(568, 320)]) {
    testWidgets('goal preview expands and closes on $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: const Scaffold(body: Column(children: [
          ExpandableGoalPreview(
            maxSize: 300,
            labels: {
              'enlargeGoalTarget': 'Open target',
              'goalTarget': 'Target',
              'tapToEnlarge': 'Expand',
            },
            preview: SizedBox(width: 400, height: 400, child: Text('Reference')),
          ),
          Expanded(child: Text('Playable board')),
        ])),
      ));
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
