import 'package:gridponder_engine/engine.dart';
import 'package:test/test.dart';

void main() {
  final game = GameDefinition.fromJson({
    'layers': [
      {'id': 'ground', 'occupancy': 'exactly_one', 'default': 'floor'}
    ],
    'entityKinds': {
      'floor': {'layer': 'ground', 'symbol': '.'}
    },
    'actions': [
      {
        'id': 'move',
        'params': {
          'direction': {'type': 'direction'}
        }
      }
    ],
    'systems': <dynamic>[],
    'ui': {
      'showGuide': true,
      'readouts': [
        {'variable': 'capacity', 'label': 'Energy', 'maxVariable': 'maximum'},
        {'variable': 'signal', 'label': 'Signal', 'blankWhen': -1},
      ]
    },
  },
      id: 'example',
      title: 'Synthetic example',
      description: 'Public authored rules.');
  final level = LevelDefinition.fromJson({
    'id': 'example',
    'guide': 'Public local instructions.',
    'board': {
      'size': [2, 1],
      'layers': <String, dynamic>{}
    },
    'state': {
      'avatar': {
        'enabled': true,
        'position': [0, 0]
      },
      'variables': {
        'capacity': 2,
        'maximum': 7,
        'signal': -1,
        'hidden_solution_marker': 'NEVER_SHOW'
      }
    },
    'goals': <dynamic>[],
    'loseConditions': [
      {
        'type': 'max_actions',
        'config': {'limit': 11}
      }
    ],
    'metadata': {'description': 'HIDDEN_SOLUTION_TEXT'},
  }, game.layers);

  test('visible instructions and current capacity reach every inference mode',
      () {
    final state = level.initialState();
    for (final mode in ['single', 'fixed-n', 'flex-n', 'full']) {
      final prompt = LlmAgent.buildPrompt(
          AgentObservation.build(game, level, state),
          inferenceMode: mode);
      expect(prompt, contains('Public authored rules.'));
      expect(
          prompt, contains('CURRENT LEVEL GUIDE:\nPublic local instructions.'));
      expect(prompt, contains('Energy: 2/7'));
      expect(prompt, contains('Signal: -'));
      expect(prompt, contains('Moves this attempt: 0 of 11 allowed'));
      expect(prompt, isNot(contains('NEVER_SHOW')));
      expect(prompt, isNot(contains('HIDDEN_SOLUTION_TEXT')));
    }
    state.variables['capacity'] = 4;
    state.variables['maximum'] = 9;
    final prompt =
        LlmAgent.buildPrompt(AgentObservation.build(game, level, state));
    expect(prompt, contains('Energy: 4/9'));
  });

  test('anonymous discovery omits authored instructions and HUD names', () {
    final prompt = LlmAgent.buildPrompt(
        AgentObservation.build(game, level, level.initialState()),
        anonymize: true);
    for (final hidden in [
      'Public authored rules.',
      'Public local instructions.',
      'Energy:',
      'Signal:',
      'NEVER_SHOW'
    ]) {
      expect(prompt, isNot(contains(hidden)));
    }
    expect(prompt, contains('Readout 1: 2/7'));
    expect(prompt, contains('Moves this attempt: 0 of 11 allowed'));
  });
}
