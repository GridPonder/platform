"""Direct movement for rigid multi-cell objects."""
from __future__ import annotations

from .. import _events as ev
from .._game_def import GameDef
from .._models import GameState, Pos, dir_delta, transform_delta
from ._base import GameSystem, config_list


class SlidingBlocksSystem(GameSystem):
    def __init__(self, sys_id: str, config: dict | None = None):
        super().__init__(sys_id, "sliding_blocks")
        self._config = config

    def observation_object_lines(self, mco, state: GameState, game: GameDef) -> list[str]:
        """Expose movement constraints using neutral group labels."""
        axis = mco.params.get("axis")
        lines = [f"axis: {axis}"] if isinstance(axis, str) and axis else []
        group = _movement_group(mco)
        if group is not None:
            groups = list(dict.fromkeys(
                _movement_group(item) for item in state.board.multi_cell_objects
                if _movement_group(item) is not None
            ))
            lines.append(f"movement group: {groups.index(group) + 1}")
            lines.append(f"movement transform: {_movement_transform(mco)}")
        return lines

    def execute_action_resolution(
        self,
        action: dict,
        state: GameState,
        game: GameDef,
    ) -> list[dict]:
        config = self._config if self._config is not None else game.system_config(self.id)
        if action.get("actionId") != config.get("moveAction", "move"):
            return []

        params = action.get("params", {})
        direction = params.get("direction")
        start = _parse_pos(params.get("position"))
        if direction is None or start is None:
            return [ev.action_vetoed()]

        block = _block_at(state, start)
        if block is None:
            return [ev.action_vetoed()]
        if direction not in {"up", "down", "left", "right"}:
            return [ev.action_vetoed()]

        group = _movement_group(block)
        members = [item for item in state.board.multi_cell_objects
                   if item.id == block.id or
                   (group is not None and _movement_group(item) == group)]
        # All supported transforms are self-inverse. Convert from the selected
        # member's direction to the shared frame, then to each member's frame.
        shared_delta = transform_delta(dir_delta(direction), _movement_transform(block))
        plans = []
        member_ids = {item.id for item in members}
        destinations = set()
        edges = set()
        for member in members:
            delta = transform_delta(shared_delta, _movement_transform(member))
            member_direction = next(d for d in ("up", "down", "left", "right")
                                    if dir_delta(d) == delta)
            if not _axis_allows(member.params.get("axis", "both"), member_direction):
                return [ev.action_vetoed()]
            old_cells = list(member.cells)
            old_cell_set = set(old_cells)
            new_cells = [Pos(p.x + delta[0], p.y + delta[1]) for p in old_cells]
            exiting = any(not state.board.is_in_bounds(p) for p in new_cells)
            if exiting and not _can_escape(
                member, old_cells, member_direction, state, game, config
            ):
                return [ev.action_vetoed()]
            for pos in new_cells:
                if not state.board.is_in_bounds(pos):
                    continue
                if pos in destinations or not _is_valid_destination(
                    pos, member, old_cell_set, state, game, config, member_ids
                ):
                    return [ev.action_vetoed()]
                destinations.add(pos)
            # Vacated cells may be reused, but pieces cannot pass through each
            # other by exchanging cells in opposite directions.
            for old, new in zip(old_cells, new_cells):
                if (new, old) in edges:
                    return [ev.action_vetoed()]
                edges.add((old, new))
            plans.append((member, old_cells, new_cells, member_direction, exiting))

        # Commit only after every member has passed validation. Rules and
        # observers see the complete simultaneous result through normal events.
        events = []
        for member, old_cells, new_cells, member_direction, exiting in plans:
            if exiting:
                state.board.multi_cell_objects.remove(member)
                variable = str(config.get("escapedVariable", "escapedCount"))
                old_value = state.variables.get(variable, 0)
                state.variables[variable] = old_value + 1
                events.extend([
                    {"type": "multi_cell_object_exited", "id": member.id,
                     "kind": member.kind, "direction": member_direction},
                    ev.variable_changed(variable, old_value, old_value + 1),
                ])
            else:
                member.cells = new_cells
                events.append({
                    "type": "multi_cell_object_moved", "id": member.id,
                    "kind": member.kind, "fromCells": old_cells,
                    "toCells": new_cells, "direction": member_direction,
                })
        return events


def _movement_group(block) -> str | None:
    group = block.params.get("movementGroup")
    return group if isinstance(group, str) and group else None


def _movement_transform(block) -> str:
    transform = block.params.get("movementTransform")
    return transform if transform in ("identity", "invert", "mirror_x", "mirror_y") else "identity"


def _parse_pos(raw) -> Pos | None:
    if isinstance(raw, (list, tuple)) and len(raw) >= 2:
        return Pos(int(raw[0]), int(raw[1]))
    return None


def _block_at(state: GameState, pos: Pos):
    for block in state.board.multi_cell_objects:
        if pos in block.cells:
            return block
    return None


def _axis_allows(axis: str, direction: str) -> bool:
    if axis == "horizontal":
        return direction in {"left", "right"}
    if axis == "vertical":
        return direction in {"up", "down"}
    if axis == "both":
        return direction in {"up", "down", "left", "right"}
    return False


def _is_valid_destination(
    pos: Pos,
    moving_block,
    current_cells: set[Pos],
    state: GameState,
    game: GameDef,
    config: dict,
    moving_ids: set[str],
) -> bool:
    if not state.board.is_in_bounds(pos) or state.board.is_void(pos):
        return False

    ground_layer = str(config.get("groundLayer", "ground"))
    ground = state.board.get_entity(ground_layer, pos)
    valid_ground_tags = [
        str(tag) for tag in config_list(config, "validGroundTags", ["walkable"])
    ]
    if ground is None or not any(
        game.has_tag(ground.kind, tag) for tag in valid_ground_tags
    ):
        return False

    for other in state.board.multi_cell_objects:
        if other.id in moving_ids:
            continue
        if pos in other.cells:
            return False

    blocking_layers = [
        str(layer) for layer in config_list(config, "blockingLayers", ["objects"])
    ]
    blocking_tags = [
        str(tag) for tag in config_list(config, "blockingTags", ["solid"])
    ]
    coverable_tags = [
        str(tag) for tag in config_list(config, "coverableTags", [])
    ]
    coverable_blocked_roles = {
        str(role)
        for role in config_list(config, "coverableBlockedRoles", [])
    }
    moving_role = moving_block.params.get("role")

    for layer_id in blocking_layers:
        entity = state.board.get_entity(layer_id, pos)
        if entity is None:
            continue
        if pos in current_cells:
            continue
        if blocking_tags and not any(
            game.has_tag(entity.kind, tag) for tag in blocking_tags
        ):
            continue
        can_cover = any(
            game.has_tag(entity.kind, tag) for tag in coverable_tags
        ) and (
            moving_role is None
            or str(moving_role) not in coverable_blocked_roles
        )
        if not can_cover:
            return False

    return True


def _can_escape(
    block,
    old_cells: list[Pos],
    direction: str,
    state: GameState,
    game: GameDef,
    config: dict,
) -> bool:
    escape_roles = {
        str(role) for role in config_list(config, "escapeRoles", [])
    }
    role = block.params.get("role")
    if role is None or str(role) not in escape_roles:
        return False

    exit_tags = [str(tag) for tag in config_list(config, "exitTags", ["exit"])]
    if not exit_tags:
        return True

    if direction == "right":
        edge = max(pos.x for pos in old_cells)
        edge_cells = [pos for pos in old_cells if pos.x == edge]
    elif direction == "left":
        edge = min(pos.x for pos in old_cells)
        edge_cells = [pos for pos in old_cells if pos.x == edge]
    elif direction == "down":
        edge = max(pos.y for pos in old_cells)
        edge_cells = [pos for pos in old_cells if pos.y == edge]
    elif direction == "up":
        edge = min(pos.y for pos in old_cells)
        edge_cells = [pos for pos in old_cells if pos.y == edge]
    else:
        return False

    for cell in edge_cells:
        ground_layer = str(config.get("groundLayer", "ground"))
        ground = state.board.get_entity(ground_layer, cell)
        if ground is not None and any(
            game.has_tag(ground.kind, tag) for tag in exit_tags
        ):
            return True
    return False
