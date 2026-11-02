import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:gridponder_engine/engine.dart';
import 'package:gridponder_engine/src/systems/pulse_network_system.dart';

void main() {
  final root = Directory('../python/_fixtures/pulse_network_smoke');
  Map<String, dynamic> read(String path) =>
      jsonDecode(File('${root.path}/$path').readAsStringSync())
          as Map<String, dynamic>;
  final game = GameDefinition.fromJson(read('game.json'));
  test('one pressed control cannot fire twice from duplicate events', () {
    final level =
        LevelDefinition.fromJson(read('levels/relay_on.json'), game.layers);
    final state = level.initialState();
    const pos = Position(0, 0);
    state.board.setEntity('controls', pos, const EntityInstance('pressed'));
    final event =
        GameEvent.cellTransformed(pos, 'ready', 'pressed', 'controls');
    const PulseNetworkSystem(id: 'network')
        .executeCascadeResolution([event, event], state, game);
    for (var x = 0; x < 3; x++) {
      expect(state.board.getEntity('lights', Position(x, 0))?.kind, 'lit');
    }
    expect(state.board.getEntity('controls', pos)?.kind, 'ready');
  });
  for (final file
      in Directory('${root.path}/levels').listSync().whereType<File>()) {
    test('pulse_network ${file.uri.pathSegments.last}', () {
      final level = LevelDefinition.fromJson(
          jsonDecode(file.readAsStringSync()), game.layers);
      final engine = TurnEngine(game, level);
      for (final action in level.solution.goldPath) {
        expect(engine.executeTurn(action).accepted, isTrue);
        expect(engine.isLost, isFalse);
      }
      expect(engine.isWon, isTrue);
      final settled = engine.state.copy();
      expect(engine.undo(), isTrue);
      expect(engine.executeTurn(level.solution.goldPath.last).accepted, isTrue);
      for (final layer in settled.board.layers.keys) {
        for (var y = 0; y < settled.board.height; y++) {
          for (var x = 0; x < settled.board.width; x++) {
            expect(
                engine.state.board.getEntity(layer, Position(x, y))?.toJson(),
                settled.board.getEntity(layer, Position(x, y))?.toJson());
          }
        }
      }
      engine.reset();
      expect(engine.state.actionCount, 0);
    });
  }
}
