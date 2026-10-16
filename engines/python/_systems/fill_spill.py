"""FillSpillSystem — see docs/dsl/04_systems.md."""
from __future__ import annotations
from collections import deque
from typing import Optional

from .._models import Pos, Entity, GameState, dir_delta
from .._game_def import GameDef
from .. import _events as ev
from ._base import GameSystem, config_list

#: Up, right, down, left — the order every neighbour scan uses, in both engines.
_NEIGHBOURS = ((0, -1), (1, 0), (0, 1), (-1, 0))

#: Every pass of the grow loop joins a cell, merges a pool or ends the pool's
#: growth, and every spill moves water strictly downhill, so settling always
#: terminates. The cap guards against a malformed level only.
_MAX_STEPS = 100_000


class _Pool:
    """A body of standing water: its cells, its volume, and the sum of the
    ground heights under it. Its level is (units + height_sum) / len(cells),
    kept as that exact fraction — never a float — so both engines agree."""

    __slots__ = ("cells", "units", "height_sum")

    def __init__(self, cells: set, units: int, height_sum: int):
        self.cells = cells
        self.units = units
        self.height_sum = height_sum

    def level(self) -> tuple[int, int]:
        return self.units + self.height_sum, len(self.cells)


def _lt(a: tuple[int, int], b: tuple[int, int]) -> bool:
    return a[0] * b[1] < b[0] * a[1]


def _eq(a: tuple[int, int], b: tuple[int, int]) -> bool:
    return a[0] * b[1] == b[0] * a[1]


class _Settler:
    """One settle of one board. Water keeps its volume; the level is derived."""

    def __init__(self, heights: dict, passable):
        self.heights = heights          # (x, y) -> int, passable cells only
        self.passable = passable        # (x, y) -> bool
        self.pools: list[_Pool] = []
        self.owner: dict[tuple[int, int], int] = {}
        self.steps = 0

    # -- geometry -------------------------------------------------------------

    def neighbours(self, cell):
        x, y = cell
        for dx, dy in _NEIGHBOURS:
            other = (x + dx, y + dy)
            if self.passable(other):
                yield other

    def surface(self, cell) -> tuple[int, int]:
        """Water level on a wet cell, ground height on a dry one."""
        index = self.owner.get(cell)
        if index is not None:
            return self.pools[index].level()
        return self.heights[cell], 1

    def _lowest(self, cells) -> tuple[int, int]:
        """The cell with the lowest surface; ties go to reading order."""
        best = None
        best_surface = None
        for cell in cells:
            s = self.surface(cell)
            if (best is None or _lt(s, best_surface)
                    or (_eq(s, best_surface) and (cell[1], cell[0]) < (best[1], best[0]))):
                best, best_surface = cell, s
        return best

    # -- pools ----------------------------------------------------------------

    def _merge(self, into: int, other: int) -> None:
        target, source = self.pools[into], self.pools[other]
        for cell in source.cells:
            self.owner[cell] = into
        target.cells |= source.cells
        target.units += source.units
        target.height_sum += source.height_sum
        source.cells = set()
        source.units = 0
        source.height_sum = 0

    def pour(self, units: int, cell) -> Optional[tuple[int, tuple[int, int]]]:
        """Add water at a cell: it runs downhill, then fills from the bottom.

        Returns the spill `(units, cell)` still to be poured, or None.
        """
        while True:
            index = self.owner.get(cell)
            if index is not None:
                self.pools[index].units += units
                return self._grow(index)
            height = (self.heights[cell], 1)
            lower = [d for d in self.neighbours(cell) if _lt(self.surface(d), height)]
            if not lower:
                break
            cell = self._lowest(lower)
        self.pools.append(_Pool({cell}, units, self.heights[cell]))
        index = len(self.pools) - 1
        self.owner[cell] = index
        return self._grow(index)

    def _grow(self, index: int) -> Optional[tuple[int, tuple[int, int]]]:
        """Raise a pool until its water is spent or it reaches a lip.

        The pool rises evenly over its cells. Each time its level would pass
        the lowest surface on its rim it either merges the pool standing there,
        takes in the dry rim cells at that height (with any flat plateau they
        lead to), or — when those rim cells lead to lower ground — stops at
        exactly that height and hands everything above it on as a spill.
        """
        while True:
            self.steps += 1
            if self.steps > _MAX_STEPS:
                return None
            pool = self.pools[index]
            count, height_sum, units = len(pool.cells), pool.height_sum, pool.units
            rim = set()
            for cell in pool.cells:
                for other in self.neighbours(cell):
                    if self.owner.get(other) != index:
                        rim.add(other)
            if not rim:
                return None
            low = self.surface(self._lowest(rim))
            # The water cannot reach `low`: it settles below it.
            if units * low[1] <= low[0] * count - height_sum * low[1]:
                return None

            merged = False
            for cell in sorted(rim, key=lambda c: (c[1], c[0])):
                other = self.owner.get(cell)
                if other is not None and other != index and self.pools[other].cells \
                        and _eq(self.surface(cell), low):
                    self._merge(index, other)
                    merged = True
            if merged:
                continue

            # Every wet rim pool stands higher than `low`, so `low` is a dry
            # ground height: a whole number.
            x = low[0] // low[1]
            plateau = set()
            queue = deque(c for c in rim if c not in self.owner and self.heights[c] == x)
            plateau.update(queue)
            while queue:
                cell = queue.popleft()
                for other in self.neighbours(cell):
                    if (other not in plateau and other not in self.owner
                            and self.heights[other] == x):
                        plateau.add(other)
                        queue.append(other)

            lips = []
            level_pools = set()
            for cell in plateau:
                for other in self.neighbours(cell):
                    if other in plateau or self.owner.get(other) == index:
                        continue
                    s = self.surface(other)
                    if _lt(s, (x, 1)):
                        lips.append(other)
                    elif other in self.owner and _eq(s, (x, 1)):
                        level_pools.add(self.owner[other])

            if lips:
                kept = x * count - height_sum
                pool.units = kept
                return units - kept, self._lowest(lips)

            for cell in plateau:
                self.owner[cell] = index
            pool.cells |= plateau
            pool.height_sum += x * len(plateau)
            for other in sorted(level_pools):
                if other != index and self.pools[other].cells:
                    self._merge(index, other)


class FillSpillSystem(GameSystem):
    """Standing water with a fixed volume, settled over a height map.

    Water is never created or destroyed. It runs downhill, fills the lowest
    hollow first and rises evenly; when it reaches the lowest lip of its
    hollow it stops there and the rest pours over into the next hollow.
    Water trapped below a lip stays trapped. Two pools that meet become one.

    Every settle re-pours each pool's whole volume at its lowest cell, which
    reproduces a stable board exactly and resolves an unstable one (a gate
    just opened) the way the water would flow. Volumes stay whole numbers:
    a pool is only ever divided at a lip, and lips are ground heights.

    Phases: gates toggle in ``action_resolution`` (declare this system before
    ``avatar_navigation``); the water settles in ``npc_resolution`` and once at
    level load.

    Optional ``seeps`` are slow leaks: after each turn's settle (not at load)
    every seep moves up to ``rate`` units from the highest pool beside it to
    the lowest surface beside it, taking only water above its sill and never
    leaving the far side higher than the near side.

    Tolerance contract (both engines must agree): a missing or non-dict
    ``heights`` makes the system inert. Ground kinds absent from ``heights``
    are banks. A water cell whose ``units`` param is missing or not an
    integer contributes nothing; a pool whose units sum to zero or less
    vanishes. Gate and marker entries that are not dicts with string kinds are
    ignored. A non-dict ``seeps`` entry or a ``rate`` that is not a positive
    integer disables seeps.
    """

    def __init__(self, sys_id: str):
        super().__init__(sys_id, "fill_spill")

    # -- phases ---------------------------------------------------------------

    def execute_action_resolution(self, action: dict, state: GameState, game: GameDef) -> list[dict]:
        config = game.system_config(self.id)
        if not isinstance(config.get("heights"), dict):
            return []
        gates = [g for g in config_list(config, "gates", []) if _valid_gate(g)]
        if not gates:
            return []
        if action.get("actionId") != config.get("gateAction", "move"):
            return []
        direction = action.get("params", {}).get("direction")
        avatar = state.avatar
        if not isinstance(direction, str) or not avatar.enabled or avatar.position is None:
            return []
        try:
            dx, dy = dir_delta(direction)
        except KeyError:
            return []
        target = Pos(avatar.position.x + dx, avatar.position.y + dy)
        if not state.board.is_in_bounds(target):
            return []
        for gate in gates:
            layer = gate.get("layer", "objects")
            entity = state.board.get_entity(layer, target)
            if entity is None:
                continue
            if entity.kind == gate["closed"]:
                wanted = gate["open"]
            elif entity.kind == gate["open"]:
                water_layer = config.get("waterLayer", "water")
                if state.board.get_entity(water_layer, target) is not None:
                    return []  # a board cannot be dropped against standing water
                wanted = gate["closed"]
            else:
                continue
            state.board.set_entity(layer, target, Entity(wanted, dict(entity.params)))
            return [ev.cell_transformed(target, entity.kind, wanted, layer)]
        return []

    def execute_npc_resolution(self, state: GameState, game: GameDef) -> list[dict]:
        return self._settle(state, game, turn=True)

    def execute_load_settle(self, state: GameState, game: GameDef) -> list[dict]:
        return self._settle(state, game, turn=False)

    # -- settling -------------------------------------------------------------

    def _settle(self, state: GameState, game: GameDef, turn: bool) -> list[dict]:
        config = game.system_config(self.id)
        height_of = config.get("heights")
        if not isinstance(height_of, dict):
            return []
        board = state.board
        ground_layer = config.get("groundLayer", "ground")
        water_layer = config.get("waterLayer", "water")
        water_kinds = [k for k in config_list(config, "waterKinds", ["water"]) if isinstance(k, str)]
        if not water_kinds or board.layers.get(water_layer) is None:
            return []

        barriers = config.get("barriers")
        barrier_layer, barrier_kinds = "objects", set()
        if isinstance(barriers, dict):
            barrier_layer = barriers.get("layer", "objects")
            barrier_kinds = {k for k in config_list(barriers, "kinds", []) if isinstance(k, str)}
        seep_layer, seep_kinds, seep_rate = _seep_config(config)

        heights: dict[tuple[int, int], int] = {}
        seep_sills: list[tuple[tuple[int, int], int]] = []
        for y in range(board.height):
            for x in range(board.width):
                ground = board.get_entity(ground_layer, Pos(x, y))
                if ground is None:
                    continue
                h = height_of.get(ground.kind)
                if not isinstance(h, int) or isinstance(h, bool):
                    continue
                blocker = board.get_entity(barrier_layer, Pos(x, y))
                if blocker is not None and blocker.kind in barrier_kinds:
                    continue
                seep = board.get_entity(seep_layer, Pos(x, y)) if seep_kinds else None
                if seep is not None and seep.kind in seep_kinds:
                    seep_sills.append(((x, y), h))
                    continue
                heights[(x, y)] = h

        # Existing pools: connected water cells; volume is the sum of `units`.
        water = board.layers[water_layer]
        wet = {(p.x, p.y): e for p, e in water.entries()}
        seen: set = set()
        sources = []
        for start in sorted(wet, key=lambda c: (c[1], c[0])):
            if start in seen:
                continue
            component, queue = [], deque([start])
            seen.add(start)
            while queue:
                cell = queue.popleft()
                component.append(cell)
                x, y = cell
                for dx, dy in _NEIGHBOURS:
                    other = (x + dx, y + dy)
                    if other in wet and other not in seen:
                        seen.add(other)
                        queue.append(other)
            units = 0
            for cell in component:
                u = wet[cell].params.get("units")
                if isinstance(u, int) and not isinstance(u, bool):
                    units += u
            ground = [c for c in component if c in heights]
            if units <= 0 or not ground:
                continue
            seed = min(ground, key=lambda c: (heights[c], c[1], c[0]))
            sources.append((seed, units))

        settler = _pour_all(heights, sources)
        if turn:
            for cell, sill in sorted(seep_sills, key=lambda s: (s[0][1], s[0][0])):
                settler = _seep(settler, heights, cell, sill, seep_rate)

        # Write the water layer back.
        new_water: dict[tuple[int, int], Entity] = {}
        for pool in settler.pools:
            if not pool.cells or pool.units <= 0:
                continue
            num, den = pool.level()
            seed = min(pool.cells, key=lambda c: (heights[c], c[1], c[0]))
            for cell in pool.cells:
                # depth = num/den - h ; band = ceil(depth) - 1, clamped
                depth_num = num - heights[cell] * den
                band = (depth_num + den - 1) // den - 1
                kind = water_kinds[max(0, min(band, len(water_kinds) - 1))]
                params = {"units": pool.units} if cell == seed else {}
                new_water[cell] = Entity(kind, params)

        changed = False
        for cell in set(wet) | set(new_water):
            old, new = wet.get(cell), new_water.get(cell)
            if old is None or new is None or old.kind != new.kind or old.params != new.params:
                board.set_entity(water_layer, Pos(*cell), new)
                changed = True

        events = self._apply_markers(config, state, set(new_water))
        self._apply_flood(config, state, set(new_water))
        if changed:
            events.insert(0, ev.water_settled(len(new_water)))
        return events

    def _apply_markers(self, config: dict, state: GameState, wet: set) -> list[dict]:
        markers = config.get("markers")
        if not isinstance(markers, dict):
            return []
        layer_id = markers.get("layer", "objects")
        layer = state.board.layers.get(layer_id)
        if layer is None:
            return []
        pairs = [p for p in config_list(markers, "pairs", [])
                 if isinstance(p, dict) and isinstance(p.get("dry"), str) and isinstance(p.get("wet"), str)]
        events = []
        for pos, entity in list(layer.entries()):
            for pair in pairs:
                if entity.kind not in (pair["dry"], pair["wet"]):
                    continue
                wanted = pair["wet"] if (pos.x, pos.y) in wet else pair["dry"]
                if wanted != entity.kind:
                    state.board.set_entity(layer_id, pos, Entity(wanted, dict(entity.params)))
                    events.append(ev.cell_transformed(pos, entity.kind, wanted, layer_id))
                break
        return events

    def _apply_flood(self, config: dict, state: GameState, wet: set) -> None:
        flood = config.get("flood")
        if not isinstance(flood, dict):
            return
        variable = flood.get("variable")
        if not isinstance(variable, str) or not variable:
            return
        flooded = 0
        avatar = state.avatar
        if flood.get("avatar", True) and avatar.enabled and avatar.position is not None \
                and (avatar.position.x, avatar.position.y) in wet:
            flooded += 1
        kinds = {k for k in config_list(flood, "kinds", []) if isinstance(k, str)}
        layer = state.board.layers.get(flood.get("layer", "objects"))
        if kinds and layer is not None:
            for pos, entity in layer.entries():
                if entity.kind in kinds and (pos.x, pos.y) in wet:
                    flooded += 1
        if flooded:
            current = state.variables.get(variable, 0)
            state.variables[variable] = (current if isinstance(current, int) else 0) + flooded


def _seep_config(config: dict) -> tuple[str, set, int]:
    seeps = config.get("seeps")
    if not isinstance(seeps, dict):
        return "objects", set(), 0
    layer = seeps.get("layer", "objects")
    kinds = {k for k in config_list(seeps, "kinds", []) if isinstance(k, str)}
    rate = seeps.get("rate", 1)
    if not isinstance(rate, int) or isinstance(rate, bool) or rate <= 0:
        return layer, set(), 0
    return layer, kinds, rate


def _pour_all(heights: dict, sources: list) -> _Settler:
    """Pour every (seed, units) source into a fresh settler, seeds in reading
    order (ties keep list order)."""
    settler = _Settler(heights, lambda c: c in heights)
    order = sorted(range(len(sources)), key=lambda i: (sources[i][0][1], sources[i][0][0], i))
    for i in order:
        seed, units = sources[i]
        if units <= 0:
            continue
        pending = [(units, seed)]
        while pending:
            amount, cell = pending.pop()
            spill = settler.pour(amount, cell)
            if spill is not None:
                pending.append(spill)
    return settler


def _seep(settler: _Settler, heights: dict, cell, sill: int, rate: int) -> _Settler:
    """One seep's turn: up to `rate` units leave the highest pool beside it
    (only water standing above the sill) for the lowest surface beside it
    outside that pool, unless that would leave the far side higher than the
    near side. Returns the settler for the board afterwards."""
    x, y = cell
    beside = [(x + dx, y + dy) for dx, dy in _NEIGHBOURS]
    beside = [c for c in beside if c in heights]
    wet = [c for c in beside if c in settler.owner]
    if not wet:
        return settler
    source = wet[0]
    for c in wet[1:]:
        s, b = settler.surface(c), settler.surface(source)
        if _lt(b, s) or (_eq(s, b) and (c[1], c[0]) < (source[1], source[0])):
            source = c
    level = settler.surface(source)
    if not _lt((sill, 1), level):
        return settler
    index = settler.owner[source]
    others = [c for c in beside if settler.owner.get(c) != index]
    if not others:
        return settler
    target = settler._lowest(others)
    if not _lt(settler.surface(target), level):
        return settler
    pool = settler.pools[index]
    above = pool.units + pool.height_sum - sum(max(heights[c], sill) for c in pool.cells)
    amount = min(rate, above)
    if amount <= 0:
        return settler
    sources = []
    for i, p in enumerate(settler.pools):
        if not p.cells or p.units <= 0:
            continue
        seed = min(p.cells, key=lambda c: (heights[c], c[1], c[0]))
        sources.append((seed, p.units - amount if i == index else p.units))
    sources.append((target, amount))
    after = _pour_all(heights, sources)
    # No overshoot: the far side must not end up higher than the near side,
    # or two nearly level pools would trade a unit back and forth for ever.
    if _lt(after.surface(source), after.surface(target)):
        return settler
    return after


def _valid_gate(gate) -> bool:
    return (isinstance(gate, dict) and isinstance(gate.get("closed"), str)
            and isinstance(gate.get("open"), str))
