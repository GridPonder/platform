import '../engine/game_system.dart';
import '../models/entity.dart';
import '../models/event.dart';
import '../models/game_definition.dart';
import '../models/game_state.dart';
import '../models/position.dart';

/// Applies configured effects on arrival at a cardinal neighbour of an entity.
/// Only avatar_entered events trigger it; level load and blocked moves do not.
class ProximityEffectsSystem extends GameSystem {
  final Map<String, dynamic> config;

  const ProximityEffectsSystem({required super.id, required this.config})
      : super(type: 'proximity_effects');

  @override
  List<GameEvent> executeCascadeResolution(
    List<GameEvent> triggerEvents,
    LevelState state,
    GameDefinition game,
  ) {
    final layer = config['layer'] as String? ?? 'objects';
    final reactions = config['reactions'] as List? ?? const [];
    final events = <GameEvent>[];
    for (final arrival in triggerEvents) {
      if (arrival.type != 'avatar_entered') continue;
      final dest = arrival.position;
      if (dest == null) continue;
      final neighbors = [
        Position(dest.x, dest.y - 1),
        Position(dest.x + 1, dest.y),
        Position(dest.x, dest.y + 1),
        Position(dest.x - 1, dest.y),
      ];
      for (final neighbor in neighbors) {
        if (!state.board.isInBounds(neighbor)) continue;
        final entity = state.board.getEntity(layer, neighbor);
        if (entity == null) continue;
        final kind = entity.kind;
        final params = Map<String, dynamic>.of(entity.params);
        for (final raw in reactions) {
          final reaction = (raw as Map).cast<String, dynamic>();
          final tag = reaction['tag'];
          if (tag is! String || !game.hasTag(kind, tag)) continue;
          final effect = reaction['effect'];
          int value;
          int? delta;
          if (effect == 'cycle' || effect == 'threshold') {
            final param = reaction['param'] as String? ?? 'count';
            final old = params[param] ?? 0;
            if (old is! int || old < 0) {
              throw FormatException(
                'Invalid $param on ${entity.kind} at $neighbor',
              );
            }
            value = old + 1;
            if (effect == 'cycle') {
              final modulus = reaction['modulus'] ?? 3;
              if (modulus is! int || modulus < 2) {
                throw const FormatException(
                  'proximity_effects modulus must be >= 2',
                );
              }
              value %= modulus;
            } else {
              final thresholdParam =
                  reaction['thresholdParam'] as String? ?? 'threshold';
              final threshold = params[thresholdParam];
              if (threshold is! int || threshold < 1) {
                throw FormatException(
                  'Invalid $thresholdParam on ${entity.kind} at $neighbor',
                );
              }
              if (value >= threshold) {
                final flag = reaction['triggerVariable'];
                if (flag is String) state.variables[flag] = 1;
              }
            }
            params[param] = value;
            state.board.setEntity(
              layer,
              neighbor,
              EntityInstance(kind, Map.of(params)),
            );
          } else if (effect == 'damage') {
            final variable = reaction['variable'];
            final amount = reaction['amount'] ?? 1;
            final current = state.variables[variable];
            if (variable is! String || current is! int) {
              throw const FormatException(
                'proximity_effects damage needs an integer variable',
              );
            }
            if (amount is! int || amount < 1) {
              throw const FormatException(
                'proximity_effects damage amount must be positive',
              );
            }
            value = current - amount;
            delta = -amount;
            state.variables[variable] = value;
            if (value <= 0) {
              final flag = reaction['triggerVariable'];
              if (flag is String) state.variables[flag] = 1;
            }
          } else {
            throw FormatException('Unsupported proximity effect: $effect');
          }
          events.add(
            GameEvent('proximity_triggered', {
              'position': neighbor,
              'avatarPosition': dest,
              'kind': kind,
              'effect': effect,
              'value': value,
              'delta': delta,
            }),
          );
        }
      }
    }
    return events;
  }
}
