import 'package:flutter_test/flutter_test.dart';
import 'package:gridponder_app/src/animation/sight_feedback.dart';
import 'package:gridponder_engine/engine.dart';

final _game = GameDefinition.fromJson({
  'entityKinds': {
    'sensor': {'layer': 'actors', 'tags': [], 'symbol': 's'},
    'camera': {'layer': 'structures', 'tags': [], 'symbol': 'c'},
  },
}, id: 'feedback_test');

GameEvent _seen(int source, int target, {String? id, String kind = 'sensor'}) =>
    GameEvent.lineOfSightDetected(
      Position(source, 0),
      Position(target, 0),
      'avatar',
      id ?? 'unit_$source',
      kind,
    );

void main() {
  test('pulses once until sight is lost, then pulses on reacquisition', () {
    final tracker = SightFeedbackTracker();
    expect(tracker.advance([_seen(0, 8)], _game), hasLength(1));
    expect(tracker.advance([_seen(0, 7)], _game), isEmpty);
    expect(tracker.advance([], _game), isEmpty);
    expect(tracker.advance([_seen(0, 6)], _game), hasLength(1));
  });

  test('follows actors whose IDs change with their origin cell', () {
    final tracker = SightFeedbackTracker();
    expect(
      tracker.advance([
        _seen(1, 8, id: 'unit_0'),
        GameEvent.npcMoved(
          'unit_0',
          const Position(0, 0),
          const Position(1, 0),
        ),
      ], _game),
      hasLength(1),
    );
    expect(
      tracker.advance([
        _seen(2, 7, id: 'unit_1'),
        GameEvent.npcMoved(
          'unit_1',
          const Position(1, 0),
          const Position(2, 0),
        ),
      ], _game),
      isEmpty,
    );
    expect(tracker.advance([_seen(2, 6)], _game), isEmpty);
  });

  test(
    'a second source acquires independently while the first stays active',
    () {
      final tracker = SightFeedbackTracker();
      tracker.advance([_seen(0, 8)], _game);
      final second = _seen(4, 7);
      expect(tracker.advance([_seen(0, 7), second], _game), [second]);
      expect(tracker.advance([_seen(4, 6)], _game), isEmpty);
      expect(tracker.advance([_seen(0, 5), _seen(4, 5)], _game), hasLength(1));
    },
  );

  test('simultaneous movers do not inherit another actor\'s sight', () {
    final tracker = SightFeedbackTracker();
    tracker.advance([_seen(1, 8, id: 'unit_0')], _game);
    final newSource = _seen(1, 7, id: 'unit_0');
    expect(
      tracker.advance([
        newSource,
        _seen(2, 7, id: 'unit_1'),
        GameEvent.npcMoved(
          'unit_0',
          const Position(0, 0),
          const Position(1, 0),
        ),
        GameEvent.npcMoved(
          'unit_1',
          const Position(1, 0),
          const Position(2, 0),
        ),
      ], _game),
      [newSource],
    );
  });

  test('stable source IDs survive movement and duplicate events', () {
    final tracker = SightFeedbackTracker();
    final first = _seen(0, 8, id: 'fixed_id', kind: 'camera');
    expect(tracker.advance([first, first], _game), [first]);
    expect(
      tracker.advance([_seen(3, 7, id: 'fixed_id', kind: 'camera')], _game),
      isEmpty,
    );
  });

  test('tracks directly moved actor sources without relying on their IDs', () {
    final tracker = SightFeedbackTracker();
    tracker.advance([_seen(0, 8, id: 'actors:0,0')], _game);
    expect(
      tracker.advance([
        _seen(1, 7, id: 'actors:1,0'),
        GameEvent.actorMoved(
          'sensor',
          const Position(0, 0),
          const Position(1, 0),
          'right',
        ),
      ], _game),
      isEmpty,
    );
  });

  test('undo restores detection history and clear starts a fresh attempt', () {
    final tracker = SightFeedbackTracker();
    tracker.advance([_seen(0, 8)], _game);
    tracker.advance([], _game);
    tracker.undo();
    expect(tracker.advance([_seen(0, 7)], _game), isEmpty);
    tracker.clear();
    tracker.undo();
    expect(tracker.advance([_seen(0, 7)], _game), hasLength(1));
  });

  test('non-avatar detections keep their per-event feedback', () {
    final tracker = SightFeedbackTracker();
    final event = GameEvent.lineOfSightDetected(
      const Position(0, 0),
      const Position(1, 0),
      'beacon',
      'fixed',
      'camera',
    );
    expect(tracker.advance([event], _game), [event]);
    expect(tracker.advance([event], _game), [event]);
  });
}
