import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gridponder_app/src/services/solver_policy.dart';
import 'package:gridponder_app/src/widgets/controls_widget.dart';
import 'package:gridponder_app/src/widgets/network_controls.dart';
import 'package:gridponder_app/src/widgets/network_presentation.dart';
import 'package:gridponder_engine/engine.dart';

/// The engine's network fixture with a second task `job` that waits for
/// `first`. Neither task's `done_` field is copied into a variable.
({TurnEngine engine, SystemDef system}) chainedFixture({
  Map? labels,
  Map<String, dynamic>? systemOverrides,
}) {
  final json = jsonDecode(
    File('../engines/python/_fixtures/state_network.json').readAsStringSync(),
  );
  final c = json['game']['systems'][0]['config'] as Map;
  c['tasks']['first'] = {'requires': {}};
  c['tasks']['job']['after'] = ['first'];
  c['controls']['first'] = {'type': 'commit', 'target': 'first'};
  if (labels != null) c['labels'] = labels;
  (json['game']['actions'] as List).add({
    'id': 'first',
    'params': <String, dynamic>{},
  });
  if (systemOverrides != null)
    json['level']['systemOverrides'] = systemOverrides;
  final game = GameDefinition.fromJson(json['game']);
  final level = LevelDefinition.fromJson(json['level'], game.layers);
  final engine = TurnEngine(game, level);
  return (
    engine: engine,
    system: game.withSystemOverrides(level.systemOverrides).systems.single,
  );
}

void main() {
  group('task status', () {
    test('a completed prerequisite unlocks the next task without readouts', () {
      final f = chainedFixture();
      expect(f.engine.state.variables.containsKey('done_first'), isFalse);
      var view = NetworkView.of(f.system, f.engine.state);
      expect(view.canCommit('first'), isTrue);
      expect(view.canCommit('job'), isFalse);
      expect(view.commitBlocker('job'), 'Complete Task first first.');

      f.engine.executeTurn(const GameAction('first'));
      view = NetworkView.of(f.system, f.engine.state);
      expect(view.canCommit('first'), isFalse);
      expect(view.canCommit('job'), isTrue);
      expect(view.commitBlocker('job'), isNull);
    });

    testWidgets('the controls offer the second task once the first passes', (
      tester,
    ) async {
      final f = chainedFixture();
      f.engine.executeTurn(const GameAction('first'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NetworkControls(
              view: NetworkView.of(f.system, f.engine.state),
              enabled: true,
              onAction: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('Submit Task job…'), findsOneWidget);
      expect(find.text('Submit Task first…'), findsNothing);
    });
    testWidgets('ControlsWidget offers the next task under systemOverrides', (
      tester,
    ) async {
      // Each withSystemOverrides call builds fresh config maps, as the
      // play screen does for the controls' game and the network view.
      final f = chainedFixture(
        systemOverrides: {
          'net': {'energy': 8},
        },
      );
      final level = f.engine.level;
      GameDefinition overridden() =>
          f.engine.game.withSystemOverrides(level.systemOverrides);
      f.engine.executeTurn(const GameAction('first'));
      expect(f.engine.state.variables.containsKey('done_first'), isFalse);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ControlsWidget(
              onAction: (_) {},
              onUndo: () {},
              onReset: () {},
              onExit: () {},
              canUndo: false,
              game: overridden(),
              publicVariables: Map<String, dynamic>.of(
                f.engine.state.variables,
              ),
              networkView: NetworkView.of(
                overridden().systems.single,
                f.engine.state,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Submit Task job…'), findsOneWidget);
      expect(find.text('Submit Task first…'), findsNothing);
    });
  });

  group('loss message', () {
    test('explains a network failure only for its own lose reason', () {
      final f = chainedFixture();
      f.engine.executeTurn(const GameAction('first'));
      f.engine.executeTurn(const GameAction('send'));
      expect(f.engine.isLost, isTrue);
      final view = NetworkView.of(f.system, f.engine.state);
      expect(view.failedTask, 'job');
      expect(
        view.lossMessage('variable_threshold:failed')?.title,
        'Task job did not pass',
      );
      expect(view.lossMessage('max_actions'), isNull);
      expect(view.lossMessage('variable_threshold:hazard'), isNull);
      expect(view.lossMessage(null), isNull);
    });

    test('exhaustion without a failed task reads as running out', () {
      final view = NetworkView(
        {
          'tasks': {'job': {}},
          'readouts': {'failed': 'broken'},
        },
        {'journal': '1 [-] port=0', 'energy': 0},
      );
      expect(view.failedTask, isNull);
      expect(
        view.lossMessage('variable_threshold:broken')?.title,
        'Out of energy',
      );
      // Without a `failed` readout no lose condition can name the network.
      expect(
        NetworkView({}, {}).lossMessage('variable_threshold:failed'),
        isNull,
      );
    });
  });

  group('terms', () {
    test('neutral defaults and authored labels', () {
      const neutral = NetworkTerms();
      expect(neutral.task, 'task');
      expect(neutral.energyCount(1), '1 energy');
      expect(neutral.energyCount(3), '3 energy');
      expect(neutral.inputs, 'inputs');

      final themed = NetworkTerms.of({
        'labels': {
          'task': 'inspection',
          'energy': 'charge',
          'input': 'switch',
          'inputPlural': 'switches',
        },
      });
      expect(themed.tasks, 'inspections');
      expect(themed.energyCount(1), '1 charge');
      expect(themed.energyCount(2), '2 charges');
      expect(themed.inputs, 'switches');
    });

    test('labels and task titles reach the step notes', () {
      final f = chainedFixture(labels: {'task': 'order', 'energy': 'charge'});
      final view = NetworkView.of(f.system, f.engine.state);
      expect(view.stepNote('send'), 'Submit Order job (1 charge).');
      expect(view.stepNote('on'), 'Set P ON and run a step (1 charge).');
    });
  });

  group('solver policy', () {
    test('a gold path keeps action parameters', () {
      final cursor = PolicyCursor.fromActions(const [
        GameAction('move', {'direction': 'up'}),
        GameAction('place', {
          'position': [2, 3],
        }),
        GameAction('on'),
      ]);
      final first = cursor.nextGameAction!;
      expect(first.actionId, 'move');
      expect(first.params, {'direction': 'up'});
      expect(cursor.nextAction, 'move');
      cursor.advance({});
      expect(cursor.nextGameAction!.params, {
        'position': [2, 3],
      });
      cursor.advance({});
      expect(cursor.nextGameAction!.params, isEmpty);
    });

    test('authored policies accept ids and parameterised objects', () {
      final cursor = PolicyCursor({
        'actions': [
          'on',
          {'action': 'move', 'direction': 'left'},
        ],
        'win': true,
      });
      expect(cursor.nextGameAction!.actionId, 'on');
      cursor.advance({});
      expect(cursor.nextGameAction!.params, {'direction': 'left'});
    });
  });
}
