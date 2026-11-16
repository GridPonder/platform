import 'dart:math' show min;

import '../engine/game_system.dart';
import '../models/entity.dart';
import '../models/event.dart';
import '../models/game_action.dart';
import '../models/game_definition.dart';
import '../models/game_state.dart';
import '../models/position.dart';
import 'tile_placement_constraints.dart';

/// Optional rigid tiles. No existing system reads or writes these variables.
class TilePlacementSystem extends GameSystem {
  const TilePlacementSystem({required super.id})
      : super(type: 'tile_placement');
  static List<Position> points(dynamic raw) => [
        for (final p in raw as List) Position(p[0] as int, p[1] as int),
      ];
  static List<Map<String, dynamic>> pieces(Map<String, dynamic> c) =>
      (c['pieces'] as List)
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList();
  static Position transform(Map p, Position point, int rotation) {
    Position turn(Position a) {
      for (var i = 0; i < rotation; i++) {
        a = Position(-a.y, a.x);
      }
      return a;
    }

    final raw = points(p['cells']).map(turn).toList(), a = turn(point);
    return Position(
      a.x - raw.map((p) => p.x).reduce(min),
      a.y - raw.map((p) => p.y).reduce(min),
    );
  }

  static Map variantPiece(Map p, List placement) {
    final variants = p['variants'] as List?;
    return variants == null
        ? p
        : {
            ...p,
            ...Map.from(
                variants[placement.length > 3 ? placement[3] as int : 0] as Map)
          };
  }

  static List<Position> cells(Map p, List placement) {
    final piece = variantPiece(p, placement);
    return [
      for (final a in points(piece['cells']))
        transform(piece, a, placement[2] as int) +
            Position(placement[0] as int, placement[1] as int)
    ];
  }

  static List<Map<String, dynamic>> edges(Map p, List placement) {
    final piece = variantPiece(p, placement);
    return [
      for (final e in piece['edges'] as List? ?? [])
        {
          'position': transform(
                  piece, Position.fromJson(e['cell']), placement[2] as int) +
              Position(placement[0] as int, placement[1] as int),
          'direction': ((e['direction'] as int) + (placement[2] as int)) % 4,
          'symbol': e['symbol'],
        }
    ];
  }

  static String? problem(
    Map<String, dynamic> c,
    Map placements,
    int phase,
    List moved,
    String? pieceId,
    List placement, {
    int steps = 0,
    int lifts = 0,
  }) {
    final byId = {for (final p in pieces(c)) p['id']: p};
    if (!byId.containsKey(pieceId)) return 'Choose a piece.';
    if ((placement.length != 3 && placement.length != 4) ||
        placement.any((v) => v is! int) ||
        placement[2] < 0 ||
        placement[2] > 3) {
      return 'Use an integer anchor and a quarter-turn rotation (0–3).';
    }
    if (placement.length > 3 &&
        (placement[3] < 0 ||
            placement[3] >=
                ((byId[pieceId]!['variants'] as List?)?.length ?? 0)))
      return 'Choose an available form.';
    if (phase > 0 &&
        !moved.contains(pieceId) &&
        moved.length >= (c['maxMoved'] as int? ?? byId.length)) {
      return 'Piece-move limit reached. Undo to try a different piece.';
    }
    final updates = linkedPlacements(c, placements, pieceId!, placement);
    final occupied = {
      for (final e in placements.entries)
        if (!updates.containsKey(e.key)) ...cells(byId[e.key]!, e.value as List)
    };
    final transfer = phase > 0 ? c['transfer'] as Map? : null;
    final movement = transfer ?? c['insertion'] as Map?;
    final target =
        points(movement?['area'] ?? c['playArea'] ?? c['targets'][phase])
            .toSet();
    final markers = {
      for (final m in c['markers'] as List? ?? [])
        Position.fromJson(m['position']): m['color']
    };
    for (final e in updates.entries) {
      for (final point in cells(byId[e.key]!, e.value)) {
        if (!target.contains(point))
          return c.containsKey('playArea')
              ? 'Keep every square inside the active play area.'
              : 'Keep every square inside the active target.';
        if (occupied.contains(point)) return 'Pieces cannot overlap.';
        if (markers.containsKey(point) &&
            markers[point] != byId[e.key]!['color'])
          return 'This colour clue needs a matching piece.';
        occupied.add(point);
      }
    }
    final after = {...placements, ...updates};
    return transferProblem(c, placements, phase, pieceId, placement,
            steps: steps, lifts: lifts) ??
        insertionProblem(c, placements, pieceId, placement) ??
        supportProblem(c, after) ??
        freeSpaceProblem(c, after);
  }

  static String? echoPartner(Map<String, dynamic> c, Map placed, String key) {
    if (!placed.containsKey(key)) return null;
    for (final pair in c['echoLinks'] as List? ?? []) {
      if ((pair as List).contains(key)) {
        final other = pair[0] == key ? pair[1] : pair[0];
        if (placed.containsKey(other)) return other as String;
      }
    }
    return null;
  }

  static List<String> linkedGroup(
      Map<String, dynamic> c, Map placed, String key) {
    final partner = echoPartner(c, placed, key);
    if (partner != null) return [key, partner]..sort();
    if (c['linkedMovement'] == null || !placed.containsKey(key)) return [key];
    final byId = {for (final p in pieces(c)) p['id']: p};
    final pads = points(c['linkedMovement']['releaseCells'] ?? []).toSet();
    final released = {
      for (final e in placed.entries)
        if (cells(byId[e.key]!, e.value as List).any(pads.contains)) e.key
    };
    final marked = <String, List<dynamic>>{};
    final graph = {for (final id in placed.keys) id: <String>{}};
    for (final e in placed.entries)
      for (final edge in edges(byId[e.key]!, e.value as List)) {
        final p = edge['position'] as Position;
        marked['${p.x},${p.y},${edge['direction']}'] = [e.key, edge['symbol']];
      }
    const steps = [
      Position(0, -1),
      Position(1, 0),
      Position(0, 1),
      Position(-1, 0)
    ];
    for (final e in marked.entries) {
      final raw = e.key.split(',').map(int.parse).toList(), d = raw[2];
      final other = marked[
          '${raw[0] + steps[d].x},${raw[1] + steps[d].y},${(d + 2) % 4}'];
      if (other != null &&
          other[0] != e.value[0] &&
          other[1] == e.value[1] &&
          !released.contains(e.value[0]) &&
          !released.contains(other[0])) {
        graph[e.value[0]]!.add(other[0] as String);
        graph[other[0]]!.add(e.value[0] as String);
      }
    }
    final seen = <String>{key}, pending = <String>[key];
    while (pending.isNotEmpty)
      for (final next in graph[pending.removeLast()]!.difference(seen)) {
        seen.add(next);
        pending.add(next);
      }
    return seen.toList()..sort();
  }

  static Map<String, List<dynamic>> linkedPlacements(
      Map<String, dynamic> c, Map placed, String key, List placement) {
    final partner = echoPartner(c, placed, key);
    if (partner != null) {
      final old = placed[key] as List, other = placed[partner] as List;
      final dx = (placement[0] as int) - (old[0] as int),
          dy = (placement[1] as int) - (old[1] as int);
      final delta = ((placement[2] as int) - (old[2] as int)) % 4;
      return {
        key: List<dynamic>.from(placement),
        partner: [
          (other[0] as int) + dx,
          (other[1] as int) + dy,
          ((other[2] as int) - delta) % 4,
          ...other.skip(3)
        ]
      };
    }
    final group = linkedGroup(c, placed, key);
    if (group.length == 1) return {key: List<dynamic>.from(placement)};
    final byId = {for (final p in pieces(c)) p['id']: p},
        old = placed[key] as List;
    final delta = ((placement[2] as int) - (old[2] as int)) % 4;
    Position rotate(Position p) {
      for (var i = 0; i < delta; i++) {
        p = Position(-p.y, p.x);
      }
      return p;
    }

    final origin = Position(old[0] as int, old[1] as int);
    final local =
        cells(byId[key]!, old).map((p) => rotate(p - origin)).toList();
    final mx = local.map((p) => p.x).reduce(min),
        my = local.map((p) => p.y).reduce(min);
    final result = <String, List<dynamic>>{};
    for (final id in group) {
      final pose = placed[id] as List;
      final world =
          cells(byId[id]!, pose).map((p) => rotate(p - origin)).toList();
      result[id] = [
        world.map((p) => p.x).reduce(min) - mx + (placement[0] as int),
        world.map((p) => p.y).reduce(min) - my + (placement[1] as int),
        ((pose[2] as int) + delta) % 4,
        if (pose.length > 3) pose[3]
      ];
    }
    return result;
  }

  static List<String> rotationGroup(Map<String, dynamic> c, String key) {
    final graph = {for (final p in pieces(c)) p['id']: <String>{}};
    for (final pair in c['rotationLinks'] as List? ?? []) {
      graph[pair[0]]!.add(pair[1] as String);
      graph[pair[1]]!.add(pair[0] as String);
    }
    final seen = <String>{key}, pending = <String>[key];
    while (pending.isNotEmpty) {
      for (final next in graph[pending.removeLast()]!.difference(seen)) {
        seen.add(next);
        pending.add(next);
      }
    }
    return seen.toList()..sort();
  }

  static int freeRegions(Map<String, dynamic> c, Map placed) {
    final byId = {for (final p in pieces(c)) p['id']: p};
    final occupied = {
      for (final e in placed.entries) ...cells(byId[e.key]!, e.value as List)
    };
    final remaining = points(c['playArea']).toSet().difference(occupied);
    var count = 0;
    const steps = [
      Position(0, -1),
      Position(1, 0),
      Position(0, 1),
      Position(-1, 0)
    ];
    while (remaining.isNotEmpty) {
      final seed = remaining.first;
      remaining.remove(seed);
      final pending = [seed];
      count++;
      while (pending.isNotEmpty) {
        final point = pending.removeLast();
        for (final step in steps) {
          final next = point + step;
          if (remaining.remove(next)) pending.add(next);
        }
      }
    }
    return count;
  }

  static String? freeSpaceProblem(Map<String, dynamic> c, Map placed) => c[
                  'freeSpace'] ==
              true &&
          freeRegions(c, placed) > 1
      ? 'That move seals an empty pocket. Keep all empty play cells connected.'
      : null;

  static int transferCost(Map placed, String key, List? placement) {
    final old = placed[key] as List?;
    if (old == null || placement == null) return 1;
    return ((old[0] as int) - (placement[0] as int)).abs() +
        ((old[1] as int) - (placement[1] as int)).abs();
  }

  static String? transferProblem(Map<String, dynamic> c, Map placed, int phase,
      String key, List? placement,
      {int steps = 0, int lifts = 0, List? roster}) {
    final rule = phase > 0 ? c['transfer'] as Map? : null;
    if (rule == null) return null;
    final byId = {for (final p in pieces(c)) p['id']: p};
    final cost = transferCost(placed, key, placement);
    if (steps + cost > (rule['maxSteps'] as int)) {
      return 'Step limit reached. Undo to try a shorter route.';
    }
    if (placement == null) {
      final slots = roster == null
          ? byId.length - placed.length
          : roster.where((key) => !placed.containsKey(key)).length;
      final extra = roster == null || roster.contains(key) ? 1 : 0;
      if (slots + extra > (rule['trayCapacity'] as int? ?? 1)) {
        return 'The tray slot is occupied. Place that piece back first.';
      }
      if (lifts >= (rule['maxRemovals'] as int? ?? 1)) {
        return 'Tray removal limit reached. Undo to choose a different removal.';
      }
    } else if (placed.containsKey(key) && rule['slideOnly'] == true) {
      final old = placed[key] as List;
      if (placement[2] != old[2])
        return 'Return the piece to the tray before rotating it.';
      final dx = (placement[0] as int) - (old[0] as int),
          dy = (placement[1] as int) - (old[1] as int);
      if (dx != 0 && dy != 0)
        return 'Slide horizontally or vertically. Turn in a separate move.';
      final group = linkedGroup(c, placed, key);
      final occupied = {
        for (final e in placed.entries)
          if (!group.contains(e.key)) ...cells(byId[e.key]!, e.value as List)
      };
      final area = points(rule['area']).toSet();
      for (var step = 1; step <= cost; step++) {
        final anchor = [
          (old[0] as int) + dx.sign * step,
          (old[1] as int) + dy.sign * step,
          old[2],
          ...old.skip(3)
        ];
        final updates = linkedPlacements(c, placed, key, anchor);
        final swept = [
          for (final e in updates.entries) ...cells(byId[e.key]!, e.value)
        ];
        if (swept.any((p) => !area.contains(p)))
          return 'A blocked square stops this slide.';
        if (swept.any(occupied.contains))
          return 'Another piece blocks this slide.';
      }
    }
    if (rule['keepEdges'] == true) {
      final after = Map<dynamic, dynamic>.from(placed)..remove(key);
      if (placement != null)
        after.addAll(linkedPlacements(c, placed, key, placement));
      final marked = <String, List<dynamic>>{};
      for (final e in after.entries) {
        for (final edge in edges(byId[e.key]!, e.value as List)) {
          final p = edge['position'] as Position;
          marked['${p.x},${p.y},${edge['direction']}'] = [
            e.key,
            edge['symbol']
          ];
        }
      }
      const offsets = [
        Position(0, -1),
        Position(1, 0),
        Position(0, 1),
        Position(-1, 0)
      ];
      for (final e in marked.entries) {
        final raw = e.key.split(',').map(int.parse).toList(), d = raw[2];
        final other = marked[
            '${raw[0] + offsets[d].x},${raw[1] + offsets[d].y},${(d + 2) % 4}'];
        if (other == null || other[0] == e.value[0] || other[1] != e.value[1]) {
          return 'Keep the numbered edges connected during the transfer.';
        }
      }
    }
    return null;
  }

  static String? insertionProblem(
      Map<String, dynamic> c, Map placed, String key, List? placement) {
    final rule = c['insertion'] as Map?;
    if (rule == null) return null;
    final byId = {for (final p in pieces(c)) p['id']: p};
    final piece = byId[key]!, side = piece['entrySide'];
    if (side is! int || side < 0 || side > 3)
      return 'This piece needs an entry side (0-3).';
    final area = points(rule['area']).toSet();
    final width = c['size'][0] as int, height = c['size'][1] as int;
    final occupied = {
      for (final e in placed.entries)
        if (e.key != key) ...cells(byId[e.key]!, e.value as List)
    };
    final old = placed[key] as List?;
    if (placement != null && old != null) {
      if (placement[2] != old[2])
        return 'Return the piece through its entry side before rotating it.';
      final dx = (placement[0] as int) - (old[0] as int),
          dy = (placement[1] as int) - (old[1] as int);
      if (dx != 0 && dy != 0)
        return 'Slide horizontally or vertically. Turn in a separate move.';
      for (var step = 1; step <= dx.abs() + dy.abs(); step++) {
        final swept = cells(piece, [
          (old[0] as int) + dx.sign * step,
          (old[1] as int) + dy.sign * step,
          old[2]
        ]);
        if (swept.any((p) => !area.contains(p)))
          return 'A wall blocks this slide.';
        if (swept.any(occupied.contains))
          return 'Another piece blocks this slide.';
      }
      return null;
    }
    final anchor = placement ?? old!;
    const offsets = [
      Position(0, -1),
      Position(1, 0),
      Position(0, 1),
      Position(-1, 0)
    ];
    final delta = offsets[side];
    var extent = 0;
    for (final p in points(piece['cells'])) {
      if (p.x > extent) extent = p.x;
      if (p.y > extent) extent = p.y;
    }
    for (var step = 1; step < width + height + extent + 3; step++) {
      final swept = cells(piece, [
        (anchor[0] as int) + delta.x * step,
        (anchor[1] as int) + delta.y * step,
        anchor[2]
      ]);
      final inside = swept
          .where((p) => p.x >= 0 && p.y >= 0 && p.x < width && p.y < height)
          .toList();
      if (inside.isEmpty) return null;
      if (inside.any((p) => !area.contains(p) || occupied.contains(p))) {
        return 'Clear the route to the ${[
          'top',
          'right',
          'bottom',
          'left'
        ][side]} entry. Pieces cannot jump over walls or other pieces.';
      }
    }
    return 'No clear route to the entry side.';
  }

  static String? supportProblem(Map<String, dynamic> c, Map placements) {
    if (c['support'] != true) return null;
    final byId = {for (final p in pieces(c)) p['id']: p};
    final occupied = <Position, String>{
      for (final e in placements.entries)
        for (final p in cells(byId[e.key]!, e.value as List)) p: e.key as String
    };
    return unsupportedTiles(occupied, (c['size'][1] as int) - 1).isEmpty
        ? null
        : 'Every piece needs support from the floor or a supported piece below. Remove upper pieces first.';
  }

  @override
  List<GameEvent> executeActionResolution(
    GameAction action,
    LevelState state,
    GameDefinition game,
  ) {
    final c = game.systemConfig(id, {}), v = state.variables, prefix = '$id.';
    final names = [
      c['placeAction'] ?? 'place_piece',
      c['removeAction'] ?? 'remove_piece',
      c['nextAction'] ?? 'next_target',
      c['changeAction'] ?? 'change_piece',
      c['turnAction'] ?? 'turn_piece',
      c['rotateAction'] ?? 'rotate_piece',
      c['swapAction'] ?? 'swap_echo',
    ];
    if (!names.contains(action.actionId)) return [];
    final placed = Map<String, dynamic>.from(
      v['${prefix}placements'] as Map? ?? {},
    );
    final moved = List<String>.from(v['${prefix}moved'] as List? ?? []);
    final phase = v['${prefix}phase'] as int? ?? 0;
    final rawKey = action.params['piece'],
        key = rawKey is String ? rawKey : null;
    final limits = c['limits'] as Map?;
    if (action.actionId == names[5]) {
      if (limits == null ||
          key == null ||
          !pieces(c).any((p) => p['id'] == key))
        return [GameEvent.actionVetoed('Select a piece to rotate.')];
      if ((v['${prefix}rotationsUsed'] as int? ?? 0) >=
          (limits['rotations'] as int))
        return [
          GameEvent.actionVetoed(
              'Rotation budget reached. Undo to recover rotations.')
        ];
      if (phase > 0 &&
          placed.containsKey(key) &&
          (c['transfer'] as Map?)?['slideOnly'] == true)
        return [
          GameEvent.actionVetoed(
              'Return the piece to the tray before rotating it.')
        ];
      final pending =
          Map<String, dynamic>.from(v['${prefix}previewRotations'] as Map);
      final rotation = ((pending[key] as int? ?? 0) + 1) % 4;
      if (placed.containsKey(key)) {
        final old = placed[key] as List;
        final updates = linkedPlacements(
            c, placed, key, [old[0], old[1], rotation, ...old.skip(3)]);
        for (final e in updates.entries) {
          pending[e.key] = e.value[2];
        }
      } else {
        pending[key] = rotation;
      }
      v['${prefix}previewRotations'] = pending;
      v['${prefix}rotationsUsed'] =
          (v['${prefix}rotationsUsed'] as int? ?? 0) + 1;
      _settle(state, game);
      return [
        GameEvent.variableChanged('${prefix}previewRotations', null, pending)
      ];
    }
    if (limits != null &&
        action.actionId != names[2] &&
        (v['${prefix}movesUsed'] as int? ?? 0) >= (limits['moves'] as int))
      return [
        GameEvent.actionVetoed(
            'Move budget reached. Undo to try a shorter solution.')
      ];
    if (action.actionId == names[2]) {
      if (v['${prefix}fit'] != 1 ||
          phase + 1 >= (c['targets'] as List).length) {
        return [
          GameEvent.actionVetoed(
            'Complete the current target before continuing.',
          ),
        ];
      }
      v['${prefix}phase'] = phase + 1;
      v['${prefix}moved'] = <String>[];
      if (c['transfer'] != null) {
        v['${prefix}transferSteps'] = 0;
        v['${prefix}removalsUsed'] = 0;
        v['${prefix}transferRoster'] = placed.keys.toList()..sort();
      }
    } else {
      var cost = 1;
      if (action.actionId == names[0]) {
        final raw = action.params['position'];
        final placement = raw is List && raw.length == 2
            ? [...raw, action.params['rotation'] ?? 0]
            : <dynamic>[];
        final piece = pieces(c).where((p) => p['id'] == key).firstOrNull;
        if (piece?['variants'] != null && placement.isNotEmpty)
          placement.add((v['${prefix}forms'] as Map?)?[key] ?? 0);
        if (c['rotationLinks'] != null &&
            piece != null &&
            placement.length >= 3 &&
            placement[2] !=
                ((v['${prefix}orientations'] as Map?)?[key] ??
                    piece['startRotation'] ??
                    0))
          return [
            GameEvent.actionVetoed(
                'Use Rotate so paired orientations change together.')
          ];
        if (limits != null &&
            piece != null &&
            placement.length >= 3 &&
            placement[2] != ((v['${prefix}previewRotations'] as Map)[key] ?? 0))
          return [
            GameEvent.actionVetoed(
                'Use Rotate to change the piece orientation.')
          ];
        final error = problem(c, placed, phase, moved, key, placement,
            steps: v['${prefix}transferSteps'] as int? ?? 0,
            lifts: v['${prefix}removalsUsed'] as int? ?? 0);
        if (error != null) return [GameEvent.actionVetoed(error)];
        if (placed[key] is List &&
            (placed[key] as List).join(',') == placement.join(',')) {
          return [GameEvent.actionVetoed('That piece is already there.')];
        }
        cost = transferCost(placed, key!, placement);
        final group = linkedGroup(c, placed, key);
        final updates = linkedPlacements(c, placed, key, placement);
        placed.addAll(updates);
        if (limits != null) {
          v['${prefix}previewRotations'] = {
            ...v['${prefix}previewRotations'] as Map,
            for (final e in updates.entries) e.key: e.value[2]
          };
        }
        if (c['linkedMovement'] != null && group.length > 1) {
          v['${prefix}linkMoved'] = 1;
          if (linkedGroup(c, placed, key).length < group.length)
            v['${prefix}linkReleased'] = 1;
        }
      } else if (action.actionId == names[6]) {
        final partner = key == null ? null : echoPartner(c, placed, key);
        if (c['echoSwap'] != true || key == null || partner == null)
          return [GameEvent.actionVetoed('Select an echo partner to swap.')];
        if (phase > 0 && (c['transfer'] as Map?)?['slideOnly'] == true)
          return [
            GameEvent.actionVetoed(
                'Swapping is not allowed during a slide-only transfer.')
          ];
        final proposed = Map<String, dynamic>.from(placed);
        final pending = v['${prefix}previewRotations'] as Map? ?? {};
        for (final pair in [
          [key, partner],
          [partner, key]
        ]) {
          final old = placed[pair[0]] as List, anchor = placed[pair[1]] as List;
          proposed[pair[0]] = [
            anchor[0],
            anchor[1],
            pending[pair[0]] ?? old[2],
            ...old.skip(3)
          ];
        }
        for (final member in [key, partner]) {
          final others = Map<String, dynamic>.from(proposed)..remove(member);
          final error = problem(
              c, others, phase, moved, member, proposed[member] as List);
          if (error != null)
            return [GameEvent.actionVetoed('Echo swap blocked: $error')];
        }
        placed
          ..clear()
          ..addAll(proposed);
        if (limits != null)
          v['${prefix}previewRotations'] = {
            ...pending,
            for (final member in [key, partner])
              member: (proposed[member] as List)[2]
          };
        v['${prefix}echoSwaps'] = (v['${prefix}echoSwaps'] as int? ?? 0) + 1;
      } else if (action.actionId == names[4]) {
        if (c['rotationLinks'] == null ||
            key == null ||
            !pieces(c).any((p) => p['id'] == key))
          return [GameEvent.actionVetoed('Select a piece to rotate.')];
        final group = rotationGroup(c, key);
        final orientations =
            Map<String, dynamic>.from(v['${prefix}orientations'] as Map? ?? {});
        final proposed = Map<String, dynamic>.from(placed);
        for (final member in group) {
          orientations[member] = ((orientations[member] as int? ?? 0) + 1) % 4;
          if (placed.containsKey(member)) {
            final pose = List<dynamic>.from(placed[member] as List);
            pose[2] = orientations[member];
            proposed[member] = pose;
          }
        }
        for (final member in group) {
          if (proposed.containsKey(member)) {
            final others = Map<String, dynamic>.from(proposed)..remove(member);
            final error = problem(
                c, others, phase, moved, member, proposed[member] as List);
            if (error != null)
              return [
                GameEvent.actionVetoed('Paired rotation blocked: $error')
              ];
          }
        }
        if (group.length > 1 && group.where(placed.containsKey).length >= 2)
          v['${prefix}pairedTurned'] = 1;
        placed
          ..clear()
          ..addAll(proposed);
        v['${prefix}orientations'] = orientations;
      } else if (action.actionId == names[3]) {
        final piece = pieces(c).where((p) => p['id'] == key).firstOrNull;
        if (piece == null ||
            piece['variants'] == null ||
            !placed.containsKey(key))
          return [
            GameEvent.actionVetoed(
                'Place a changeable piece on a workshop first.')
          ];
        final old = placed[key] as List;
        if (!cells(piece, old)
            .any(points(c['variantCells'] ?? []).toSet().contains))
          return [
            GameEvent.actionVetoed(
                'Move the piece onto a workshop to change form.')
          ];
        final form = ((old.length > 3 ? old[3] as int : 0) + 1) %
            (piece['variants'] as List).length;
        final pose = [old[0], old[1], old[2], form];
        final error = problem(c, placed, phase, moved, key, pose);
        if (error != null) return [GameEvent.actionVetoed(error)];
        placed[key!] = pose;
        v['${prefix}forms'] = {...v['${prefix}forms'] as Map? ?? {}, key: form};
      } else {
        if (!placed.containsKey(key))
          return [GameEvent.actionVetoed('Select a placed piece to remove.')];
        if (phase > 0 &&
            !moved.contains(key) &&
            moved.length >= (c['maxMoved'] as int? ?? pieces(c).length)) {
          return [
            GameEvent.actionVetoed(
              'Piece-move limit reached. Undo to try a different piece.',
            ),
          ];
        }
        if (linkedGroup(c, placed, key!).length > 1)
          return [
            GameEvent.actionVetoed(echoPartner(c, placed, key) != null
                ? 'Echo partners stay on the board. Move or rotate either to control both.'
                : (c['linkedMovement'] as Map?)?['releaseCells'] == null
                    ? 'This group is permanently bonded. Use Undo to reverse a connection.'
                    : 'This group is linked. Reach a release pad before returning a piece.')
          ];
        final remaining = Map<String, dynamic>.from(placed)..remove(key);
        final error = transferProblem(c, placed, phase, key, null,
                steps: v['${prefix}transferSteps'] as int? ?? 0,
                lifts: v['${prefix}removalsUsed'] as int? ?? 0,
                roster: v['${prefix}transferRoster'] as List?) ??
            insertionProblem(c, placed, key, null) ??
            supportProblem(c, remaining) ??
            freeSpaceProblem(c, remaining);
        if (error != null) return [GameEvent.actionVetoed(error)];
        placed.remove(key);
        if ((v['${prefix}forms'] as Map?)?.containsKey(key) == true)
          v['${prefix}forms'] = {...v['${prefix}forms'] as Map, key: 0};
      }
      if (limits != null)
        v['${prefix}movesUsed'] = (v['${prefix}movesUsed'] as int? ?? 0) + 1;
      if (phase > 0 && !moved.contains(key)) moved.add(key);
      v['${prefix}placements'] = placed;
      v['${prefix}moved'] = moved;
      if (phase > 0 && c['transfer'] != null) {
        v['${prefix}transferSteps'] =
            (v['${prefix}transferSteps'] as int? ?? 0) + cost;
        if (action.actionId == names[1])
          v['${prefix}removalsUsed'] =
              (v['${prefix}removalsUsed'] as int? ?? 0) + 1;
      }
    }
    _settle(state, game);
    return [GameEvent.variableChanged('${prefix}placements', null, placed)];
  }

  @override
  List<GameEvent> executeLoadSettle(LevelState state, GameDefinition game) {
    _settle(state, game);
    return [];
  }

  void _settle(LevelState state, GameDefinition game) {
    final c = game.systemConfig(id, {}), v = state.variables, prefix = '$id.';
    if (c['transfer'] != null) {
      v.putIfAbsent('${prefix}transferSteps', () => 0);
      v.putIfAbsent('${prefix}removalsUsed', () => 0);
    }
    if (pieces(c).any((p) => p['variants'] != null))
      v.putIfAbsent(
          '${prefix}forms',
          () => {
                for (final p in pieces(c))
                  if (p['variants'] != null) p['id']: 0
              });
    if (c['linkedMovement'] != null) {
      v.putIfAbsent('${prefix}linkMoved', () => 0);
      v.putIfAbsent('${prefix}linkReleased', () => 0);
    }
    final placed = v['${prefix}placements'] as Map? ?? {},
        phase = v['${prefix}phase'] as int? ?? 0;
    if (c['echoSwap'] == true) v.putIfAbsent('${prefix}echoSwaps', () => 0);
    if (c['limits'] != null) {
      v.putIfAbsent('${prefix}movesUsed', () => 0);
      v.putIfAbsent('${prefix}rotationsUsed', () => 0);
      v.putIfAbsent(
          '${prefix}previewRotations',
          () => {
                for (final p in pieces(c))
                  p['id']: placed.containsKey(p['id'])
                      ? (placed[p['id']] as List)[2]
                      : 0
              });
    }
    if (c['rotationLinks'] != null) {
      v.putIfAbsent(
          '${prefix}orientations',
          () => {
                for (final p in pieces(c))
                  p['id']: placed.containsKey(p['id'])
                      ? (placed[p['id']] as List)[2]
                      : p['startRotation'] ?? 0
              });
      v.putIfAbsent('${prefix}pairedTurned', () => 0);
    }
    final target = points(c['targets'][phase]).toSet(),
        byId = {for (final p in pieces(c)) p['id']: p};
    final occupied = <Position, String>{},
        marked = <String, Map<String, dynamic>>{};
    final lightConfig = c['lights'] as Map?;
    final lights = points(lightConfig?['initial'] ?? []).toSet();
    const steps = [
      Position(0, -1),
      Position(1, 0),
      Position(0, 1),
      Position(-1, 0),
    ];
    for (final entry in placed.entries) {
      final p = byId[entry.key]!, placement = entry.value as List;
      for (final cell in cells(p, placement)) {
        occupied[cell] = entry.key as String;
      }
      for (final e in edges(p, placement)) {
        final a = e['position'] as Position;
        marked['${a.x},${a.y},${e['direction']}'] = {
          'id': entry.key,
          'symbol': e['symbol'],
        };
      }
      if (p['pulse'] != null) {
        final a =
            transform(p, Position.fromJson(p['pulse']), placement[2] as int) +
                Position(placement[0] as int, placement[1] as int);
        for (final d in steps) {
          final q = a + d;
          if (target.contains(q)) {
            if (!lights.add(q)) lights.remove(q);
          }
        }
      }
    }
    var edgeErrors = 0;
    for (final entry in marked.entries) {
      final a = entry.key.split(',').map(int.parse).toList(), direction = a[2];
      final q = Position(a[0], a[1]) + steps[direction];
      final other = marked['${q.x},${q.y},${(direction + 2) % 4}'];
      if (other == null ||
          other['id'] == entry.value['id'] ||
          other['symbol'] != entry.value['symbol']) edgeErrors++;
    }
    if (c['allowUnused'] == true) {
      for (final p in pieces(c)) {
        if (!placed.containsKey(p['id']))
          edgeErrors += (p['edges'] as List? ?? []).length;
      }
    }
    final echoOk = (c['echoLinks'] as List? ?? [])
        .every((pair) => (pair as List).every(placed.containsKey));
    var contactErrors = 0;
    if (c.containsKey('neighborCounts') || c.containsKey('forbiddenContacts')) {
      final neighbors = {for (final key in byId.keys) key: <String>{}};
      for (final entry in occupied.entries) {
        for (final d in steps) {
          final other = occupied[entry.key + d];
          if (other != null && other != entry.value) {
            neighbors[entry.value]!.add(other);
          }
        }
      }
      final counts = {for (final e in neighbors.entries) e.key: e.value.length};
      for (final e in (c['neighborCounts'] as Map? ?? {}).entries) {
        if (counts[e.key] != e.value) contactErrors++;
      }
      for (final pair in c['forbiddenContacts'] as List? ?? []) {
        if (neighbors[pair[0]]?.contains(pair[1]) == true) contactErrors++;
      }
      v['${prefix}neighborCounts'] = counts;
      v['${prefix}contactErrors'] = contactErrors;
    }
    final wanted = points(lightConfig?['target'] ?? []).toSet();
    final lightErrors = lightConfig == null
        ? 0
        : lights.difference(wanted).length + wanted.difference(lights).length;
    final totals = c.containsKey('rowTotals') ? rowSums(c, occupied) : <int>[];
    final wantedRows = c['rowTotals'] as List? ?? [];
    final rowErrors = [
      for (var i = 0; i < totals.length; i++)
        if (totals[i] != wantedRows[i]) i
    ].length;
    if (c.containsKey('rowTotals')) {
      v.addAll({'${prefix}rowSums': totals, '${prefix}rowErrors': rowErrors});
    }
    final columns =
        c.containsKey('columnTotals') ? columnSums(c, occupied) : <int>[];
    final wantedColumns = c['columnTotals'] as List? ?? [];
    final columnErrors = [
      for (var i = 0; i < columns.length; i++)
        if (columns[i] != wantedColumns[i]) i
    ].length;
    if (c.containsKey('columnTotals')) {
      v.addAll({
        '${prefix}columnSums': columns,
        '${prefix}columnErrors': columnErrors
      });
    }
    final stable = c['support'] != true ||
        unsupportedTiles(occupied, (c['size'][1] as int) - 1).isEmpty;
    final formErrors = pieces(c)
        .where((p) =>
            p.containsKey('requiredVariant') &&
            ((v['${prefix}forms'] as Map?)?[p['id']] ?? 0) !=
                p['requiredVariant'])
        .length;
    if (pieces(c).any((p) => p['variants'] != null))
      v['${prefix}formErrors'] = formErrors;
    final linked = c['linkedMovement'] as Map? ?? {};
    final linksOk = (linked['requireMove'] != true ||
            v['${prefix}linkMoved'] == 1) &&
        (linked['requireRelease'] != true || v['${prefix}linkReleased'] == 1);
    if (c['freeSpace'] == true)
      v['${prefix}freeRegions'] = freeRegions(c, placed);
    final fit = occupied.keys.toSet().difference(target).isEmpty &&
        target.difference(occupied.keys.toSet()).isEmpty &&
        (c['allowUnused'] == true || placed.length == byId.length) &&
        echoOk &&
        edgeErrors == 0 &&
        lightErrors == 0 &&
        rowErrors == 0 &&
        columnErrors == 0 &&
        stable &&
        formErrors == 0 &&
        contactErrors == 0 &&
        linksOk &&
        (c['requirePairedTurn'] != true || v['${prefix}pairedTurned'] == 1) &&
        freeSpaceProblem(c, placed) == null;
    final sorted = lights.toList()
      ..sort((a, b) => a.x == b.x ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
    v.addAll({
      '${prefix}fit': fit ? 1 : 0,
      '${prefix}complete':
          fit && phase == (c['targets'] as List).length - 1 ? 1 : 0,
      '${prefix}filled': occupied.keys.toSet().intersection(target).length,
      '${prefix}edgeErrors': edgeErrors,
      '${prefix}lightErrors': lightErrors,
      '${prefix}lights': [
        for (final p in sorted) [p.x, p.y],
      ],
    });
    for (var y = 0; y < state.board.height; y++) {
      for (var x = 0; x < state.board.width; x++) {
        final key = occupied[Position(x, y)];
        state.board.setEntity(
          c['piecesLayer'] as String? ?? 'pieces',
          Position(x, y),
          key == null
              ? null
              : EntityInstance(byId[key]!['kind'] as String, {'piece': key}),
        );
      }
    }
  }

  @override
  List<String> observationStatusLines(
    LevelState state,
    GameDefinition game,
    initialBoard,
  ) {
    final v = state.variables, c = game.systemConfig(id, {});
    return [
      'Tile placement',
      'phase: ${(v['$id.phase'] as int? ?? 0) + 1}/${(c['targets'] as List).length}',
      'placements: ${v['$id.placements'] ?? {}}',
      'moved: ${v['$id.moved'] ?? []}',
      'edge mismatches: ${v['$id.edgeErrors'] ?? 0}; light mismatches: ${v['$id.lightErrors'] ?? 0}',
    ];
  }
}
