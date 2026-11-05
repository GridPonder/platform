/// Walks a level's explained conditional solution (`metadata.solver`).
///
/// A policy node is `{actions, notes?, learned?, next | win | <variable>:
/// {value: node}}`: play `actions` in order (each with an optional note), then
/// continue at `next`, stop on `win`, or branch on the public state variable
/// named by the remaining key. Branching only ever reads public variables, so
/// the walker plays the live attempt without knowing its hidden setup.
class PolicyCursor {
  static const _structure = {'actions', 'notes', 'learned', 'next', 'win'};

  Map node;
  int index = 0;

  /// False once the live state reached a branch value the policy never
  /// expected — the attempt left the script.
  bool onScript = true;

  PolicyCursor(this.node);

  /// A plain move list as a policy, for levels without an explained solver.
  factory PolicyCursor.fromPath(List<String> actions) => PolicyCursor({
    'actions': actions,
    'next': {'win': true},
  });

  List get _actions => node['actions'] as List? ?? const [];

  bool get finished => index >= _actions.length && node['win'] == true;

  String? get nextAction =>
      index < _actions.length ? _actions[index] as String : null;

  /// Why the next action is played, when the policy explains it.
  String? get note {
    final notes = node['notes'] as List?;
    return notes != null && index < notes.length
        ? notes[index] as String
        : null;
  }

  /// What the last branch revealed, shown until the first move after it.
  String? get learned => index == 0 ? node['learned'] as String? : null;

  /// Move past the action just played, then follow branches using [variables].
  void advance(Map<String, dynamic> variables) {
    index++;
    settle(variables);
  }

  /// Follow `next` links and branches until an action is due or the policy
  /// ends.
  void settle(Map<String, dynamic> variables) {
    while (onScript && index >= _actions.length && node['win'] != true) {
      if (node['next'] is Map) {
        node = node['next'] as Map;
        index = 0;
        continue;
      }
      Object? key;
      for (final k in node.keys) {
        if (!_structure.contains(k)) key = k;
      }
      final child = key == null
          ? null
          : (node[key] as Map)['${variables[key]}'];
      if (child is! Map) {
        onScript = false;
        return;
      }
      node = child;
      index = 0;
    }
  }
}
