import 'dart:convert';
import 'dart:io';
import 'package:gridponder_engine/engine.dart';
import 'package:test/test.dart';

TurnEngine fixture() {
  final json = jsonDecode(
      File('../python/_fixtures/state_network.json').readAsStringSync());
  final game = GameDefinition.fromJson(json['game']);
  return TurnEngine(game, LevelDefinition.fromJson(json['level'], game.layers));
}

void main() {
  test('synchronous transitions, clamp memory and snapshot restore', () {
    final e = fixture();
    e.executeTurn(const GameAction('on'));
    expect(e.state.variables['__network_net']['values'], {'n': 1, 'm': 0});
    e.executeTurn(const GameAction('mask'));
    e.executeTurn(const GameAction('off'));
    expect(e.state.variables['__network_net']['values'], {'n': 1, 'm': 0});
    expect(e.state.variables['reading'], 0);
    e.undo();
    expect(e.state.variables['reading'], 1);
    e.reset();
    expect(e.state.variables['reading'], -1);
  });
  test('wrong transaction is a paid failure, not a secret-dependent veto', () {
    final e = fixture();
    final result = e.executeTurn(const GameAction('send'));
    expect(result.accepted, isTrue);
    expect(e.isLost, isTrue);
    expect(e.state.variables['energy'], 5);
    expect(e.executeTurn(const GameAction('sample')).accepted, isFalse);
  });
  test('public prerequisite veto is free', () {
    final json = jsonDecode(
        File('../python/_fixtures/state_network.json').readAsStringSync());
    final c = json['game']['systems'][0]['config'];
    c['tasks']['first'] = {'requires': {}};
    c['tasks']['job']['after'] = ['first'];
    c['controls']['first'] = {'type': 'commit', 'target': 'first'};
    (json['game']['actions'] as List).add({'id': 'first', 'params': <String, dynamic>{}});
    final game = GameDefinition.fromJson(json['game']);
    final e =
        TurnEngine(game, LevelDefinition.fromJson(json['level'], game.layers));
    expect(e.executeTurn(const GameAction('send')).accepted, isFalse);
    expect(e.state.variables['energy'], 6);
    e.executeTurn(const GameAction('first'));
    e.executeTurn(const GameAction('on'));
    expect(e.executeTurn(const GameAction('send')).accepted, isTrue);
    expect(e.isLost, isFalse);
  });
  test('assistance policy defaults off and parses opt-in', () {
    expect(
        GameDefinition.fromJson({
          'ui': {'restrictedInformation': true}
        }).ui.restrictedInformation,
        isTrue);
    expect(GameDefinition.fromJson({}).ui.restrictedInformation, isFalse);
  });
}
