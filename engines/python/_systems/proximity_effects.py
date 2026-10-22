"""Apply configured effects when an avatar enters a cell beside an entity.

The arrival event is the only trigger. Standing beside an entity at level load,
leaving its neighbourhood, and blocked moves do not apply an effect.
"""
from __future__ import annotations

from .._game_def import GameDef
from .._models import Entity, GameState, Pos
from ._base import GameSystem


class ProximityEffectsSystem(GameSystem):
    def __init__(self, sys_id: str, config: dict):
        super().__init__(sys_id, "proximity_effects")
        self.config = config

    def execute_cascade_resolution(
        self, trigger_events: list[dict], state: GameState, game: GameDef
    ) -> list[dict]:
        layer = self.config.get("layer", "objects")
        reactions = self.config.get("reactions", [])
        events: list[dict] = []
        for arrival in trigger_events:
            if arrival.get("type") != "avatar_entered":
                continue
            raw = arrival.get("position")
            dest = raw if isinstance(raw, Pos) else Pos.from_json(raw)
            for neighbor in (
                Pos(dest.x, dest.y - 1), Pos(dest.x + 1, dest.y),
                Pos(dest.x, dest.y + 1), Pos(dest.x - 1, dest.y),
            ):
                if not state.board.is_in_bounds(neighbor):
                    continue
                entity = state.board.get_entity(layer, neighbor)
                if entity is None:
                    continue
                for reaction in reactions:
                    tag = reaction.get("tag")
                    if not isinstance(tag, str) or not game.has_tag(entity.kind, tag):
                        continue
                    effect = reaction.get("effect")
                    value: int | None = None
                    delta: int | None = None
                    if effect in ("cycle", "threshold"):
                        param = reaction.get("param", "count")
                        old = entity.params.get(param, 0)
                        if type(old) is not int or old < 0:
                            raise ValueError(f"Invalid {param} on {entity.kind} at {neighbor}")
                        value = old + 1
                        if effect == "cycle":
                            modulus = reaction.get("modulus", 3)
                            if type(modulus) is not int or modulus < 2:
                                raise ValueError("proximity_effects modulus must be >= 2")
                            value %= modulus
                        else:
                            threshold_param = reaction.get("thresholdParam", "threshold")
                            threshold = entity.params.get(threshold_param)
                            if type(threshold) is not int or threshold < 1:
                                raise ValueError(f"Invalid {threshold_param} on {entity.kind} at {neighbor}")
                            if value >= threshold:
                                flag = reaction.get("triggerVariable")
                                if isinstance(flag, str):
                                    state.variables[flag] = 1
                        params = dict(entity.params)
                        params[param] = value
                        state.board.set_entity(layer, neighbor, Entity(entity.kind, params))
                        entity = state.board.get_entity(layer, neighbor)
                    elif effect == "damage":
                        variable = reaction.get("variable")
                        amount = reaction.get("amount", 1)
                        current = state.variables.get(variable)
                        if not isinstance(variable, str) or type(current) is not int:
                            raise ValueError("proximity_effects damage needs an integer variable")
                        if type(amount) is not int or amount < 1:
                            raise ValueError("proximity_effects damage amount must be positive")
                        value = current - amount
                        delta = -amount
                        state.variables[variable] = value
                        if value <= 0:
                            flag = reaction.get("triggerVariable")
                            if isinstance(flag, str):
                                state.variables[flag] = 1
                    else:
                        raise ValueError(f"Unsupported proximity effect: {effect}")
                    events.append({
                        "type": "proximity_triggered",
                        "position": neighbor,
                        "avatarPosition": dest,
                        "kind": entity.kind,
                        "effect": effect,
                        "value": value,
                        "delta": delta,
                    })
        return events
