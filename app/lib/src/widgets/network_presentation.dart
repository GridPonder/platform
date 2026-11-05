import 'package:flutter/material.dart';
import 'package:gridponder_engine/engine.dart';

/// Player-facing vocabulary for a `state_network`, read from the system's
/// optional `labels` config. Engines ignore `labels`; it only names things.
///
/// Every word has a neutral default, so a level without labels reads as a
/// plain network ("task", "energy", "input", "node", "probe", "step",
/// "hold"). A pack picks its own theme, e.g. `{"task": "inspection",
/// "energy": "charge", "input": "switch", "inputPlural": "switches"}`.
/// A plural defaults to the label plus "s", or to the neutral plural when the
/// label is absent.
class NetworkTerms {
  final Map labels;

  const NetworkTerms([this.labels = const {}]);

  factory NetworkTerms.of(Map? config) =>
      NetworkTerms((config?['labels'] as Map?) ?? const {});

  String _word(String key, String fallback) =>
      (labels[key] as String?) ?? fallback;

  String _plural(String key, String fallback) =>
      (labels['${key}Plural'] as String?) ??
      (labels[key] is String ? '${labels[key]}s' : fallback);

  /// One transaction (`commit` target).
  String get task => _word('task', 'task');
  String get tasks => _plural('task', 'tasks');

  /// The budget shared by pulses and commits.
  String get energy => _word('energy', 'energy');
  String get energyPlural => _plural('energy', 'energy');
  String energyCount(Object? n) => '$n ${n == 1 ? energy : energyPlural}';

  /// An external input bit set before each pulse.
  String get input => _word('input', 'input');
  String get inputs => _plural('input', 'inputs');

  /// A network node (its output bit is what tasks check).
  String get node => _word('node', 'node');
  String get nodes => _plural('node', 'nodes');

  /// A selectable observation point (`probes`).
  String get probe => _word('probe', 'probe');

  /// One powered update (`pulse` control).
  String get pulse => _word('pulse', 'step');

  /// Forcing a node's output low (`clamp` control).
  String get clamp => _word('clamp', 'hold');

  static String capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String bit(Object? v) => v == 1 ? 'ON' : 'OFF';

  static String pattern(Map requires) =>
      requires.entries.map((e) => '${e.key} ${bit(e.value)}').join(', ');
}

/// A level's network: its config, wording and every public field, read
/// through [StateNetworkSystem.publicView] rather than the level's `readouts`,
/// so a field the level never copies into a variable is still available.
class NetworkView {
  final Map<String, dynamic> config;
  final Map<String, dynamic> fields;
  final NetworkTerms terms;

  NetworkView(this.config, this.fields) : terms = NetworkTerms.of(config);

  factory NetworkView.of(SystemDef system, LevelState state) => NetworkView(
    system.config,
    StateNetworkSystem(id: system.id, config: system.config).publicView(state),
  );

  Object? read(String field) => fields[field];

  Map get controls => config['controls'] as Map? ?? const {};
  Map get tasks => config['tasks'] as Map? ?? const {};
  List<String> get inputNames =>
      (config['inputs'] as List? ?? const []).cast<String>();

  bool isDone(String task) => read('done_$task') == 1;

  /// Prerequisites of [task] that are not complete yet.
  List<String> waitingFor(String task) => [
    for (final id in (tasks[task]?['after'] as List? ?? const []))
      if (!isDone(id as String)) id,
  ];

  /// True when committing [task] now is accepted by the engine.
  bool canCommit(String task) => !isDone(task) && waitingFor(task).isEmpty;

  /// The task's own label, else "<Task> <id>".
  String taskTitle(String task) =>
      (tasks[task]?['label'] as String?) ??
      '${NetworkTerms.capitalize(terms.task)} $task';

  /// The pulse action whose input bits equal [inputs], if any.
  String? pulseFor(Map<String, int> inputs) {
    for (final entry in controls.entries) {
      if (entry.value['type'] == 'pulse' &&
          inputNames.every((n) => entry.value['inputs'][n] == inputs[n])) {
        return entry.key as String;
      }
    }
    return null;
  }

  /// The task whose failure ended the attempt, from the public journal.
  String? get failedTask {
    final last = (read('journal') ?? '').toString().split(' | ').last;
    if (!last.endsWith(' failed')) return null;
    final task = last.substring(0, last.length - ' failed'.length);
    return tasks.containsKey(task) ? task : null;
  }

  /// True when [loseReason] (an engine reason code) is this network's own
  /// failure: a `variable_threshold` on the variable `failed` is copied to.
  bool ownsLoss(String? loseReason) {
    final variable = (config['readouts'] as Map?)?['failed'];
    return variable != null && loseReason == 'variable_threshold:$variable';
  }

  /// Banner text for a loss this network caused, or null when another system
  /// (or a lose condition on some other variable) ended the attempt.
  ({String title, String subtitle})? lossMessage(String? loseReason) {
    if (!ownsLoss(loseReason)) return null;
    final task = failedTask;
    if (task != null) {
      return (
        title: '${taskTitle(task)} did not pass',
        subtitle:
            'Required: ${NetworkTerms.pattern(tasks[task]['requires'] as Map? ?? const {})}. '
            'At least one ${terms.node} output differed. Restart to try again.',
      );
    }
    return (
      title: 'Out of ${terms.energyPlural}',
      subtitle:
          'The ${terms.tasks} and the final state were not complete when the last ${terms.energy} was spent. Restart to try a different sequence.',
    );
  }

  /// A short, plain description of what playing [actionId] does.
  String stepNote(String actionId) {
    final c = controls[actionId] as Map?;
    switch (c?['type']) {
      case 'pulse':
        final bits = (c!['inputs'] as Map).entries
            .map(
              (e) =>
                  '${e.key.toString().toUpperCase()} ${NetworkTerms.bit(e.value)}',
            )
            .join(', ');
        return 'Set $bits and run a ${terms.pulse} (1 ${terms.energy}).';
      case 'probe':
        return 'Move the ${terms.probe} to ${c!['target']} (free).';
      case 'clamp':
        return c!['target'] == ''
            ? 'Release the ${terms.clamp} (free).'
            : '${NetworkTerms.capitalize(terms.clamp)} ${c['target']} (free): its output counts as OFF.';
      case 'commit':
        return 'Submit ${taskTitle(c!['target'] as String)} (1 ${terms.energy}).';
    }
    return 'Play $actionId.';
  }

  /// A longer explanation of [actionId] for a guided walkthrough.
  String lessonNote(String actionId) {
    final c = controls[actionId] as Map?;
    final target = c?['target'];
    switch (c?['type']) {
      case 'pulse':
        return '${stepNote(actionId)} Every ${terms.node} updates, even with all ${terms.inputs} OFF. Then ${terms.probe} ${read('probe')} is read.';
      case 'probe':
        return '${stepNote(actionId)} Moving it measures nothing; the next ${terms.pulse} will.';
      case 'clamp':
        return target == ''
            ? '${stepNote(actionId)} The output works normally again; the ${terms.node} memory was never cleared.'
            : '${stepNote(actionId)} Downstream ${terms.nodes} receive OFF too, but its memory still changes on each ${terms.pulse}.';
      case 'commit':
        return 'Submit ${taskTitle(target as String)}: ${NetworkTerms.pattern(tasks[target]['requires'] as Map? ?? const {})}. '
            'The preceding moves produced that pattern. This spends 1 ${terms.energy} without a ${terms.pulse}.';
    }
    return stepNote(actionId);
  }

  /// Why [task] cannot be submitted now, or null when it can.
  String? commitBlocker(String task) {
    final waiting = waitingFor(task);
    if (waiting.isNotEmpty) {
      return 'Complete ${waiting.map(taskTitle).join(', ')} first.';
    }
    if (isDone(task)) return '${taskTitle(task)} is already complete.';
    return null;
  }

  /// Asks the player to confirm committing [task]. True means go ahead.
  Future<bool> confirmCommit(BuildContext context, String task) async {
    final t = tasks[task] as Map;
    final closes = (t['closes'] as List? ?? const []);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Submit ${taskTitle(task)}?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This checks ${terms.node} outputs, not the ${terms.inputs}.',
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final e in (t['requires'] as Map? ?? const {}).entries)
                    Chip(
                      label: Text(
                        '${e.key}: ${e.value == 1 ? 'ON (1)' : 'OFF (0)'}',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'Costs 1 ${terms.energy}; no ${terms.pulse} runs. A wrong pattern ends this attempt.',
              ),
              if (closes.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('Passing closes: ${closes.join(', ')}.'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            key: const ValueKey('confirm-inspection'),
            onPressed: () => Navigator.pop(context, true),
            child: Text('Submit · 1 ${terms.energy}'),
          ),
        ],
      ),
    );
    return accepted == true;
  }
}

/// Remaining energy, the last reading and a guide button for a network level.
class NetworkStatusRow extends StatelessWidget {
  final NetworkView view;
  final VoidCallback onGuide;

  const NetworkStatusRow({
    super.key,
    required this.view,
    required this.onGuide,
  });

  @override
  Widget build(BuildContext context) {
    final reading = view.read('reading');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.bolt, color: Color(0xFF176C73)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${view.terms.energyCount(view.read('energy'))} left',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (reading == 0 || reading == 1)
                  Text(
                    'Last reading: ${view.read('sample')} ${NetworkTerms.bit(reading)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF176C73),
                    ),
                  ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onGuide,
            icon: const Icon(Icons.menu_book_outlined),
            label: const Text('Guide'),
          ),
        ],
      ),
    );
  }
}

/// The guided walkthrough panel (Teach me) or a first-level hint.
class NetworkGuidance extends StatelessWidget {
  final NetworkView view;
  final List<GameAction> path;

  /// Index of the next walkthrough move, or null when no walkthrough runs.
  final int? lessonIndex;
  final bool won;
  final bool busy;
  final VoidCallback onNext;
  final VoidCallback onExit;

  const NetworkGuidance({
    super.key,
    required this.view,
    required this.path,
    required this.lessonIndex,
    required this.won,
    required this.busy,
    required this.onNext,
    required this.onExit,
  });

  /// The hint shown before any walkthrough, on the pack's first level.
  static Widget? firstLevelHint(NetworkView view) {
    final first = view.tasks.entries.firstOrNull;
    if (first == null) return null;
    final t = view.terms;
    final fresh = view.read('sample') == 'none';
    return Text(
      fresh
          ? 'Start here: leave the ${t.inputs} OFF and run a ${t.pulse}. Then read ${t.probe} ${view.read('probe')}. Need a walkthrough? Choose Teach me below.'
          : 'A reading is one clue, not the answer. ${view.taskTitle(first.key as String)} needs ${NetworkTerms.pattern(first.value['requires'] as Map? ?? const {})} together. Teach me walks through a complete example.',
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 13, color: Color(0xFF176C73)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final index = lessonIndex ?? 0;
    final done = index >= path.length || won;
    final explanation = done
        ? 'All ${view.terms.tasks} passed and the final state is reached. Restart to try it yourself.'
        : view.lessonNote(path[index].actionId);
    return Container(
      constraints: const BoxConstraints(maxWidth: 900),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F4F2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            done
                ? 'Demonstration complete'
                : 'Guided example · move ${index + 1}/${path.length}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            explanation,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!done)
                TextButton(
                  key: const ValueKey('lesson-next'),
                  onPressed: busy ? null : onNext,
                  child: const Text('Do this step'),
                ),
              TextButton(
                onPressed: onExit,
                child: Text(done ? 'Try yourself' : 'Exit lesson & restart'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
