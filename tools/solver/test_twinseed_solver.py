"""Twinseed bounds and optimized backends, using only public game content."""
from __future__ import annotations

import json
import math
from pathlib import Path

import pytest

import engine_adapter as ea
from games import twinseed, twinseed_fast
from engines.python._models import Pos


LEVELS = sorted(
    (Path(__file__).resolve().parents[2] / "packs/twinseed/levels").glob("*.json")
)


@pytest.fixture(params=["engine", "fast", "cython"])
def backend(request):
    if request.param == "engine":
        return twinseed
    if request.param == "fast":
        return twinseed_fast
    from games import twinseed_cython
    if not twinseed_cython.CYTHON_AVAILABLE:
        pytest.skip("optional Cython extension is not built")
    from games import twinseed_cy
    return twinseed_cy


def _encoded(state, info):
    """Express the authoritative engine state in the optimized byte format."""
    gs = state.game_state
    cells = []
    for y in range(info.height):
        for x in range(info.width):
            pos = Pos(x, y)
            ground = gs.board.get_entity("ground", pos)
            obj = gs.board.get_entity("objects", pos)
            g = twinseed_fast._GROUND_STR[ground.kind] if ground else twinseed_fast.GROUND_EMPTY
            o = twinseed_fast._OBJ_STR[obj.kind] if obj else twinseed_fast.OBJ_NONE
            cells.append((o << 3) | g)
    clone = next(
        (pos.y * info.width + pos.x for pos, _ in gs.board.layers["clone"].entries()),
        twinseed_fast.CLONE_INACTIVE,
    )
    avatar = gs.avatar.position
    cells.extend([
        avatar.y * info.width + avatar.x,
        clone,
        twinseed_fast._INV_STR.get(gs.avatar.item, twinseed_fast.INV_NONE),
    ])
    return bytes(cells)


@pytest.mark.parametrize("level_path", LEVELS, ids=lambda p: p.stem)
def test_public_paths_and_successors(backend, level_path):
    """Check every stored state and every one-action branch against the engine."""
    level = json.loads(level_path.read_text())
    actions = ea.gold_path_actions(level)
    reference, reference_info = twinseed.load(level)
    state, info = backend.load(level)
    won = False
    for i, action in enumerate(actions):
        h = backend.heuristic(state, info)
        assert 0 <= h <= len(actions) - i
        assert not backend.can_prune(state, info, i, len(actions))
        assert h == twinseed.heuristic(reference, reference_info)
        if backend is not twinseed:
            encoded = _encoded(reference, reference_info)
            assert state == encoded
            for branch in twinseed.ACTIONS:
                expected, expected_win, _ = twinseed.apply(reference, branch, reference_info)
                actual, actual_win, _ = backend.apply(encoded, branch, info)
                assert actual == _encoded(expected, reference_info), (level_path.stem, i, branch)
                assert actual_win == expected_win, (level_path.stem, i, branch)
        reference, reference_won, _ = twinseed.apply(reference, action, reference_info)
        state, won, _ = backend.apply(state, action, info)
        assert won == reference_won

    assert won
    assert backend.heuristic(state, info) == 0
    assert not backend.can_prune(state, info, len(actions), len(actions))
    if backend is not twinseed:
        assert state == _encoded(reference, reference_info)


def _level(width, height, avatar, baskets, plots, *, ice=(), void=()):
    return {
        "id": "solver_regression",
        "board": {
            "size": [width, height],
            "layers": {
                "ground": {"format": "sparse", "entries": [
                    {"position": list(pos), "kind": kind}
                    for kind, positions in [
                        ("garden_plot", plots), ("ice", ice), ("void", void),
                    ]
                    for pos in positions
                ]},
                "objects": {"format": "sparse", "entries": [
                    {"position": list(pos), "kind": "seed_basket"} for pos in baskets
                ]},
            },
        },
        "state": {"avatar": {"position": list(avatar)}},
        "goals": [{"id": "plant_all", "type": "all_cleared",
                   "config": {"kind": "garden_plot"}}],
    }


def test_stranded_spare_basket_does_not_prevent_solving(backend):
    level = _level(
        5, 3, (4, 0), [(0, 0), (4, 1)], [(4, 2)],
        void=[(2, y) for y in range(3)],
    )
    state, info = backend.load(level)
    assert backend.heuristic(state, info) == 1
    assert not backend.can_prune(state, info, 0, 1)
    state, won, _ = backend.apply(state, "move_down", info)
    assert won
    assert backend.heuristic(state, info) == 0
    assert not backend.can_prune(state, info, 1, 1)


def test_missing_baskets_are_a_dead_end(backend):
    state, info = backend.load(_level(3, 1, (0, 0), [], [(2, 0)]))
    assert math.isinf(backend.heuristic(state, info))


def test_four_plot_assignment(backend):
    state, info = backend.load(_level(
        4, 3, (0, 0), [(x, 1) for x in range(4)], [(x, 2) for x in range(4)],
    ))
    assert backend.heuristic(state, info) == 4


@pytest.mark.parametrize("plot,ice", [
    ((3, 0), [(1, 0)]),
    ((5, 0), [(1, 0), (3, 0), (4, 0)]),
])
def test_one_move_can_push_while_sliding_then_slide_the_basket(backend, plot, ice):
    level = _level(plot[0] + 1, 1, (0, 0), [(1, 0)], [plot], ice=ice)
    state, info = backend.load(level)
    assert backend.heuristic(state, info) == 1
    state, won, _ = backend.apply(state, "move_right", info)
    assert won
    assert backend.heuristic(state, info) == 0
