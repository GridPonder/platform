import 'package:flutter/material.dart';
import 'package:gridponder_engine/engine.dart';
import 'board_renderer.dart';
import 'network_input_controller.dart';
import 'network_circuit_clues.dart';
import 'network_lesson.dart';
import 'network_presentation.dart';

/// Annotates the real board using only public targets and recorded measurements.
/// The original cells, sprites and positions remain the primary representation.
class NetworkBench extends StatelessWidget {
  final NetworkView view;
  final Map<String, dynamic>? publicCircuit;
  final Map<String, dynamic>? lesson;
  final NetworkInputController inputController;
  final LevelState state;
  final GameDefinition game;
  final Widget board;
  final Widget Function(Widget) wrapBoard;
  final void Function(GameAction) onAction;
  final bool enabled;
  final Widget? guidance;

  const NetworkBench({
    super.key,
    required this.view,
    required this.inputController,
    required this.state,
    required this.game,
    required this.board,
    required this.wrapBoard,
    required this.onAction,
    required this.enabled,
    this.guidance,
    this.publicCircuit,
    this.lesson,
  });

  Map<String, dynamic> get config => view.config;
  NetworkTerms get _terms => view.terms;
  Object? _read(String field) => view.read(field);
  List<PublicCircuitNode> get _clues =>
      ((publicCircuit?['nodes'] as List?) ?? [])
          .map((n) => PublicCircuitNode(n as Map))
          .toList();
  PublicCircuitNode? get _focusedClue {
    final clues = _clues;
    if (clues.isEmpty) return null;
    return clues.firstWhere(
      (n) => n.id == inputController.clueModule,
      orElse: () => clues.last,
    );
  }

  /// The nodes `publicCircuit.pairedInputs` assigns inputs to, in order:
  /// `pairedNodes` when given, else the first two public nodes.
  List<String> get _pairedNodes =>
      ((publicCircuit?['pairedNodes'] as List?) ??
              _clues.take(2).map((n) => n.id).toList())
          .cast<String>();

  Map get _controls => config['controls'] as Map? ?? {};
  List get _indicators => config['indicators'] as List? ?? [];

  List? _position(String field) {
    final matches = _indicators.where((i) => i['field'] == field);
    return matches.isEmpty ? null : matches.first['position'] as List;
  }

  String? _action(String type, Object? target) {
    final matches = _controls.entries.where(
      (e) => e.value['type'] == type && e.value['target'] == target,
    );
    return matches.isEmpty ? null : matches.first.key as String;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: inputController,
    builder: (context, _) => _buildBench(context),
  );

  Widget _buildBench(BuildContext context) {
    _registerControls();
    final tasks = config['tasks'] as Map? ?? {};
    final ready = tasks.entries.where((e) => view.canCommit(e.key as String));
    final current = ready.isEmpty ? null : ready.first;
    final targets =
        current?.value['requires'] as Map? ?? config['safe'] as Map? ?? {};
    final journal = (_read('journal') ?? 'No tests yet.').toString();
    return Column(
      children: [
        if (lesson != null)
          NetworkLesson(
            lesson: lesson!,
            publicCircuit: publicCircuit ?? {},
            controller: inputController,
            read: _read,
            won: state.isWon,
            terms: _terms,
          ),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Text(
              state.isWon
                  ? 'Complete!'
                  : current == null
                  ? 'Final state · memory targets:'
                  : '${lesson?['tasks']?[current.key] ?? view.taskTitle(current.key as String)} · output targets:',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final e in targets.entries)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: e.value == 1
                      ? const Color(0xFFFFE8A3)
                      : const Color(0xFFE3E9E9),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('${e.key} ${NetworkTerms.bit(e.value)}'),
              ),
            IconButton(
              tooltip: 'Readings so far',
              icon: const Icon(Icons.history_edu, size: 20),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Readings so far'),
                  content: SizedBox(
                    width: 480,
                    child: SingleChildScrollView(
                      child: SelectableText(journal.replaceAll(' | ', '\n')),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (lesson == null || guidance != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child:
                guidance ??
                Text(
                  'Complete every ${_terms.task} in order, then reach the final state.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
                ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final clue = _focusedClue;
              final diagram = wrapBoard(_grid(targets, current?.key));
              if (clue == null) return diagram;
              final detail = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 5),
                    child: Text(
                      'Tap a ${_terms.node}’s rule to trace its inputs.\nSolid = certain wire · dashed = possible wire.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF41666B),
                      ),
                    ),
                  ),
                  NetworkClueDetail(
                    node: clue,
                    terms: _terms,
                    pairedNodes: _pairedNodes,
                    pairs: publicCircuit?['pairedInputs'] as List? ?? [],
                    held: _read('clamp') == clue.id,
                  ),
                ],
              );
              if (constraints.maxWidth >= 760) {
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1140),
                    child: Row(
                      children: [
                        Expanded(child: diagram),
                        const SizedBox(width: 16),
                        SizedBox(width: 280, child: detail),
                      ],
                    ),
                  ),
                );
              }
              return Column(
                children: [
                  Expanded(child: diagram),
                  detail,
                ],
              );
            },
          ),
        ),
        Text(
          'Selected: ${inputController.selected?.label ?? 'none'}',
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF315AB6),
            fontWeight: FontWeight.w600,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            'Arrows: select · Enter: activate · Space: run ${_terms.pulse}. Gold = target; Read = last reading.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  void _registerControls() {
    final items = <NetworkBoardControl>[];
    for (final name in config['inputs'] as List? ?? []) {
      final pos = _position('input_$name');
      if (pos != null)
        items.add(
          NetworkBoardControl(
            Position(pos[0] as int, pos[1] as int),
            '${NetworkTerms.capitalize(_terms.input)} ${name.toString().toUpperCase()} — ${NetworkTerms.bit(inputController.inputs[name])}',
            () {
              if (enabled) inputController.toggle(name as String);
            },
            id: 'switch-$name',
          ),
        );
    }
    for (final entry in (config['probes'] as Map? ?? {}).entries) {
      final pos = _position('open_${entry.key}');
      final action = _action('probe', entry.key);
      if (pos != null && action != null && _read('open_${entry.key}') != 0) {
        items.add(
          NetworkBoardControl(
            Position(pos[0] as int, pos[1] as int),
            '${NetworkTerms.capitalize(_terms.probe)} ${entry.key}',
            () {
              if (enabled) onAction(GameAction(action, {}));
            },
            id: 'socket-${entry.key}',
          ),
        );
      }
    }
    for (final action in game.actions.where(
      (a) => _controls[a.id]?['type'] == 'clamp',
    )) {
      final target = _controls[action.id]['target'];
      if (target == null || target == '') continue;
      for (final layer in state.board.layers.values) {
        for (var y = 0; y < state.board.height; y++) {
          for (var x = 0; x < state.board.width; x++) {
            if (action.entityKind?.contains(
                  layer.getAt(Position(x, y))?.kind,
                ) ==
                true) {
              final release = _action('clamp', '');
              final held = _read('clamp') == target;
              items.add(
                NetworkBoardControl(
                  Position(x, y),
                  '${NetworkTerms.capitalize(_terms.clamp)} $target OFF — ${held ? 'active; Enter releases' : 'inactive'}',
                  () {
                    if (enabled)
                      onAction(
                        GameAction(
                          held && release != null ? release : action.id,
                          {},
                        ),
                      );
                  },
                  id: 'tool-$target',
                ),
              );
            }
          }
        }
      }
    }
    for (final task in (config['tasks'] as Map? ?? {}).entries) {
      final pos = _position('done_${task.key}');
      final action = _action('commit', task.key);
      final ready = view.canCommit(task.key as String);
      if (pos != null && action != null && ready) {
        items.add(
          NetworkBoardControl(
            Position(pos[0] as int, pos[1] as int),
            '${view.taskTitle(task.key as String)} — Enter reviews requirements',
            () {
              if (enabled) onAction(GameAction(action, {}));
            },
            id: 'inspection-${task.key}',
          ),
        );
      }
    }
    // Refresh action closures from public state; no notification during build.
    inputController.controls = items;
  }

  Widget _grid(Map targets, Object? current) {
    final probes = config['probes'] as Map? ?? {};
    final reading = _read('reading');
    final measured = probes[_read('sample')];
    final known = reading == 0 || reading == 1;
    // The public clamp indicators identify module tiles without consulting
    // hidden node operations, input wiring, or private runtime memory.
    final modules = <String, List>{};
    for (final item in _indicators.where((i) => i['field'] == 'clamp')) {
      final kinds = item['kinds'] as Map;
      for (final e in kinds.entries) {
        if (e.key != '' && e.value != kinds['']) {
          modules[e.key as String] = item['position'] as List;
        }
      }
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final cell = BoardRenderer.cellSizeFor(
          constraints,
          state.board.width,
          state.board.height,
        );
        Widget at(List position, Widget child, {double dx = 0}) => Positioned(
          left: ((position[0] as num) + dx) * cell,
          top: (position[1] as num) * cell,
          width: cell,
          height: cell,
          child: child,
        );
        Widget hit(
          String key,
          String tooltip,
          String? action, {
          bool selected = false,
          bool locked = false,
        }) => Tooltip(
          message: tooltip,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: ValueKey(key),
              onTap: enabled && action != null && !locked
                  ? () {
                      final control = inputController.controls.where(
                        (c) => c.id == key,
                      );
                      if (control.isNotEmpty) {
                        inputController.select(control.first.position);
                        control.first.activate();
                      } else {
                        onAction(GameAction(action, {}));
                      }
                    }
                  : null,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  border: selected
                      ? Border.all(color: const Color(0xFF009688), width: 3)
                      : null,
                  color: selected
                      ? const Color(0xFF009688).withValues(alpha: .08)
                      : null,
                ),
              ),
            ),
          ),
        );
        return SizedBox(
          width: cell * state.board.width,
          height: cell * state.board.height,
          child: Stack(
            children: [
              Positioned.fill(child: board),
              if (_focusedClue case final PublicCircuitNode clue)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      key: const ValueKey('public-circuit-wires'),
                      painter: CircuitCluePainter(
                        node: clue,
                        cell: cell,
                        positions: {
                          for (final e in modules.entries)
                            e.key:
                                Offset(
                                  (e.value[0] as num).toDouble() + .5,
                                  (e.value[1] as num).toDouble() + .5,
                                ) *
                                cell,
                          for (final name in config['inputs'] as List? ?? [])
                            if (_position('input_$name') case final List pos)
                              name as String:
                                  Offset(
                                    (pos[0] as num).toDouble() + .5,
                                    (pos[1] as num).toDouble() + .5,
                                  ) *
                                  cell,
                        },
                      ),
                    ),
                  ),
                ),
              for (final clue in _clues)
                if (modules[clue.id] case final List pos)
                  at(
                    pos,
                    Semantics(
                      button: true,
                      label:
                          'Public rule for ${clue.id}: ${clue.formula}; ${clue.startLabel}',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: ValueKey('clue-${clue.id}'),
                          onTap: () => inputController.inspectClue(clue.id),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: _focusedClue?.id == clue.id
                                      ? const Color(0xFFDAEEEE)
                                      : const Color(0xFFFFFCF4),
                                  border: Border.all(
                                    color: _focusedClue?.id == clue.id
                                        ? const Color(0xFF18777C)
                                        : const Color(0xFFBEB9A9),
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '${clue.id} ←',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        clue.formula,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                      Text(
                                        clue.startLabel,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFF41666B),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    dx: -1,
                  ),
              for (final name in config['inputs'] as List? ?? [])
                if (_position('input_$name') case final List pos)
                  at(
                    pos,
                    Tooltip(
                      message:
                          '${NetworkTerms.capitalize(_terms.input)} ${name.toString().toUpperCase()}: click or Enter to stage the next ${_terms.pulse}',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: ValueKey('switch-$name'),
                          onTap: !enabled
                              ? null
                              : () {
                                  inputController.select(
                                    Position(pos[0] as int, pos[1] as int),
                                  );
                                  inputController.toggle(name as String);
                                },
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              color: inputController.inputs[name] == 1
                                  ? const Color(0xFFFFDF80)
                                  : const Color(0xFFE5EEEE),
                              child: FittedBox(
                                child: Text(
                                  '${name.toString().toUpperCase()} ${inputController.inputs[name] == 1 ? 'ON' : 'OFF'}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              for (final e in modules.entries) ...[
                at(
                  e.value,
                  Tooltip(
                    message: 'Show public circuit clue for ${e.key}',
                    child: InkWell(
                      key: ValueKey('module-${e.key}'),
                      onTap: publicCircuit == null
                          ? null
                          : () => inputController.inspectClue(e.key),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          border: _focusedClue?.id == e.key
                              ? Border.all(
                                  color: const Color(0xFF18777C),
                                  width: 2,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
                // These annotation cells are the empty space beside module tiles.
                // Never cover another authored instrument or leave the grid.
                if ((e.value[0] as int) + 1 < state.board.width &&
                    state.board.layers.entries
                        .where((l) => l.key != 'ground')
                        .every(
                          (l) =>
                              l.value.getAt(
                                Position(
                                  (e.value[0] as int) + 1,
                                  e.value[1] as int,
                                ),
                              ) ==
                              null,
                        ))
                  at(
                    e.value,
                    IgnorePointer(
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFE8A3),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  targets.containsKey(e.key)
                                      ? '${current == null ? 'Memory' : 'Aim'} ${targets[e.key] == 1 ? 'ON' : 'OFF'}'
                                      : 'Either',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                measured == e.key && known
                                    ? 'Read ${reading == 1 ? 'ON' : 'OFF'}'
                                    : 'Read ?',
                                key: ValueKey('reading-${e.key}'),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: measured == e.key && known
                                      ? const Color(0xFF00695C)
                                      : Colors.blueGrey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    dx: 1,
                  ),
              ],
              for (final e in probes.entries)
                if (_position('open_${e.key}') case final List pos)
                  at(
                    pos,
                    hit(
                      'socket-${e.key}',
                      _read('open_${e.key}') == 0
                          ? '${NetworkTerms.capitalize(_terms.probe)} ${e.key} is closed'
                          : 'Select ${_terms.probe} ${e.key}; the next ${_terms.pulse} reads it',
                      _action('probe', e.key),
                      selected: _read('probe') == e.key,
                      locked: _read('open_${e.key}') == 0,
                    ),
                  ),
              for (final task in (config['tasks'] as Map? ?? {}).entries)
                if (_position('done_${task.key}') case final List pos)
                  at(
                    pos,
                    hit(
                      'inspection-${task.key}',
                      '${view.taskTitle(task.key as String)}: ${NetworkTerms.pattern(task.value['requires'] as Map)}',
                      _action('commit', task.key),
                      selected: task.key == current,
                      locked: _read('done_${task.key}') == 1,
                    ),
                  ),
              // Authored action/entity associations make clamp tools clickable.
              for (final action in game.actions.where(
                (a) => _controls[a.id]?['type'] == 'clamp',
              ))
                for (final layer in state.board.layers.values)
                  for (var y = 0; y < state.board.height; y++)
                    for (var x = 0; x < state.board.width; x++)
                      if (action.entityKind?.contains(
                                layer.getAt(Position(x, y))?.kind,
                              ) ==
                              true &&
                          (_controls[action.id]['target'] ?? '') != '')
                        at(
                          [x, y],
                          hit(
                            'tool-${_controls[action.id]['target']}',
                            '${NetworkTerms.capitalize(_terms.clamp)} output ${_controls[action.id]['target']} OFF; memory still updates',
                            action.id,
                          ),
                        ),
              if (inputController.selected
                  case final NetworkBoardControl selected)
                at(
                  [selected.position.x, selected.position.y],
                  IgnorePointer(
                    child: Container(
                      key: const ValueKey('network-grid-cursor'),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: const Color(0xFF315AB6),
                          width: 3,
                        ),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Align(
                        alignment: Alignment.topLeft,
                        child: Icon(
                          Icons.arrow_drop_down,
                          color: Color(0xFF315AB6),
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Small screens scroll the whole bench rather than shrinking the grid to zero
/// when controls and explanatory text occupy the viewport.
class NetworkPageLayout extends StatelessWidget {
  final bool network;
  final double extraContentHeight;
  final List<Widget> children;
  const NetworkPageLayout({
    super.key,
    required this.network,
    required this.children,
    this.extraContentHeight = 0,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (!network ||
          (constraints.maxWidth >= 760 && constraints.maxHeight >= 650)) {
        return Column(children: children);
      }
      return SingleChildScrollView(
        child: Column(
          children: [
            for (final child in children)
              if (child is Expanded)
                SizedBox(
                  height:
                      constraints.maxWidth.clamp(320, 640) * 8 / 9 +
                      360 +
                      extraContentHeight,
                  child: child.child,
                )
              else
                child,
          ],
        ),
      );
    },
  );
}
