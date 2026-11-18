// Read trusted test cases from stdin; no pack-specific fixtures live here.
import 'dart:convert';
import 'dart:io';
import 'package:gridponder_engine/engine.dart';

Future<void> main() async {
  final cases = jsonDecode(await stdin.transform(utf8.decoder).join()) as List;
  var turns = 0;
  for (final c in cases) {
    final game = GameDefinition.fromJson(c['game']);
    final level = LevelDefinition.fromJson(c['level'], game.layers);
    final engine = TurnEngine(game, level);
    for (var i = 0; i < (c['actions'] as List).length; i++) {
      final result = engine.executeTurn(GameAction.fromJson(c['actions'][i]));
      final expected = c['expected'][i];
      if (!result.accepted ||
          engine.isWon != expected['won'] ||
          engine.isLost != expected['lost']) {
        throw StateError('Terminal/acceptance divergence at step $i');
      }
      final actual = engine.state.variables;
      bool equal(Object? a, Object? b) {
        if (a is Map && b is Map)
          return a.length == b.length &&
              a.keys.every((k) => b.containsKey(k) && equal(a[k], b[k]));
        if (a is List && b is List)
          return a.length == b.length &&
              List.generate(a.length, (j) => j).every((j) => equal(a[j], b[j]));
        return a == b;
      }

      final public = Map.fromEntries(
          actual.entries.where((e) => !e.key.startsWith('__network_')));
      if (!equal(public, expected['public']))
        throw StateError(
            'Public projection divergence at step $i: $public vs ${expected['public']}');
      final internal = actual.entries
          .singleWhere((e) => e.key.startsWith('__network_'))
          .value;
      if (!equal(internal, expected['runtime']))
        throw StateError('Transition divergence at step $i');
      turns++;
    }
  }
  print('${cases.length} traces / $turns turns agree across engines.');
}
