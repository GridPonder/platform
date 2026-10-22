import 'dart:collection';

import '../engine/game_system.dart';
import '../models/entity.dart';
import '../models/event.dart';
import '../models/game_action.dart';
import '../models/game_definition.dart';
import '../models/game_state.dart';
import '../models/position.dart';

/// Every pass of the grow loop joins a cell, merges a pool or ends the pool's
/// growth, and every spill moves water strictly downhill, so settling always
/// terminates. The cap guards against a malformed level only.
const int _maxSteps = 100000;

/// FillSpillSystem — see docs/dsl/04_systems.md.
///
/// Standing water with a fixed volume, settled over a height map. Water is
/// never created or destroyed. It runs downhill, fills the lowest hollow first
/// and rises evenly; when it reaches the lowest lip of its hollow it stops
/// there and the rest pours over into the next hollow. Water trapped below a
/// lip stays trapped. Two pools that meet become one.
///
/// Every settle re-pours each pool's whole volume at its lowest cell, which
/// reproduces a stable board exactly and resolves an unstable one (a gate just
/// opened) the way the water would flow. Volumes stay whole numbers: a pool is
/// only ever divided at a lip, and lips are ground heights.
///
/// Phases: gates toggle in `action_resolution` (declare this system before
/// `avatar_navigation`); the water settles in `npc_resolution` and once at
/// level load.
///
/// Optional `seeps` are slow leaks: after each turn's settle (not at load)
/// every seep moves up to `rate` units from the highest pool beside it to the
/// lowest surface beside it, taking only water above its sill and never
/// leaving the far side higher than the near side.
///
/// Optional `siphons` are pipes over a bank: an `empty` siphon starts (turns
/// `running`) whenever the highest pool beside it stands above its crest, the
/// ground height under it; a running siphon keeps drawing up to `rate` units a
/// turn from that pool, down to its intake floor, and turns `empty` on the
/// first turn it moves nothing. The avatar walking into a running siphon vents
/// it. Siphons act after the seeps.
///
/// Markers may add an `over` kind and a `maxDepth`: such a marker is `wet`
/// only while the water on it stands more than 0 and at most `maxDepth` deep,
/// and `over` when deeper.
///
/// Tolerance contract (both engines must agree): a missing or non-map
/// `heights` makes the system inert. Ground kinds absent from `heights` are
/// banks. A water cell whose `units` param is missing or not an integer
/// contributes nothing; a pool whose units sum to zero or less vanishes. Gate
/// and marker entries that are not maps with string kinds are ignored. A
/// non-map `seeps` entry or a `rate` that is not a positive integer disables
/// seeps; the same holds for `siphons`, which also need string `empty` and
/// `running` kinds. A marker pair with an `over` kind but no positive integer
/// `maxDepth` ignores `over`.
class FillSpillSystem extends GameSystem {
  const FillSpillSystem({required super.id}) : super(type: 'fill_spill');

  @override
  List<GameEvent> executeActionResolution(
    GameAction action,
    LevelState state,
    GameDefinition game,
  ) {
    final config = game.systemConfig(id, {});
    if (config['heights'] is! Map) return const [];
    final rawGates = config['gates'];
    final gates = <Map>[
      if (rawGates is List)
        for (final g in rawGates)
          if (g is Map && g['closed'] is String && g['open'] is String) g,
    ];
    final siphons = _SiphonConfig.parse(config['siphons']);
    if (gates.isEmpty && siphons.running == null) return const [];
    if (action.actionId != (config['gateAction'] ?? 'move')) return const [];
    final direction = action.direction;
    final avatar = state.avatar;
    final pos = avatar.position;
    if (direction == null || !avatar.enabled || pos == null) return const [];
    final target = pos.moved(direction);
    if (!state.board.isInBounds(target)) return const [];
    final running = siphons.running;
    if (running != null) {
      final entity = state.board.getEntity(siphons.layer, target);
      if (entity != null && entity.kind == running) {
        state.board.setEntity(
          siphons.layer,
          target,
          EntityInstance(
            siphons.empty!,
            Map<String, dynamic>.from(entity.params),
          ),
        );
        return [
          GameEvent.cellTransformed(
              target, running, siphons.empty!, siphons.layer),
        ];
      }
    }
    for (final gate in gates) {
      final layer = (gate['layer'] as String?) ?? 'objects';
      final entity = state.board.getEntity(layer, target);
      if (entity == null) continue;
      final String wanted;
      if (entity.kind == gate['closed']) {
        wanted = gate['open'] as String;
      } else if (entity.kind == gate['open']) {
        final waterLayer = (config['waterLayer'] as String?) ?? 'water';
        // A board cannot be dropped against standing water.
        if (state.board.getEntity(waterLayer, target) != null) return const [];
        wanted = gate['closed'] as String;
      } else {
        continue;
      }
      state.board.setEntity(
        layer,
        target,
        EntityInstance(wanted, Map<String, dynamic>.from(entity.params)),
      );
      return [GameEvent.cellTransformed(target, entity.kind, wanted, layer)];
    }
    return const [];
  }

  @override
  List<GameEvent> executeNpcResolution(LevelState state, GameDefinition game) =>
      _settle(state, game, turn: true);

  @override
  List<GameEvent> executeLoadSettle(LevelState state, GameDefinition game) =>
      _settle(state, game, turn: false);

  List<GameEvent> _settle(
    LevelState state,
    GameDefinition game, {
    required bool turn,
  }) {
    final config = game.systemConfig(id, {});
    final heightOf = config['heights'];
    if (heightOf is! Map) return const [];
    final board = state.board;
    final width = board.width;
    final groundLayer = (config['groundLayer'] as String?) ?? 'ground';
    final waterLayer = (config['waterLayer'] as String?) ?? 'water';
    final rawKinds = config['waterKinds'];
    final waterKinds = <String>[
      for (final k in (rawKinds is List ? rawKinds : const ['water']))
        if (k is String) k,
    ];
    final water = board.layers[waterLayer];
    if (waterKinds.isEmpty || water == null) return const [];

    var barrierLayer = 'objects';
    final barrierKinds = <String>{};
    final barriers = config['barriers'];
    if (barriers is Map) {
      barrierLayer = (barriers['layer'] as String?) ?? 'objects';
      final kinds = barriers['kinds'];
      if (kinds is List) {
        for (final k in kinds) {
          if (k is String) barrierKinds.add(k);
        }
      }
    }

    final seeps = _SeepConfig.parse(config['seeps']);
    final siphonConfig = _SiphonConfig.parse(config['siphons']);
    // Python collects siphons only when the running kind is truthy.
    final collectSiphons =
        siphonConfig.running != null && siphonConfig.running!.isNotEmpty;

    // Cells are indexed y * width + x, so index order is reading order.
    final heights = <int, int>{};
    final seepSills = <List<int>>[]; // [cell, sill], in reading order
    // (cell, crest, running), in reading order
    final siphons = <(int, int, bool)>[];
    for (var y = 0; y < board.height; y++) {
      for (var x = 0; x < width; x++) {
        final pos = Position(x, y);
        final ground = board.getEntity(groundLayer, pos);
        if (ground == null) continue;
        final h = heightOf[ground.kind];
        if (h is! int) continue;
        final blocker = board.getEntity(barrierLayer, pos);
        if (blocker != null && barrierKinds.contains(blocker.kind)) continue;
        if (seeps.kinds.isNotEmpty) {
          final seep = board.getEntity(seeps.layer, pos);
          if (seep != null && seeps.kinds.contains(seep.kind)) {
            seepSills.add([y * width + x, h]);
            continue;
          }
        }
        if (collectSiphons) {
          final pipe = board.getEntity(siphonConfig.layer, pos);
          if (pipe != null &&
              (pipe.kind == siphonConfig.empty ||
                  pipe.kind == siphonConfig.running)) {
            siphons.add((y * width + x, h, pipe.kind == siphonConfig.running));
            continue;
          }
        }
        heights[y * width + x] = h;
      }
    }

    // Existing pools: connected water cells; volume is the sum of `units`.
    final wet = <int, EntityInstance>{};
    for (final entry in water.entries()) {
      wet[entry.key.y * width + entry.key.x] = entry.value;
    }
    final seen = <int>{};
    final sources = <List<int>>[]; // [seed, units]
    final starts = wet.keys.toList()..sort();
    for (final start in starts) {
      if (seen.contains(start)) continue;
      final component = <int>[];
      final queue = Queue<int>()..add(start);
      seen.add(start);
      while (queue.isNotEmpty) {
        final cell = queue.removeFirst();
        component.add(cell);
        for (final other in _around(cell, width, board.height)) {
          if (wet.containsKey(other) && seen.add(other)) queue.add(other);
        }
      }
      var units = 0;
      for (final cell in component) {
        final u = wet[cell]!.params['units'];
        if (u is int) units += u;
      }
      final ground = [
        for (final c in component)
          if (heights.containsKey(c)) c,
      ];
      if (units <= 0 || ground.isEmpty) continue;
      sources.add([_lowestGround(ground, heights), units]);
    }

    var settler = _pourAll(heights, width, board.height, sources);
    if (turn) {
      for (final seep in seepSills) {
        settler = _seep(settler, seep[0], seep[1], seeps.rate);
      }
    }

    final siphonEvents = <GameEvent>[];
    if (turn) {
      for (final (cell, crest, running) in siphons) {
        final (next, now) =
            _siphon(settler, cell, crest, siphonConfig.rate, running);
        settler = next;
        if (now != running) {
          final old = running ? siphonConfig.running! : siphonConfig.empty!;
          final fresh = running ? siphonConfig.empty! : siphonConfig.running!;
          final pos = Position(cell % width, cell ~/ width);
          final entity = board.getEntity(siphonConfig.layer, pos)!;
          board.setEntity(
            siphonConfig.layer,
            pos,
            EntityInstance(fresh, Map<String, dynamic>.from(entity.params)),
          );
          siphonEvents.add(
            GameEvent.cellTransformed(pos, old, fresh, siphonConfig.layer),
          );
        }
      }
    }

    // Write the water layer back.
    final newWater = <int, EntityInstance>{};
    final depth = <int, List<int>>{}; // cell -> [num, den]
    for (final pool in settler.pools) {
      if (pool.cells.isEmpty || pool.units <= 0) continue;
      final num = pool.units + pool.heightSum;
      final den = pool.cells.length;
      final seed = _lowestGround(pool.cells, heights);
      for (final cell in pool.cells) {
        // depth = num/den - h ; band = ceil(depth) - 1, clamped
        final depthNum = num - heights[cell]! * den;
        depth[cell] = [depthNum, den];
        final band = (depthNum + den - 1) ~/ den - 1;
        final kind = waterKinds[band.clamp(0, waterKinds.length - 1)];
        final params = cell == seed
            ? <String, dynamic>{'units': pool.units}
            : <String, dynamic>{};
        newWater[cell] = EntityInstance(kind, params);
      }
    }

    var changed = false;
    for (final cell in {...wet.keys, ...newWater.keys}) {
      final old = wet[cell];
      final fresh = newWater[cell];
      if (old == null ||
          fresh == null ||
          old.kind != fresh.kind ||
          !_sameParams(old.params, fresh.params)) {
        board.setEntity(
          waterLayer,
          Position(cell % width, cell ~/ width),
          fresh,
        );
        changed = true;
      }
    }

    final wetCells = newWater.keys.toSet();
    final events = [
      ...siphonEvents,
      ..._applyMarkers(config, state, depth, width),
    ];
    _applyFlood(config, state, wetCells, width);
    if (changed) events.insert(0, GameEvent.waterSettled(newWater.length));
    return events;
  }

  List<GameEvent> _applyMarkers(
    Map<String, dynamic> config,
    LevelState state,
    Map<int, List<int>> depth,
    int width,
  ) {
    final markers = config['markers'];
    if (markers is! Map) return <GameEvent>[];
    final layerId = (markers['layer'] as String?) ?? 'objects';
    final layer = state.board.layers[layerId];
    if (layer == null) return <GameEvent>[];
    final rawPairs = markers['pairs'];
    final pairs = <Map>[
      if (rawPairs is List)
        for (final p in rawPairs)
          if (p is Map && p['dry'] is String && p['wet'] is String) p,
    ];
    final events = <GameEvent>[];
    for (final entry in layer.entries().toList()) {
      final pos = entry.key;
      final entity = entry.value;
      for (final pair in pairs) {
        final over = pair['over'];
        final maxDepth = pair['maxDepth'];
        final banded = over is String && maxDepth is int && maxDepth > 0;
        if (entity.kind != pair['dry'] &&
            entity.kind != pair['wet'] &&
            !(banded && entity.kind == over)) {
          continue;
        }
        final d = depth[pos.y * width + pos.x];
        final String wanted;
        if (!banded) {
          wanted = (d != null ? pair['wet'] : pair['dry']) as String;
        } else if (d == null || d[0] <= 0) {
          wanted = pair['dry'] as String;
        } else if (d[0] <= (maxDepth as int) * d[1]) {
          wanted = pair['wet'] as String;
        } else {
          wanted = over as String;
        }
        if (wanted != entity.kind) {
          state.board.setEntity(
            layerId,
            pos,
            EntityInstance(wanted, Map<String, dynamic>.from(entity.params)),
          );
          events.add(
            GameEvent.cellTransformed(pos, entity.kind, wanted, layerId),
          );
        }
        break;
      }
    }
    return events;
  }

  void _applyFlood(
    Map<String, dynamic> config,
    LevelState state,
    Set<int> wet,
    int width,
  ) {
    final flood = config['flood'];
    if (flood is! Map) return;
    final variable = flood['variable'];
    if (variable is! String || variable.isEmpty) return;
    var flooded = 0;
    final avatar = state.avatar;
    final pos = avatar.position;
    if ((flood['avatar'] ?? true) == true &&
        avatar.enabled &&
        pos != null &&
        wet.contains(pos.y * width + pos.x)) {
      flooded += 1;
    }
    final rawKinds = flood['kinds'];
    final kinds = <String>{
      if (rawKinds is List)
        for (final k in rawKinds)
          if (k is String) k,
    };
    final layer = state.board.layers[(flood['layer'] as String?) ?? 'objects'];
    if (kinds.isNotEmpty && layer != null) {
      for (final entry in layer.entries()) {
        if (kinds.contains(entry.value.kind) &&
            wet.contains(entry.key.y * width + entry.key.x)) {
          flooded += 1;
        }
      }
    }
    if (flooded > 0) {
      final current = state.variables[variable];
      state.variables[variable] = (current is int ? current : 0) + flooded;
    }
  }
}

/// The optional `seeps` config: slow leaks through the bank.
class _SeepConfig {
  final String layer;
  final Set<String> kinds;
  final int rate;
  const _SeepConfig(this.layer, this.kinds, this.rate);

  static _SeepConfig parse(Object? raw) {
    if (raw is! Map) return const _SeepConfig('objects', {}, 0);
    final layer = (raw['layer'] as String?) ?? 'objects';
    final rate = raw.containsKey('rate') ? raw['rate'] : 1;
    if (rate is! int || rate <= 0) return _SeepConfig(layer, const {}, 0);
    final kinds = raw['kinds'];
    return _SeepConfig(
        layer,
        {
          if (kinds is List)
            for (final k in kinds)
              if (k is String) k,
        },
        rate);
  }
}

/// The optional `siphons` config: pipes over a bank. [running] is null when
/// siphons are disabled.
class _SiphonConfig {
  final String layer;
  final String? empty;
  final String? running;
  final int rate;
  const _SiphonConfig(this.layer, this.empty, this.running, this.rate);

  static _SiphonConfig parse(Object? raw) {
    if (raw is! Map) return const _SiphonConfig('objects', null, null, 0);
    final layer = (raw['layer'] as String?) ?? 'objects';
    final empty = raw['empty'];
    final running = raw['running'];
    final rate = raw.containsKey('rate') ? raw['rate'] : 1;
    if (empty is! String || running is! String || rate is! int || rate <= 0) {
      return _SiphonConfig(layer, null, null, 0);
    }
    return _SiphonConfig(layer, empty, running, rate);
  }
}

/// Pour every [seed, units] source into a fresh settler, seeds in reading
/// order (ties keep list order — Dart's sort is not stable, so the index is
/// part of the key).
_Settler _pourAll(
  Map<int, int> heights,
  int width,
  int height,
  List<List<int>> sources,
) {
  final settler = _Settler(heights, width, height);
  final order = List<int>.generate(sources.length, (i) => i)
    ..sort((a, b) {
      final c = sources[a][0].compareTo(sources[b][0]);
      return c != 0 ? c : a.compareTo(b);
    });
  for (final i in order) {
    final units = sources[i][1];
    if (units <= 0) continue;
    final pending = <List<int>>[
      [units, sources[i][0]],
    ];
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      final spill = settler.pour(next[0], next[1]);
      if (spill != null) pending.add(spill);
    }
  }
  return settler;
}

/// One seep's turn: up to `rate` units leave the highest pool beside it (only
/// water standing above the sill) for the lowest surface beside it outside
/// that pool, unless that would leave the far side higher than the near side.
/// Returns the settler for the board afterwards.
_Settler _seep(_Settler settler, int cell, int sill, int rate) {
  final heights = settler.heights;
  final beside = _around(
    cell,
    settler.width,
    settler.height,
  ).where(heights.containsKey).toList();
  final wet = [
    for (final c in beside)
      if (settler.owner.containsKey(c)) c,
  ];
  if (wet.isEmpty) return settler;
  var source = wet.first;
  for (final c in wet.skip(1)) {
    final s = settler.surface(c);
    final b = settler.surface(source);
    if (_Settler._lt(b, s) || (_Settler._eq(s, b) && c < source)) source = c;
  }
  final level = settler.surface(source);
  if (!_Settler._lt([sill, 1], level)) return settler;
  final index = settler.owner[source]!;
  final others = [
    for (final c in beside)
      if (settler.owner[c] != index) c,
  ];
  if (others.isEmpty) return settler;
  final target = settler.lowest(others);
  if (!_Settler._lt(settler.surface(target), level)) return settler;
  final pool = settler.pools[index];
  final mouths = <int>{
    for (final c in beside)
      if (settler.owner[c] == index) c,
  };
  final (parts, amount) = _draw(heights, settler.width, settler.height,
      {...pool.cells}, pool.units, mouths, rate,
      minimumLevel: sill);
  if (amount <= 0) return settler;
  final sources = <List<int>>[];
  for (var i = 0; i < settler.pools.length; i++) {
    final p = settler.pools[i];
    if (i == index || p.cells.isEmpty || p.units <= 0) continue;
    sources.add([
      _lowestGround(p.cells, heights),
      p.units,
    ]);
  }
  for (final (cells, units) in parts) {
    if (units > 0) sources.add([_lowestGround(cells, heights), units]);
  }
  sources.add([target, amount]);
  final after = _pourAll(heights, settler.width, settler.height, sources);
  // No overshoot: the far side must not end up higher than the near side, or
  // two nearly level pools would trade a unit back and forth for ever.
  if (_Settler._lt(after.surface(source), after.surface(target))) {
    return settler;
  }
  return after;
}

/// Connected parts of a cell set, each found from its first cell in reading
/// order; parts listed in reading order of those cells.
List<Set<int>> _components(Set<int> cells, int width, int height) {
  final left = {...cells};
  final parts = <Set<int>>[];
  final starts = cells.toList()..sort();
  for (final start in starts) {
    if (!left.contains(start)) continue;
    final part = <int>{start};
    final queue = Queue<int>()..add(start);
    left.remove(start);
    while (queue.isNotEmpty) {
      final cell = queue.removeFirst();
      for (final other in _around(cell, width, height)) {
        if (left.remove(other)) {
          part.add(other);
          queue.add(other);
        }
      }
    }
    parts.add(part);
  }
  return parts;
}

/// Lowest-ground key (height, then reading order) of a cell, for `min`.
int _cmpGround(int a, int b, Map<int, int> heights) {
  final c = heights[a]!.compareTo(heights[b]!);
  return c != 0 ? c : a.compareTo(b);
}

/// Take up to [want] units out of one pool through adjacent [mouths].
/// Only the part joined to a mouth falls: when its surface reaches a height x that
/// divides the pool, every part that no longer touches a mouth is left
/// standing at exactly x. The draw stops when the lowest mouth cell would run
/// dry, or at [minimumLevel] when a seep's sill is higher.
/// Returns (parts, drawn): parts are (cells, units), the drawing part
/// last.
(List<(Set<int>, int)>, int) _draw(
  Map<int, int> heights,
  int width,
  int height,
  Set<int> startCells,
  int startUnits,
  Set<int> mouths,
  int want, {
  int? minimumLevel,
}) {
  var cells = startCells;
  var units = startUnits;
  final trapped = <(Set<int>, int)>[];
  var drawn = 0;
  while (drawn < want) {
    final inlet = [
      for (final c in mouths)
        if (cells.contains(c)) c,
    ];
    if (inlet.isEmpty) break;
    var floor = heights[inlet.first]!;
    for (final c in inlet) {
      if (heights[c]! < floor) floor = heights[c]!;
    }
    if (minimumLevel != null && minimumLevel > floor) floor = minimumLevel;
    var top = units; // level * cells.length
    for (final c in cells) {
      top += heights[c]!;
    }
    final n = cells.length;
    (int, List<Set<int>>)? split;
    final inner = <int>{
      for (final c in cells)
        if (heights[c]! > floor) heights[c]!,
    }.toList()
      ..sort((a, b) => b.compareTo(a));
    for (final x in inner) {
      if (x * n >= top) continue;
      final parts = _components(
        {
          for (final c in cells)
            if (heights[c]! < x) c,
        },
        width,
        height,
      );
      if (parts.length > 1) {
        split = (x, parts);
        break;
      }
    }
    final stop = split != null ? split.$1 : floor;
    var atStop = 0;
    for (final c in cells) {
      final h = heights[c]!;
      if (h < stop) atStop += stop - h;
    }
    final room = units - atStop;
    final take = want - drawn < room ? want - drawn : room;
    if (take > 0) {
      units -= take;
      drawn += take;
    }
    if (drawn >= want || split == null) break;
    final (x, parts) = split;
    final mouthParts = [
      for (final p in parts)
        if (p.any(mouths.contains)) p,
    ];
    if (mouthParts.isEmpty) break;
    // Each part's key: its lowest mouth cell (height, then reading order).
    int keyOf(Set<int> p) => p
        .where(mouths.contains)
        .reduce((a, b) => _cmpGround(a, b, heights) <= 0 ? a : b);
    var keep = mouthParts.first;
    var keepKey = keyOf(keep);
    for (final p in mouthParts.skip(1)) {
      final k = keyOf(p);
      if (_cmpGround(k, keepKey, heights) < 0) {
        keep = p;
        keepKey = k;
      }
    }
    for (final p in parts) {
      if (!identical(p, keep)) {
        var u = 0;
        for (final c in p) {
          u += x - heights[c]!;
        }
        trapped.add((p, u));
      }
    }
    cells = keep;
    units = 0;
    for (final c in keep) {
      units += x - heights[c]!;
    }
  }
  return ([...trapped, (cells, units)], drawn);
}

/// One siphon's turn. Returns (settler, running afterwards).
(_Settler, bool) _siphon(
  _Settler settler,
  int cell,
  int crest,
  int rate,
  bool running,
) {
  final heights = settler.heights;
  final beside = _around(
    cell,
    settler.width,
    settler.height,
  ).where(heights.containsKey).toList();
  final wet = [
    for (final c in beside)
      if (settler.owner.containsKey(c)) c,
  ];
  if (wet.isEmpty) return (settler, false);
  var source = wet.first;
  for (final c in wet.skip(1)) {
    final s = settler.surface(c);
    final b = settler.surface(source);
    if (_Settler._lt(b, s) || (_Settler._eq(s, b) && c < source)) source = c;
  }
  final level = settler.surface(source);
  if (!running && !_Settler._lt([crest, 1], level)) return (settler, false);
  final index = settler.owner[source]!;
  final others = [
    for (final c in beside)
      if (settler.owner[c] != index) c,
  ];
  if (others.isEmpty) return (settler, false);
  final target = settler.lowest(others);
  if (!_Settler._lt(settler.surface(target), level)) return (settler, false);
  final pool = settler.pools[index];
  final mouths = <int>{
    for (final c in beside)
      if (settler.owner[c] == index) c,
  };
  final rest = <List<int>>[];
  for (var i = 0; i < settler.pools.length; i++) {
    final p = settler.pools[i];
    if (i != index && p.cells.isNotEmpty && p.units > 0) {
      rest.add([_lowestGround(p.cells, heights), p.units]);
    }
  }
  var want = rate;
  while (want > 0) {
    final (parts, drawn) = _draw(heights, settler.width, settler.height,
        {...pool.cells}, pool.units, mouths, want);
    if (drawn <= 0) return (settler, false);
    final sources = <List<int>>[...rest];
    for (final (cells, units) in parts) {
      if (units > 0) sources.add([_lowestGround(cells, heights), units]);
    }
    sources.add([target, drawn]);
    final after = _pourAll(heights, settler.width, settler.height, sources);
    final drawing = parts.last.$1;
    final mouth = _lowestGround(mouths.where(drawing.contains), heights);
    // No overshoot: the outlet side must not end up above the intake side.
    if (!_Settler._lt(after.surface(mouth), after.surface(target))) {
      return (after, true);
    }
    want = drawn - 1;
  }
  return (settler, false);
}

bool _sameParams(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key) || a[key] != b[key]) return false;
  }
  return true;
}

/// Lowest ground cell; ties go to reading order.
int _lowestGround(Iterable<int> cells, Map<int, int> heights) {
  int? best;
  for (final c in cells) {
    if (best == null ||
        heights[c]! < heights[best]! ||
        (heights[c] == heights[best] && c < best)) {
      best = c;
    }
  }
  return best!;
}

/// In-bounds orthogonal neighbours: up, right, down, left.
Iterable<int> _around(int cell, int width, int height) sync* {
  final x = cell % width;
  final y = cell ~/ width;
  if (y > 0) yield cell - width;
  if (x < width - 1) yield cell + 1;
  if (y < height - 1) yield cell + width;
  if (x > 0) yield cell - 1;
}

/// A body of standing water. Its level is (units + heightSum) / cells.length,
/// kept as that exact fraction — never a double — so both engines agree.
class _Pool {
  Set<int> cells;
  int units;
  int heightSum;
  _Pool(this.cells, this.units, this.heightSum);
}

class _Settler {
  final Map<int, int> heights; // passable cells only
  final int width;
  final int height;
  final List<_Pool> pools = [];
  final Map<int, int> owner = {};
  int steps = 0;

  _Settler(this.heights, this.width, this.height);

  Iterable<int> neighbours(int cell) =>
      _around(cell, width, height).where(heights.containsKey);

  /// Water level on a wet cell, ground height on a dry one: [num, den].
  List<int> surface(int cell) {
    final index = owner[cell];
    if (index != null) {
      final pool = pools[index];
      return [pool.units + pool.heightSum, pool.cells.length];
    }
    return [heights[cell]!, 1];
  }

  static bool _lt(List<int> a, List<int> b) => a[0] * b[1] < b[0] * a[1];
  static bool _eq(List<int> a, List<int> b) => a[0] * b[1] == b[0] * a[1];

  /// The cell with the lowest surface; ties go to reading order.
  int lowest(Iterable<int> cells) {
    int? best;
    List<int>? bestSurface;
    for (final cell in cells) {
      final s = surface(cell);
      if (best == null ||
          _lt(s, bestSurface!) ||
          (_eq(s, bestSurface) && cell < best)) {
        best = cell;
        bestSurface = s;
      }
    }
    return best!;
  }

  void _merge(int into, int other) {
    final target = pools[into];
    final source = pools[other];
    for (final cell in source.cells) {
      owner[cell] = into;
    }
    target.cells = {...target.cells, ...source.cells};
    target.units += source.units;
    target.heightSum += source.heightSum;
    source.cells = <int>{};
    source.units = 0;
    source.heightSum = 0;
  }

  /// Add water at a cell: it runs downhill, then fills from the bottom.
  /// Returns the spill `[units, cell]` still to be poured, or null.
  List<int>? pour(int units, int start) {
    var cell = start;
    while (true) {
      final index = owner[cell];
      if (index != null) {
        pools[index].units += units;
        return _grow(index);
      }
      final here = [heights[cell]!, 1];
      final lower = [
        for (final d in neighbours(cell))
          if (_lt(surface(d), here)) d,
      ];
      if (lower.isEmpty) break;
      cell = lowest(lower);
    }
    pools.add(_Pool({cell}, units, heights[cell]!));
    final index = pools.length - 1;
    owner[cell] = index;
    return _grow(index);
  }

  /// Raise a pool until its water is spent or it reaches a lip.
  List<int>? _grow(int index) {
    while (true) {
      steps += 1;
      if (steps > _maxSteps) return null;
      final pool = pools[index];
      final count = pool.cells.length;
      final heightSum = pool.heightSum;
      final units = pool.units;
      final rim = <int>{};
      for (final cell in pool.cells) {
        for (final other in neighbours(cell)) {
          if (owner[other] != index) rim.add(other);
        }
      }
      if (rim.isEmpty) return null;
      final low = surface(lowest(rim));
      // The water cannot reach `low`: it settles below it.
      if (units * low[1] <= low[0] * count - heightSum * low[1]) return null;

      var merged = false;
      final ordered = rim.toList()..sort();
      for (final cell in ordered) {
        final other = owner[cell];
        if (other != null &&
            other != index &&
            pools[other].cells.isNotEmpty &&
            _eq(surface(cell), low)) {
          _merge(index, other);
          merged = true;
        }
      }
      if (merged) continue;

      // Every wet rim pool stands higher than `low`, so `low` is a dry ground
      // height: a whole number.
      final x = low[0] ~/ low[1];
      final plateau = <int>{};
      final queue = Queue<int>();
      for (final c in rim) {
        if (!owner.containsKey(c) && heights[c] == x) {
          plateau.add(c);
          queue.add(c);
        }
      }
      while (queue.isNotEmpty) {
        final cell = queue.removeFirst();
        for (final other in neighbours(cell)) {
          if (!plateau.contains(other) &&
              !owner.containsKey(other) &&
              heights[other] == x) {
            plateau.add(other);
            queue.add(other);
          }
        }
      }

      final lips = <int>[];
      final levelPools = <int>{};
      for (final cell in plateau) {
        for (final other in neighbours(cell)) {
          if (plateau.contains(other) || owner[other] == index) continue;
          final s = surface(other);
          if (_lt(s, [x, 1])) {
            lips.add(other);
          } else if (owner.containsKey(other) && _eq(s, [x, 1])) {
            levelPools.add(owner[other]!);
          }
        }
      }

      if (lips.isNotEmpty) {
        final kept = x * count - heightSum;
        // A previously submerged ridge can be dry at the spill level.
        // Split there and store each remaining volume on its own pool.
        final cells = {
          for (final cell in pool.cells)
            if (heights[cell]! < x) cell,
        };
        for (final cell in pool.cells) {
          owner.remove(cell);
        }
        pool.cells = {};
        pool.units = 0;
        pool.heightSum = 0;
        for (final part in _components(cells, width, height)) {
          final partHeight = part.fold<int>(0, (sum, c) => sum + heights[c]!);
          final partIndex = pools.length;
          pools.add(_Pool(part, x * part.length - partHeight, partHeight));
          for (final cell in part) {
            owner[cell] = partIndex;
          }
        }
        return [units - kept, lowest(lips)];
      }

      for (final cell in plateau) {
        owner[cell] = index;
      }
      pool.cells = {...pool.cells, ...plateau};
      pool.heightSum += x * plateau.length;
      final others = levelPools.toList()..sort();
      for (final other in others) {
        if (other != index && pools[other].cells.isNotEmpty) {
          _merge(index, other);
        }
      }
    }
  }
}
