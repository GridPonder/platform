"""SupportCollapseSystem — see docs/dsl/04_systems.md."""
from __future__ import annotations

from collections import deque
from typing import Optional

from .._game_def import GameDef
from .._models import Entity, GameState, Pos, dir_delta
from .. import _events as ev
from ._base import GameSystem, config_list

_CARDINALS = [Pos(0, -1), Pos(0, 1), Pos(-1, 0), Pos(1, 0)]
_DIAGONALS = _CARDINALS + [Pos(-1, -1), Pos(1, -1), Pos(-1, 1), Pos(1, 1)]


class SupportCollapseSystem(GameSystem):
    """Cells that lose their connection to a support root fall as rigid bodies.

    A structure is held up by cells tagged as roots. After any cell is removed,
    every maximal group of member cells that can no longer reach a root is an
    orphan, and each orphan translates in the configured direction — keeping its
    exact shape — until one of its cells is blocked. Components fall
    simultaneously, one step at a time, so stacked orphans resolve
    deterministically without an ordering rule.

    Generic: any game with a structure hanging from fixed roots names its own
    root/member tags and fall direction. The player-facing sever verb is
    optional — omit `severAction` and drive the collapse from `triggerEvents`
    when cells are removed by rules or other systems instead.
    """

    def __init__(self, sys_id: str, config: Optional[dict] = None):
        super().__init__(sys_id, "support_collapse")
        self.config = config or {}

    @staticmethod
    def _switch_kinds(sw: dict) -> tuple[dict, dict]:
        """The `pressed` map and its reverse.

        A released cell must come back as the kind it was, so the map must be
        one-to-one, and no kind may be both a released and a pressed form (a
        pressed cell would otherwise switch again on every pass).
        """
        to_pressed = {str(k): str(v) for k, v in (sw.get("pressed") or {}).items()}
        to_released: dict = {}
        for released, pressed in to_pressed.items():
            if pressed in to_released:
                raise ValueError(
                    f"support_collapse switches.pressed maps both "
                    f"'{to_released[pressed]}' and '{released}' to '{pressed}'; "
                    "each pressed kind needs exactly one released kind")
            to_released[pressed] = released
        both = sorted(set(to_pressed) & set(to_released))
        if both:
            raise ValueError(
                "support_collapse switches.pressed uses "
                f"{', '.join(repr(k) for k in both)} as both a released and a pressed kind")
        return to_pressed, to_released

    # ── config ──────────────────────────────────────────────────────────────
    def _cfg(self, game: GameDef) -> dict:
        return self.config or game.system_config(self.id)

    @staticmethod
    def _default_kind(game: GameDef, layer_id: str) -> Optional[str]:
        """The kind an emptied cell reverts to on an exactly_one layer."""
        for layer in game.layers:
            if layer.get("id") == layer_id:
                if layer.get("isExactlyOne"):
                    return layer.get("defaultKind") or "empty"
                return None
        return None

    def _empty(self, game: GameDef, layer_id: str) -> Optional[Entity]:
        kind = self._default_kind(game, layer_id)
        return Entity(kind) if kind else None

    # ── phase 2: the sever verb ─────────────────────────────────────────────
    def execute_action_resolution(
        self, action: dict, state: GameState, game: GameDef
    ) -> list[dict]:
        cfg = self._cfg(game)
        sever_action = cfg.get("severAction")
        if not sever_action or action.get("actionId") != sever_action:
            return []

        avatar = state.avatar
        if not avatar.enabled or avatar.position is None:
            return [ev.action_vetoed()]

        layer_id = cfg.get("layer", "ground")
        layer = state.board.layers.get(layer_id)
        if layer is None:
            return [ev.action_vetoed()]

        # The target may be named either way, so a pack can bind the verb to a
        # directional swipe or to tapping the cell itself. Both resolve to a
        # single cell adjacent to the actor.
        params = action.get("params", {})
        raw_position = params.get("position")
        if raw_position is not None:
            target = Pos.from_json(raw_position)
            if abs(target.x - avatar.position.x) + abs(
                target.y - avatar.position.y
            ) != 1:
                return [ev.action_vetoed()]  # not adjacent
        else:
            dir_str = params.get("direction")
            if not dir_str:
                return [ev.action_vetoed()]
            dx, dy = dir_delta(dir_str)
            if dx == 0 and dy == 0:
                return [ev.action_vetoed()]
            target = Pos(avatar.position.x + dx, avatar.position.y + dy)

        if not state.board.is_in_bounds(target):
            return [ev.action_vetoed()]

        entity = layer.get(target)
        severable = config_list(cfg, "severableTags", ["severable"])
        if entity is None or not any(
            game.has_tag(entity.kind, tag) for tag in severable
        ):
            return [ev.action_vetoed()]

        previous_kind = entity.kind
        fuse = cfg.get("fuse") or {}
        ignite = {str(k): str(v) for k, v in (fuse.get("ignite") or {}).items()}
        if previous_kind in ignite:
            # Lighting a fuse removes nothing yet: the cell burns later.
            lit = ignite[previous_kind]
            delay_param = fuse.get("delayParam", "delay")
            layer.set(
                target,
                Entity(lit, {**entity.params, delay_param: int(fuse.get("delay", 1))}),
            )
            return [ev.cell_transformed(target, previous_kind, lit, layer_id)]
        layer.set(target, self._empty(game, layer_id))
        events = [ev.cell_cleared(target, previous_kind, layer_id)]
        events.extend(self._collapse(state, game, cfg))
        return events

    # ── phase 5: event-driven collapse ──────────────────────────────────────
    def execute_cascade_resolution(
        self, trigger_events: list[dict], state: GameState, game: GameDef
    ) -> list[dict]:
        cfg = self._cfg(game)
        triggers = set(config_list(cfg, "triggerEvents", []))
        if not triggers:
            return []
        if not any(e.get("type") in triggers for e in trigger_events):
            return []
        return self._collapse(state, game, cfg)

    # ── phase 6: strain ─────────────────────────────────────────────────────
    def execute_npc_resolution(self, state: GameState, game: GameDef) -> list[dict]:
        """Overloaded load-limited cells tire once per turn and fail at zero.

        The load on a cell is every member cell that would fall if that cell
        were removed — so supports that share a load carry none of it until
        one of them goes. Each accepted turn, every overloaded cell loses one
        point of endurance; then every overloaded cell with none left fails at
        once (it is removed and the structure collapses). Failures repeat
        without further wear until nothing more breaks, so a cell already at
        zero gives way the moment a failure overloads it.
        """
        cfg = self._cfg(game)
        events = self._burn(state, game, cfg)
        strain = cfg.get("strain")
        if not strain:
            return events
        layer_id = cfg.get("layer", "ground")
        layer = state.board.layers.get(layer_id)
        if layer is None:
            return events
        board = state.board
        tags = config_list(strain, "tags", ["load_limited"])
        cap_param = strain.get("capacityParam", "capacity")
        end_param = strain.get("enduranceParam", "endurance")
        default_endurance = int(strain.get("endurance", 0))

        def overloaded() -> list[Pos]:
            out: list[Pos] = []
            for p, load in self._loads(state, game, cfg, tags).items():
                cap = layer.get(p).params.get(cap_param)
                if isinstance(cap, int) and load > cap:
                    out.append(p)
            return out

        def endurance(p: Pos) -> int:
            value = layer.get(p).params.get(end_param)
            return value if isinstance(value, int) else default_endurance

        for p in overloaded():
            entity = layer.get(p)
            left = max(0, endurance(p) - 1)
            layer.set(p, Entity(entity.kind, {**entity.params, end_param: left}))

        avatar_pos = state.avatar.position if state.avatar.enabled else None
        for _ in range(board.width * board.height + 1):
            failing = [p for p in overloaded() if endurance(p) <= 0]
            if not failing:
                break
            for p in failing:
                kind = layer.get(p).kind
                layer.set(p, self._empty(game, layer_id))
                events.append(ev.cell_cleared(p, kind, layer_id))
            if avatar_pos is not None and avatar_pos in failing:
                events.extend(self._avatar_fell(state, cfg))
            events.extend(self._collapse(state, game, cfg))
            avatar_pos = state.avatar.position if state.avatar.enabled else None
        return events

    def _burn(self, state: GameState, game: GameDef, cfg: dict) -> list[dict]:
        """Lit fuse cells count down, then burn away and light their neighbours.

        Every lit cell whose delay is above 0 loses 1. Every lit cell already
        at 0 when the turn began is removed, and each fuse cell touching it is
        lit with delay 0, so it burns one turn later: a fuse burns one cell per
        turn. Then the structure collapses once.
        """
        fuse = cfg.get("fuse")
        if not fuse:
            return []
        ignite = {str(k): str(v) for k, v in (fuse.get("ignite") or {}).items()}
        if not ignite:
            return []
        layer_id = cfg.get("layer", "ground")
        layer = state.board.layers.get(layer_id)
        if layer is None:
            return []
        board = state.board
        delay_param = fuse.get("delayParam", "delay")
        lit_kinds = set(ignite.values())
        deltas = _DIAGONALS if cfg.get("connectivity") == "diagonal" else _CARDINALS

        burning: list[Pos] = []
        for y in range(board.height):
            for x in range(board.width):
                p = Pos(x, y)
                e = layer.get(p)
                if e is None or e.kind not in lit_kinds:
                    continue
                delay = e.params.get(delay_param)
                if isinstance(delay, int) and delay > 0:
                    layer.set(p, Entity(e.kind, {**e.params, delay_param: delay - 1}))
                else:
                    burning.append(p)
        if not burning:
            return []

        events: list[dict] = []
        for p in burning:
            kind = layer.get(p).kind
            layer.set(p, self._empty(game, layer_id))
            events.append(ev.cell_cleared(p, kind, layer_id))
        for p in burning:
            for d in deltas:
                nb = Pos(p.x + d.x, p.y + d.y)
                if not board.is_in_bounds(nb):
                    continue
                e = layer.get(nb)
                if e is not None and e.kind in ignite:
                    lit = ignite[e.kind]
                    layer.set(nb, Entity(lit, {**e.params, delay_param: 0}))
                    events.append(ev.cell_transformed(nb, e.kind, lit, layer_id))
        avatar_pos = state.avatar.position if state.avatar.enabled else None
        if avatar_pos is not None and avatar_pos in burning:
            events.extend(self._avatar_fell(state, cfg))
        events.extend(self._collapse(state, game, cfg))
        return events

    def observation_status_lines(self, state: GameState, game: GameDef, initial_board) -> list[str]:
        """Burning fuse cells, then capacity and endurance for load-limited cells."""
        cfg = self._cfg(game)
        return (
            self._fuse_lines(state, game, cfg)
            + self._strain_lines(state, game, cfg)
            + self._switch_lines(state, game, cfg)
        )

    def _switch_lines(self, state: GameState, game: GameDef, cfg: dict) -> list[str]:
        sw = cfg.get("switches")
        if not sw:
            return []
        board = state.board
        layer_id = cfg.get("layer", "ground")
        target = board.layers.get(sw.get("switchLayer", layer_id))
        plates = board.layers.get(sw.get("plateLayer", layer_id))
        if target is None or plates is None:
            return []
        plate_tags = config_list(sw, "plateTags", ["plate"])
        press_layers = config_list(sw, "pressLayers", [layer_id])
        press_tags = config_list(sw, "pressTags", ["solid"])
        ch = sw.get("channelParam", "channel")
        to_pressed, to_released = self._switch_kinds(sw)
        switch_kinds = set(to_pressed) | set(to_released)
        lines: list[str] = []
        for y in range(board.height):
            for x in range(board.width):
                p = Pos(x, y)
                e = plates.get(p)
                if e is None or not any(game.has_tag(e.kind, t) for t in plate_tags):
                    continue
                down = False
                for pl in press_layers:
                    occ = board.layers.get(pl)
                    o = occ.get(p) if occ is not None else None
                    if o is not None and any(game.has_tag(o.kind, t) for t in press_tags):
                        down = True
                name = game.observation_name(e.kind)
                state_word = "pressed" if down else "empty"
                lines.append(f"({x},{y}): {name} {e.params.get(ch)}, {state_word}")
        for y in range(board.height):
            for x in range(board.width):
                p = Pos(x, y)
                e = target.get(p)
                if e is None or e.kind not in switch_kinds:
                    continue
                name = game.observation_name(e.kind)
                lines.append(f"({x},{y}): {name}, channel {e.params.get(ch)}")
        if not lines:
            return []
        return [
            "Switches (a plate is pressed while a solid piece rests in its "
            "cell; while any plate of a channel is pressed, that channel's "
            "switched cells take their pressed form):"
        ] + lines

    def _fuse_lines(self, state: GameState, game: GameDef, cfg: dict) -> list[str]:
        fuse = cfg.get("fuse")
        if not fuse:
            return []
        layer = state.board.layers.get(cfg.get("layer", "ground"))
        if layer is None:
            return []
        lit_kinds = {str(v) for v in (fuse.get("ignite") or {}).values()}
        delay_param = fuse.get("delayParam", "delay")
        lines: list[str] = []
        for y in range(state.board.height):
            for x in range(state.board.width):
                e = layer.get(Pos(x, y))
                if e is None or e.kind not in lit_kinds:
                    continue
                delay = e.params.get(delay_param)
                turns = (delay if isinstance(delay, int) and delay > 0 else 0) + 1
                name = game.observation_name(e.kind)
                plural = "" if turns == 1 else "s"
                lines.append(f"({x},{y}): {name} burns away in {turns} turn{plural}")
        if not lines:
            return []
        return [
            "Burning fuses (in 1 turn = at the end of your next turn; as a "
            "cell burns away it lights the fuse cells touching it, which burn "
            "away one turn later):"
        ] + lines

    def _strain_lines(self, state: GameState, game: GameDef, cfg: dict) -> list[str]:
        strain = cfg.get("strain")
        if not strain:
            return []
        layer = state.board.layers.get(cfg.get("layer", "ground"))
        if layer is None:
            return []
        tags = config_list(strain, "tags", ["load_limited"])
        cap_param = strain.get("capacityParam", "capacity")
        end_param = strain.get("enduranceParam", "endurance")
        default_endurance = int(strain.get("endurance", 0))
        lines: list[str] = []
        for y in range(state.board.height):
            for x in range(state.board.width):
                e = layer.get(Pos(x, y))
                if e is None or not any(game.has_tag(e.kind, t) for t in tags):
                    continue
                cap = e.params.get(cap_param)
                if not isinstance(cap, int):
                    continue
                left = e.params.get(end_param)
                left = left if isinstance(left, int) else default_endurance
                name = game.observation_name(e.kind)
                lines.append(f"({x},{y}): {name} capacity {cap}, endurance {left}")
        if not lines:
            return []
        return [
            "Load limits (a cell's load is every structure cell that would fall "
            "without it; each turn it is over capacity it loses 1 endurance, "
            "and at 0 it fails):"
        ] + lines

    def _loads(
        self, state: GameState, game: GameDef, cfg: dict, tags: list[str]
    ) -> dict[Pos, int]:
        """Load on every cell carrying one of `tags`, keyed by position."""
        layer = state.board.layers.get(cfg.get("layer", "ground"))
        board = state.board
        limited = [
            Pos(x, y)
            for y in range(board.height)
            for x in range(board.width)
            if (e := layer.get(Pos(x, y))) is not None
            and any(game.has_tag(e.kind, t) for t in tags)
        ]
        if not limited:
            return {}
        held = self._supported(state, game, cfg)
        loads: dict[Pos, int] = {}
        for p in limited:
            without = self._supported(state, game, cfg, removed=p)
            loads[p] = sum(
                1 for c in held if c != p and c not in without and self._is_member(layer.get(c), game, cfg)
            )
        return loads

    def _avatar_fell(self, state: GameState, cfg: dict) -> list[dict]:
        var = cfg.get("avatarFellVariable")
        if not var:
            return []
        old = state.variables.get(var, 0) or 0
        state.variables[var] = old + 1
        return [ev.variable_changed(var, old, state.variables[var])]

    # ── the algorithm ───────────────────────────────────────────────────────
    @staticmethod
    def _is_member(entity: Optional[Entity], game: GameDef, cfg: dict) -> bool:
        member_tags = config_list(cfg, "memberTags", ["supported"])
        return entity is not None and any(game.has_tag(entity.kind, t) for t in member_tags)

    def _supported(
        self, state: GameState, game: GameDef, cfg: dict, removed: Optional[Pos] = None
    ) -> set[Pos]:
        """Every root, and every member cell connected to one.

        `removed` is treated as empty, which is how a cell's load is measured.
        """
        layer = state.board.layers.get(cfg.get("layer", "ground"))
        board = state.board
        root_tags = config_list(cfg, "rootTags", ["support_root"])
        deltas = _DIAGONALS if cfg.get("connectivity") == "diagonal" else _CARDINALS

        def is_root(pos: Pos) -> bool:
            e = layer.get(pos)
            return e is not None and any(game.has_tag(e.kind, t) for t in root_tags)

        supported: set[Pos] = set()
        queue: deque[Pos] = deque()
        for y in range(board.height):
            for x in range(board.width):
                p = Pos(x, y)
                if p != removed and is_root(p):
                    supported.add(p)
                    queue.append(p)
        while queue:
            cur = queue.popleft()
            for d in deltas:
                nb = Pos(cur.x + d.x, cur.y + d.y)
                if nb in supported or nb == removed or not board.is_in_bounds(nb):
                    continue
                if self._is_member(layer.get(nb), game, cfg):
                    supported.add(nb)
                    queue.append(nb)
        return supported

    def _switch(self, state: GameState, game: GameDef, cfg: dict) -> list[dict]:
        """Point every switched cell the way its channel's plates say.

        A plate is pressed while a cell carrying one of `pressTags` sits on its
        position. While any plate of a channel is pressed, every cell of that
        channel whose kind is a key of `pressed` takes the mapped kind; while
        none is, mapped kinds revert. Channels are matched by `channelParam`.
        """
        sw = cfg.get("switches")
        if not sw:
            return []
        board = state.board
        layer_id = cfg.get("layer", "ground")
        target = board.layers.get(sw.get("switchLayer", layer_id))
        plates = board.layers.get(sw.get("plateLayer", layer_id))
        if target is None or plates is None:
            return []
        plate_tags = config_list(sw, "plateTags", ["plate"])
        press_layers = config_list(sw, "pressLayers", [layer_id])
        press_tags = config_list(sw, "pressTags", ["solid"])
        ch = sw.get("channelParam", "channel")
        to_pressed, to_released = self._switch_kinds(sw)

        pressed: set = set()
        for y in range(board.height):
            for x in range(board.width):
                p = Pos(x, y)
                e = plates.get(p)
                if e is None or not any(game.has_tag(e.kind, t) for t in plate_tags):
                    continue
                for pl in press_layers:
                    occ = board.layers.get(pl)
                    o = occ.get(p) if occ is not None else None
                    if o is not None and any(game.has_tag(o.kind, t) for t in press_tags):
                        pressed.add(e.params.get(ch))
                        break

        events: list[dict] = []
        tid = sw.get("switchLayer", layer_id)
        for y in range(board.height):
            for x in range(board.width):
                p = Pos(x, y)
                e = target.get(p)
                if e is None:
                    continue
                on = e.params.get(ch) in pressed
                new = None
                if on and e.kind in to_pressed:
                    new = to_pressed[e.kind]
                elif not on and e.kind in to_released:
                    new = to_released[e.kind]
                if new is None or new == e.kind:
                    continue
                target.set(p, Entity(new, dict(e.params)))
                events.append(ev.cell_transformed(p, e.kind, new, tid))
        return events

    def _collapse(self, state: GameState, game: GameDef, cfg: dict) -> list[dict]:
        """Drop everything unsupported; repeat while switches change what holds.

        A switch may turn a support root (or member) into a kind that is not one,
        e.g. a clamp that lets go when its plate is pressed. When a pass switches
        such a cell, the structure it held falls in a further pass of the same
        collapse, so cascades resolve within one turn: pass by pass, and within
        a pass the piece whose lowest cell is lowest lands first.
        """
        events: list[dict] = []
        board = state.board
        for _ in range(board.width * board.height + 1):
            step = self._collapse_pass(state, game, cfg)
            events.extend(step)
            if not any(
                e.get("type") == "cell_transformed"
                and self._holds(e.get("fromKind"), game, cfg) != self._holds(e.get("toKind"), game, cfg)
                for e in step
            ):
                break
        return events

    @staticmethod
    def _holds(kind: Optional[str], game: GameDef, cfg: dict) -> tuple[bool, bool]:
        """(is a support root, is a member) for a kind name."""
        if kind is None:
            return (False, False)
        roots = config_list(cfg, "rootTags", ["support_root"])
        members = config_list(cfg, "memberTags", ["supported"])
        return (any(game.has_tag(kind, t) for t in roots), any(game.has_tag(kind, t) for t in members))

    def _collapse_pass(self, state: GameState, game: GameDef, cfg: dict) -> list[dict]:
        layer_id = cfg.get("layer", "ground")
        layer = state.board.layers.get(layer_id)
        if layer is None:
            return []
        board = state.board
        deltas = _DIAGONALS if cfg.get("connectivity") == "diagonal" else _CARDINALS

        def is_member(pos: Pos) -> bool:
            return self._is_member(layer.get(pos), game, cfg)

        # 0. Removals may have emptied a plate: switches update first.
        switched = self._switch(state, game, cfg)

        # 1. BFS the supported set outward from every root.
        supported = self._supported(state, game, cfg)

        # 2. Group the unsupported members into maximal connected components.
        remaining = {
            Pos(x, y)
            for y in range(board.height)
            for x in range(board.width)
            if is_member(Pos(x, y)) and Pos(x, y) not in supported
        }
        if not remaining:
            return switched

        components: list[list[Pos]] = []
        while remaining:
            seed = next(iter(remaining))
            remaining.discard(seed)
            comp = [seed]
            q: deque[Pos] = deque([seed])
            while q:
                cur = q.popleft()
                for d in deltas:
                    nb = Pos(cur.x + d.x, cur.y + d.y)
                    if nb in remaining:
                        remaining.discard(nb)
                        comp.append(nb)
                        q.append(nb)
            components.append(comp)

        # 3. Lift every orphan cell off the board first, so a component is never
        #    blocked by the hole it is falling out of, nor by another orphan
        #    that is falling alongside it.
        kinds: list[dict[Pos, Entity]] = []
        for comp in components:
            kinds.append({p: layer.get(p) for p in comp})
            for p in comp:
                layer.set(p, self._empty(game, layer_id))

        dx, dy = dir_delta(cfg.get("direction", "down"))
        step = Pos(dx, dy)
        rest_layers = config_list(cfg, "restLayers", [layer_id])
        rest_tags = config_list(cfg, "restTags", ["solid"])
        settle = {k: str(v) for k, v in cfg.get("settleTransform", {}).items()}
        deflect = {str(k): str(v) for k, v in (cfg.get("deflect") or {}).items()}

        def obstacles(cells: list[Pos], d: Pos) -> list[str]:
            """Kinds blocking a step by `d`. An empty list means the step is free."""
            out: list[str] = []
            for c in cells:
                nxt = Pos(c.x + d.x, c.y + d.y)
                if not board.is_in_bounds(nxt):
                    continue  # leaving the board never blocks
                for rl in rest_layers:
                    rlayer = board.layers.get(rl)
                    if rlayer is None:
                        continue
                    e = rlayer.get(nxt)
                    if e is not None and any(
                        game.has_tag(e.kind, t) for t in rest_tags
                    ):
                        out.append(e.kind)
            return out

        def deflection(blocking: list[str]) -> Optional[Pos]:
            """The one agreed slide direction, or None if the component rests.

            A flat blocker holds the whole component, and ramps pulling opposite
            ways cancel — both cases fall back to resting, so the result never
            depends on which cell of the component is inspected first.
            """
            if not deflect:
                return None
            directions = set()
            for kind in blocking:
                match = None
                for tag, direction in deflect.items():
                    if game.has_tag(kind, tag):
                        match = direction
                        break
                if match is None:
                    return None
                directions.add(match)
            if len(directions) != 1:
                return None
            sdx, sdy = dir_delta(directions.pop())
            return Pos(sdx, sdy)

        # 4. Resolve components one at a time, the one furthest along the fall
        #    direction first, writing each back to the board as it lands. Every
        #    component that could block another has therefore already come to
        #    rest by the time the other is resolved. Sorting is what makes this
        #    deterministic; stepping them in lockstep is not, because a lifted
        #    component is invisible to the others and they pass through it.
        def fall_order(idx: int) -> tuple:
            cells = components[idx]
            reach = max(c.x * step.x + c.y * step.y for c in cells)
            return (-reach, min(c.x for c in cells), min(c.y for c in cells))

        events: list[dict] = list(switched)
        avatar_pos = state.avatar.position if state.avatar.enabled else None
        avatar_component: Optional[int] = None
        avatar_destination: Optional[Pos] = None
        max_steps = 2 * (board.width + board.height) + 1

        for idx in sorted(range(len(components)), key=fall_order):
            cells = list(components[idx])
            slid_at: Optional[int] = None
            for _ in range(max_steps):
                if not any(board.is_in_bounds(c) for c in cells):
                    break
                blocking = obstacles(cells, step)
                if not blocking:
                    cells = [Pos(c.x + step.x, c.y + step.y) for c in cells]
                    continue
                slide = deflection(blocking)
                if slide is None:
                    break
                # A component may slide at most once per lane, or two facing
                # ramps would trade it back and forth forever. It must travel
                # one cell along the fall direction to earn another slide.
                lane = min(c.y for c in cells) if step.y else min(c.x for c in cells)
                if slid_at == lane or obstacles(cells, slide):
                    break
                if any(
                    not board.is_in_bounds(Pos(c.x + slide.x, c.y + slide.y))
                    for c in cells
                ):
                    break  # sideways motion never leaves the board
                cells = [Pos(c.x + slide.x, c.y + slide.y) for c in cells]
                slid_at = lane

            for src, dst in zip(components[idx], cells):
                if avatar_pos is not None and src == avatar_pos:
                    avatar_component = idx
                    avatar_destination = dst
                if not board.is_in_bounds(dst):
                    continue  # this cell left the world
                entity = kinds[idx][src]
                new_kind = settle.get(entity.kind, entity.kind)
                layer.set(dst, Entity(new_kind, dict(entity.params)))
                events.append(
                    ev.object_settled(
                        new_kind, dst, src, layer_id, from_kind=entity.kind
                    )
                )
            # A landed piece may press a plate before the next piece moves.
            events.extend(self._switch(state, game, cfg))

        # 6. The avatar rides its component down.
        if avatar_component is not None and cfg.get("carryAvatar", True):
            if avatar_destination is not None and board.is_in_bounds(
                avatar_destination
            ):
                state.avatar.position = avatar_destination
            var = cfg.get("avatarFellVariable")
            if var:
                old = state.variables.get(var, 0) or 0
                state.variables[var] = old + 1
                events.append(ev.variable_changed(var, old, state.variables[var]))

        return events
