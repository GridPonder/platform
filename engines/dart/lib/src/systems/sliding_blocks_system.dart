import '../engine/game_system.dart';
import '../models/board.dart';
import '../models/event.dart';
import '../models/direction_transform.dart';
import '../models/game_action.dart';
import '../models/game_definition.dart';
import '../models/game_state.dart';
import '../models/position.dart';

class SlidingBlocksSystem extends GameSystem {
  static const _cardinalDirections = {'up', 'down', 'left', 'right'};

  final Map<String, dynamic>? config;

  const SlidingBlocksSystem({required super.id, this.config})
      : super(type: 'sliding_blocks');

  /// Expose movement constraints using neutral group labels.
  @override
  List<String> observationObjectLines(
      MultiCellObjectInstance mco, LevelState state, GameDefinition game) {
    final axis = mco.params['axis'];
    final lines = <String>[
      if (axis is String && axis.isNotEmpty) 'axis: $axis',
    ];
    final group = _movementGroup(mco);
    if (group != null) {
      final groups = state.board.multiCellObjects
          .map(_movementGroup)
          .whereType<String>()
          .toSet()
          .toList();
      lines.add('movement group: ${groups.indexOf(group) + 1}');
      lines.add('movement transform: ${_movementTransform(mco)}');
    }
    return lines;
  }

  @override
  List<GameEvent> executeActionResolution(
    GameAction action,
    LevelState state,
    GameDefinition game,
  ) {
    final effectiveConfig = config ?? game.systemConfig(id, {});
    final moveAction = effectiveConfig['moveAction'] as String? ?? 'move';
    if (action.actionId != moveAction) return const [];

    final directionName = action.params['direction'];
    final start = _parsePosition(action.params['position']);
    if (directionName is! String ||
        !_cardinalDirections.contains(directionName) ||
        start == null) {
      return [GameEvent.actionVetoed()];
    }
    final direction = action.direction!;

    final block = _blockAt(state, start);
    if (block == null) return [GameEvent.actionVetoed()];

    final group = _movementGroup(block);
    final members = state.board.multiCellObjects
        .where((item) =>
            item.id == block.id ||
            (group != null && _movementGroup(item) == group))
        .toList();
    // Every supported transform is self-inverse.
    final sharedDelta =
        transformDelta(direction.offset, _movementTransform(block));
    final plans = <({
      MultiCellObjectInstance block,
      List<Position> oldCells,
      List<Position> newCells,
      String direction,
      bool exiting
    })>[];
    final movingIds = members.map((m) => m.id).toSet();
    final destinations = <Position>{};
    final edges = <(Position, Position)>{};
    for (final member in members) {
      final delta = transformDelta(sharedDelta, _movementTransform(member));
      final memberDirection = _directionName(delta);
      if (!_axisAllows(
          member.params['axis'] as String? ?? 'both', memberDirection)) {
        return [GameEvent.actionVetoed()];
      }
      final oldCells = member.cells.toList();
      final oldCellSet = oldCells.toSet();
      final newCells = oldCells.map((p) => p + delta).toList();
      final exiting = newCells.any((p) => !state.board.isInBounds(p));
      if (exiting &&
          !_canEscape(
              member, oldCells, memberDirection, state, game, effectiveConfig)) {
        return [GameEvent.actionVetoed()];
      }
      for (final cell in newCells) {
        if (!state.board.isInBounds(cell)) continue;
        if (!destinations.add(cell) ||
            !_isValidDestination(cell, member, oldCellSet, state, game,
                effectiveConfig, movingIds)) {
          return [GameEvent.actionVetoed()];
        }
      }
      // Allow following into vacated cells, but forbid head-on cell exchanges.
      for (var i = 0; i < oldCells.length; i++) {
        if (edges.contains((newCells[i], oldCells[i]))) {
          return [GameEvent.actionVetoed()];
        }
        edges.add((oldCells[i], newCells[i]));
      }
      plans.add((
        block: member,
        oldCells: oldCells,
        newCells: newCells,
        direction: memberDirection,
        exiting: exiting
      ));
    }

    final events = <GameEvent>[];
    for (final plan in plans) {
      final member = plan.block;
      if (plan.exiting) {
        state.board.multiCellObjects.removeWhere((m) => m.id == member.id);
        final variable =
            effectiveConfig['escapedVariable'] as String? ?? 'escapedCount';
        final oldValue = (state.variables[variable] as num?) ?? 0;
        state.variables[variable] = oldValue + 1;
        events.addAll([
          GameEvent('multi_cell_object_exited', {
            'id': member.id,
            'kind': member.kind,
            'direction': plan.direction,
          }),
          GameEvent.variableChanged(variable, oldValue, oldValue + 1),
        ]);
      } else {
        _moveBlockCells(member, plan.oldCells, plan.newCells);
        events.add(GameEvent('multi_cell_object_moved', {
          'id': member.id,
          'kind': member.kind,
          'fromCells': plan.oldCells,
          'toCells': plan.newCells,
          'direction': plan.direction,
        }));
      }
    }
    return events;
  }

  String? _movementGroup(MultiCellObjectInstance block) {
    final group = block.params['movementGroup'];
    return group is String && group.isNotEmpty ? group : null;
  }

  String _movementTransform(MultiCellObjectInstance block) {
    final transform = block.params['movementTransform'];
    return const {'identity', 'invert', 'mirror_x', 'mirror_y'}
            .contains(transform)
        ? transform as String
        : 'identity';
  }

  String _directionName(Position delta) {
    if (delta.x == 1) return 'right';
    if (delta.x == -1) return 'left';
    return delta.y == 1 ? 'down' : 'up';
  }

  MultiCellObjectInstance? _blockAt(LevelState state, Position pos) {
    for (final block in state.board.multiCellObjects) {
      if (block.cells.contains(pos)) return block;
    }
    return null;
  }

  Position? _parsePosition(dynamic raw) {
    if (raw is List && raw.length >= 2) {
      final x = raw[0];
      final y = raw[1];
      if (x is int && y is int) return Position(x, y);
    }
    return null;
  }

  bool _axisAllows(String axis, String direction) {
    return switch (axis) {
      'horizontal' => direction == 'left' || direction == 'right',
      'vertical' => direction == 'up' || direction == 'down',
      'both' => _cardinalDirections.contains(direction),
      _ => false,
    };
  }

  bool _isValidDestination(
    Position pos,
    MultiCellObjectInstance movingBlock,
    Set<Position> currentCells,
    LevelState state,
    GameDefinition game,
    Map<String, dynamic> config,
    Set<String> movingIds,
  ) {
    if (!state.board.isInBounds(pos)) return false;
    if (state.board.isVoid(pos)) return false;

    final groundLayer = config['groundLayer'] as String? ?? 'ground';
    final ground = state.board.getEntity(groundLayer, pos);
    final validGroundTags = (config['validGroundTags'] as List? ?? ['walkable'])
        .map((v) => v.toString())
        .toList();
    if (ground == null ||
        !validGroundTags.any((tag) => game.hasTag(ground.kind, tag))) {
      return false;
    }

    for (final other in state.board.multiCellObjects) {
      if (movingIds.contains(other.id)) continue;
      if (other.cells.contains(pos)) return false;
    }

    final blockingLayers = (config['blockingLayers'] as List? ?? ['objects'])
        .map((v) => v.toString());
    final blockingTags = (config['blockingTags'] as List? ?? ['solid'])
        .map((v) => v.toString())
        .toList();
    final coverableTags = (config['coverableTags'] as List? ?? const [])
        .map((v) => v.toString())
        .toList();
    final coverableBlockedRoles =
        (config['coverableBlockedRoles'] as List? ?? const [])
            .map((v) => v.toString())
            .toSet();
    final movingRole = movingBlock.params['role']?.toString();
    for (final layerId in blockingLayers) {
      final entity = state.board.getEntity(layerId, pos);
      if (entity == null) continue;
      if (currentCells.contains(pos)) continue;
      if (blockingTags.isEmpty ||
          blockingTags.any((tag) => game.hasTag(entity.kind, tag))) {
        final canCover = coverableTags
                .any((tag) => game.hasTag(entity.kind, tag)) &&
            (movingRole == null || !coverableBlockedRoles.contains(movingRole));
        if (canCover) continue;
        return false;
      }
    }

    return true;
  }

  bool _canEscape(
    MultiCellObjectInstance block,
    List<Position> oldCells,
    String direction,
    LevelState state,
    GameDefinition game,
    Map<String, dynamic> config,
  ) {
    final escapeRoles = (config['escapeRoles'] as List? ?? const [])
        .map((value) => value.toString())
        .toSet();
    if (!escapeRoles.contains(block.params['role']?.toString())) return false;

    final exitTags = (config['exitTags'] as List? ?? ['exit'])
        .map((v) => v.toString())
        .toList();
    if (exitTags.isEmpty) return true;

    final edgeCells = switch (direction) {
      'right' => _cellsAtX(oldCells, _maxX(oldCells)),
      'left' => _cellsAtX(oldCells, _minX(oldCells)),
      'down' => _cellsAtY(oldCells, _maxY(oldCells)),
      'up' => _cellsAtY(oldCells, _minY(oldCells)),
      _ => const <Position>[],
    };

    for (final cell in edgeCells) {
      final groundLayer = config['groundLayer'] as String? ?? 'ground';
      final ground = state.board.getEntity(groundLayer, cell);
      if (ground != null &&
          exitTags.any((tag) => game.hasTag(ground.kind, tag))) {
        return true;
      }
    }
    return false;
  }

  void _moveBlockCells(
    MultiCellObjectInstance block,
    List<Position> oldCells,
    List<Position> newCells,
  ) {
    block.cells
      ..clear()
      ..addAll(newCells);

    if (block.cellSprites.isEmpty) return;
    final oldSprites = Map<Position, String>.from(block.cellSprites);
    block.cellSprites.clear();
    for (var i = 0; i < oldCells.length; i++) {
      final sprite = oldSprites[oldCells[i]];
      if (sprite != null) block.cellSprites[newCells[i]] = sprite;
    }
  }

  int _minX(List<Position> cells) =>
      cells.map((p) => p.x).reduce((a, b) => a < b ? a : b);

  int _maxX(List<Position> cells) =>
      cells.map((p) => p.x).reduce((a, b) => a > b ? a : b);

  int _minY(List<Position> cells) =>
      cells.map((p) => p.y).reduce((a, b) => a < b ? a : b);

  int _maxY(List<Position> cells) =>
      cells.map((p) => p.y).reduce((a, b) => a > b ? a : b);

  List<Position> _cellsAtX(List<Position> cells, int x) =>
      cells.where((p) => p.x == x).toList();

  List<Position> _cellsAtY(List<Position> cells, int y) =>
      cells.where((p) => p.y == y).toList();
}
