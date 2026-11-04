"""Synchronous orthogonal pulse networks with once-per-turn cell processing."""
from ._base import GameSystem
from .._models import Pos, Entity
from .. import _events as ev


class PulseNetworkSystem(GameSystem):
    def __init__(self, sys_id):
        super().__init__(sys_id, "pulse_network")

    def execute_cascade_resolution(self, trigger_events, state, game):
        config = game.system_config(self.id)
        events = []
        for event in trigger_events:
            if (event.get("type") == "cell_transformed"
                    and event.get("layer") == config["controlsLayer"]
                    and event.get("toKind") == config["pressedKind"]):
                pos = event["position"]
                pos = pos if isinstance(pos, Pos) else Pos.from_json(pos)
                entity = state.board.get_entity(config["controlsLayer"], pos)
                if entity and entity.kind == config["pressedKind"]:
                    events.extend(self._pulse(pos, state, config, trigger_events))
        return events

    def _pulse(self, source, state, c, trigger_events=()):
        if not isinstance(source, Pos):
            source = Pos.from_json(source)
        board, events = state.board, []
        light_layer, object_layer = c["lightsLayer"], c["objectsLayer"]
        signal_layer, controls = c["signalsLayer"], c["controlsLayer"]
        off, on, relay = c["offKind"], c["onKind"], c["relayKind"]
        delays, writes, fuses = c.get("delayKinds") or {}, c.get("writeKinds") or {}, c.get("fuseKinds") or {}

        def kind(layer, p):
            entity = board.get_entity(layer, p)
            return entity.kind if entity else None

        def change(layer, p, target):
            entity = board.get_entity(layer, p)
            if entity is None:
                return
            board.set_entity(layer, p, Entity(target, dict(entity.params)))
            events.append(ev.cell_transformed(p, entity.kind, target, layer))

        def trace(name, wave=1):
            if c.get("trace") is True:
                events.append(ev.pulse_trace(name, wave))

        def number(p):
            return p.y * board.width + p.x

        lights = {Pos(x, y) for y in range(board.height) for x in range(board.width)
                  if kind(light_layer, Pos(x, y)) in (off, on)}

        def neighbours(p):
            return [(q, bit) for q, bit in [
                (Pos(p.x-1, p.y), 4), (Pos(p.x+1, p.y), 1),
                (Pos(p.x, p.y-1), 8), (Pos(p.x, p.y+1), 2)] if q in lights]

        def emit(p, buffer):
            for q, bit in neighbours(p):
                buffer[q] = buffer.get(q, 0) | bit

        def flip(p):
            was_on = kind(light_layer, p) == on
            change(light_layer, p, c["fallingKind"] if was_on else c["risingKind"])
            change(light_layer, p, off if was_on else on)

        positions = [Pos(x, y) for y in range(board.height) for x in range(board.width)]
        loaded = [(p, empty) for p in positions for empty, full in delays.items()
                  if kind(object_layer, p) == full]
        source_kind = kind(object_layer, source)
        for p in sorted(lights, key=number):
            change(signal_layer, p, c["idleKind"])
        change(controls, source, c["readyKind"])
        queued = c.get("queuedVariable")
        if queued:
            old = state.variables.get(queued)
            state.variables[queued] = 0
            events.append(ev.variable_changed(queued, old, 0))
        incoming = {}
        routed = set()
        if c.get("activateMovedRelays") is True:
            def position(raw):
                return raw if isinstance(raw, Pos) else Pos.from_json(raw)
            moves = [e for e in trigger_events if e.get("type") == "tile_moved"
                     and e.get("layer") == light_layer]
            before = {position(e["fromPosition"]): e["kind"] for e in moves}
            for event in moves:
                p = position(event["position"])
                if before.get(p) == event["kind"]:
                    continue
                # Protect the moved result, just like a directly written light.
                routed.add(p)
                if before.get(p) == off and event["kind"] == on and kind(object_layer, p) == relay:
                    emit(p, incoming)
                    trace(f"seed_{number(p)}")
        for p, _ in loaded:
            emit(p, incoming)
            trace(f"delay_{number(p)}")
        direct = [q for q, _ in neighbours(source)]
        if source_kind in (c.get("flipKinds") or []):
            direct = ([source] if source in lights else []) + direct
        elif source_kind not in writes:
            direct = []
        for p in direct:
            old = kind(light_layer, p)
            target = writes.get(source_kind, on if old == off else off)
            if kind(object_layer, p) == relay and old == off and target == on:
                emit(p, incoming)
                trace(f"seed_{number(p)}")
                change(object_layer, p, relay)
        if source_kind in delays:
            change(object_layer, source, delays[source_kind])
            if queued:
                state.variables[queued] = 1
                events.append(ev.variable_changed(queued, 0, 1))
        seen = set(direct) | routed
        for p in direct:
            change(signal_layer, p, c["hitKind"])
            if source_kind in writes:
                target = writes[source_kind]
                trace(f"write_{number(source)}_{number(p)}_{'ON' if target == on else 'OFF'}")
                change(light_layer, p, target)
            else:
                trace(f"direct_{number(source)}_{number(p)}")
                flip(p)
        if source_kind in fuses:
            change(object_layer, source, fuses[source_kind])
            old = kind(controls, source)
            board.set_entity(controls, source, None)
            events.extend([ev.object_removed(source, old), ev.cell_cleared(source, old)])
        for p, empty in loaded:
            change(object_layer, p, empty)
        wave = 1
        while incoming:
            output = {}
            for p, mask in sorted(incoming.items(), key=lambda item: number(item[0])):
                if p in seen:
                    trace(f"ignored_{number(p)}_{mask}", wave)
                    continue
                seen.add(p)
                collisions = c.get("collisions") is not False
                cancel = collisions and ((mask & 5) == 5 or (mask & 10) == 10)
                burst = collisions and c.get("bursts") is not False and not cancel and bool(mask & 5) and bool(mask & 10)
                forwarding = (not cancel and kind(object_layer, p) == relay
                              and kind(light_layer, p) == off)
                if burst or forwarding:
                    emit(p, output)
                if forwarding:
                    trace(f"relay_{number(p)}", wave)
                    change(object_layer, p, relay)
                if burst:
                    trace(f"burst_{number(p)}", wave)
                outcome = "cancel" if cancel else "burst" if burst else "normal"
                trace(f"arrival_{number(p)}_{mask}_{outcome}", wave)
                change(signal_layer, p, c["cancelledKind"] if cancel else c["burstKind"] if burst else c["hitKind"])
                if not cancel:
                    flip(p)
            incoming = output
            wave += 1
            if wave > len(lights) + 2:
                raise RuntimeError("pulse_network exceeded its once-per-cell wave bound")
        return events
