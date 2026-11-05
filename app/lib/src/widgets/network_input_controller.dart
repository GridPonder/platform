import 'package:flutter/foundation.dart';
import 'package:gridponder_engine/engine.dart';

class NetworkBoardControl {
  final Position position;
  final String label;
  final VoidCallback activate;
  const NetworkBoardControl(this.position, this.label, this.activate);
}

/// Staged inputs and a navigation cursor. Neither changes engine state.
class NetworkInputController extends ChangeNotifier {
  final Map<String, int> inputs = {};
  List<NetworkBoardControl> controls = const [];
  Position? cursor;
  String? clueModule;
  final Map<String, String> hypotheses = {};
  String evidenceNotes = '';

  void recordHypothesis(String id, String choice) {
    hypotheses[id] = choice;
    notifyListeners();
  }

  void inspectClue(String id) {
    clueModule = id;
    notifyListeners();
  }

  void reset(Iterable<String> names) {
    inputs
      ..clear()
      ..addEntries(names.map((n) => MapEntry(n, 0)));
    controls = const [];
    cursor = null;
    clueModule = null;
    hypotheses.clear();
    evidenceNotes = '';
    notifyListeners();
  }

  void toggle(String name) {
    inputs[name] = inputs[name] == 1 ? 0 : 1;
    notifyListeners();
  }

  void sync(Map values) {
    for (final e in values.entries) {
      inputs[e.key as String] = e.value as int;
    }
    notifyListeners();
  }

  NetworkBoardControl? get selected {
    for (final control in controls) {
      if (control.position == cursor) return control;
    }
    return controls.isEmpty ? null : controls.first;
  }

  void select(Position position) {
    cursor = position;
    notifyListeners();
  }

  void activate() => selected?.activate();

  void move(int dx, int dy) {
    final origin = selected?.position;
    if (origin == null) return;
    final candidates = controls
        .where(
          (c) =>
              (c.position.x - origin.x) * dx + (c.position.y - origin.y) * dy >
              0,
        )
        .toList();
    // Prefer the same row/column; then the nearest instrument in that direction.
    double score(NetworkBoardControl c) {
      final x = c.position.x - origin.x, y = c.position.y - origin.y;
      return (dx == 0 ? x.abs() : y.abs()) * 100 + x.abs() + y.abs().toDouble();
    }

    candidates.sort((a, b) => score(a).compareTo(score(b)));
    if (candidates.isNotEmpty) select(candidates.first.position);
  }
}
