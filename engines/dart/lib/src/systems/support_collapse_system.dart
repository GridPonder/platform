import 'dart:collection';

import '../engine/game_system.dart';
import '../models/board.dart';
import '../models/direction.dart';
import '../models/entity.dart';
import '../models/event.dart';
import '../models/game_action.dart';
import '../models/game_definition.dart';
import '../models/game_state.dart';
import '../models/position.dart';

/// Cells that lose their connection to a support root fall as rigid bodies.
///
/// A structure is held up by cells tagged as roots. After any cell is removed,
/// every maximal group of member cells that can no longer reach a root is an
/// orphan, and each orphan translates in the configured direction — keeping its
/// exact shape — until one of its cells is blocked. Components fall
/// simultaneously, one step at a time, so stacked orphans resolve
/// deterministically without an ordering rule.
///
/// Generic: any game with a structure hanging from fixed roots names its own
/// root/member tags and fall direction. The player-facing sever verb is
/// optional — omit `severAction` and drive the collapse from `triggerEvents`
/// when cells are removed by rules or other systems instead.
class SupportCollapseSystem extends GameSystem {
  final Map<String, dynamic>? config;

  const SupportCollapseSystem({required super.id, this.config})
      : super(type: 'support_collapse');

  static const _cardinals = <Position>[
    Position(0, -1),
    Position(0, 1),
    Position(-1, 0),
    Position(1, 0),
  ];

  static const _diagonals = <Position>[
    ..._cardinals,
    Position(-1, -1),
    Position(1, -1),
    Position(-1, 1),
    Position(1, 1),
  ];

  Map<String, dynamic> _cfg(GameDefinition game) =>
      config ?? game.systemConfig(id, {});

  List<String> _stringList(dynamic raw, List<String> fallback) {
    if (raw is! List) return fallback;
    return raw.map((value) => value.toString()).toList();
  }

  /// The kind an emptied cell reverts to on an `exactly_one` layer.
  String? _defaultKind(GameDefinition game, String layerId) {
    for (final layer in game.layers) {
      if (layer.id != layerId) continue;
      if (layer.isExactlyOne) return layer.defaultKind ?? 'empty';
      return null;
    }
    return null;
  }

  EntityInstance? _empty(GameDefinition game, String layerId) {
    final kind = _defaultKind(game, layerId);
    return kind == null ? null : EntityInstance(kind);
  }

  bool _hasAnyTag(GameDefinition game, String kind, List<String> tags) {
    final def = game.entityKinds[kind];
    if (def == null) return false;
    for (final tag in tags) {
      if (def.hasTag(tag)) return true;
    }
    return false;
  }

  // ── phase 2: the sever verb ───────────────────────────────────────────────
  @override
  List<GameEvent> executeActionResolution(
    GameAction action,
    LevelState state,
    GameDefinition game,
  ) {
    final cfg = _cfg(game);
    final severAction = cfg['severAction'] as String?;
    if (severAction == null || action.actionId != severAction) return const [];

    final avatar = state.avatar;
    if (!avatar.enabled || avatar.position == null) {
      return [GameEvent.actionVetoed()];
    }

    final layerId = cfg['layer'] as String? ?? 'ground';
    final layer = state.board.layers[layerId];
    if (layer == null) return [GameEvent.actionVetoed()];

    // The target may be named either way, so a pack can bind the verb to a
    // directional swipe or to tapping the cell itself. Both resolve to a single
    // cell adjacent to the actor.
    final Position target;
    final rawPosition = action.params['position'];
    if (rawPosition != null) {
      target = Position.fromJson(rawPosition);
      final dx = (target.x - avatar.position!.x).abs();
      final dy = (target.y - avatar.position!.y).abs();
      if (dx + dy != 1) return [GameEvent.actionVetoed()]; // not adjacent
    } else {
      final dirStr = action.directionStr;
      if (dirStr == null) return [GameEvent.actionVetoed()];
      final Direction dir;
      try {
        dir = Direction.fromJson(dirStr);
      } on FormatException {
        return [GameEvent.actionVetoed()];
      }
      target = avatar.position! + dir.offset;
    }

    if (!state.board.isInBounds(target)) return [GameEvent.actionVetoed()];

    final entity = layer.getAt(target);
    final severable = _stringList(cfg['severableTags'], const ['severable']);
    if (entity == null || !_hasAnyTag(game, entity.kind, severable)) {
      return [GameEvent.actionVetoed()];
    }

    final previousKind = entity.kind;
    final ignite = _ignite(cfg);
    final lit = ignite[previousKind];
    if (lit != null) {
      // Lighting a fuse removes nothing yet: the cell burns later.
      final fuse = cfg['fuse'] as Map;
      final delayParam = fuse['delayParam'] as String? ?? 'delay';
      final delay = (fuse['delay'] as num?)?.toInt() ?? 1;
      layer.setAt(
          target, EntityInstance(lit, {...entity.params, delayParam: delay}));
      return [GameEvent.cellTransformed(target, previousKind, lit, layerId)];
    }
    layer.setAt(target, _empty(game, layerId));
    return [
      GameEvent.cellCleared(target, previousKind, layer: layerId),
      ..._collapse(state, game, cfg),
    ];
  }

  // ── phase 5: event-driven collapse ────────────────────────────────────────
  @override
  List<GameEvent> executeCascadeResolution(
    List<GameEvent> triggerEvents,
    LevelState state,
    GameDefinition game,
  ) {
    final cfg = _cfg(game);
    final triggers = _stringList(cfg['triggerEvents'], const []).toSet();
    if (triggers.isEmpty) return const [];
    if (!triggerEvents.any((event) => triggers.contains(event.type))) {
      return const [];
    }
    return _collapse(state, game, cfg);
  }

  // ── phase 6: strain ───────────────────────────────────────────────────────
  /// Overloaded load-limited cells tire once per turn and fail at zero.
  ///
  /// The load on a cell is every member cell that would fall if that cell
  /// were removed — so supports that share a load carry none of it until one
  /// of them goes. Each accepted turn, every overloaded cell loses one point of
  /// endurance; then every overloaded cell with none left fails at once (it is
  /// removed and the structure collapses). Failures repeat without further
  /// wear until nothing more breaks, so a cell already at zero gives way the
  /// moment a failure overloads it. Mirrors Python `execute_npc_resolution`.
  @override
  List<GameEvent> executeNpcResolution(LevelState state, GameDefinition game) {
    final cfg = _cfg(game);
    final events = _burn(state, game, cfg);
    final strain = cfg['strain'];
    if (strain is! Map) return events;
    final layerId = cfg['layer'] as String? ?? 'ground';
    final layer = state.board.layers[layerId];
    if (layer == null) return events;
    final board = state.board;
    final tags = _stringList(strain['tags'], const ['load_limited']);
    final capParam = strain['capacityParam'] as String? ?? 'capacity';
    final endParam = strain['enduranceParam'] as String? ?? 'endurance';
    final defaultEndurance = (strain['endurance'] as num?)?.toInt() ?? 0;

    List<Position> overloaded() {
      final out = <Position>[];
      _loads(state, game, cfg, tags).forEach((p, load) {
        final cap = layer.getAt(p)!.param(capParam);
        if (cap is int && load > cap) out.add(p);
      });
      return out;
    }

    int endurance(Position p) {
      final value = layer.getAt(p)!.param(endParam);
      return value is int ? value : defaultEndurance;
    }

    for (final p in overloaded()) {
      final entity = layer.getAt(p)!;
      final left = endurance(p) - 1 < 0 ? 0 : endurance(p) - 1;
      layer.setAt(
          p,
          EntityInstance(
              entity.kind, {...entity.params, endParam: left}));
    }

    var avatarPos = state.avatar.enabled ? state.avatar.position : null;
    for (var pass = 0; pass < board.width * board.height + 1; pass++) {
      final failing = overloaded().where((p) => endurance(p) <= 0).toList();
      if (failing.isEmpty) break;
      for (final p in failing) {
        final kind = layer.getAt(p)!.kind;
        layer.setAt(p, _empty(game, layerId));
        events.add(GameEvent.cellCleared(p, kind, layer: layerId));
      }
      if (avatarPos != null && failing.contains(avatarPos)) {
        events.addAll(_avatarFell(state, cfg));
      }
      events.addAll(_collapse(state, game, cfg));
      avatarPos = state.avatar.enabled ? state.avatar.position : null;
    }
    return events;
  }

  Map<String, String> _ignite(Map<String, dynamic> cfg) {
    final fuse = cfg['fuse'];
    if (fuse is! Map) return const {};
    final raw = fuse['ignite'];
    if (raw is! Map) return const {};
    return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  /// Lit fuse cells count down, then burn away and light their neighbours.
  ///
  /// Every lit cell whose delay is above 0 loses 1. Every lit cell already at
  /// 0 when the turn began is removed, and each fuse cell touching it is lit
  /// with delay 0, so it burns one turn later: a fuse burns one cell per turn.
  /// Then the structure collapses once. Mirrors Python `_burn`.
  List<GameEvent> _burn(
      LevelState state, GameDefinition game, Map<String, dynamic> cfg) {
    final ignite = _ignite(cfg);
    if (ignite.isEmpty) return <GameEvent>[];
    final layerId = cfg['layer'] as String? ?? 'ground';
    final layer = state.board.layers[layerId];
    if (layer == null) return <GameEvent>[];
    final board = state.board;
    final delayParam = (cfg['fuse'] as Map)['delayParam'] as String? ?? 'delay';
    final litKinds = ignite.values.toSet();
    final deltas = cfg['connectivity'] == 'diagonal' ? _diagonals : _cardinals;

    final burning = <Position>[];
    for (var y = 0; y < board.height; y++) {
      for (var x = 0; x < board.width; x++) {
        final p = Position(x, y);
        final e = layer.getAt(p);
        if (e == null || !litKinds.contains(e.kind)) continue;
        final delay = e.param(delayParam);
        if (delay is int && delay > 0) {
          layer.setAt(
              p, EntityInstance(e.kind, {...e.params, delayParam: delay - 1}));
        } else {
          burning.add(p);
        }
      }
    }
    if (burning.isEmpty) return <GameEvent>[];

    final events = <GameEvent>[];
    for (final p in burning) {
      final kind = layer.getAt(p)!.kind;
      layer.setAt(p, _empty(game, layerId));
      events.add(GameEvent.cellCleared(p, kind, layer: layerId));
    }
    for (final p in burning) {
      for (final d in deltas) {
        final nb = p + d;
        if (!board.isInBounds(nb)) continue;
        final e = layer.getAt(nb);
        if (e == null) continue;
        final lit = ignite[e.kind];
        if (lit == null) continue;
        layer.setAt(nb, EntityInstance(lit, {...e.params, delayParam: 0}));
        events.add(GameEvent.cellTransformed(nb, e.kind, lit, layerId));
      }
    }
    final avatarPos = state.avatar.enabled ? state.avatar.position : null;
    if (avatarPos != null && burning.contains(avatarPos)) {
      events.addAll(_avatarFell(state, cfg));
    }
    events.addAll(_collapse(state, game, cfg));
    return events;
  }

  /// Burning fuse cells, then capacity and endurance for load-limited cells.
  @override
  List<String> observationStatusLines(
          LevelState state, GameDefinition game, Board initialBoard) =>
      [
        ..._fuseLines(state, game),
        ..._strainLines(state, game),
        ..._switchLines(state, game),
      ];

  List<String> _fuseLines(LevelState state, GameDefinition game) {
    final cfg = _cfg(game);
    final fuse = cfg['fuse'];
    if (fuse is! Map) return const [];
    final layer = state.board.layers[cfg['layer'] as String? ?? 'ground'];
    if (layer == null) return const [];
    final litKinds = _ignite(cfg).values.toSet();
    final delayParam = fuse['delayParam'] as String? ?? 'delay';
    final lines = <String>[];
    for (var y = 0; y < state.board.height; y++) {
      for (var x = 0; x < state.board.width; x++) {
        final e = layer.getAt(Position(x, y));
        if (e == null || !litKinds.contains(e.kind)) continue;
        final delay = e.param(delayParam);
        final turns = (delay is int && delay > 0 ? delay : 0) + 1;
        final plural = turns == 1 ? '' : 's';
        final name = game.observationName(e.kind);
        lines.add('($x,$y): $name burns away in $turns turn$plural');
      }
    }
    if (lines.isEmpty) return const [];
    return [
      'Burning fuses (in 1 turn = at the end of your next turn; as a cell '
          'burns away it lights the fuse cells touching it, which burn away '
          'one turn later):',
      ...lines,
    ];
  }

  List<String> _strainLines(LevelState state, GameDefinition game) {
    final cfg = _cfg(game);
    final strain = cfg['strain'];
    if (strain is! Map) return const [];
    final layer = state.board.layers[cfg['layer'] as String? ?? 'ground'];
    if (layer == null) return const [];
    final tags = _stringList(strain['tags'], const ['load_limited']);
    final capParam = strain['capacityParam'] as String? ?? 'capacity';
    final endParam = strain['enduranceParam'] as String? ?? 'endurance';
    final defaultEndurance = (strain['endurance'] as num?)?.toInt() ?? 0;
    final lines = <String>[];
    for (var y = 0; y < state.board.height; y++) {
      for (var x = 0; x < state.board.width; x++) {
        final e = layer.getAt(Position(x, y));
        if (e == null || !_hasAnyTag(game, e.kind, tags)) continue;
        final cap = e.param(capParam);
        if (cap is! int) continue;
        final raw = e.param(endParam);
        final left = raw is int ? raw : defaultEndurance;
        final name = game.observationName(e.kind);
        lines.add('($x,$y): $name capacity $cap, endurance $left');
      }
    }
    if (lines.isEmpty) return const [];
    return [
      "Load limits (a cell's load is every structure cell that would fall "
          'without it; each turn it is over capacity it loses 1 endurance, '
          'and at 0 it fails):',
      ...lines,
    ];
  }

  /// Load on every cell carrying one of [tags], in row-major order.
  Map<Position, int> _loads(LevelState state, GameDefinition game,
      Map<String, dynamic> cfg, List<String> tags) {
    final layer = state.board.layers[cfg['layer'] as String? ?? 'ground']!;
    final board = state.board;
    final limited = <Position>[];
    for (var y = 0; y < board.height; y++) {
      for (var x = 0; x < board.width; x++) {
        final e = layer.getAt(Position(x, y));
        if (e != null && _hasAnyTag(game, e.kind, tags)) {
          limited.add(Position(x, y));
        }
      }
    }
    final loads = <Position, int>{};
    if (limited.isEmpty) return loads;
    final held = _supported(state, game, cfg);
    for (final p in limited) {
      final without = _supported(state, game, cfg, removed: p);
      var load = 0;
      for (final c in held) {
        if (c != p &&
            !without.contains(c) &&
            _isMember(layer.getAt(c), game, cfg)) {
          load++;
        }
      }
      loads[p] = load;
    }
    return loads;
  }

  List<GameEvent> _avatarFell(LevelState state, Map<String, dynamic> cfg) {
    final variable = cfg['avatarFellVariable'] as String?;
    if (variable == null) return const [];
    final old = state.variables[variable];
    final oldNum = old is num ? old.toInt() : 0;
    state.variables[variable] = oldNum + 1;
    return [GameEvent.variableChanged(variable, oldNum, oldNum + 1)];
  }

  bool _isMember(
      EntityInstance? entity, GameDefinition game, Map<String, dynamic> cfg) {
    final memberTags = _stringList(cfg['memberTags'], const ['supported']);
    return entity != null && _hasAnyTag(game, entity.kind, memberTags);
  }

  /// Every root, and every member cell connected to one. [removed] is treated
  /// as empty, which is how a cell's load is measured.
  Set<Position> _supported(
      LevelState state, GameDefinition game, Map<String, dynamic> cfg,
      {Position? removed}) {
    final layer = state.board.layers[cfg['layer'] as String? ?? 'ground']!;
    final board = state.board;
    final rootTags = _stringList(cfg['rootTags'], const ['support_root']);
    final deltas = cfg['connectivity'] == 'diagonal' ? _diagonals : _cardinals;
    final supported = <Position>{};
    final queue = Queue<Position>();
    for (var y = 0; y < board.height; y++) {
      for (var x = 0; x < board.width; x++) {
        final p = Position(x, y);
        final e = layer.getAt(p);
        if (p != removed && e != null && _hasAnyTag(game, e.kind, rootTags)) {
          supported.add(p);
          queue.add(p);
        }
      }
    }
    while (queue.isNotEmpty) {
      final cur = queue.removeFirst();
      for (final d in deltas) {
        final nb = cur + d;
        if (supported.contains(nb) || nb == removed || !board.isInBounds(nb)) {
          continue;
        }
        if (_isMember(layer.getAt(nb), game, cfg)) {
          supported.add(nb);
          queue.add(nb);
        }
      }
    }
    return supported;
  }

  /// Channels with at least one pressed plate. Mirrors Python `_switch`.
  Set<Object?> _pressedChannels(
      LevelState state, GameDefinition game, Map<String, dynamic> cfg) {
    final sw = cfg['switches'] as Map;
    final layerId = cfg['layer'] as String? ?? 'ground';
    final board = state.board;
    final plates = board.layers[sw['plateLayer'] as String? ?? layerId];
    final pressed = <Object?>{};
    if (plates == null) return pressed;
    final plateTags = _stringList(sw['plateTags'], const ['plate']);
    final pressLayers = _stringList(sw['pressLayers'], [layerId]);
    final pressTags = _stringList(sw['pressTags'], const ['solid']);
    final ch = sw['channelParam'] as String? ?? 'channel';
    for (var y = 0; y < board.height; y++) {
      for (var x = 0; x < board.width; x++) {
        final p = Position(x, y);
        final e = plates.getAt(p);
        if (e == null || !_hasAnyTag(game, e.kind, plateTags)) continue;
        for (final pl in pressLayers) {
          final o = board.layers[pl]?.getAt(p);
          if (o != null && _hasAnyTag(game, o.kind, pressTags)) {
            pressed.add(e.param(ch));
            break;
          }
        }
      }
    }
    return pressed;
  }

  /// Point every switched cell the way its channel's plates say.
  ///
  /// A plate is pressed while a cell carrying one of `pressTags` sits on its
  /// position. While any plate of a channel is pressed, every cell of that
  /// channel whose kind is a key of `pressed` takes the mapped kind; while
  /// none is, mapped kinds revert.
  List<GameEvent> _switch(
      LevelState state, GameDefinition game, Map<String, dynamic> cfg) {
    final sw = cfg['switches'];
    if (sw is! Map) return const [];
    final layerId = cfg['layer'] as String? ?? 'ground';
    final targetId = sw['switchLayer'] as String? ?? layerId;
    final board = state.board;
    final target = board.layers[targetId];
    if (target == null || board.layers[sw['plateLayer'] as String? ?? layerId] == null) {
      return const [];
    }
    final ch = sw['channelParam'] as String? ?? 'channel';
    final toPressed = (sw['pressed'] as Map? ?? const {})
        .map((k, v) => MapEntry(k.toString(), v.toString()));
    final toReleased = toPressed.map((k, v) => MapEntry(v, k));
    final pressed = _pressedChannels(state, game, cfg);
    final events = <GameEvent>[];
    for (var y = 0; y < board.height; y++) {
      for (var x = 0; x < board.width; x++) {
        final p = Position(x, y);
        final e = target.getAt(p);
        if (e == null) continue;
        final on = pressed.contains(e.param(ch));
        String? next;
        if (on && toPressed.containsKey(e.kind)) {
          next = toPressed[e.kind];
        } else if (!on && toReleased.containsKey(e.kind)) {
          next = toReleased[e.kind];
        }
        if (next == null || next == e.kind) continue;
        target.setAt(p, e.copyWith(kind: next));
        events.add(GameEvent.cellTransformed(p, e.kind, next, targetId));
      }
    }
    return events;
  }

  List<String> _switchLines(LevelState state, GameDefinition game) {
    final cfg = _cfg(game);
    final sw = cfg['switches'];
    if (sw is! Map) return const [];
    final layerId = cfg['layer'] as String? ?? 'ground';
    final board = state.board;
    final target = board.layers[sw['switchLayer'] as String? ?? layerId];
    final plates = board.layers[sw['plateLayer'] as String? ?? layerId];
    if (target == null || plates == null) return const [];
    final plateTags = _stringList(sw['plateTags'], const ['plate']);
    final pressLayers = _stringList(sw['pressLayers'], [layerId]);
    final pressTags = _stringList(sw['pressTags'], const ['solid']);
    final ch = sw['channelParam'] as String? ?? 'channel';
    final toPressed = (sw['pressed'] as Map? ?? const {})
        .map((k, v) => MapEntry(k.toString(), v.toString()));
    final switchKinds = {...toPressed.keys, ...toPressed.values};
    final lines = <String>[];
    for (var y = 0; y < board.height; y++) {
      for (var x = 0; x < board.width; x++) {
        final p = Position(x, y);
        final e = plates.getAt(p);
        if (e == null || !_hasAnyTag(game, e.kind, plateTags)) continue;
        var down = false;
        for (final pl in pressLayers) {
          final o = board.layers[pl]?.getAt(p);
          if (o != null && _hasAnyTag(game, o.kind, pressTags)) down = true;
        }
        final name = game.observationName(e.kind);
        lines.add('($x,$y): $name ${_pyStr(e.param(ch))}, '
            '${down ? 'pressed' : 'empty'}');
      }
    }
    for (var y = 0; y < board.height; y++) {
      for (var x = 0; x < board.width; x++) {
        final e = target.getAt(Position(x, y));
        if (e == null || !switchKinds.contains(e.kind)) continue;
        final name = game.observationName(e.kind);
        lines.add('($x,$y): $name, channel ${_pyStr(e.param(ch))}');
      }
    }
    if (lines.isEmpty) return const [];
    return [
      'Switches (a plate is pressed while a solid piece rests in its cell; '
          "while any plate of a channel is pressed, that channel's switched "
          'cells take their pressed form):',
      ...lines,
    ];
  }

  /// Python's str() of a param value, so status lines match across engines.
  static String _pyStr(Object? v) => v == null ? 'None' : v.toString();

  // ── the algorithm ─────────────────────────────────────────────────────────
  /// Drop everything unsupported; repeat while switches change what holds.
  /// Mirrors Python `_collapse`: a switch that turns a support root or member
  /// into a kind that is not one (a clamp letting go) triggers another pass,
  /// so cascades resolve within one turn. Bounded by the board area.
  List<GameEvent> _collapse(
    LevelState state,
    GameDefinition game,
    Map<String, dynamic> cfg,
  ) {
    final events = <GameEvent>[];
    final board = state.board;
    for (var i = 0; i < board.width * board.height + 1; i++) {
      final step = _collapsePass(state, game, cfg);
      events.addAll(step);
      final changed = step.any((e) =>
          e.type == 'cell_transformed' &&
          _holds(e['fromKind'] as String?, game, cfg) !=
              _holds(e['toKind'] as String?, game, cfg));
      if (!changed) break;
    }
    return events;
  }

  /// Encodes (is a support root, is a member) for a kind name as 0..3.
  int _holds(String? kind, GameDefinition game, Map<String, dynamic> cfg) {
    if (kind == null) return 0;
    final roots = _stringList(cfg['rootTags'], const ['support_root']);
    final members = _stringList(cfg['memberTags'], const ['supported']);
    return (_hasAnyTag(game, kind, roots) ? 2 : 0) +
        (_hasAnyTag(game, kind, members) ? 1 : 0);
  }

  List<GameEvent> _collapsePass(
    LevelState state,
    GameDefinition game,
    Map<String, dynamic> cfg,
  ) {
    final layerId = cfg['layer'] as String? ?? 'ground';
    final layer = state.board.layers[layerId];
    if (layer == null) return const [];
    final board = state.board;

    final deltas = cfg['connectivity'] == 'diagonal' ? _diagonals : _cardinals;

    bool isMember(Position pos) => _isMember(layer.getAt(pos), game, cfg);

    // 0. Removals may have emptied a plate: switches update first.
    final switched = _switch(state, game, cfg);

    // 1. BFS the supported set outward from every root.
    final supported = _supported(state, game, cfg);

    // 2. Group the unsupported members into maximal connected components.
    final remaining = <Position>{};
    for (var y = 0; y < board.height; y++) {
      for (var x = 0; x < board.width; x++) {
        final p = Position(x, y);
        if (isMember(p) && !supported.contains(p)) remaining.add(p);
      }
    }
    if (remaining.isEmpty) return switched;

    final components = <List<Position>>[];
    while (remaining.isNotEmpty) {
      final seed = remaining.first;
      remaining.remove(seed);
      final comp = <Position>[seed];
      final q = Queue<Position>()..add(seed);
      while (q.isNotEmpty) {
        final cur = q.removeFirst();
        for (final d in deltas) {
          final nb = cur + d;
          if (remaining.remove(nb)) {
            comp.add(nb);
            q.add(nb);
          }
        }
      }
      components.add(comp);
    }

    // 3. Lift every orphan cell off the board first, so a component is never
    //    blocked by the hole it is falling out of, nor by another orphan that
    //    is falling alongside it.
    final kinds = <Map<Position, EntityInstance>>[];
    for (final comp in components) {
      final snapshot = <Position, EntityInstance>{};
      for (final p in comp) {
        final e = layer.getAt(p);
        if (e != null) snapshot[p] = e;
      }
      kinds.add(snapshot);
      for (final p in comp) {
        layer.setAt(p, _empty(game, layerId));
      }
    }

    final fallDir = Direction.fromJson(cfg['direction'] as String? ?? 'down');
    final step = fallDir.offset;
    final restLayers = _stringList(cfg['restLayers'], [layerId]);
    final restTags = _stringList(cfg['restTags'], const ['solid']);
    final settleRaw = cfg['settleTransform'] as Map? ?? const {};
    final settle =
        settleRaw.map((k, v) => MapEntry(k.toString(), v.toString()));
    final deflectRaw = cfg['deflect'] as Map? ?? const {};
    final deflect =
        deflectRaw.map((k, v) => MapEntry(k.toString(), v.toString()));

    /// Kinds blocking a step by [d]. An empty list means the step is free.
    List<String> obstacles(List<Position> cells, Position d) {
      final out = <String>[];
      for (final c in cells) {
        final next = c + d;
        if (!board.isInBounds(next)) continue; // leaving the board never blocks
        for (final rl in restLayers) {
          final rlayer = board.layers[rl];
          if (rlayer == null) continue;
          final e = rlayer.getAt(next);
          if (e != null && _hasAnyTag(game, e.kind, restTags)) out.add(e.kind);
        }
      }
      return out;
    }

    /// The one agreed slide direction, or null if the component rests.
    ///
    /// A flat blocker holds the whole component, and ramps pulling opposite
    /// ways cancel — both fall back to resting, so the result never depends on
    /// which cell of the component is inspected first.
    Position? deflection(List<String> blocking) {
      if (deflect.isEmpty) return null;
      final directions = <String>{};
      for (final kind in blocking) {
        String? match;
        for (final entry in deflect.entries) {
          if (_hasAnyTag(game, kind, [entry.key])) {
            match = entry.value;
            break;
          }
        }
        if (match == null) return null;
        directions.add(match);
      }
      if (directions.length != 1) return null;
      return Direction.fromJson(directions.first).offset;
    }

    // 4. Resolve components one at a time, the one furthest along the fall
    //    direction first, writing each back to the board as it lands. Every
    //    component that could block another has therefore already come to rest
    //    by the time the other is resolved. Sorting is what makes this
    //    deterministic; stepping them in lockstep is not, because a lifted
    //    component is invisible to the others and they pass through it.
    int reachOf(List<Position> cells) => cells
        .map((c) => c.x * step.x + c.y * step.y)
        .reduce((a, b) => a > b ? a : b);
    int minXOf(List<Position> cells) =>
        cells.map((c) => c.x).reduce((a, b) => a < b ? a : b);
    int minYOf(List<Position> cells) =>
        cells.map((c) => c.y).reduce((a, b) => a < b ? a : b);

    final order = List<int>.generate(components.length, (i) => i)
      ..sort((a, b) {
        final byReach =
            reachOf(components[b]).compareTo(reachOf(components[a]));
        if (byReach != 0) return byReach;
        final byX = minXOf(components[a]).compareTo(minXOf(components[b]));
        if (byX != 0) return byX;
        return minYOf(components[a]).compareTo(minYOf(components[b]));
      });

    final events = <GameEvent>[...switched];
    final avatarPos = state.avatar.enabled ? state.avatar.position : null;
    int? avatarComponent;
    Position? avatarDestination;
    final maxSteps = 2 * (board.width + board.height) + 1;

    for (final idx in order) {
      var cells = List<Position>.from(components[idx]);
      int? slidAt;
      for (var pass = 0; pass < maxSteps; pass++) {
        if (!cells.any(board.isInBounds)) break;
        final blocking = obstacles(cells, step);
        if (blocking.isEmpty) {
          cells = cells.map((c) => c + step).toList();
          continue;
        }
        final slide = deflection(blocking);
        if (slide == null) break;
        // A component may slide at most once per lane, or two facing ramps
        // would trade it back and forth forever. It must travel one cell along
        // the fall direction to earn another slide.
        final lane = step.y != 0 ? minYOf(cells) : minXOf(cells);
        if (slidAt == lane || obstacles(cells, slide).isNotEmpty) break;
        if (cells.any((c) => !board.isInBounds(c + slide))) {
          break; // sideways motion never leaves the board
        }
        cells = cells.map((c) => c + slide).toList();
        slidAt = lane;
      }

      final comp = components[idx];
      for (var i = 0; i < comp.length; i++) {
        final src = comp[i];
        final dst = cells[i];
        if (avatarPos != null && src == avatarPos) {
          avatarComponent = idx;
          avatarDestination = dst;
        }
        if (!board.isInBounds(dst)) continue; // this cell left the world
        final entity = kinds[idx][src];
        if (entity == null) continue;
        final newKind = settle[entity.kind] ?? entity.kind;
        layer.setAt(dst, entity.copyWith(kind: newKind));
        events.add(GameEvent.objectSettled(newKind, dst, src,
            layer: layerId, fromKind: entity.kind));
      }
      // A landed piece may press a plate before the next piece moves.
      events.addAll(_switch(state, game, cfg));
    }

    // 6. The avatar rides its component down.
    final carryAvatar = cfg['carryAvatar'] as bool? ?? true;
    if (avatarComponent != null && carryAvatar) {
      if (avatarDestination != null && board.isInBounds(avatarDestination)) {
        state.avatar = state.avatar.copyWith(position: avatarDestination);
      }
      final variable = cfg['avatarFellVariable'] as String?;
      if (variable != null) {
        final old = state.variables[variable];
        final oldNum = old is num ? old.toInt() : 0;
        state.variables[variable] = oldNum + 1;
        events.add(GameEvent.variableChanged(variable, oldNum, oldNum + 1));
      }
    }

    return events;
  }
}
