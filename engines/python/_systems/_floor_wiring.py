"""Port connectivity for covered wiring tiles. Crossings do not join."""
GROUPS = {'cross': ['NS', 'EW'], 'ne': ['NE', 'SW'], 'nw': ['NW', 'SE'],
          'junction': ['NESW'], 'h': ['EW'], 'v': ['NS']}
DIRECTIONS = {'N': (0,-1,'S'), 'E': (1,0,'W'), 'S': (0,1,'N'), 'W': (-1,0,'E')}


def floor_sources(floor):
    """Map each socket input to all source terminals electrically connected to it."""
    tiles = {(t['x'],t['y']): t['shape'] for t in floor['tiles']}
    terminals = {(t['x'],t['y'],t['side']): t for t in floor['terminals']}
    result = {}
    for t in floor['terminals']:
        if t['kind'] != 'sink': continue
        stack = [(t['x'],t['y'],t['side'])]; seen = set(); sources = set()
        while stack:
            x,y,side = stack.pop()
            if (x,y,side) in seen: continue
            seen.add((x,y,side))
            terminal = terminals.get((x,y,side))
            if terminal and terminal['kind'] == 'source': sources.add(terminal['id'])
            for group in GROUPS[tiles[x,y]]:
                if side not in group: continue
                for port in group:
                    if (x,y,port) not in seen: stack.append((x,y,port))
                    dx,dy,other = DIRECTIONS[port]
                    if (x+dx,y+dy) in tiles: stack.append((x+dx,y+dy,other))
        result[t['id']] = sorted(sources)
    return result
