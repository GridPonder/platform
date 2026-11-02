import 'package:flutter/material.dart';
import 'package:gridponder_engine/engine.dart';

String _cell(int p, int width) => '(${p ~/ width + 1},${p % width + 1})';

/// Observe the real execution entry point so user, hint, and AgentRunner moves
/// all retain the exact same diagnostic events. No shared engine changes.
class ReactionTracingEngine extends TurnEngine {
  final void Function(ReactionTrace) onReaction;
  final void Function() onReset;
  final void Function() onUndo;
  ReactionTracingEngine(
    super.game,
    super.level, {
    required this.onReaction,
    required this.onReset,
    required this.onUndo,
  });

  @override
  TurnResult executeTurn(GameAction action) {
    final before = state.copy();
    final result = super.executeTurn(action);
    if (result.accepted)
      onReaction(ReactionTrace.capture(before, state, action, result.events));
    return result;
  }

  @override
  void reset() {
    super.reset();
    onReset();
  }

  @override
  bool undo() {
    final accepted = super.undo();
    if (accepted) onUndo();
    return accepted;
  }
}

class ReactionEntry {
  final int wave, cell;
  final String outcome, before, after;
  final List<String> sources;
  const ReactionEntry(
    this.wave,
    this.cell,
    this.outcome,
    this.before,
    this.after,
    this.sources,
  );
}

/// Reads diagnostic events emitted by the actual circuit rules, not a second
/// simulation. It also checks every recorded arrival against its sending edge.
class ReactionTrace {
  final int turn, width;
  final String control;
  final List<ReactionEntry> entries;
  final List<String> errors;
  const ReactionTrace(
    this.turn,
    this.width,
    this.control,
    this.entries,
    this.errors,
  );

  factory ReactionTrace.capture(
    LevelState before,
    LevelState after,
    GameAction action,
    List<GameEvent> events,
  ) {
    final width = before.board.width;
    final height = before.board.height;
    final records = <({String kind, List<String> args, int wave})>[];
    for (final e in events) {
      if (e.type != 'variable_changed' && e.type != 'pulse_trace') continue;
      final name = e.type == 'pulse_trace'
          ? 'rx_${e['record']}'
          : e['variable'];
      final value = e.type == 'pulse_trace' ? e['wave'] : e['newValue'];
      if (name is! String ||
          !name.startsWith('rx_') ||
          value is! int ||
          value <= 0)
        continue;
      final parts = name.split('_');
      records.add((kind: parts[1], args: parts.sublist(2), wave: value));
    }
    final packets = <String, Map<int, Set<String>>>{};
    final masks = <String, int>{};
    final errors = <String>[];
    void packet(int source, int dest, int wave, String reason) {
      final key = '$wave:$dest';
      packets
          .putIfAbsent(key, () => {})
          .putIfAbsent(source, () => {})
          .add(reason);
      final delta = source - dest;
      final bit = delta == -1 && source ~/ width == dest ~/ width
          ? 1
          : delta == -width
          ? 2
          : delta == 1 && source ~/ width == dest ~/ width
          ? 4
          : delta == width
          ? 8
          : 0;
      masks[key] = (masks[key] ?? 0) | bit;
    }

    for (final r in records) {
      if (!['seed', 'delay', 'relay', 'burst'].contains(r.kind)) continue;
      final source = int.parse(r.args[0]);
      final wave = ['seed', 'delay'].contains(r.kind) ? 1 : r.wave + 1;
      final reason = switch (r.kind) {
        'seed' || 'relay' => 'R pulse',
        'delay' => 'stored D pulse',
        _ => 'collision burst',
      };
      final x = source % width, y = source ~/ width;
      for (final (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]) {
        if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
        if (before.board.getEntity('lights', Position(nx, ny)) == null)
          continue;
        packet(source, ny * width + nx, wave, reason);
      }
    }
    final reactions = <({int wave, int cell, int mask, String outcome})>[];
    for (final r in records) {
      if (r.kind == 'direct' || r.kind == 'write') {
        final source = int.parse(r.args[0]), dest = int.parse(r.args[1]);
        packet(
          source,
          dest,
          0,
          r.kind == 'write' ? '${r.args[2]} write' : 'direct tap',
        );
        reactions.add((
          wave: 0,
          cell: dest,
          mask: 0,
          outcome: r.kind == 'write' ? r.args[2] : 'direct',
        ));
      } else if (r.kind == 'arrival' || r.kind == 'ignored') {
        reactions.add((
          wave: r.wave,
          cell: int.parse(r.args[0]),
          mask: int.parse(r.args[1]),
          outcome: r.kind == 'ignored' ? 'ignored' : r.args[2],
        ));
      }
    }
    reactions.sort(
      (a, b) => a.wave != b.wave
          ? a.wave.compareTo(b.wave)
          : a.cell.compareTo(b.cell),
    );
    final current = <int, String>{};
    for (var p = 0; p < width * height; p++) {
      final light = before.board.getEntity(
        'lights',
        Position(p % width, p ~/ width),
      );
      if (light != null) current[p] = light.kind;
    }
    final entries = <ReactionEntry>[];
    final processed = <int>{};
    for (final r in reactions) {
      final key = '${r.wave}:${r.cell}', incoming = packets[key] ?? {};
      if (r.wave > 0 && (masks[key] ?? 0) != r.mask) {
        errors.add(
          'Wave ${r.wave}, cell ${_cell(r.cell, width)}: arrival mask ${r.mask} has no matching same-wave sending edges (${masks[key] ?? 0}).',
        );
      }
      final old = current[r.cell] ?? 'missing';
      if (r.wave > 0 && r.outcome != 'ignored') {
        final opposite = (r.mask & 5) == 5 || (r.mask & 10) == 10;
        final perpendicular = (r.mask & 5) != 0 && (r.mask & 10) != 0;
        final expected = opposite
            ? 'cancel'
            : perpendicular
            ? 'burst'
            : 'normal';
        // Perpendicular arrivals may merge without bursting when disabled.
        if (r.outcome != expected &&
            !(perpendicular && !opposite && r.outcome == 'normal'))
          errors.add(
            'Cell ${_cell(r.cell, width)}: ${r.outcome} is invalid for same-wave directions ${r.mask}.',
          );
      }
      if (r.outcome == 'ignored' && !processed.contains(r.cell)) {
        errors.add(
          'Cell ${_cell(r.cell, width)} ignored its first valid arrival.',
        );
      } else if (r.outcome != 'ignored' && !processed.add(r.cell)) {
        errors.add('Cell ${_cell(r.cell, width)} processed twice in one tap.');
      }
      final next = switch (r.outcome) {
        'cancel' || 'ignored' => old,
        'ON' => 'on',
        'OFF' => 'off',
        _ => old == 'on' ? 'off' : 'on',
      };
      current[r.cell] = next;
      final sources = incoming.entries
          .map((e) => '${e.value.join(' + ')} from ${_cell(e.key, width)}')
          .toList();
      if (sources.isEmpty)
        errors.add(
          'Unexplained reaction at ${_cell(r.cell, width)}, wave ${r.wave}.',
        );
      entries.add(ReactionEntry(r.wave, r.cell, r.outcome, old, next, sources));
    }
    for (final r in records) {
      if (!['seed', 'relay', 'burst', 'delay'].contains(r.kind)) continue;
      final source = int.parse(r.args[0]);
      if (r.kind == 'delay') {
        final kind =
            before.board
                .getEntity('objects', Position(source % width, source ~/ width))
                ?.kind ??
            '';
        if (!kind.startsWith('delay_') || !kind.endsWith('_loaded')) {
          errors.add(
            'Cell ${_cell(source, width)} released a D pulse without a previously loaded store.',
          );
        }
      } else {
        final wave = r.kind == 'seed' ? 0 : r.wave;
        final valid = entries.any(
          (e) =>
              e.cell == source &&
              e.wave == wave &&
              (r.kind == 'burst'
                  ? e.outcome == 'burst'
                  : e.before == 'off' && e.after == 'on'),
        );
        if (!valid)
          errors.add(
            'Unjustified ${r.kind} output from ${_cell(source, width)} in wave $wave.',
          );
      }
    }
    final actualChanges = <int, int>{}, expectedChanges = <int, int>{};
    for (final entry in entries.where((e) => e.before != e.after)) {
      expectedChanges.update(entry.cell, (n) => n + 1, ifAbsent: () => 1);
    }
    for (final event in events) {
      if (event.type != 'cell_transformed' ||
          event['layer'] != 'lights' ||
          !['on', 'off'].contains(event['fromKind']))
        continue;
      final next = switch (event['toKind']) {
        'rising' => 'on',
        'falling' => 'off',
        final String s => s,
        _ => '',
      };
      if (next == event['fromKind']) continue;
      final pos = event.position;
      if (pos != null)
        actualChanges.update(
          pos.y * width + pos.x,
          (n) => n + 1,
          ifAbsent: () => 1,
        );
    }
    for (final e in current.entries) {
      final actual = after.board
          .getEntity('lights', Position(e.key % width, e.key ~/ width))
          ?.kind;
      if (actual != e.value)
        errors.add(
          'Cell ${_cell(e.key, width)}: actual ${actual?.toUpperCase()} differs from explained ${e.value.toUpperCase()}.',
        );
      if ((actualChanges[e.key] ?? 0) != (expectedChanges[e.key] ?? 0)) {
        errors.add(
          'Cell ${_cell(e.key, width)} has an unexplained light transition.',
        );
      }
    }
    final pos = action.params['position'];
    final label = pos is List ? '(${pos[1] + 1},${pos[0] + 1})' : 'control';
    return ReactionTrace(after.actionCount, width, label, entries, errors);
  }
}

class ReactionDebugger extends StatefulWidget {
  final List<ReactionTrace> turns;
  const ReactionDebugger({super.key, required this.turns});
  @override
  State<ReactionDebugger> createState() => _ReactionDebuggerState();
}

class _ReactionDebuggerState extends State<ReactionDebugger> {
  late int selected = widget.turns.length - 1;
  int? cell;
  @override
  Widget build(BuildContext context) {
    final trace = selected < 0 ? null : widget.turns[selected];
    final positions =
        trace?.entries.map((e) => e.cell).toSet().toList() ?? <int>[];
    positions.sort();
    final entries =
        trace?.entries.where((e) => cell == null || e.cell == cell).toList() ??
        <ReactionEntry>[];
    return AlertDialog(
      title: const Text('Reaction debugger'),
      content: SizedBox(
        width: 820,
        height: MediaQuery.sizeOf(context).height * 0.65,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Coordinates: (row, column), starting at 1. Wave 0 = direct changes. Only arrivals in the same wave collide.',
            ),
            if (trace == null)
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Text(
                  'Make a move, then open this debugger to inspect its reactions.',
                ),
              ),
            if (trace != null) ...[
              Wrap(
                spacing: 20,
                children: [
                  DropdownButton<int>(
                    value: selected,
                    items: [
                      for (var i = 0; i < widget.turns.length; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(
                            'Tap ${widget.turns[i].turn} at ${widget.turns[i].control}',
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      selected = v!;
                      cell = null;
                    }),
                  ),
                  DropdownButton<int>(
                    value: cell ?? -1,
                    items: [
                      const DropdownMenuItem(
                        value: -1,
                        child: Text('All affected cells'),
                      ),
                      for (final p in positions)
                        DropdownMenuItem(
                          value: p,
                          child: Text('Cell ${_cell(p, trace.width)}'),
                        ),
                    ],
                    onChanged: (v) => setState(() => cell = v == -1 ? null : v),
                  ),
                ],
              ),
              Text(
                trace.errors.isEmpty
                    ? 'Every change has a matching signal source.'
                    : 'Signal verification failed:',
                style: TextStyle(
                  color: trace.errors.isEmpty
                      ? Colors.green.shade800
                      : Colors.red.shade800,
                ),
              ),
              if (trace.errors.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 110),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final error in trace.errors)
                          Text(
                            error,
                            style: const TextStyle(color: Colors.red),
                          ),
                      ],
                    ),
                  ),
                ),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final e = entries[index];
                    final reason = switch (e.outcome) {
                      'cancel' => 'opposite arrivals cancel',
                      'burst' => 'same-wave perpendicular collision',
                      'ignored' => 'already processed: later arrival ignored',
                      'normal' => 'incoming pulse',
                      'direct' => 'direct tap',
                      _ => '${e.outcome} write',
                    };
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Wave ${e.wave} · ${_cell(e.cell, trace.width)} · ${e.before.toUpperCase()} → ${e.after.toUpperCase()}',
                      ),
                      subtitle: Text('$reason\n${e.sources.join('\n')}'),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
