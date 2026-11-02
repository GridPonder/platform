import 'package:flutter/material.dart';
import 'network_circuit_clues.dart';
import 'network_input_controller.dart';

/// Optional teaching content. Reads only authored public clues and projected
/// measurements; a player's hypothesis is never checked against private state.
class NetworkLesson extends StatelessWidget {
  final Map<String, dynamic> lesson;
  final Map<String, dynamic> publicCircuit;
  final NetworkInputController controller;
  final Object? Function(String) read;
  final bool won;

  const NetworkLesson({
    super.key,
    required this.lesson,
    required this.publicCircuit,
    required this.controller,
    required this.read,
    required this.won,
  });

  Future<void> _notebook(BuildContext context) async {
    final notes = TextEditingController(text: controller.evidenceNotes);
    final clues = ((publicCircuit['nodes'] as List?) ?? [])
        .map((n) => PublicCircuitNode(n as Map))
        .toList();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hypotheses & evidence'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your theories are unverified. Compare them with your measurements. Notes last for this attempt; Restart clears them.',
                ),
                for (final clue in clues.where(
                  (n) => n.alternatives.length > 1,
                )) ...[
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: ValueKey('hypothesis-${clue.id}'),
                    isExpanded: true,
                    initialValue: controller.hypotheses[clue.id] ?? '',
                    decoration: InputDecoration(
                      labelText: '${clue.id} · my theory',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Still investigating'),
                      ),
                      for (var i = 0; i < clue.alternatives.length; i++)
                        DropdownMenuItem(
                          value: '$i',
                          child: Text(
                            PublicCircuitNode({
                              'id': clue.id,
                              'alternatives': [clue.alternatives[i]],
                              'start': clue.start,
                            }).formula,
                          ),
                        ),
                    ],
                    onChanged: (value) =>
                        controller.recordHypothesis(clue.id, value ?? ''),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('hypothesis-notes'),
                  controller: notes,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'My evidence and next experiment',
                    hintText: 'I observed… My next test will distinguish…',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => controller.evidenceNotes = value,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Recorded experiments',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SelectableText(
                  (read('journal') ?? 'No tests yet.').toString().replaceAll(
                    ' | ',
                    '\n',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Back to the machine'),
          ),
        ],
      ),
    );
    // The dialog may still animate out after its route returns.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    notes.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = (lesson['tasks'] as Map).keys.toList();
    final done = tasks.where((id) => read('done_$id') == 1).length;
    final labels = (lesson['milestones'] as List).cast<String>();
    final spent =
        (lesson['initialPower'] as num).toInt() -
        (read('energy') as num).toInt();
    final target = (lesson['target'] as num).toInt();
    final icon = switch (lesson['scene']) {
      'lamp' => Icons.lightbulb_outline,
      'lift' => Icons.elevator_outlined,
      _ => Icons.precision_manufacturing_outlined,
    };
    final journal = (read('journal') ?? '').toString();
    final tests = RegExp(r'=[01]').allMatches(journal).length;
    return Container(
      key: const ValueKey('network-lesson'),
      constraints: const BoxConstraints(maxWidth: 1000),
      padding: const EdgeInsets.all(10),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF3EC),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: Icon(
                  won ? Icons.task_alt : icon,
                  key: ValueKey('$done:$won'),
                  size: 34,
                  color: done > 0
                      ? const Color(0xFF3D8067)
                      : const Color(0xFF536A70),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  won
                      ? 'Repair complete! ${lesson['insight']}'
                      : lesson['brief'] as String,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 4,
            children: [
              for (var i = 0; i < labels.length; i++)
                Text(
                  '${i < done ? '✓' : '○'} ${labels[i]}',
                  key: ValueKey('milestone-$i'),
                ),
              Text('${won ? '✓' : '○'} Safely parked'),
              TextButton.icon(
                key: const ValueKey('hypotheses'),
                onPressed: () => _notebook(context),
                icon: const Icon(Icons.edit_note, size: 20),
                label: const Text('Hypotheses'),
              ),
            ],
          ),
          if (!won)
            Text(
              done == tasks.length
                  ? lesson['shutdown'] as String
                  : lesson['tip'] as String,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          const SizedBox(height: 4),
          TweenAnimationBuilder<double>(
            key: ValueKey('pulse-stages-$tests'),
            tween: Tween(begin: 0, end: tests == 0 ? 0 : 3),
            duration: Duration(
              milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 900,
            ),
            builder: (context, phase, _) => Wrap(
              alignment: WrapAlignment.center,
              spacing: 6,
              children: [
                for (final (index, label) in [
                  '1 · Set X',
                  '2 · Update from old outputs',
                  '3 · Read selected socket',
                ].indexed)
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: phase >= index + 1
                          ? const Color(0xFF176C73)
                          : Colors.blueGrey,
                      fontWeight: phase >= index + 1
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            won
                ? (spent <= target
                      ? 'Efficiency goal met · $spent charges used (goal: $target).'
                      : 'Job complete · $spent charges used. Optional replay goal: $target.')
                : 'Room to experiment · optional efficiency goal: $target charges. All successful repairs unlock the next job.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: Color(0xFF536A70)),
          ),
        ],
      ),
    );
  }
}
