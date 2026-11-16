"""Optional numeric goals and support checks; helper, not a registered system."""


def unsupported_tiles(occupied, floor_y):
    """Every piece needs a path of downward contacts to the bottom floor.

    A contact supports the whole rigid piece, so overhangs are allowed. Cycles
    without a floor connection cannot support each other.
    """
    grounded = {key for (x, y), key in occupied.items() if y == floor_y}
    while True:
        supported = grounded | {key for (x, y), key in occupied.items()
                                if occupied.get((x, y+1)) in grounded}
        if supported == grounded:
            return sorted(set(occupied.values()) - grounded)
        grounded = supported


def row_sums(config, occupied):
    values = {p['id']: p.get('value', 0) for p in config['pieces']}
    totals = [0] * config['size'][1]
    for (x, y), key in occupied.items():
        totals[y] += values[key]
    return totals


def column_sums(config, occupied):
    values = {p['id']: p.get('value', 0) for p in config['pieces']}
    totals = [0] * config['size'][0]
    for (x, y), key in occupied.items():
        totals[x] += values[key]
    return totals
