"""
Tests for two `follower_npcs` / `avatar_navigation` options that need to drive
TurnEngine directly:

- `yieldingLayers` (avatar_navigation): the avatar may step into a cell that a
  patrolling or circling NPC is genuinely vacating this same turn.
- `movementBlockingLayers` (follower_npcs behavior): extra layers whose solid
  entities stop a patrol or circuit NPC.

Run from the repo root:  python3 engines/python/test_yielding_layers.py
"""
from __future__ import annotations
import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(ROOT))

from engines.python._game_def import GameDef
from engines.python._models import Pos
from engines.python._turn_engine import TurnEngine


# -- yieldingLayers (avatar_navigation) ---------------------------------------
#
# `yieldingLayers` lets the avatar step straight into a cell a `patrol`/
# `clockwise` follower_npcs NPC is genuinely vacating this same turn, instead
# of blocking the press and forcing the player to repeat it once the NPC has
# actually moved. It must never apply to a chasing behavior.


def _yield_game(behavior: dict) -> GameDef:
    data = {
        "id": "com.gridponder.test_yielding_layers",
        "layers": [
            {"id": "ground", "occupancy": "exactly_one", "default": "empty"},
            {"id": "actors", "occupancy": "zero_or_one"},
        ],
        "entityKinds": {
            "empty": {"layer": "ground", "tags": ["walkable"]},
            "void": {"layer": "ground", "tags": []},
            "hazard": {"layer": "actors", "tags": ["npc", "solid"]},
        },
        "actions": [
            {"id": "move", "params": {"direction": {"type": "direction", "values": ["up", "down", "left", "right"]}}},
        ],
        "systems": [
            {"id": "navigation", "type": "avatar_navigation", "config": {
                "solidLayers": ["objects", "actors"],
                "yieldingLayers": ["actors"],
            }},
            {"id": "npcs", "type": "follower_npcs", "config": {"behaviors": {"hunt": behavior}}},
        ],
    }
    return GameDef.from_dict(data, id="test_yielding_layers")


def _yield_level(avatar: tuple[int, int], hazard: tuple[int, int], facing: str) -> dict:
    """3x2 board. Hazard sits in the top row, avatar directly below it, so the
    avatar's only route onto the hazard's cell is off the patrol axis — the
    same cell the hazard would reverse into is never the avatar's own
    starting cell."""
    return {
        "id": "test_level",
        "board": {
            "size": [3, 2],
            "layers": {
                "actors": {
                    "format": "sparse",
                    "entries": [
                        {"position": list(hazard), "kind": "hazard", "behavior": "hunt", "facing": facing},
                    ],
                },
            },
        },
        "state": {"avatar": {"enabled": True, "position": list(avatar)}},
        "goals": [],
        "loseConditions": [
            {"type": "variable_threshold",
             "config": {"variable": "caught", "target": 1, "comparison": "gte"}},
        ],
    }


def _hazard_pos(engine: TurnEngine):
    for pos, entity in engine.state.board.layers["actors"].entries():
        if entity.kind == "hazard":
            return pos
    return None


def test_yielding_layer_lets_the_avatar_in_when_a_patrol_vacates():
    """The headline scenario: a patrol about to reverse off the board edge
    must not cost the player a wasted press.

    The hazard at (2,0) faces right into the edge, so this turn it reverses
    to (1,0). The avatar, parked below the hazard's cell, must be let straight
    in — in the same press, landing exactly where the hazard just left.
    """
    game = _yield_game({"type": "patrol"})
    engine = TurnEngine(game, _yield_level(avatar=(2, 1), hazard=(2, 0), facing="right"))

    result = engine.execute_turn("move", {"direction": "up"})

    assert engine.state.avatar.position == Pos(2, 0), engine.state.avatar.position
    assert any(e["type"] == "avatar_entered" for e in result.events), result.events
    assert _hazard_pos(engine) == Pos(1, 0), _hazard_pos(engine)


def test_yielding_layer_lets_the_avatar_in_for_clockwise_too():
    """Same headline scenario, `clockwise` behavior.

    The ringer faces "right" into the edge at (2,0); its next candidate,
    "down", lands on the avatar's OWN starting cell (2,1) — which the
    prediction (run before the avatar has moved) still sees as occupied, so
    it predicts the ringer rotates on to "left" -> (1,0) instead. Real
    `npc_resolution` runs after the avatar has already moved off (2,1), so
    the actual ringer takes the now-free "down" step to (2,1) instead. The
    predicted destination and the real one differ — but both agree the
    ringer leaves (2,0), which is the only thing this feature needs to get
    right: the avatar is let in either way, and the two never collide.
    """
    game = _yield_game({"type": "clockwise"})
    engine = TurnEngine(game, _yield_level(avatar=(2, 1), hazard=(2, 0), facing="right"))

    result = engine.execute_turn("move", {"direction": "up"})

    assert engine.state.avatar.position == Pos(2, 0), engine.state.avatar.position
    assert any(e["type"] == "avatar_entered" for e in result.events), result.events
    assert _hazard_pos(engine) == Pos(2, 1), _hazard_pos(engine)


def test_yielding_layer_lethal_patrol_still_catches_an_exact_swap():
    """Not the headline vacate case above: here the hazard's reversal target
    is the avatar's OWN starting cell, not some other cell off the patrol
    axis. Avatar and hazard trade cells in the same turn — final positions
    never overlap, so a same-cell check alone would miss it, but the two
    crossed paths exactly as if they'd collided head-on. A lethal-contact
    patrol must still catch the avatar here.

    2x1 corridor. Hazard at (1,0) faces right into the edge, so it reverses
    to (0,0) — the avatar's own starting cell — while the avatar moves right
    into (1,0), the hazard's starting cell.
    """
    game = _yield_game({"type": "patrol", "lethalContact": True})
    level = _yield_level(avatar=(0, 0), hazard=(1, 0), facing="right")
    level["board"]["size"] = [2, 1]
    engine = TurnEngine(game, level)

    result = engine.execute_turn("move", {"direction": "right"})

    assert any(e["type"] == "avatar_caught" for e in result.events), result.events
    assert engine.state.variables["caught"] == 1, engine.state.variables
    assert result.is_lost, result


def test_yielding_layer_does_not_apply_to_chasing_behaviors():
    """Chasing behaviors keep blocking exactly as before.

    Predicting a `toward_avatar` NPC from here would be a real circular
    dependency (the avatar's move depends on where the NPC ends up, which
    depends on where the avatar ends up) — never attempted, regardless of
    `yieldingLayers`.
    """
    game = _yield_game({"type": "toward_avatar", "requiresLineOfSight": True})
    engine = TurnEngine(game, _yield_level(avatar=(2, 1), hazard=(2, 0), facing="right"))

    result = engine.execute_turn("move", {"direction": "up"})

    assert engine.state.avatar.position == Pos(2, 1), engine.state.avatar.position
    assert not any(e["type"] == "avatar_entered" for e in result.events), result.events


def test_yielding_layer_still_blocks_a_fully_boxed_in_patrol():
    """A patrol that cannot even reverse (both directions blocked) is not
    vacating anything, so the avatar's move must still be blocked."""
    game = _yield_game({"type": "patrol"})
    level = _yield_level(avatar=(1, 1), hazard=(1, 0), facing="right")
    # Wall the hazard in on both sides so neither forward nor reversed is legal.
    level["board"]["layers"]["ground"] = {
        "format": "sparse",
        "entries": [{"position": [0, 0], "kind": "void"}, {"position": [2, 0], "kind": "void"}],
    }
    engine = TurnEngine(game, level)

    result = engine.execute_turn("move", {"direction": "up"})

    assert engine.state.avatar.position == Pos(1, 1), engine.state.avatar.position
    assert not any(e["type"] == "avatar_entered" for e in result.events), result.events
    assert _hazard_pos(engine) == Pos(1, 0), "boxed-in hazard must not have moved"


TESTS_YIELDING_LAYERS = [
    test_yielding_layer_lets_the_avatar_in_when_a_patrol_vacates,
    test_yielding_layer_lets_the_avatar_in_for_clockwise_too,
    test_yielding_layer_lethal_patrol_still_catches_an_exact_swap,
    test_yielding_layer_does_not_apply_to_chasing_behaviors,
    test_yielding_layer_still_blocks_a_fully_boxed_in_patrol,
]


def _movement_blocking_layers_game(behavior: dict) -> GameDef:
    """A patrol/clockwise-only fixture with an extra `barrier_layer`, used to
    prove `movementBlockingLayers` is additive on top of the hardcoded `objects`
    check — never a replacement for it."""
    data = {
        "id": "com.gridponder.test_movement_blocking_layers",
        "layers": [
            {"id": "ground", "occupancy": "exactly_one", "default": "empty"},
            {"id": "barrier_layer", "occupancy": "zero_or_one"},
            {"id": "actors", "occupancy": "zero_or_one"},
        ],
        "entityKinds": {
            "empty": {"layer": "ground", "tags": ["walkable"]},
            "block": {"layer": "barrier_layer", "tags": ["solid"]},
            "watcher": {"layer": "actors", "tags": ["npc", "solid"]},
        },
        "actions": [
            {"id": "move", "params": {"direction": {"type": "direction", "values": ["up", "down", "left", "right"]}}},
        ],
        "systems": [
            {"id": "navigation", "type": "avatar_navigation", "config": {}},
            {"id": "npcs", "type": "follower_npcs", "config": {"behaviors": {"hunt": behavior}}},
        ],
    }
    return GameDef.from_dict(data, id="test_movement_blocking_layers")


def _movement_blocking_layers_level() -> dict:
    """3x2 board. The watcher sits at (1,0) facing right with a `block`
    entity on `barrier_layer` directly ahead at (2,0); the avatar parks on
    the row below, out of the way, so it never affects the watcher's own
    move."""
    return {
        "id": "test_level",
        "board": {
            "size": [3, 2],
            "layers": {
                "barrier_layer": {
                    "format": "sparse",
                    "entries": [{"position": [2, 0], "kind": "block"}],
                },
                "actors": {
                    "format": "sparse",
                    "entries": [
                        {"position": [1, 0], "kind": "watcher", "behavior": "hunt", "facing": "right"},
                    ],
                },
            },
        },
        "state": {"avatar": {"enabled": True, "position": [0, 1]}},
        "goals": [],
        "loseConditions": [],
    }


def _watcher_pos_blocking(engine: TurnEngine):
    for pos, entity in engine.state.board.layers["actors"].entries():
        if entity.kind == "watcher":
            return pos
    return None


def test_movement_blocking_layers_patrol_reverses_off_a_solid_on_that_layer():
    """A patrol configured with `movementBlockingLayers: ["barrier_layer"]` must
    treat a `solid`-tagged entity there exactly like an `objects`-layer
    solid: forward (2,0) is blocked, so it reverses to (0,0)."""
    game = _movement_blocking_layers_game({"type": "patrol", "movementBlockingLayers": ["barrier_layer"]})
    engine = TurnEngine(game, _movement_blocking_layers_level())

    # The bottom edge blocks this move, so it only spends a beat — the avatar
    # itself never moves, staying clear of the reverse cell above it.
    engine.execute_turn("move", {"direction": "down"})

    assert _watcher_pos_blocking(engine) == Pos(0, 0), _watcher_pos_blocking(engine)
    watcher = engine.state.board.get_entity("actors", Pos(0, 0))
    assert watcher.param("facing") == "left", watcher.param("facing")


def test_movement_blocking_layers_unset_does_not_block():
    """Negative control: proves the field is genuinely additive/opt-in, not
    accidentally always-on. Same board, same `block` entity on
    `barrier_layer`, but the behavior never names that layer, so the patrol
    walks straight through as if it were not there."""
    game = _movement_blocking_layers_game({"type": "patrol"})
    engine = TurnEngine(game, _movement_blocking_layers_level())

    engine.execute_turn("move", {"direction": "down"})

    assert _watcher_pos_blocking(engine) == Pos(2, 0), _watcher_pos_blocking(engine)
    watcher = engine.state.board.get_entity("actors", Pos(2, 0))
    assert watcher.param("facing") == "right", watcher.param("facing")


TESTS_MOVEMENT_BLOCKING_LAYERS = [
    test_movement_blocking_layers_patrol_reverses_off_a_solid_on_that_layer,
    test_movement_blocking_layers_unset_does_not_block,
]


TESTS = TESTS_YIELDING_LAYERS + TESTS_MOVEMENT_BLOCKING_LAYERS


def run_all() -> bool:
    print("yielding / movement-blocking layer tests")
    passed = failed = 0
    for t in TESTS:
        try:
            t()
            passed += 1
            print(f"  ✓ {t.__name__}")
        except AssertionError as exc:
            print(f"  FAIL {t.__name__}: {exc}")
            failed += 1
        except Exception as exc:
            import traceback
            print(f"  ERROR {t.__name__}: {exc}")
            traceback.print_exc()
            failed += 1

    print(f"\n{'=' * 50}")
    print(f"Results: {passed} passed, {failed} failed")
    return failed == 0


if __name__ == "__main__":
    sys.exit(0 if run_all() else 1)
