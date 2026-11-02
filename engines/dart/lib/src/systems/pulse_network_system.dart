import '../engine/game_system.dart';
import '../models/event.dart';
import '../models/game_definition.dart';
import '../models/game_state.dart';
import '../models/position.dart';

/// Synchronous local pulses. Each light processes once; direction sets are
/// combined with OR and next-wave arrivals never mix with the current wave.
class PulseNetworkSystem extends GameSystem {
  const PulseNetworkSystem({required super.id}) : super(type: 'pulse_network');

  @override
  List<GameEvent> executeCascadeResolution(
      List<GameEvent> triggerEvents, LevelState state, GameDefinition game) {
    final config = game.systemConfig(id, {});
    final events = <GameEvent>[];
    for (final event in triggerEvents) {
      if (event.type != 'cell_transformed' ||
          event['layer'] != config['controlsLayer'] ||
          event['toKind'] != config['pressedKind']) continue;
      final pos = event['position'] is Position
          ? event['position'] as Position
          : Position.fromJson(event['position']);
      if (state.board.getEntity(config['controlsLayer'] as String, pos)?.kind ==
          config['pressedKind']) {
        events.addAll(_pulse(pos, state, config));
      }
    }
    return events;
  }

  List<GameEvent> _pulse(
      Position source, LevelState state, Map<String, dynamic> c) {
    final board = state.board, events = <GameEvent>[];
    final lightLayer = c['lightsLayer'] as String,
        objectLayer = c['objectsLayer'] as String;
    final signals = c['signalsLayer'] as String,
        controls = c['controlsLayer'] as String;
    final off = c['offKind'] as String,
        on = c['onKind'] as String,
        relay = c['relayKind'] as String;
    final delays = Map<String, String>.from(c['delayKinds'] as Map? ?? {});
    final writes = Map<String, String>.from(c['writeKinds'] as Map? ?? {});
    final fuses = Map<String, String>.from(c['fuseKinds'] as Map? ?? {});
    String? kind(String layer, Position p) => board.getEntity(layer, p)?.kind;
    void change(String layer, Position p, String target) {
      final entity = board.getEntity(layer, p);
      if (entity == null) return;
      board.setEntity(layer, p, entity.copyWith(kind: target));
      events.add(GameEvent.cellTransformed(p, entity.kind, target, layer));
    }

    void trace(String name, [int wave = 1]) {
      if (c['trace'] == true) {
        events.add(GameEvent.pulseTrace(name, wave));
      }
    }

    int number(Position p) => p.y * board.width + p.x;
    final positions = [
      for (var y = 0; y < board.height; y++)
        for (var x = 0; x < board.width; x++) Position(x, y)
    ];
    final lights =
        positions.where((p) => [off, on].contains(kind(lightLayer, p))).toSet();
    List<(Position, int)> neighbours(Position p) => [
          (Position(p.x - 1, p.y), 4),
          (Position(p.x + 1, p.y), 1),
          (Position(p.x, p.y - 1), 8),
          (Position(p.x, p.y + 1), 2),
        ].where((edge) => lights.contains(edge.$1)).toList();
    void emit(Position p, Map<Position, int> buffer) {
      for (final (q, bit) in neighbours(p)) {
        buffer[q] = (buffer[q] ?? 0) | bit;
      }
    }

    void flip(Position p) {
      final wasOn = kind(lightLayer, p) == on;
      change(lightLayer, p, c[wasOn ? 'fallingKind' : 'risingKind'] as String);
      change(lightLayer, p, wasOn ? off : on);
    }

    final loaded = [
      for (final p in positions)
        for (final entry in delays.entries)
          if (kind(objectLayer, p) == entry.value) (p, entry.key)
    ];
    final sourceKind = kind(objectLayer, source);
    for (final p in positions.where(lights.contains)) {
      change(signals, p, c['idleKind'] as String);
    }
    change(controls, source, c['readyKind'] as String);
    final queued = c['queuedVariable'] as String?;
    if (queued != null) {
      final old = state.variables[queued];
      state.variables[queued] = 0;
      events.add(GameEvent.variableChanged(queued, old, 0));
    }
    var incoming = <Position, int>{};
    for (final (p, _) in loaded) {
      emit(p, incoming);
      trace('delay_${number(p)}');
    }
    var direct = neighbours(source).map((edge) => edge.$1).toList();
    if ((c['flipKinds'] as List? ?? []).contains(sourceKind)) {
      direct = [if (lights.contains(source)) source, ...direct];
    } else if (!writes.containsKey(sourceKind)) {
      direct = [];
    }
    for (final p in direct) {
      if (kind(objectLayer, p) == relay &&
          kind(lightLayer, p) == off &&
          writes[sourceKind] != off) {
        emit(p, incoming);
        trace('seed_${number(p)}');
        change(objectLayer, p, relay);
      }
    }
    if (delays.containsKey(sourceKind)) {
      change(objectLayer, source, delays[sourceKind]!);
      if (queued != null) {
        state.variables[queued] = 1;
        events.add(GameEvent.variableChanged(queued, 0, 1));
      }
    }
    final seen = direct.toSet();
    for (final p in direct) {
      change(signals, p, c['hitKind'] as String);
      if (writes.containsKey(sourceKind)) {
        final target = writes[sourceKind]!;
        trace(
            'write_${number(source)}_${number(p)}_${target == on ? 'ON' : 'OFF'}');
        change(lightLayer, p, target);
      } else {
        trace('direct_${number(source)}_${number(p)}');
        flip(p);
      }
    }
    if (fuses.containsKey(sourceKind)) {
      change(objectLayer, source, fuses[sourceKind]!);
      final old = kind(controls, source)!;
      board.setEntity(controls, source, null);
      events.addAll([
        GameEvent.objectRemoved(source, old),
        GameEvent.cellCleared(source, old)
      ]);
    }
    for (final (p, empty) in loaded) {
      change(objectLayer, p, empty);
    }
    var wave = 1;
    while (incoming.isNotEmpty) {
      final output = <Position, int>{};
      final cells = incoming.keys.toList()
        ..sort((a, b) => number(a).compareTo(number(b)));
      for (final p in cells) {
        final mask = incoming[p]!;
        if (seen.contains(p)) {
          trace('ignored_${number(p)}_$mask', wave);
          continue;
        }
        seen.add(p);
        final collisions = c['collisions'] != false;
        final cancel = collisions && ((mask & 5) == 5 || (mask & 10) == 10);
        final burst = collisions &&
            c['bursts'] != false &&
            !cancel &&
            (mask & 5) != 0 &&
            (mask & 10) != 0;
        final forwarding = !cancel &&
            kind(objectLayer, p) == relay &&
            kind(lightLayer, p) == off;
        if (burst || forwarding) {
          emit(p, output);
        }
        if (forwarding) {
          trace('relay_${number(p)}', wave);
          change(objectLayer, p, relay);
        }
        if (burst) {
          trace('burst_${number(p)}', wave);
        }
        final outcome = cancel
            ? 'cancel'
            : burst
                ? 'burst'
                : 'normal';
        trace('arrival_${number(p)}_${mask}_$outcome', wave);
        change(
            signals,
            p,
            c[cancel
                ? 'cancelledKind'
                : burst
                    ? 'burstKind'
                    : 'hitKind'] as String);
        if (!cancel) {
          flip(p);
        }
      }
      incoming = output;
      wave++;
      if (wave > lights.length + 2) {
        throw StateError('pulse_network exceeded its once-per-cell wave bound');
      }
    }
    return events;
  }
}
