"""Focused rigid-placement checks; mirrored by the Dart test."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from engines.python import GameDef, TurnEngine
from engines.python._systems.tile_placement import cells, edges


def engine(extra=None):
    config = dict(size=[2, 2], targets=[[[0,0],[1,0],[0,1],[1,1]]], pieces=[
        dict(id='x', kind='tile', color='#aa0000', cells=[[0,0],[1,0]], pulse=[0,0]),
        dict(id='y', kind='tile', color='#0000aa', cells=[[0,0],[1,0]])])
    config.update(extra or {})
    game = GameDef.from_dict(dict(
        layers=[dict(id='ground', occupancy='exactly_one', default='floor'), dict(id='pieces', occupancy='zero_or_one')],
        entityKinds=dict(floor=dict(layer='ground',symbol='.'), tile=dict(layer='pieces',symbol='T')),
        actions=[dict(id=a, params={}) for a in ['place_piece','remove_piece','next_target','change_piece','turn_piece','rotate_piece','swap_echo']],
        systems=[dict(id='tiles', type='tile_placement', config=config)], rules=[]), id='placement_test')
    return TurnEngine(game, dict(id='test', board=dict(size=config['size'], layers={}), state=dict(avatar=dict(enabled=False)),
        goals=[dict(id='done', type='variable_threshold', config=dict(variable='tiles.complete',target=1,comparison='eq'))]))


def place(e, key='x', x=0, y=0, r=0):
    return e.execute_turn('place_piece', dict(piece=key, position=[x,y], rotation=r)).accepted


def transfer_engine(keep_edges=False):
    tiles=[dict(id='x',kind='tile',color='#aa0000',cells=[[0,0],[1,0]]),
           dict(id='y',kind='tile',color='#0000aa',cells=[[0,0]]),
           dict(id='z',kind='tile',color='#00aa00',cells=[[0,0]])]
    if keep_edges:
        tiles[0]['edges']=[dict(cell=[1,0],direction=1,symbol='1')]
        tiles[1]['edges']=[dict(cell=[0,0],direction=3,symbol='1')]
    e=engine(dict(size=[6,3],pieces=tiles,targets=[[[x,1] for x in range(4)],[[0,0],[1,0],[3,0],[4,0]]],
        transfer=dict(area=[[x,y] for y in range(3) for x in range(6) if (x,y)!=(2,0)],maxSteps=8,maxRemovals=1,trayCapacity=1,slideOnly=True,keepEdges=keep_edges)))
    assert place(e,'x',0,1) and place(e,'y',2,1) and place(e,'z',3,1)
    assert e.execute_turn('next_target',{}).accepted
    return e


def insertion_engine():
    return engine(dict(size=[5,4],targets=[[[3,2],[4,2],[1,2],[4,3]]],
        pieces=[dict(id='x',kind='tile',color='#aa0000',cells=[[0,0],[1,0]],entrySide=3),
                dict(id='y',kind='tile',color='#0000aa',cells=[[0,0]],entrySide=0),
                dict(id='z',kind='tile',color='#00aa00',cells=[[0,0]],entrySide=1)],
        insertion=dict(area=[[x,y] for y in range(4) for x in range(5) if (x,y)!=(2,0)])))


class PlacementTests(unittest.TestCase):
    def test_transfer_steps_tray_replacement_collision_and_undo(self):
        e=transfer_engine();before=e.state_key();depth=e.undo_depth
        self.assertFalse(place(e,'x',4,1))  # Clear endpoint behind occupied cells.
        self.assertFalse(place(e,'x',4,0))  # Diagonal teleport.
        self.assertFalse(place(e,'x',0,1,1))  # Board rotation.
        self.assertEqual(e.state_key(),before);self.assertEqual(e.undo_depth,depth)
        self.assertTrue(place(e,'x',0,2));self.assertTrue(place(e,'x',2,2))
        self.assertEqual(e.state.variables['tiles.transferSteps'],3)
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='y')).accepted)
        before=e.state_key()
        self.assertFalse(e.execute_turn('remove_piece',dict(piece='z')).accepted)
        self.assertFalse(place(e,'y',2,0))
        self.assertEqual(e.state_key(),before)
        self.assertTrue(place(e,'y',0,2))  # Return never prevents replacement.
        self.assertFalse(e.execute_turn('remove_piece',dict(piece='z')).accepted)
        for x,y in [(4,1),(5,1),(5,2)]:self.assertTrue(place(e,'z',x,y))
        self.assertEqual(e.state.variables['tiles.transferSteps'],8)
        before=e.state_key();self.assertFalse(place(e,'x',3,2));self.assertEqual(e.state_key(),before)
        self.assertTrue(e.undo());self.assertEqual(e.state.variables['tiles.transferSteps'],7)
        self.assertEqual(e.state.variables['tiles.removalsUsed'],1)

    def test_transfer_edges_stay_joined_and_counters_reset(self):
        e=transfer_engine(True);before=e.state_key()
        self.assertFalse(place(e,'x',0,2))
        self.assertFalse(e.execute_turn('remove_piece',dict(piece='x')).accepted)
        self.assertEqual(e.state_key(),before)
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='z')).accepted)
        self.assertEqual(e.state.variables['tiles.removalsUsed'],1)
        self.assertTrue(e.undo());self.assertEqual(e.state.variables['tiles.removalsUsed'],0)
        self.assertEqual(e.state.variables['tiles.transferSteps'],0)
        e.reset();self.assertEqual(e.state.variables['tiles.transferSteps'],0)

    def test_paired_rotations_are_atomic_and_persist_in_the_tray(self):
        tiles=[dict(id=k,kind='tile',color='#aa0000',cells=[[0,0],[1,0]] if k!='z' else [[0,0]]) for k in ['x','y','z']]
        e=engine(dict(size=[6,4],pieces=tiles,targets=[[[0,0],[1,0],[3,0],[4,0],[5,3]]],playArea=[[x,y] for y in range(4) for x in range(6)],rotationLinks=[['x','y']],requirePairedTurn=True))
        self.assertTrue(place(e,'x',0,0));self.assertTrue(place(e,'y',3,0))
        self.assertTrue(e.execute_turn('turn_piece',dict(piece='x')).accepted)
        self.assertEqual(e.state.variables['tiles.placements']['y'],[3,0,1])
        self.assertTrue(place(e,'z',4,0));before=e.state_key();depth=e.undo_depth
        self.assertFalse(e.execute_turn('turn_piece',dict(piece='x')).accepted)
        self.assertEqual(e.state_key(),before);self.assertEqual(e.undo_depth,depth)
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='z')).accepted)
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='y')).accepted)
        self.assertEqual(e.state.variables['tiles.orientations']['y'],1)
        self.assertTrue(e.execute_turn('turn_piece',dict(piece='y')).accepted)
        self.assertEqual(e.state.variables['tiles.placements']['x'],[0,0,2])
        self.assertFalse(place(e,'y',3,0,0));self.assertTrue(place(e,'y',3,0,2))
        self.assertTrue(place(e,'z',5,3));self.assertTrue(e.is_won)
        e.reset();self.assertEqual(e.state.variables['tiles.orientations']['x'],0);self.assertEqual(e.state.variables['tiles.pairedTurned'],0)

    def test_linked_group_rotates_atomically_and_releases(self):
        tiles=[dict(id='x',kind='tile',color='#aa0000',cells=[[0,0]],edges=[dict(cell=[0,0],direction=1,symbol='1')]),dict(id='y',kind='tile',color='#0000aa',cells=[[0,0]],edges=[dict(cell=[0,0],direction=3,symbol='1')]),dict(id='z',kind='tile',color='#00aa00',cells=[[0,0]])]
        e=engine(dict(size=[5,4],pieces=tiles,targets=[[[0,0],[1,0],[4,3]]],playArea=[[x,y] for y in range(4) for x in range(5)],linkedMovement=dict(releaseCells=[[2,2]],requireMove=True,requireRelease=True)))
        self.assertTrue(place(e,'x',0,0));self.assertTrue(place(e,'y',1,0))
        self.assertFalse(e.execute_turn('remove_piece',dict(piece='x')).accepted)
        self.assertTrue(place(e,'x',1,1,1))
        self.assertEqual(e.state.variables['tiles.placements']['y'],[1,2,1])
        before=e.state_key();self.assertFalse(place(e,'x',4,3,1));self.assertEqual(e.state_key(),before)
        self.assertTrue(place(e,'x',2,2,0));self.assertEqual(e.state.variables['tiles.linkReleased'],1)
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='x')).accepted)
        e.undo();e.undo();self.assertEqual(e.state.variables['tiles.linkReleased'],0)

    def test_link_rotation_normalizes_a_non_square_pivot(self):
        from engines.python._systems.tile_placement import linked_placements
        c=dict(pieces=[dict(id='x',cells=[[0,0],[0,1],[1,1]],edges=[dict(cell=[0,0],direction=1,symbol='1')]),dict(id='y',cells=[[0,0],[1,0]],edges=[dict(cell=[0,0],direction=3,symbol='1')])],linkedMovement=dict(releaseCells=[]))
        self.assertEqual(linked_placements(c,dict(x=[2,1,0],y=[3,1,0]),'x',[1,2,1]),dict(x=[1,2,1],y=[2,3,1]))

    def test_workshop_transform_collision_and_return_memory(self):
        tiles=[dict(id='x',kind='tile',color='#aa0000',cells=[[0,0],[0,1],[1,1]],variants=[dict(cells=[[0,0],[0,1],[1,1]]),dict(cells=[[0,0],[1,0],[2,0]])],requiredVariant=1),dict(id='y',kind='tile',color='#0000aa',cells=[[0,0]])]
        e=engine(dict(size=[5,3],pieces=tiles,targets=[[[2,2],[3,2],[4,2],[4,0]]],playArea=[[x,y] for y in range(3) for x in range(5)],variantCells=[[0,0]]))
        self.assertTrue(place(e,'x',2,0));self.assertFalse(e.execute_turn('change_piece',dict(piece='x')).accepted)
        self.assertTrue(place(e,'x',0,0));self.assertTrue(place(e,'y',2,0))
        before=e.state_key();self.assertFalse(e.execute_turn('change_piece',dict(piece='x')).accepted);self.assertEqual(e.state_key(),before)
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='y')).accepted)
        self.assertTrue(e.execute_turn('change_piece',dict(piece='x')).accepted)
        self.assertEqual(e.state.variables['tiles.forms']['x'],1)
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='x')).accepted);self.assertEqual(e.state.variables['tiles.forms']['x'],0)
        self.assertTrue(place(e,'x',0,0));self.assertTrue(e.execute_turn('change_piece',dict(piece='x')).accepted)
        self.assertTrue(place(e,'x',2,2));self.assertTrue(place(e,'y',4,0));self.assertTrue(e.is_won)

    def test_empty_space_cannot_be_split_or_reopened_as_a_pocket(self):
        tiles=[dict(id=k,kind='tile',color='#aa0000',cells=[[0,0]]) for k in 'abcdef']
        e=engine(dict(size=[5,5],pieces=tiles,targets=[[[2,1],[1,2],[3,2],[2,3],[2,2],[4,4]]],playArea=[[x,y] for y in range(5) for x in range(5)],freeSpace=True))
        for k,x,y in [('a',2,1),('b',1,2),('c',3,2)]:self.assertTrue(place(e,k,x,y))
        before=e.state_key();self.assertFalse(place(e,'d',2,3));self.assertEqual(e.state_key(),before)
        self.assertTrue(place(e,'e',2,2));self.assertTrue(place(e,'d',2,3))
        self.assertFalse(e.execute_turn('remove_piece',dict(piece='e')).accepted)
        self.assertTrue(place(e,'f',4,4));self.assertTrue(e.is_won);self.assertEqual(e.state.variables['tiles.freeRegions'],1)

    def test_side_entry_checks_route_and_reversible_extraction(self):
        e=insertion_engine()
        self.assertFalse(place(e,'y',2,2))  # A wall lies between top and endpoint.
        self.assertTrue(place(e,'y',1,2))
        before=e.state_key();depth=e.undo_depth
        self.assertFalse(place(e,'x',3,2))  # Endpoint is clear, entry lane is blocked.
        self.assertEqual(e.state_key(),before);self.assertEqual(e.undo_depth,depth)
        self.assertTrue(place(e,'x',0,1))
        self.assertFalse(e.execute_turn('remove_piece',dict(piece='y')).accepted)
        self.assertFalse(place(e,'x',0,1,1))
        self.assertFalse(place(e,'x',3,3))
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='x')).accepted)
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='y')).accepted)
        self.assertTrue(place(e,'x',3,2));self.assertTrue(place(e,'y',1,2))
        self.assertFalse(e.execute_turn('remove_piece',dict(piece='x')).accepted)
        self.assertTrue(place(e,'z',4,3));self.assertTrue(e.is_won)
        self.assertTrue(e.undo());self.assertFalse(e.is_won)
        e.reset();self.assertFalse(e.state.variables.get('tiles.placements'))

    def test_cross_sums_require_columns_even_when_all_rows_match(self):
        tiles=[dict(id=k,kind='tile',color='#aa0000',value=v,cells=[[0,0]]) for k,v in [('a',1),('b',2),('c',1),('d',2)]]
        e=engine(dict(pieces=tiles,rowTotals=[3,3],columnTotals=[3,3]))
        for key,x,y in [('a',0,0),('b',1,0),('c',0,1),('d',1,1)]:self.assertTrue(place(e,key,x,y))
        self.assertEqual(e.state.variables['tiles.rowErrors'],0)
        self.assertEqual(e.state.variables['tiles.columnSums'],[2,4])
        self.assertEqual(e.state.variables['tiles.columnErrors'],2)
        self.assertFalse(e.is_won)
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='c')).accepted)
        self.assertTrue(place(e,'d',0,1));self.assertTrue(place(e,'c',1,1))
        self.assertEqual(e.state.variables['tiles.columnSums'],[3,3]);self.assertTrue(e.is_won)
        self.assertTrue(e.undo());self.assertFalse(e.is_won)
        e.reset();self.assertEqual(e.state.variables['tiles.columnSums'],[0,0])

    def test_numeric_goals_reject_full_wrong_total(self):
        tiles=[dict(id=k,kind='tile',color='#aa0000',value=i,cells=[[0,0],[1,0]]) for k,i in [('x',2),('y',5)]]
        e=engine(dict(pieces=tiles,rowTotals=[4,10]))
        for x,key in enumerate(['x','y']): self.assertTrue(place(e,key,x,0,1))
        self.assertEqual(e.state.variables['tiles.rowSums'],[7,7])
        self.assertFalse(e.is_won)
        e.reset();place(e);place(e,'y',0,1)
        self.assertEqual(e.state.variables['tiles.rowSums'],[4,10])
        self.assertTrue(e.is_won)
        e.undo();self.assertFalse(e.is_won)

    def test_support_veto_preserves_state_and_history(self):
        tiles=[dict(id=k,kind='tile',color='#aa0000',cells=[[0,0],[1,0]]) for k in ['x','y','z']]
        e=engine(dict(size=[2,3],pieces=tiles,targets=[[[x,y] for y in range(3) for x in range(2)]],support=True))
        self.assertFalse(place(e))
        self.assertTrue(place(e,'x',0,2));self.assertTrue(place(e,'y',0,1))
        before=e.state_key();depth=e.undo_depth
        self.assertFalse(e.execute_turn('remove_piece',dict(piece='x')).accepted)
        self.assertFalse(place(e,'x',0,0))
        self.assertEqual(e.state_key(),before);self.assertEqual(e.undo_depth,depth)
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='y')).accepted)
        e.undo();self.assertTrue(place(e,'z',0,0));self.assertTrue(e.is_won)

    def test_support_allows_overhangs_but_not_floating_cycles(self):
        from engines.python._systems._tile_placement_constraints import unsupported_tiles
        self.assertEqual(unsupported_tiles({(0,2):'x',(0,1):'y',(1,1):'y'},2),[])
        self.assertEqual(unsupported_tiles({(0,0):'x',(0,1):'y',(1,0):'y',(1,1):'x'},2),['x','y'])

    def test_rotation_and_edges(self):
        p=dict(cells=[[0,0],[1,0]], edges=[dict(cell=[1,0],direction=1,symbol='o')])
        self.assertEqual(cells(p,[0,0,1]),[(0,0),(0,1)])
        self.assertEqual(list(edges(p,[0,0,1])),[((0,1,2),'o')])

    def test_invalid_actions_and_undo(self):
        e=engine()
        for key,x,y,r in [('x',1,0,0),('x',0,0,4),([],0,0,0)]:
            self.assertFalse(place(e,key,x,y,r))
        self.assertTrue(place(e))
        self.assertFalse(place(e,'y'))
        self.assertEqual(e.undo_depth,1)
        self.assertTrue(e.undo())
        self.assertEqual(e.state.variables['tiles.filled'],0)

    def test_reversible_lights(self):
        e=engine(dict(lights=dict(initial=[],target=[[1,0],[0,1]])))
        self.assertTrue(place(e))
        self.assertEqual(e.state.variables['tiles.lightErrors'],0)
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='x')).accepted)
        self.assertEqual(e.state.variables['tiles.lights'],[])
        e.undo()
        self.assertEqual(e.state.variables['tiles.lightErrors'],0)
        self.assertTrue(place(e,'y',0,1))
        self.assertTrue(e.is_won)
        e.reset()
        self.assertFalse(e.is_won)
        self.assertEqual(e.state.variables['tiles.filled'],0)

    def test_colour_clue(self):
        e=engine(dict(markers=[dict(position=[0,0],color='#0000aa')]))
        self.assertFalse(place(e))
        self.assertTrue(place(e,'y'))

    def test_overlapping_pulses_cancel_and_removal_restores(self):
        tiles=[dict(id=k,kind='tile',color='#aa0000',cells=[[0,0],[1,0]],pulse=[0,0]) for k in ['x','y']]
        e=engine(dict(pieces=tiles,lights=dict(initial=[],target=[[0,0]])))
        place(e);place(e,'y',0,1,2)
        self.assertEqual(e.state.variables['tiles.lights'],[])
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='y')).accepted)
        self.assertEqual(e.state.variables['tiles.lights'],[[0,1],[1,0]])

    def test_stage_carry_and_budget(self):
        target=[[0,0],[1,0],[0,1],[1,1]]
        e=engine(dict(size=[2,3],targets=[target,[[0,1],[1,1],[0,2],[1,2]]],maxMoved=1))
        self.assertFalse(e.execute_turn('next_target').accepted)
        place(e);place(e,'y',0,1)
        self.assertFalse(e.is_won)
        self.assertTrue(e.execute_turn('next_target').accepted)
        self.assertEqual(len(e.state.variables['tiles.placements']),2)
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='x')).accepted)
        self.assertFalse(e.execute_turn('remove_piece',dict(piece='y')).accepted)
        self.assertTrue(place(e,'x',0,2))
        self.assertTrue(e.is_won)
        e.undo();e.undo()
        self.assertEqual(e.state.variables['tiles.moved'],[])


    def test_contact_web_counts_neighbors_not_shared_sides(self):
        tiles=[dict(id=k,kind='tile',cells=[[0,0],[1,0]]) for k in ['x','y','z']]
        e=engine(dict(size=[2,3],pieces=tiles,targets=[[[x,y] for y in range(3) for x in range(2)]],neighborCounts=dict(x=1,y=2,z=1),forbiddenContacts=[['x','z']]))
        self.assertTrue(place(e,'x',0,0));self.assertTrue(place(e,'z',0,1));self.assertTrue(place(e,'y',0,2))
        self.assertFalse(e.is_won)
        self.assertEqual(e.state.variables['tiles.contactErrors'],3)
        self.assertEqual(e.state.variables['tiles.neighborCounts'],dict(x=1,y=1,z=2))
        e.undo();e.undo()
        self.assertTrue(place(e,'y',0,1));self.assertTrue(place(e,'z',0,2));self.assertTrue(e.is_won)
        self.assertEqual(e.state.variables['tiles.contactErrors'],0)
        e.reset();self.assertEqual(e.state.variables['tiles.neighborCounts'],dict(x=0,y=0,z=0))

    def test_contact_web_corners_do_not_touch(self):
        tiles=[dict(id=k,kind='tile',cells=[[0,0]]) for k in ['x','y']]
        e=engine(dict(pieces=tiles,targets=[[[0,0],[1,1]]],neighborCounts=dict(x=0,y=0),forbiddenContacts=[['x','y']]))
        self.assertTrue(place(e,'x'));self.assertTrue(place(e,'y',1,1));self.assertTrue(e.is_won)


    def test_transfer_sweeps_every_linked_member_and_keeps_edges(self):
        tiles=[dict(id='x',kind='tile',cells=[[0,0]],edges=[dict(cell=[0,0],direction=2,symbol='1')]),
               dict(id='y',kind='tile',cells=[[0,0]],edges=[dict(cell=[0,0],direction=0,symbol='1')]),
               dict(id='z',kind='tile',cells=[[0,0]])]
        e=engine(dict(size=[5,2],pieces=tiles,targets=[[[0,0],[0,1],[1,1]],[[2,0],[2,1],[4,1]]],linkedMovement={},
            transfer=dict(area=[[x,y] for y in range(2) for x in range(5)],maxSteps=8,maxRemovals=1,trayCapacity=1,slideOnly=True,keepEdges=True)))
        self.assertTrue(place(e,'x'));self.assertTrue(place(e,'y',0,1));self.assertTrue(place(e,'z',1,1))
        self.assertTrue(e.execute_turn('next_target',{}).accepted)
        before=e.state_key()
        self.assertFalse(place(e,'x',2,0));self.assertEqual(e.state_key(),before)
        self.assertTrue(place(e,'z',4,1));self.assertTrue(place(e,'x',2,0))
        self.assertEqual(e.state.variables['tiles.placements']['y'],[2,1,0])
        self.assertEqual(e.state.variables['tiles.edgeErrors'],0)
        self.assertEqual(e.state.variables['tiles.transferSteps'],5);self.assertTrue(e.is_won)
        e.undo();self.assertEqual(e.state.variables['tiles.placements']['y'],[0,1,0])
        self.assertEqual(e.state.variables['tiles.transferSteps'],3)


    def test_echo_translation_opposite_rotation_and_atomic_failure(self):
        tiles=[dict(id='x',kind='tile',cells=[[0,0],[0,1],[1,1]]),dict(id='y',kind='tile',cells=[[0,0],[1,0]]),dict(id='z',kind='tile',cells=[[0,0]])]
        e=engine(dict(size=[7,5],pieces=tiles,playArea=[[x,y] for y in range(5) for x in range(7)],echoLinks=[['x','y']]))
        self.assertTrue(place(e,'x',0,1));self.assertTrue(place(e,'y',4,1))
        self.assertTrue(place(e,'x',1,2,1));self.assertEqual(e.state.variables['tiles.placements'],dict(x=[1,2,1],y=[5,2,3]))
        self.assertTrue(place(e,'y',4,1,0));self.assertEqual(e.state.variables['tiles.placements'],dict(x=[0,1,0],y=[4,1,0]))
        before=e.state_key();self.assertFalse(place(e,'x',3,1));self.assertEqual(e.state_key(),before)
        self.assertFalse(e.execute_turn('remove_piece',dict(piece='y')).accepted);self.assertEqual(e.state_key(),before)
        self.assertTrue(place(e,'z',5,2));before=e.state_key()
        self.assertFalse(place(e,'x',1,1,1));self.assertEqual(e.state_key(),before)
        e.undo();e.undo();self.assertEqual(e.state.variables['tiles.placements'],dict(x=[1,2,1],y=[5,2,3]))
        e.reset();self.assertFalse(e.state.variables.get('tiles.placements'))

    def test_echo_partners_cannot_overlap_after_opposite_turn(self):
        tiles=[dict(id=k,kind='tile',cells=[[0,0],[1,0],[2,0]]) for k in ['x','y']]
        e=engine(dict(size=[7,5],pieces=tiles,playArea=[[x,y] for y in range(5) for x in range(7)],echoLinks=[['x','y']]))
        self.assertTrue(place(e,'x',0,0,1));self.assertTrue(place(e,'y',2,0,1))
        before=e.state_key();self.assertFalse(place(e,'x',0,0,2));self.assertEqual(e.state_key(),before)


    def test_action_budgets_charge_rotate_buttons_and_restore_on_undo(self):
        e=engine(dict(limits=dict(moves=1,rotations=1)))
        self.assertTrue(e.execute_turn('rotate_piece',dict(piece='x')).accepted)
        self.assertEqual(e.state.variables['tiles.rotationsUsed'],1)
        before=e.state_key();self.assertFalse(e.execute_turn('rotate_piece',dict(piece='x')).accepted);self.assertEqual(e.state_key(),before)
        self.assertFalse(place(e,'x',0,0,0));self.assertEqual(e.state_key(),before)
        self.assertTrue(place(e,'x',0,0,1));self.assertEqual(e.state.variables['tiles.movesUsed'],1)
        before=e.state_key();self.assertFalse(place(e,'y',1,0,1));self.assertEqual(e.state_key(),before)
        e.undo();self.assertEqual(e.state.variables['tiles.movesUsed'],0);self.assertEqual(e.state.variables['tiles.rotationsUsed'],1)
        e.undo();self.assertEqual(e.state.variables['tiles.rotationsUsed'],0);self.assertEqual(e.state.variables['tiles.previewRotations']['x'],0)
        e.reset();self.assertEqual(e.state.variables['tiles.movesUsed'],0)

    def test_unused_inventory_accepts_any_valid_subset(self):
        tiles=[dict(id='x',kind='tile',cells=[[0,0],[1,0]]),dict(id='y',kind='tile',cells=[[0,0],[1,0]]),dict(id='z',kind='tile',cells=[[0,0]]),dict(id='w',kind='tile',cells=[[0,0]])]
        e=engine(dict(pieces=tiles,allowUnused=True,limits=dict(moves=3,rotations=2)))
        self.assertTrue(place(e,'x'));self.assertTrue(place(e,'z',0,1));self.assertTrue(place(e,'w',1,1))
        self.assertTrue(e.is_won);self.assertNotIn('y',e.state.variables['tiles.placements'])
        self.assertEqual(e.state.variables['tiles.movesUsed'],3)


    def test_unused_inventory_cannot_bypass_visible_connector_or_echo_rules(self):
        for mode in ['ports','echo']:
            tiles=[dict(id=k,kind='tile',cells=[[0,0]]) for k in ['x','y','z','w']]
            config=dict(pieces=tiles,allowUnused=True,targets=[[[0,0],[1,0]]])
            if mode=='ports':
                tiles[0]['edges']=[dict(cell=[0,0],direction=1,symbol='1')]
                tiles[1]['edges']=[dict(cell=[0,0],direction=3,symbol='1')]
            else:config['echoLinks']=[['x','y']]
            e=engine(config)
            self.assertTrue(place(e,'z'));self.assertTrue(place(e,'w',1,0));self.assertFalse(e.is_won)
            e.undo();e.undo()
            self.assertTrue(place(e,'x'));self.assertTrue(place(e,'y',1,0));self.assertTrue(e.is_won)

    def test_unused_inventory_does_not_occupy_transfer_tray_slot(self):
        tiles=[dict(id=k,kind='tile',cells=[[0,0],[1,0]]) for k in ['x','y']]+[dict(id='z',kind='tile',cells=[[0,0],[0,1],[1,1]])]
        e=engine(dict(size=[3,2],pieces=tiles,allowUnused=True,targets=[[[0,0],[1,0],[0,1],[1,1]],[[1,0],[2,0],[1,1],[2,1]]],
            transfer=dict(area=[[x,y] for y in range(2) for x in range(3)],maxSteps=8,maxRemovals=1,trayCapacity=1,slideOnly=True)))
        self.assertTrue(place(e));self.assertTrue(place(e,'y',0,1));self.assertTrue(e.execute_turn('next_target',{}).accepted)
        self.assertEqual(e.state.variables['tiles.transferRoster'],['x','y'])
        self.assertTrue(e.execute_turn('remove_piece',dict(piece='x')).accepted)
        before=e.state_key();self.assertFalse(e.execute_turn('remove_piece',dict(piece='y')).accepted);self.assertEqual(e.state_key(),before)
        self.assertTrue(place(e,'x',1,0));self.assertTrue(place(e,'y',1,1));self.assertTrue(e.is_won)
        self.assertEqual(e.state.variables['tiles.transferSteps'],3)


    def test_echo_swap_commits_preview_and_costs_one_move(self):
        tiles=[dict(id='x',kind='tile',cells=[[0,0],[0,1],[1,1]]),dict(id='y',kind='tile',cells=[[0,0],[1,0]])]
        e=engine(dict(size=[7,4],pieces=tiles,playArea=[[x,y] for y in range(4) for x in range(7)],echoLinks=[['x','y']],echoSwap=True,limits=dict(moves=3,rotations=2)))
        self.assertTrue(place(e,'x'));self.assertTrue(place(e,'y',4,1))
        self.assertTrue(e.execute_turn('rotate_piece',dict(piece='x')).accepted)
        self.assertTrue(e.execute_turn('swap_echo',dict(piece='x')).accepted)
        self.assertEqual(e.state.variables['tiles.placements'],dict(x=[4,1,1],y=[0,0,3]))
        self.assertEqual(e.state.variables['tiles.movesUsed'],3);self.assertEqual(e.state.variables['tiles.rotationsUsed'],1);self.assertEqual(e.state.variables['tiles.echoSwaps'],1)
        before=e.state_key();self.assertFalse(e.execute_turn('swap_echo',dict(piece='y')).accepted);self.assertEqual(e.state_key(),before)
        e.undo();self.assertEqual(e.state.variables['tiles.placements'],dict(x=[0,0,0],y=[4,1,0]));self.assertEqual(e.state.variables['tiles.echoSwaps'],0)
        self.assertEqual(e.state.variables['tiles.rotationsUsed'],1)
        e.reset();self.assertEqual(e.state.variables['tiles.echoSwaps'],0)

    def test_echo_swap_rejects_blocked_partner_atomically(self):
        tiles=[dict(id='x',kind='tile',cells=[[0,0],[1,0]]),dict(id='y',kind='tile',cells=[[0,0]])]
        e=engine(dict(size=[6,3],pieces=tiles,playArea=[[x,y] for y in range(3) for x in range(6)],echoLinks=[['x','y']],echoSwap=True))
        self.assertTrue(place(e,'x'));self.assertTrue(place(e,'y',5,1))
        before=e.state_key();self.assertFalse(e.execute_turn('swap_echo',dict(piece='x')).accepted);self.assertEqual(e.state_key(),before)


if __name__ == '__main__':
    unittest.main()
