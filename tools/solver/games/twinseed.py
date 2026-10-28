"""
Twinseed solver adapter.

Delegates game simulation to the Python engine via engine_adapter,
adding a precomputed admissible heuristic for A* search.

Heuristic (precomputed at load time):
  For each garden plot, compute the minimum number of relaxed move commands
  needed to deliver a basket. Ignore avatar positioning and movable obstacles.
  A previously placed clone can make repositioning cost only one action, so
  direction changes do not carry an extra charge.

  One command can slide a basket or keep pushing it while the avatar slides.
  Allow every intermediate stop and ignore blockers, retaining a lower bound.

  Match every remaining plot to a distinct basket at minimum total cost.
  Spare baskets need not be planted. For up to four plots enumerate assignments;
  otherwise sum the per-plot minima, relaxing the distinct-basket requirement.

Dead-end pruning:
  Prune only when the remaining plots cannot be supplied by the baskets.
  A stranded spare basket does not make the state dead.
"""

from __future__ import annotations

import sys
from collections import deque
from dataclasses import dataclass, field
from itertools import combinations, permutations
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_SOLVER = Path(__file__).parent.parent
if str(_SOLVER) not in sys.path:
    sys.path.insert(0, str(_SOLVER))

import engine_adapter as ea

_PACK_DIR = Path(__file__).parent.parent.parent.parent / "packs" / "twinseed"

ACTIONS: List[str] = ["move_up", "move_down", "move_left", "move_right", "clone"]

# (dx, dy) — direction the basket MOVES when pushed
_PUSH_DIRS: List[Tuple[int, int]] = [
    (1,  0),
    (-1, 0),
    (0,  1),
    (0, -1),
]


# ---------------------------------------------------------------------------
# Precomputed heuristic table
# ---------------------------------------------------------------------------

@dataclass
class _HeuristicTable:
    """
    push_dist[plot_xy][basket_xy] = relaxed move-command count to deliver a
    basket from basket_xy to plot_xy on the static board.

    plot_positions: the set of initial garden plot positions (never changes after load).
    """
    plot_positions: List[Tuple[int, int]]
    push_dist: Dict[Tuple[int, int], Dict[Tuple[int, int], float]] = field(
        default_factory=dict
    )

    def min_cost_assignment(
        self,
        basket_positions: List[Tuple[int, int]],
        remaining_plots: List[Tuple[int, int]],
    ) -> float:
        """
        Minimum-cost assignment of baskets to plots (admissible lower bound).

        When n_baskets > n_plots spare baskets may remain; we choose the cheapest
        subset of k=n_plots baskets to fill each plot.  We enumerate all C(n,k)
        choices of which baskets to plant, then all k! plot permutations.
        For k > 4 we fall back to per-plot minimums (always admissible).
        """
        n = len(basket_positions)
        k = len(remaining_plots)
        if k == 0:
            return 0.0
        if n < k:
            return float("inf")    # too few baskets — can't fill all plots

        inf = float("inf")

        if k <= 4:
            best = inf
            for combo in combinations(range(n), k):
                chosen = [basket_positions[i] for i in combo]
                for perm in permutations(remaining_plots):
                    cost = 0.0
                    for (bx, by), plot in zip(chosen, perm):
                        c = self.push_dist.get(plot, {}).get((bx, by), inf)
                        if c >= inf:
                            cost = inf
                            break
                        cost += c
                    if cost < best:
                        best = cost
            return best

        # Fallback for many plots: per-plot minimum (admissible lower bound).
        # Summing over plots (not baskets) is correct when n > k.
        total = 0.0
        for plot in remaining_plots:
            best_c = min(
                self.push_dist.get(plot, {}).get((bx, by), inf)
                for bx, by in basket_positions
            )
            if best_c >= inf:
                return inf
            total += best_c
        return total


def _precompute_heuristic(board: Any, width: int, height: int) -> _HeuristicTable:
    """
    Precompute push_dist tables using reverse BFS from each garden plot.
    Each edge costs one move command, including its possible ice cascade.

    Transitions (reverse pushes):
      Basket arrived at (cx, cy) by a push in direction (dx, dy).
      Origin O = (cx - dx*j, cy - dy*j) for j ≥ 1.
      Object sliding can cross any number of intermediate ice cells.
      If O is ice, the avatar can keep pushing until it steps off the ice.
      That permits one non-ice intermediate cell before the basket's final
      slide. Ignore blockers and allow early stops throughout this relaxed
      move. Originally icy cells remain available for sliding even if they
      are later melted, which only makes the estimate more optimistic.
    """
    from engines.python._models import Pos

    ground_layer = board.layers.get("ground")
    if ground_layer is None:
        return _HeuristicTable(plot_positions=[])

    def cell_kind(x: int, y: int) -> str:
        if x < 0 or y < 0 or x >= width or y >= height:
            return "oob"
        cell = ground_layer.get(Pos(x, y))
        return cell.kind if cell is not None else "empty"

    plot_positions = [
        (pos.x, pos.y)
        for pos, ent in ground_layer.entries()
        if ent.kind == "garden_plot"
    ]

    push_dist: Dict[Tuple[int, int], Dict[Tuple[int, int], float]] = {}
    inf = float("inf")

    for (gx, gy) in plot_positions:
        dist = {(gx, gy): 0.0}
        queue = deque([(gx, gy)])

        while queue:
            cx, cy = queue.popleft()
            new_cost = dist[(cx, cy)] + 1.0

            for dx, dy in _PUSH_DIRS:

                # Walk backwards from (cx, cy) in the anti-push direction.
                j = 1
                non_ice = 0
                while True:
                    ox, oy = cx - dx * j, cy - dy * j
                    kind_o = cell_kind(ox, oy)
                    if kind_o in ("oob", "void"):
                        break

                    # With a non-ice cell in the interior, the basket must
                    # start on ice so the avatar can push during its slide.
                    if non_ice == 0 or kind_o == "ice":
                        origin = (ox, oy)
                        if dist.get(origin, inf) > new_cost:
                            dist[origin] = new_cost
                            queue.append(origin)

                    if kind_o != "ice":
                        non_ice += 1
                    if non_ice > 1:
                        break
                    j += 1

        push_dist[(gx, gy)] = dist

    return _HeuristicTable(plot_positions=plot_positions, push_dist=push_dist)


# ---------------------------------------------------------------------------
# Info wrapper
# ---------------------------------------------------------------------------

@dataclass
class TwinseedInfo:
    engine_info: ea.EngineInfo
    level_id: Optional[str]
    width: int
    height: int
    htable: _HeuristicTable

    @property
    def ACTIONS(self) -> List[str]:
        return self.engine_info.ACTIONS


# ---------------------------------------------------------------------------
# Solver interface
# ---------------------------------------------------------------------------

def load(level_json: Dict[str, Any]) -> Tuple[ea.EngineState, TwinseedInfo]:
    """Load a twinseed level and precompute the heuristic table."""
    initial, engine_info = ea.load(level_json, _PACK_DIR)
    board = level_json.get("board", {})
    cols, rows = board.get("size", [0, 0])

    # Precompute from the actual engine board (after parsing rules/defaults).
    game_board = initial.game_state.board
    htable = _precompute_heuristic(game_board, cols, rows)

    info = TwinseedInfo(
        engine_info=engine_info,
        level_id=level_json.get("id"),
        width=cols,
        height=rows,
        htable=htable,
    )
    return initial, info


def apply(
    state: ea.EngineState, action: str, info: TwinseedInfo
) -> Tuple[ea.EngineState, bool, List[dict]]:
    """Apply one action via the Python engine."""
    return ea.apply(state, action, info.engine_info)


def heuristic(state: ea.EngineState, info: TwinseedInfo) -> float:
    """
    Admissible A* heuristic using the precomputed push_dist tables.

    Match remaining plots to baskets using relaxed move-command costs.
    Returns zero when all plots are planted, even if spare baskets remain.
    """
    gs = state.game_state
    board = gs.board

    objects_layer = board.layers.get("objects")
    ground_layer = board.layers.get("ground")
    if objects_layer is None or ground_layer is None:
        return 0.0

    baskets = [
        (pos.x, pos.y)
        for pos, entity in objects_layer.entries()
        if entity.kind == "seed_basket"
    ]
    # Only consider plots that still exist in the current game state.
    remaining_plots = [
        (pos.x, pos.y)
        for pos, entity in ground_layer.entries()
        if entity.kind == "garden_plot"
    ]
    return info.htable.min_cost_assignment(baskets, remaining_plots)


def can_prune(
    state: ea.EngineState, info: TwinseedInfo, depth: int, max_depth: int
) -> bool:
    """Prune only if the relaxed assignment cannot fill all remaining plots."""
    return heuristic(state, info) == float("inf")


def _wall_or_solid(board: Any, x: int, y: int) -> bool:
    """True if the cell is out of bounds, void, or holds a non-basket solid."""
    from engines.python._models import Pos
    if x < 0 or y < 0 or x >= board.width or y >= board.height:
        return True
    p = Pos(x, y)
    ground = board.layers.get("ground")
    if ground is not None:
        g = ground.get(p)
        if g is not None and g.kind == "void":
            return True
    objects = board.layers.get("objects")
    if objects is not None:
        obj = objects.get(p)
        if obj is not None and obj.kind != "seed_basket":
            return True
    return False
