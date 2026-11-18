"""Synchronous finite-state networks with explicitly sampled public outputs.

Configuration and the namespaced runtime map are trusted engine data. Only the
public projection is suitable for players; never serialize full state to agents.
"""
from .._models import Entity, Pos
from ._base import GameSystem


class StateNetworkSystem(GameSystem):
    def __init__(self, sys_id, config):
        super().__init__(sys_id, "state_network")
        self.config = config
        self._validate()

    def _validate(self):
        c = self.config
        nodes = c.get("nodes", [])
        ids = [n["id"] for n in nodes]
        inputs = c.get("inputs", [])
        if len(set(ids + inputs)) != len(ids + inputs):
            raise ValueError("state_network: duplicate identifiers")
        known = set(ids + inputs)
        arities = {"copy": 1, "toggle": 1, "not": 1, "and": 2, "or": 2, "xor": 2, "counter2": 1, "counter3": 1, "latch": 2}
        for n in nodes:
            if n.get("op") not in arities or len(n.get("inputs", [])) != arities[n["op"]]:
                raise ValueError("state_network: invalid operation/arity")
            if any(s not in known for s in n["inputs"]) or n.get("initial", 0) not in (0, 1):
                raise ValueError("state_network: invalid source/initial value")
        if not isinstance(c.get("energy"), int) or isinstance(c["energy"], bool) or c["energy"] < 1:
            raise ValueError("state_network: positive energy required")
        if any(v not in ids for v in c.get("probes", {}).values()):
            raise ValueError("state_network: invalid probe")
        if ("" if c.get("initialProbe") is None else c["initialProbe"]) not in ["", *c.get("probes", {})]:
            raise ValueError("state_network: invalid initial probe")
        if any(k not in ids or v not in (0, 1) for k, v in c.get("safe", {}).items()):
            raise ValueError("state_network: invalid safe condition")
        for t in c.get("tasks", {}).values():
            if any(task not in c.get("tasks", {}) for task in t.get("after", [])):
                raise ValueError("state_network: invalid transaction prerequisite")
            if any(k not in ids or v not in (0, 1) for k, v in t.get("requires", {}).items()):
                raise ValueError("state_network: invalid transaction condition")
            if any(p not in c.get("probes", {}) for p in t.get("closes", [])):
                raise ValueError("state_network: invalid closure")
        for a in c.get("controls", {}).values():
            kind = a.get("type")
            if kind not in ("pulse", "probe", "clamp", "commit"):
                raise ValueError("state_network: invalid control")
            if kind == "pulse" and (set(a.get("inputs", {})) != set(inputs) or any(v not in (0, 1) for v in a["inputs"].values())):
                raise ValueError("state_network: pulse must set every input")
            if kind == "probe" and a.get("target") not in c.get("probes", {}):
                raise ValueError("state_network: invalid probe control")
            if kind == "clamp" and a.get("target", "") not in ["", *ids]:
                raise ValueError("state_network: invalid clamp control")
            if kind == "commit" and a.get("target") not in c.get("tasks", {}):
                raise ValueError("state_network: invalid transaction control")

    @property
    def key(self):
        return "__network_" + self.id

    def _initial_runtime(self):
        c = self.config
        return {
            "values": {n["id"]: n.get("initial", 0) for n in c["nodes"]},
            "inputs": {s: 0 for s in c.get("inputs", [])},
            **({"counters": {n["id"]: 0 for n in c["nodes"] if n["op"].startswith("counter")}}
               if any(n["op"].startswith("counter") for n in c["nodes"]) else {}),
            "energy": c["energy"], "probe": "" if c.get("initialProbe") is None else c["initialProbe"],
            "clamp": "", "reading": -1, "sample": "none", "done": [],
            "closed": [], "journal": [], "complete": 0, "failed": 0,
        }

    def runtime(self, state):
        if self.key not in state.variables:
            state.variables[self.key] = self._initial_runtime()
        return state.variables[self.key]

    def outputs(self, r):
        return {k: (0 if k == r["clamp"] else v) for k, v in r["values"].items()}

    def public_view(self, state):
        """Every public field by name, independent of which ones `readouts`
        copies into variables. Reads state without modifying it."""
        c = self.config
        r = state.variables[self.key] if self.key in state.variables else self._initial_runtime()
        public = {k: r[k] for k in ("energy", "probe", "clamp", "reading", "sample", "complete", "failed")}
        public["journal"] = " | ".join(r["journal"]) or "No powered readings yet"
        for inp in c.get("inputs", []):
            public["input_" + inp] = r.get("inputs", {}).get(inp, 0)
        for task in c.get("tasks", {}):
            public["done_" + task] = int(task in r["done"])
        for probe in c.get("probes", {}):
            public["open_" + probe] = int(probe not in r["closed"])
        return public

    def project(self, state):
        c = self.config
        self.runtime(state)
        public = self.public_view(state)
        for field, variable in c.get("readouts", {}).items():
            if field not in public or variable.startswith("__network_"):
                raise ValueError("state_network: invalid public readout")
            state.variables[variable] = public[field]
        for item in c.get("indicators", []):
            value = public[item["field"]]
            kind = item["kinds"].get(str(value))
            if kind is not None:
                state.board.layers[item["layer"]].set(Pos.from_json(item["position"]), Entity(kind))

    def execute_load_settle(self, state, game):
        self.project(state)
        return []

    def execute_action_resolution(self, action, state, game):
        c, r = self.config, self.runtime(state)
        control = c.get("controls", {}).get(action["actionId"])
        if control is None:
            return []
        kind, target = control["type"], control.get("target", "")
        # Rejections depend exclusively on public state. Never use an internal
        # condition as a veto: action enumeration probes vetoes for free.
        if (kind == "probe" and target in r["closed"]) or (kind == "commit" and (target in r["done"] or any(t not in r["done"] for t in c["tasks"][target].get("after", [])))):
            return [{"type": "action_vetoed", "reason": "unavailable"}]
        if kind == "probe":
            r["probe"] = target
        elif kind == "clamp":
            r["clamp"] = target
        else:
            if r["energy"] <= 0:
                return [{"type": "action_vetoed", "reason": "unavailable"}]
            r["energy"] -= 1
            if kind == "pulse":
                r["inputs"] = {s: control["inputs"][s] for s in c["inputs"]}
                signals = {**self.outputs(r), **control["inputs"]}
                new = {}
                for n in c["nodes"]:
                    args = [signals[s] for s in n["inputs"]]
                    op, old = n["op"], r["values"][n["id"]]
                    if op.startswith("counter"):
                        period = int(op[-1])
                        count = (r["counters"][n["id"]] + args[0]) % period
                        r["counters"][n["id"]] = count
                        value = int(bool(args[0]) and count == 0)
                    elif op == "latch": value = 0 if args[1] else (1 if args[0] else old)
                    elif op == "copy": value = args[0]
                    elif op == "toggle": value = old ^ args[0]
                    elif op == "not": value = 1 - args[0]
                    elif op == "and": value = args[0] & args[1]
                    elif op == "or": value = args[0] | args[1]
                    else: value = args[0] ^ args[1]
                    new[n["id"]] = value
                r["values"] = new
                probe = r["probe"]
                r["sample"] = probe or "none"
                r["reading"] = self.outputs(r)[c["probes"][probe]] if probe and probe not in r["closed"] else -1
                bits = "".join(str(control["inputs"][s]) for s in c["inputs"])
                r["journal"].append(f"{bits} [{r['clamp'] or '-'}] {r['sample']}={r['reading']}")
            else:
                t = c["tasks"][target]
                out = self.outputs(r)
                if all(out[k] == v for k, v in t.get("requires", {}).items()):
                    r["done"].append(target)
                    r["closed"] = sorted(set(r["closed"] + t.get("closes", [])))
                    r["journal"].append(target + " accepted")
                else:
                    r["failed"] = 1
                    r["journal"].append(target + " failed")
        # Safe completion concerns actual memory, not a temporarily forced output.
        r["complete"] = int(not r["failed"] and len(r["done"]) == len(c.get("tasks", {}))
                            and all(r["values"][k] == v for k, v in c.get("safe", {}).items())
                            and (c.get("parkCounters") is not True or not any(r.get("counters", {}).values())))
        if r["energy"] == 0 and not r["complete"]:
            r["failed"] = 1
        self.project(state)
        return [{"type": "network_updated"}]
