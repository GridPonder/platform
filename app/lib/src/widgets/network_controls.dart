import 'package:flutter/material.dart';
import 'package:gridponder_engine/engine.dart';
import 'network_input_controller.dart';
import 'network_presentation.dart';

/// Composes existing network actions using only public control definitions and
/// the network's public fields. Changing an input here stages a pulse, not an
/// engine turn.
class NetworkControls extends StatefulWidget {
  final NetworkView view;
  final bool enabled;
  final NetworkInputController? inputController;
  final void Function(GameAction) onAction;

  const NetworkControls({
    super.key,
    required this.view,
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
  NetworkView get _view => widget.view;
  NetworkTerms get _terms => widget.view.terms;
  Map get _controls => _view.controls;
  List<String> get _names => _view.inputNames;

  Object? _read(String field) => _view.read(field);

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
    // Energy changes after either a keyboard pulse or a commit. Sync from the
    // public inputs while preserving staged choices on free selection.
    if (oldWidget.view.read('energy') != _read('energy')) {
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
                    : '${e.value['target']}${type == 'probe' && _read('open_${e.value['target']}') == 0 ? ' (closed)' : ''}',
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
    final pulse = _view.pulseFor(_inputs);
    final deliveries = _controls.entries.where(
      (e) =>
          e.value['type'] == 'commit' &&
          _view.canCommit(e.value['target'] as String),
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
                  Text('Set ${_terms.inputs} · free'),
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
                    ? () => _send(pulse)
                    : null,
                icon: const Icon(Icons.bolt),
                label: Text(
                  'Run ${_terms.pulse} · ${_names.map((n) => _inputs[n]).join()} · 1 ${_terms.energy}',
                ),
              ),
              _selector('probe', NetworkTerms.capitalize(_terms.probe)),
              _selector(
                'clamp',
                '${NetworkTerms.capitalize(_terms.clamp)} OFF',
              ),
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
                    onPressed: widget.enabled
                        ? () => _send(e.key as String)
                        : null,
                    child: Text(
                      'Submit ${_view.taskTitle(e.value['target'] as String)}…',
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
