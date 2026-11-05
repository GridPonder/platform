import 'package:flutter/material.dart';
import 'package:gridponder_engine/engine.dart';
import 'network_input_controller.dart';

/// Composes existing network actions using only public control definitions and
/// projected readouts. Changing an input here stages a pulse, not an engine turn.
class NetworkControls extends StatefulWidget {
  final Map<String, dynamic> config;
  final Map<String, dynamic> publicVariables;
  final bool enabled;
  final NetworkInputController? inputController;
  final void Function(GameAction) onAction;

  const NetworkControls({
    super.key,
    required this.config,
    required this.publicVariables,
    required this.enabled,
    this.inputController,
    required this.onAction,
  });

  @override
  State<NetworkControls> createState() => _NetworkControlsState();
}

class _NetworkControlsState extends State<NetworkControls> {
  final Map<String, int> _localInputs = {};
  Map<String, int> get _inputs =>
      widget.inputController?.inputs ?? _localInputs;
  Map get _controls => widget.config['controls'] as Map? ?? {};
  List<String> get _names =>
      (widget.config['inputs'] as List? ?? []).cast<String>();

  Object? _read(String field) =>
      widget.publicVariables[(widget.config['readouts'] as Map?)?[field]];

  @override
  void initState() {
    super.initState();
    _syncInputs();
  }

  void _syncInputs() {
    if (widget.inputController != null) return;
    for (final name in _names) {
      _inputs[name] = (_read('input_$name') as num?)?.toInt() ?? 0;
    }
  }

  @override
  void didUpdateWidget(covariant NetworkControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Energy changes after either a keyboard pulse or delivery. Sync from
    // public input readouts while preserving staged choices on free selection.
    final energyKey = (widget.config['readouts'] as Map?)?['energy'];
    if (oldWidget.publicVariables[energyKey] !=
        widget.publicVariables[energyKey]) {
      _syncInputs();
    }
  }

  void _send(String id) => widget.onAction(GameAction(id, {}));

  Widget _selector(String type, String title) {
    final entries = _controls.entries
        .where((e) => e.value['type'] == type)
        .toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    final selected = (_read(type) ?? '').toString();
    final valid = entries.any((e) => (e.value['target'] ?? '') == selected);
    return SizedBox(
      width: 164,
      child: DropdownButtonFormField<String>(
        // Recreate when external keyboard selection changes.
        key: ValueKey('$type:$selected'),
        initialValue: valid ? selected : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: '$title · free',
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
        ),
        items: [
          for (final e in entries)
            DropdownMenuItem(
              value: (e.value['target'] ?? '').toString(),
              child: Text(
                (e.value['target'] ?? '') == ''
                    ? 'None'
                    : '${e.value['target']}${type == 'probe' && _read('open_${e.value['target']}') == 0 ? ' (sealed)' : ''}',
              ),
            ),
        ],
        onChanged: !widget.enabled
            ? null
            : (value) {
                final action = entries.firstWhere(
                  (e) => (e.value['target'] ?? '') == value,
                );
                _send(action.key as String);
              },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.inputController;
    return controller == null
        ? _buildControls(context)
        : ListenableBuilder(
            listenable: controller,
            builder: (context, _) => _buildControls(context),
          );
  }

  Widget _buildControls(BuildContext context) {
    String? pulse;
    for (final entry in _controls.entries) {
      if (entry.value['type'] == 'pulse' &&
          _names.every((n) => entry.value['inputs'][n] == _inputs[n])) {
        pulse = entry.key as String;
        break;
      }
    }
    final tasks = widget.config['tasks'] as Map? ?? {};
    final deliveries = _controls.entries.where(
      (e) =>
          e.value['type'] == 'commit' &&
          _read('done_${e.value['target']}') != 1 &&
          (tasks[e.value['target']]['after'] as List? ?? []).every(
            (id) => _read('done_$id') == 1,
          ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Set test switches · free'),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final name in _names)
                        FilterChip(
                          label: Text(
                            '${name.toUpperCase()} ${_inputs[name] == 1 ? 'ON' : 'OFF'}',
                          ),
                          selected: _inputs[name] == 1,
                          onSelected: !widget.enabled
                              ? null
                              : (value) {
                                  if (widget.inputController != null) {
                                    widget.inputController!.toggle(name);
                                  } else {
                                    setState(
                                      () => _inputs[name] = value ? 1 : 0,
                                    );
                                  }
                                },
                        ),
                    ],
                  ),
                ],
              ),
              FilledButton.icon(
                key: const ValueKey('network-pulse'),
                onPressed: widget.enabled && pulse != null
                    ? () => _send(pulse!)
                    : null,
                icon: const Icon(Icons.bolt),
                label: Text(
                  'Run test · ${_names.map((n) => _inputs[n]).join()} · 1 charge',
                ),
              ),
              _selector('probe', 'Test lead'),
              _selector('clamp', 'Hold OFF'),
            ],
          ),
          if (deliveries.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                const Text('Match the target before submitting.'),
                for (final e in deliveries)
                  OutlinedButton(
                    key: ValueKey(e.key as String),
                    onPressed:
                        widget.enabled &&
                            _read('done_${e.value['target']}') != 1
                        ? () => _send(e.key as String)
                        : null,
                    child: Text(
                      tasks[e.value['target']]['label'] == null
                          ? 'Submit inspection ${e.value['target']}…'
                          : '${tasks[e.value['target']]['label']} (${e.value['target']})…',
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
