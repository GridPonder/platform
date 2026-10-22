import 'dart:convert';
import 'package:gridponder_engine/engine.dart';
import 'package:gridponder_engine/src/rules/effect_executor.dart';
import 'package:test/test.dart';

final _fixtureData = jsonDecode(
        r'''{"data":{"layers":[{"id":"objects","occupancy":"zero_or_one"},{"id":"markers","occupancy":"zero_or_one"}],"entityKinds":{"gauge":{"layer":"objects","symbol":"G","tags":["solid"]},"control":{"layer":"markers","symbol":"K","tags":["control"]},"spent":{"layer":"markers","symbol":"s"}},"actions":[{"id":"move","params":{"direction":{"type":"direction"}}}],"systems":[{"id":"nav","type":"avatar_navigation","config":{}}],"rules":[{"id":"activate","on":"avatar_entered","where":{"position_has_tag":{"layer":"markers","tag":"control"}},"then":[{"exchange_parameters":{"firstPosition":"$cell.markers.param.first","secondPosition":"$cell.markers.param.second","firstVariable":"$cell.markers.param.firstVar","secondVariable":"$cell.markers.param.secondVar"}},{"transform":{"position":"$event.position","layer":"markers","fromKind":"control","toKind":"spent"}}]}]},"level":{"id":"generic","board":{"size":[5,3],"layers":{"objects":{"format":"sparse","entries":[{"position":[1,0],"kind":"gauge","value":2,"metadata":"keep"},{"position":[3,0],"kind":"gauge","value":7},{"position":[4,0],"kind":"gauge","value":99}]},"markers":{"format":"sparse","entries":[{"position":[1,1],"kind":"control","first":[1,0],"second":[3,0],"firstVar":"left","secondVar":"right"},{"position":[3,1],"kind":"control","first":[3,0],"second":[4,0],"firstVar":"right","secondVar":"other"}]}}},"state":{"avatar":{"enabled":true,"position":[0,1]},"variables":{"left":2,"right":7,"other":99,"done":0}},"goals":[{"id":"pending","type":"variable_threshold","config":{"variable":"done","target":1}}]}}''')
    as Map<String, dynamic>;

TurnEngine fixture() {
  final game =
      GameDefinition.fromJson(_fixtureData['data'] as Map<String, dynamic>);
  final level = LevelDefinition.fromJson(
      _fixtureData['level'] as Map<String, dynamic>, game.layers);
  return TurnEngine(game, level);
}

GameAction move(String direction) =>
    GameAction('move', {'direction': direction});

void main() {
  test('atomic snapshot, metadata, one use, and configured endpoint pairs', () {
    final engine = fixture();
    final result = engine.executeTurn(move('right'));
    final event =
        result.events.singleWhere((e) => e.type == 'parameters_exchanged');
    expect([event['firstValue'], event['secondValue']], [2, 7]);
    expect(engine.state.variables,
        {'left': 7, 'right': 2, 'other': 99, 'done': 0});
    expect(
        engine.state.board.getEntity('objects', const Position(1, 0))!.params,
        {'value': 7, 'metadata': 'keep'});
    engine.executeTurn(move('left'));
    expect(
        engine
            .executeTurn(move('right'))
            .events
            .where((e) => e.type == 'parameters_exchanged'),
        isEmpty);
    engine.executeTurn(move('right'));
    engine.executeTurn(move('right'));
    expect(engine.state.variables,
        {'left': 7, 'right': 99, 'other': 2, 'done': 0});
  });

  test('undo and reset restore values and the control', () {
    final engine = fixture();
    engine.executeTurn(move('right'));
    expect(engine.undo(), isTrue);
    expect(engine.state.variables['left'], 2);
    expect(engine.state.board.getEntity('markers', const Position(1, 1))!.kind,
        'control');
    engine.executeTurn(move('right'));
    engine.reset();
    expect(engine.state.variables['right'], 7);
    expect(engine.state.board.getEntity('markers', const Position(1, 1))!.kind,
        'control');
  });

  test('missing endpoints or parameters cannot partially change values', () {
    final engine = fixture();
    for (final second in [const Position(2, 0), const Position(3, 0)]) {
      engine.state.board.setEntity('objects', const Position(3, 0),
          const EntityInstance('gauge', {'unrelated': 7}));
      final events = EffectExecutor(engine.game).execute(
          Effect.fromJson({
            'exchange_parameters': {
              'firstPosition': [1, 0],
              'secondPosition': second.toJson(),
              'firstVariable': 'left',
              'secondVariable': 'right'
            },
          }),
          const GameEvent('test', {}),
          engine.state);
      expect(events, isEmpty);
      expect(engine.state.variables['left'], 2);
      expect(engine.state.variables['right'], 7);
      expect(
          engine.state.board
              .getEntity('objects', const Position(1, 0))!
              .params['value'],
          2);
    }
  });

  test('aliased mirror variables are rejected before mutation', () {
    final engine = fixture();
    expect(
        () => EffectExecutor(engine.game).execute(
            Effect.fromJson({
              'exchange_parameters': {
                'firstPosition': [1, 0],
                'secondPosition': [3, 0],
                'firstVariable': 'left',
                'secondVariable': 'left'
              },
            }),
            const GameEvent('test', {}),
            engine.state),
        throwsFormatException);
    expect(engine.state.variables['left'], 2);
    expect(
        engine.state.board
            .getEntity('objects', const Position(1, 0))!
            .params['value'],
        2);
  });
}
