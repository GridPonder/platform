import 'package:gridponder_engine/engine.dart';

/// Origins of actors reported at their destinations in this turn's events.
Map<Position, Position> _sightSourceOrigins(Iterable<GameEvent> events) {
  final origins = <Position, Position>{};
  for (final event in events) {
    if (event.type != 'npc_moved' && event.type != 'actor_moved') continue;
    final from = event.payload['fromPosition'];
    final to = event.payload['toPosition'] ?? event.position;
    if (from is Position && to is Position) origins[to] = from;
  }
  return origins;
}

/// Pulses on acquiring the avatar, including when the source moves.
/// Actor IDs can be derived from their starting cell, so actor relations use
/// their end cell and resolve the next turn's origin through movement events.
/// Non-avatar detections are handled separately by the caller.
class SightFeedbackTracker {
  Set<String> _active = {};
  final List<Set<String>> _history = [];

  List<GameEvent> advance(List<GameEvent> events, GameDefinition game) {
    _history.add(_active);
    final origins = _sightSourceOrigins(events);
    final current = <String>{};
    final acquired = <GameEvent>[];
    for (final event in events) {
      if (event.type != 'line_of_sight_detected' ||
          event.payload['kind'] != 'avatar') {
        continue;
      }
      final position = event.payload['sourcePosition'];
      final target = event.position;
      final sourceKind = event.payload['sourceKind'];
      final id = event.payload['sourceId'];
      if (position is! Position ||
          target == null ||
          sourceKind is! String ||
          id is! String) {
        continue;
      }
      final actor = game.entityKinds[sourceKind]?.layer == 'actors';
      String sourceAt(Position pos) => '$sourceKind:${pos.x},${pos.y}';
      final previous = actor
          ? sourceAt(origins[position] ?? position)
          : '$sourceKind:$id';
      final next = actor ? sourceAt(position) : '$sourceKind:$id';
      if (!_active.contains(previous) && !current.contains(next)) {
        acquired.add(event);
      }
      current.add(next);
    }
    _active = current;
    return acquired;
  }

  void undo() {
    if (_history.isNotEmpty) _active = _history.removeLast();
  }

  void clear() {
    _active = {};
    _history.clear();
  }
}
