"""Opt-in rigid tiles, reversible placement effects and staged targets."""
from ._base import GameSystem
from .._models import Pos, Entity
from .. import _events as ev
from ._tile_placement_constraints import unsupported_tiles, row_sums, column_sums


def points(raw):
    return [tuple(p) for p in raw]


def transform(piece, point, rotation):
    def turn(p):
        x, y = p
        for _ in range(rotation):
            x, y = -y, x
        return x, y
    cells = [turn(p) for p in piece['cells']]
    x, y = turn(point)
    return x - min(p[0] for p in cells), y - min(p[1] for p in cells)


def variant_piece(piece, placement):
    variants=piece.get('variants')
    return {**piece,**variants[placement[3] if len(placement)>3 else 0]} if variants else piece


def cells(piece, placement):
    piece=variant_piece(piece,placement)
    x, y, rotation = placement[:3]
    return [(a+x, b+y) for a, b in
            (transform(piece, p, rotation) for p in piece['cells'])]


def edges(piece, placement):
    piece=variant_piece(piece,placement)
    x, y, rotation = placement[:3]
    for edge in piece.get('edges', []):
        a, b = transform(piece, edge['cell'], rotation)
        yield (a+x, b+y, (edge['direction']+rotation) % 4), edge['symbol']


def problem(config, placements, phase, moved, piece_id, placement, steps=0, lifts=0):
    pieces = {p['id']: p for p in config['pieces']}
    if not isinstance(piece_id, str) or piece_id not in pieces:
        return 'Choose a piece.'
    if (not isinstance(placement, list) or len(placement) not in (3,4)
            or any(type(v) is not int for v in placement) or not 0 <= placement[2] < 4):
        return 'Use an integer anchor and a quarter-turn rotation (0–3).'
    if len(placement)>3 and not 0<=placement[3]<len(pieces[piece_id].get('variants',[])):
        return 'Choose an available form.'
    if phase and piece_id not in moved and len(moved) >= config.get('maxMoved', len(pieces)):
        return 'Piece-move limit reached. Undo to try a different piece.'
    updates=linked_placements(config,placements,piece_id,placement)
    occupied = {p for key,value in placements.items() if key not in updates for p in cells(pieces[key],value)}
    transfer = config.get('transfer') if phase else None
    movement=transfer or config.get('insertion')
    target=set(points(movement['area'] if movement else config.get('playArea',config['targets'][phase])))
    markers={tuple(m['position']):m['color'] for m in config.get('markers',[])}
    for key,pose in updates.items():
        for point in cells(pieces[key],pose):
            if point not in target:return 'Keep every square inside the active play area.' if 'playArea' in config else 'Keep every square inside the active target.'
            if point in occupied:return 'Pieces cannot overlap.'
            if point in markers and markers[point]!=pieces[key]['color']:return 'This colour clue needs a matching piece.'
            occupied.add(point)
    after={**placements,**updates}
    return (transfer_problem(config,placements,phase,piece_id,placement,steps,lifts)
            or insertion_problem(config,placements,piece_id,placement)
            or support_problem(config,after) or free_space_problem(config,after))


def echo_partner(config, placements, piece_id):
    if piece_id not in placements:return None
    for pair in config.get('echoLinks',[]):
        if piece_id in pair:
            other=pair[1] if pair[0]==piece_id else pair[0]
            if other in placements:return other
    return None


def linked_group(config, placements, piece_id):
    partner=echo_partner(config,placements,piece_id)
    if partner is not None:return sorted([piece_id,partner])
    if config.get('linkedMovement') is None or piece_id not in placements:return [piece_id]
    by={p['id']:p for p in config['pieces']};pads=set(points(config['linkedMovement'].get('releaseCells',[])))
    released={k for k,p in placements.items() if set(cells(by[k],p))&pads}
    marked={e:(k,symbol) for k,p in placements.items() for e,symbol in edges(by[k],p)}
    graph={k:set() for k in placements}
    for (x,y,d),(key,symbol) in marked.items():
        dx,dy=[(0,-1),(1,0),(0,1),(-1,0)][d];other=marked.get((x+dx,y+dy,(d+2)%4))
        if other and other[0]!=key and other[1]==symbol and key not in released and other[0] not in released:
            graph[key].add(other[0]);graph[other[0]].add(key)
    seen={piece_id};pending=[piece_id]
    while pending:
        for key in graph[pending.pop()]-seen:seen.add(key);pending.append(key)
    return sorted(seen)


def linked_placements(config, placements, piece_id, placement):
    partner=echo_partner(config,placements,piece_id)
    if partner is not None:
        old=placements[piece_id];other=placements[partner]
        dx,dy=placement[0]-old[0],placement[1]-old[1]
        delta=(placement[2]-old[2])%4
        return {piece_id:placement,partner:[other[0]+dx,other[1]+dy,(other[2]-delta)%4,*other[3:]]}
    group=linked_group(config,placements,piece_id)
    if len(group)==1:return {piece_id:placement}
    by={p['id']:p for p in config['pieces']};old=placements[piece_id];delta=(placement[2]-old[2])%4
    def rotate(point):
        x,y=point
        for _ in range(delta):x,y=-y,x
        return x,y
    local=[rotate((x-old[0],y-old[1])) for x,y in cells(by[piece_id],old)]
    mx=min(x for x,y in local);my=min(y for x,y in local)
    result={}
    for key in group:
        world=[rotate((x-old[0],y-old[1])) for x,y in cells(by[key],placements[key])]
        pose=[min(x for x,y in world)-mx+placement[0],min(y for x,y in world)-my+placement[1],(placements[key][2]+delta)%4]
        if key == piece_id and len(placement) > 3:
            pose.append(placement[3])
        elif key != piece_id and len(placements[key]) > 3:
            pose.append(placements[key][3])
        result[key]=pose
    return result


def rotation_group(config, piece_id):
    seen={piece_id};pending=[piece_id]
    graph={p['id']:set() for p in config['pieces']}
    for a,b in config.get('rotationLinks',[]):graph[a].add(b);graph[b].add(a)
    while pending:
        for key in graph[pending.pop()]-seen:seen.add(key);pending.append(key)
    return sorted(seen)


def free_regions(config, placements):
    by={p['id']:p for p in config['pieces']}
    occupied={p for k,pose in placements.items() for p in cells(by[k],pose)}
    remaining=set(points(config['playArea']))-occupied;count=0
    while remaining:
        pending=[remaining.pop()];count+=1
        while pending:
            x,y=pending.pop()
            for dx,dy in [(0,-1),(1,0),(0,1),(-1,0)]:
                other=(x+dx,y+dy)
                if other in remaining:remaining.remove(other);pending.append(other)
    return count


def free_space_problem(config, placements):
    if config.get('freeSpace') and free_regions(config,placements)>1:
        return 'That move seals an empty pocket. Keep all empty play cells connected.'
    return None


def transfer_cost(placements, piece_id, placement):
    old=placements.get(piece_id)
    return abs(old[0]-placement[0])+abs(old[1]-placement[1]) if old is not None and placement is not None else 1


def transfer_problem(config, placements, phase, piece_id, placement, steps=0, lifts=0, roster=None):
    rule=config.get('transfer') if phase else None
    if not rule:return None
    by_id={p['id']:p for p in config['pieces']}
    cost=transfer_cost(placements,piece_id,placement)
    if steps+cost>rule['maxSteps']:
        return 'Step limit reached. Undo to try a shorter route.'
    if placement is None:
        slots=sum(key not in placements for key in roster) if roster is not None else len(by_id)-len(placements)
        extra=int(piece_id in roster) if roster is not None else 1
        if slots+extra>rule.get('trayCapacity',1):
            return 'The tray slot is occupied. Place that piece back first.'
        if lifts>=rule.get('maxRemovals',1):
            return 'Tray removal limit reached. Undo to choose a different removal.'
    elif piece_id in placements and rule.get('slideOnly',False):
        old=placements[piece_id]
        if placement[2]!=old[2]:
            return 'Return the piece to the tray before rotating it.'
        dx,dy=placement[0]-old[0],placement[1]-old[1]
        if dx and dy:return 'Slide horizontally or vertically. Turn in a separate move.'
        group=linked_group(config,placements,piece_id)
        occupied={p for key,value in placements.items() if key not in group for p in cells(by_id[key],value)}
        area=set(points(rule['area']))
        for step in range(1,cost+1):
            anchor=[old[0]+(1 if dx>0 else -1 if dx<0 else 0)*step,old[1]+(1 if dy>0 else -1 if dy<0 else 0)*step,old[2],*old[3:]]
            updates=linked_placements(config,placements,piece_id,anchor)
            swept=[p for key,pose in updates.items() for p in cells(by_id[key],pose)]
            if any(p not in area for p in swept):return 'A blocked square stops this slide.'
            if any(p in occupied for p in swept):return 'Another piece blocks this slide.'
    if rule.get('keepEdges',False):
        after={k:v for k,v in placements.items() if k!=piece_id}
        if placement is not None:after.update(linked_placements(config,placements,piece_id,placement))
        marked={edge:(key,symbol) for key,value in after.items() for edge,symbol in edges(by_id[key],value)}
        for (x,y,d),(key,symbol) in marked.items():
            dx,dy=[(0,-1),(1,0),(0,1),(-1,0)][d]
            other=marked.get((x+dx,y+dy,(d+2)%4))
            if other is None or other[0]==key or other[1]!=symbol:
                return 'Keep the numbered edges connected during the transfer.'
    return None


def insertion_problem(config, placements, piece_id, placement):
    rule=config.get('insertion')
    if not rule:return None
    by_id={p['id']:p for p in config['pieces']}
    piece=by_id[piece_id];side=piece.get('entrySide')
    if type(side) is not int or not 0<=side<4:return 'This piece needs an entry side (0-3).'
    area=set(points(rule['area']));width,height=config['size']
    old=placements.get(piece_id)
    updates=linked_placements(config,placements,piece_id,placement) if placement is not None and old is not None else {piece_id:placement if placement is not None else old}
    occupied={p for key,value in placements.items() if key not in updates for p in cells(by_id[key],value)}
    if placement is not None and old is not None:
        if placement[2]!=old[2]:return 'Return the piece through its entry side before rotating it.'
        dx,dy=placement[0]-old[0],placement[1]-old[1]
        if dx and dy:return 'Slide horizontally or vertically. Turn in a separate move.'
        sx=1 if dx>0 else -1 if dx<0 else 0;sy=1 if dy>0 else -1 if dy<0 else 0
        for step in range(1,abs(dx)+abs(dy)+1):
            for member_id in updates:
                member_old=placements[member_id]
                p=[member_old[0]+sx*step,member_old[1]+sy*step,*member_old[2:]]
                swept=cells(by_id[member_id],p)
                if any(a not in area for a in swept):return 'A wall blocks this slide.'
                if any(a in occupied for a in swept):return 'Another piece blocks this slide.'
        return None
    anchor=placement if placement is not None else old
    dx,dy=[(0,-1),(1,0),(0,1),(-1,0)][side]
    for step in range(1,width+height+max(max(p) for p in variant_piece(piece,anchor)['cells'])+3):
        swept=cells(piece,[anchor[0]+dx*step,anchor[1]+dy*step,*anchor[2:]])
        inside=[p for p in swept if 0<=p[0]<width and 0<=p[1]<height]
        if not inside:return None
        if any(p not in area or p in occupied for p in inside):
            return 'Clear the route to the '+['top','right','bottom','left'][side]+' entry. Pieces cannot jump over walls or other pieces.'
    return 'No clear route to the entry side.'


def support_problem(config, placements):
    if not config.get('support', False):
        return None
    by_id = {p['id']: p for p in config['pieces']}
    occupied = {p:key for key,value in placements.items() for p in cells(by_id[key],value)}
    if unsupported_tiles(occupied, config['size'][1]-1):
        return 'Every piece needs support from the floor or a supported piece below. Remove upper pieces first.'
    return None


class TilePlacementSystem(GameSystem):
    def __init__(self, sys_id):
        super().__init__(sys_id, 'tile_placement')

    def execute_action_resolution(self, action, state, game):
        c = game.system_config(self.id)
        name = action.get('actionId')
        names = [c.get('placeAction', 'place_piece'), c.get('removeAction', 'remove_piece'),
                 c.get('nextAction', 'next_target'),c.get('changeAction','change_piece'),c.get('turnAction','turn_piece'),c.get('rotateAction','rotate_piece'),c.get('swapAction','swap_echo')]
        if name not in names:
            return []
        v, prefix = state.variables, self.id + '.'
        placements = dict(v.get(prefix+'placements', {}))
        moved = list(v.get(prefix+'moved', []))
        phase = v.get(prefix+'phase', 0)
        args = action.get('params', {})
        piece_id = args.get('piece')
        limits=c.get('limits')
        if name==names[5]:
            if not limits or piece_id not in {p['id'] for p in c['pieces']}:
                return [ev.action_vetoed('Select a piece to rotate.')]
            if v.get(prefix+'rotationsUsed',0)>=limits['rotations']:
                return [ev.action_vetoed('Rotation budget reached. Undo to recover rotations.')]
            if phase and piece_id in placements and c.get('transfer',{}).get('slideOnly'):
                return [ev.action_vetoed('Return the piece to the tray before rotating it.')]
            pending=dict(v[prefix+'previewRotations'])
            rotation=(pending.get(piece_id,0)+1)%4
            if piece_id in placements:
                old=placements[piece_id]
                updates=linked_placements(c,placements,piece_id,[old[0],old[1],rotation,*old[3:]])
                pending.update({key:pose[2] for key,pose in updates.items()})
            else:pending[piece_id]=rotation
            v[prefix+'previewRotations']=pending
            v[prefix+'rotationsUsed']=v.get(prefix+'rotationsUsed',0)+1
            self._settle(state,game)
            return [ev.variable_changed(prefix+'previewRotations',None,pending)]
        if limits and name!=names[2] and v.get(prefix+'movesUsed',0)>=limits['moves']:
            return [ev.action_vetoed('Move budget reached. Undo to try a shorter solution.')]
        if name == names[2]:
            if not v.get(prefix+'fit') or phase+1 >= len(c['targets']):
                return [ev.action_vetoed('Complete the current target before continuing.')]
            v[prefix+'phase'] = phase+1
            v[prefix+'moved'] = []
            if c.get('transfer'):
                v[prefix+'transferSteps']=0;v[prefix+'removalsUsed']=0;v[prefix+'transferRoster']=sorted(placements)
        else:
            cost=1
            if name == names[0]:
                raw = args.get('position')
                placement = [*raw, args.get('rotation', 0)] if isinstance(raw, list) and len(raw) == 2 else []
                piece=next((p for p in c['pieces'] if p['id']==piece_id),None)
                if piece and piece.get('variants') and placement:placement.append(v.get(prefix+'forms',{}).get(piece_id,0))
                if 'rotationLinks' in c and piece and len(placement)>=3 and placement[2]!=v.get(prefix+'orientations',{}).get(piece_id,piece.get('startRotation',0)):
                    return [ev.action_vetoed('Use Rotate so paired orientations change together.')]
                if limits and piece and len(placement)>=3 and placement[2]!=v[prefix+'previewRotations'].get(piece_id,0):
                    return [ev.action_vetoed('Use Rotate to change the piece orientation.')]
                error = problem(c, placements, phase, moved, piece_id, placement,v.get(prefix+'transferSteps',0),v.get(prefix+'removalsUsed',0))
                if error:
                    return [ev.action_vetoed(error)]
                if placements.get(piece_id) == placement:
                    return [ev.action_vetoed('That piece is already there.')]
                cost=transfer_cost(placements,piece_id,placement)
                group=linked_group(c,placements,piece_id)
                updates=linked_placements(c,placements,piece_id,placement)
                placements.update(updates)
                if limits:v[prefix+'previewRotations']={**v[prefix+'previewRotations'],**{key:pose[2] for key,pose in updates.items()}}
                if c.get('linkedMovement') is not None and len(group)>1:
                    v[prefix+'linkMoved']=1
                    if len(linked_group(c,placements,piece_id))<len(group):v[prefix+'linkReleased']=1
            elif name==names[6]:
                partner=echo_partner(c,placements,piece_id)
                if not c.get('echoSwap') or partner is None:
                    return [ev.action_vetoed('Select an echo partner to swap.')]
                if phase and c.get('transfer',{}).get('slideOnly'):
                    return [ev.action_vetoed('Swapping is not allowed during a slide-only transfer.')]
                proposed=dict(placements);pending=v.get(prefix+'previewRotations',{})
                for key,other in [(piece_id,partner),(partner,piece_id)]:
                    old=placements[key];anchor=placements[other]
                    proposed[key]=[anchor[0],anchor[1],pending.get(key,old[2]),*old[3:]]
                for key in [piece_id,partner]:
                    error=problem(c,{k:p for k,p in proposed.items() if k!=key},phase,moved,key,proposed[key])
                    if error:return [ev.action_vetoed('Echo swap blocked: '+error)]
                placements=proposed
                if limits:v[prefix+'previewRotations']={**pending,**{key:proposed[key][2] for key in [piece_id,partner]}}
                v[prefix+'echoSwaps']=v.get(prefix+'echoSwaps',0)+1
            elif name==names[4]:
                if 'rotationLinks' not in c or not isinstance(piece_id,str) or piece_id not in {p['id'] for p in c['pieces']}:
                    return [ev.action_vetoed('Select a piece to rotate.')]
                group=rotation_group(c,piece_id)
                orientations=dict(v.get(prefix+'orientations',{}));proposed=dict(placements)
                for key in group:
                    orientations[key]=(orientations.get(key,0)+1)%4
                    if key in placements:
                        pose=placements[key][:];pose[2]=orientations[key];proposed[key]=pose
                for key in group:
                    if key in proposed:
                        others={k:p for k,p in proposed.items() if k!=key}
                        error=problem(c,others,phase,moved,key,proposed[key])
                        if error:return [ev.action_vetoed('Paired rotation blocked: '+error)]
                if len(group)>1 and sum(key in placements for key in group)>=2:v[prefix+'pairedTurned']=1
                placements=proposed;v[prefix+'orientations']=orientations
            elif name==names[3]:
                piece=next((p for p in c['pieces'] if p['id']==piece_id),None)
                if not piece or not piece.get('variants') or piece_id not in placements:
                    return [ev.action_vetoed('Place a changeable piece on a workshop first.')]
                old=placements[piece_id]
                if not set(cells(piece,old))&set(points(c.get('variantCells',[]))):
                    return [ev.action_vetoed('Move the piece onto a workshop to change form.')]
                form=((old[3] if len(old)>3 else 0)+1)%len(piece['variants'])
                pose=[*old[:3],form]
                error=problem(c,placements,phase,moved,piece_id,pose)
                if error:return [ev.action_vetoed(error)]
                placements[piece_id]=pose
                v[prefix+'forms']={**v.get(prefix+'forms',{}),piece_id:form}
            else:
                if not isinstance(piece_id, str) or piece_id not in placements:
                    return [ev.action_vetoed('Select a placed piece to remove.')]
                if phase and piece_id not in moved and len(moved) >= c.get('maxMoved', len(c['pieces'])):
                    return [ev.action_vetoed('Piece-move limit reached. Undo to try a different piece.')]
                if len(linked_group(c,placements,piece_id))>1:
                    return [ev.action_vetoed('Echo partners stay on the board. Move or rotate either to control both.' if echo_partner(c,placements,piece_id) is not None else 'This group is permanently bonded. Use Undo to reverse a connection.' if not c.get('linkedMovement',{}).get('releaseCells') else 'This group is linked. Reach a release pad before returning a piece.')]
                error = transfer_problem(c,placements,phase,piece_id,None,v.get(prefix+'transferSteps',0),v.get(prefix+'removalsUsed',0),v.get(prefix+'transferRoster')) or insertion_problem(c,placements,piece_id,None) or support_problem(c, {key:value for key,value in placements.items() if key != piece_id}) or free_space_problem(c,{key:value for key,value in placements.items() if key != piece_id})
                if error:
                    return [ev.action_vetoed(error)]
                del placements[piece_id]
                if piece_id in v.get(prefix+'forms',{}):v[prefix+'forms']={**v[prefix+'forms'],piece_id:0}
            if limits:v[prefix+'movesUsed']=v.get(prefix+'movesUsed',0)+1
            if phase and piece_id not in moved:
                moved.append(piece_id)
            v[prefix+'placements'], v[prefix+'moved'] = placements, moved
            if phase and c.get('transfer'):
                v[prefix+'transferSteps']=v.get(prefix+'transferSteps',0)+cost
                if name==names[1]:v[prefix+'removalsUsed']=v.get(prefix+'removalsUsed',0)+1
        self._settle(state, game)
        return [ev.variable_changed(prefix+'placements', None, placements)]

    def execute_load_settle(self, state, game):
        self._settle(state, game)
        return []

    def _settle(self, state, game):
        c, v, prefix = game.system_config(self.id), state.variables, self.id+'.'
        if c.get('transfer'):
            v.setdefault(prefix+'transferSteps',0);v.setdefault(prefix+'removalsUsed',0)
        if any(p.get('variants') for p in c['pieces']):v.setdefault(prefix+'forms',{p['id']:0 for p in c['pieces'] if p.get('variants')})
        if c.get('linkedMovement') is not None:
            v.setdefault(prefix+'linkMoved',0);v.setdefault(prefix+'linkReleased',0)
        placements = v.get(prefix+'placements', {})
        if c.get('echoSwap'):v.setdefault(prefix+'echoSwaps',0)
        if c.get('limits'):
            v.setdefault(prefix+'movesUsed',0);v.setdefault(prefix+'rotationsUsed',0)
            v.setdefault(prefix+'previewRotations',{p['id']:(placements[p['id']][2] if p['id'] in placements else 0) for p in c['pieces']})
        if 'rotationLinks' in c:
            v.setdefault(prefix+'orientations',{p['id']:(placements[p['id']][2] if p['id'] in placements else p.get('startRotation',0)) for p in c['pieces']})
            v.setdefault(prefix+'pairedTurned',0)
        phase = v.get(prefix+'phase', 0)
        target = set(points(c['targets'][phase]))
        pieces = {p['id']: p for p in c['pieces']}
        occupied, marked = {}, {}
        light_config = c.get('lights')
        lights = set(points(light_config.get('initial', []))) if light_config else set()
        steps = [(0,-1),(1,0),(0,1),(-1,0)]
        for key, placement in placements.items():
            piece = pieces[key]
            occupied.update((p, key) for p in cells(piece, placement))
            marked.update((edge, (key, symbol)) for edge, symbol in edges(piece, placement))
            if 'pulse' in piece:
                x, y = transform(piece, piece['pulse'], placement[2])
                for dx, dy in steps:
                    p = x+placement[0]+dx, y+placement[1]+dy
                    if p in target:
                        lights.symmetric_difference_update([p])
        edge_errors = 0
        for (x, y, direction), (key, symbol) in marked.items():
            dx, dy = steps[direction]
            other = marked.get((x+dx, y+dy, (direction+2)%4))
            if other is None or other[0] == key or other[1] != symbol:
                edge_errors += 1
        contact_errors=0
        if 'neighborCounts' in c or 'forbiddenContacts' in c:
            neighbors={key:set() for key in pieces}
            for (x,y),key in occupied.items():
                for dx,dy in steps:
                    other=occupied.get((x+dx,y+dy))
                    if other is not None and other!=key:neighbors[key].add(other)
            counts={key:len(value) for key,value in neighbors.items()}
            contact_errors=sum(counts.get(key,0)!=wanted for key,wanted in c.get('neighborCounts',{}).items())
            contact_errors+=sum(b in neighbors.get(a,set()) for a,b in c.get('forbiddenContacts',[]))
            v[prefix+'neighborCounts']=counts
            v[prefix+'contactErrors']=contact_errors
        if c.get('allowUnused'):
            edge_errors+=sum(len(piece.get('edges',[])) for key,piece in pieces.items() if key not in placements)
        echo_ok=all(key in placements for pair in c.get('echoLinks',[]) for key in pair)
        light_errors = len(lights.symmetric_difference(set(points(light_config['target'])))) if light_config else 0
        totals = row_sums(c, occupied) if 'rowTotals' in c else []
        row_errors = sum(a != b for a,b in zip(totals,c.get('rowTotals',[])))
        if 'rowTotals' in c:
            v.update({prefix+'rowSums':totals, prefix+'rowErrors':row_errors})
        columns = column_sums(c, occupied) if 'columnTotals' in c else []
        column_errors = sum(a != b for a,b in zip(columns,c.get('columnTotals',[])))
        if 'columnTotals' in c:
            v.update({prefix+'columnSums':columns, prefix+'columnErrors':column_errors})
        stable = not c.get('support', False) or not unsupported_tiles(occupied, c['size'][1]-1)
        form_errors=sum(v.get(prefix+'forms',{}).get(p['id'],0)!=p['requiredVariant'] for p in c['pieces'] if 'requiredVariant' in p)
        if any(p.get('variants') for p in c['pieces']):v[prefix+'formErrors']=form_errors
        linked=c.get('linkedMovement') or {}
        links_ok=(not linked.get('requireMove') or v.get(prefix+'linkMoved')) and (not linked.get('requireRelease') or v.get(prefix+'linkReleased'))
        if c.get('freeSpace'):v[prefix+'freeRegions']=free_regions(c,placements)
        fit = set(occupied) == target and (c.get('allowUnused',False) or len(placements) == len(pieces)) and echo_ok and not edge_errors and not light_errors and not row_errors and not column_errors and stable and not form_errors and not contact_errors and links_ok and (not c.get('requirePairedTurn') or v.get(prefix+'pairedTurned')) and not free_space_problem(c,placements)
        v.update({prefix+'fit':int(fit), prefix+'complete':int(fit and phase == len(c['targets'])-1),
                  prefix+'filled':len(set(occupied) & target), prefix+'edgeErrors':edge_errors,
                  prefix+'lightErrors':light_errors, prefix+'lights':[list(p) for p in sorted(lights)]})
        layer = c.get('piecesLayer', 'pieces')
        for y in range(state.board.height):
            for x in range(state.board.width):
                key = occupied.get((x,y))
                state.board.set_entity(layer, Pos(x,y), Entity(pieces[key]['kind'], {'piece':key}) if key else None)

    def observation_status_lines(self, state, game, initial_board):
        c, v, prefix = game.system_config(self.id), state.variables, self.id+'.'
        return ['Tile placement', f"phase: {v.get(prefix+'phase',0)+1}/{len(c['targets'])}",
                f"placements: {v.get(prefix+'placements',{})}", f"moved: {v.get(prefix+'moved',[])}",
                f"edge mismatches: {v.get(prefix+'edgeErrors',0)}; light mismatches: {v.get(prefix+'lightErrors',0)}"]
