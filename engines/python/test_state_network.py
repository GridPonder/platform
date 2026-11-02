"""Generic transition, sampling and information-boundary regressions."""
import copy
import unittest
from ._game_def import GameDef
from ._turn_engine import TurnEngine
from ._systems.state_network import StateNetworkSystem
from .observation import build_prompt
from .action_enum import enumerate_actions


def fixture(op='toggle'):
    c={'inputs':['p'], 'nodes':[{'id':'n','op':op,'inputs':['p']},{'id':'m','op':'copy','inputs':['n']}], 'energy':6,'probes':{'port':'n'},'initialProbe':'port','safe':{'n':0,'m':0},'tasks':{'job':{'requires':{'n':1}}},
       'controls':{'on':{'type':'pulse','inputs':{'p':1}},'off':{'type':'pulse','inputs':{'p':0}},'mask':{'type':'clamp','target':'n'},'unmask':{'type':'clamp','target':''},'sample':{'type':'probe','target':'port'},'send':{'type':'commit','target':'job'}},'readouts':{k:k for k in ['energy','reading','journal','complete','failed']}}
    game={'layers':[{'id':'ground','occupancy':'exactly_one','default':'empty'}],'entityKinds':{'empty':{'layer':'ground','symbol':'.','tags':[]}},'actions':[{'id':a,'params':{}} for a in c['controls']],'systems':[{'id':'net','type':'state_network','config':c}], 'ui':{'readouts':[{'variable':k,'label':k} for k in c['readouts']]}}
    level={'id':'fixture','board':{'size':[1,1],'layers':{}},'state':{'avatar':{'enabled':False}},'goals':[{'id':'complete','type':'variable_threshold','config':{'variable':'complete','target':1}}], 'loseConditions':[{'type':'variable_threshold','config':{'variable':'failed','target':1}}]}
    return game,level

class NetworkTests(unittest.TestCase):
    def engine(self,op='toggle'):
        g,l=fixture(op);return TurnEngine(GameDef(g),l)
    def test_snapshot_and_order(self):
        e=self.engine();e.execute_turn('on');r=e.state.variables['__network_net']
        self.assertEqual(r['values'],{'n':1,'m':0})
        g,l=fixture();g['systems'][0]['config']['nodes'].reverse();b=TurnEngine(GameDef(g),l);b.execute_turn('on')
        self.assertEqual(r['values'],b.state.variables['__network_net']['values'])
    def test_clamp_does_not_reset_memory(self):
        e=self.engine();e.execute_turn('on');e.execute_turn('mask');e.execute_turn('off')
        r=e.state.variables['__network_net'];self.assertEqual(r['values'],{'n':1,'m':0});self.assertEqual(r['reading'],0)
        e.execute_turn('unmask');e.execute_turn('off');self.assertEqual(e.state.variables['reading'],1)
    def test_sampling_is_not_free_and_undo_is_exact(self):
        e=self.engine();e.execute_turn('on');before=e.state.copy();e.execute_turn('sample')
        self.assertEqual(e.state.variables['reading'],1);self.assertEqual(e.state.variables['energy'],5)
        e.execute_turn('off');e.undo();e.undo();self.assertEqual(e.state.variables,before.variables)
        e.reset();self.assertEqual(e.state.variables['reading'],-1)
    def test_wrong_commit_is_paid_failure_not_veto(self):
        e=self.engine();r=e.execute_turn('send');self.assertTrue(r.accepted);self.assertTrue(e.is_lost);self.assertEqual(e.state.variables['energy'],5)
    def test_final_cell_may_win(self):
        g,l=fixture('copy');g['systems'][0]['config']['energy']=4;e=TurnEngine(GameDef(g),l)
        for a in ['on','send','off','off']:e.execute_turn(a)
        self.assertTrue(e.is_won);self.assertFalse(e.is_lost);self.assertEqual(e.state.variables['energy'],0)
    def test_initial_observations_and_action_menus_match(self):
        es=[self.engine(op) for op in ['copy','toggle']]
        self.assertEqual(build_prompt(es[0]._game,es[0]._level,es[0].state),build_prompt(es[1]._game,es[1]._level,es[1].state))
        self.assertEqual(enumerate_actions(es[0]._game,es[0].state,es[0]),enumerate_actions(es[1]._game,es[1].state,es[1]))
        self.assertNotIn('__network_',build_prompt(es[0]._game,es[0]._level,es[0].state))
    def test_exhaustion_and_terminal_guard(self):
        g,l=fixture();g['systems'][0]['config']['energy']=1;e=TurnEngine(GameDef(g),l);e.execute_turn('on')
        self.assertTrue(e.is_lost);self.assertFalse(e.execute_turn('sample').accepted)
    def test_public_prerequisite_veto_is_free(self):
        g,l=fixture();c=g['systems'][0]['config']
        c['tasks']['first']={'requires':{}}
        c['tasks']['job']['after']=['first']
        c['controls']['first']={'type':'commit','target':'first'}
        g['actions'].append({'id':'first','params':{}})
        e=TurnEngine(GameDef(g),l)
        self.assertFalse(e.execute_turn('send').accepted)
        self.assertEqual(e.state.variables['energy'],6)
        e.execute_turn('first');e.execute_turn('on')
        self.assertTrue(e.execute_turn('send').accepted)
        self.assertFalse(e.is_lost)

    def test_crossing_keeps_wires_separate_and_junction_joins(self):
        from ._systems._floor_wiring import floor_sources
        floor={'tiles':[{'x':0,'y':0,'shape':'cross'}], 'terminals':[
            {'id':'x','kind':'source','x':0,'y':0,'side':'N'},
            {'id':'y','kind':'source','x':0,'y':0,'side':'W'},
            {'id':'a','kind':'sink','x':0,'y':0,'side':'S'},
            {'id':'b','kind':'sink','x':0,'y':0,'side':'E'}]}
        self.assertEqual(floor_sources(floor), {'a':['x'],'b':['y']})
        floor['tiles'][0]['shape']='junction'
        self.assertEqual(floor_sources(floor), {'a':['x','y'],'b':['x','y']})
        floor['tiles'][0]['shape']='ne'
        self.assertEqual(floor_sources(floor), {'a':['y'],'b':['x']})

    def test_counter_counts_while_clamped_and_low_input_pauses(self):
        e=self.engine('counter3')
        for a in ['on','off','mask','on','on']:
            self.assertTrue(e.execute_turn(a).accepted)
        rt=e.state.variables['__network_net']
        self.assertEqual(rt['counters']['n'],0)
        self.assertEqual(rt['values']['n'],1)
        self.assertEqual(e.state.variables['reading'],0)
        self.assertEqual(rt['values']['m'],0)
        before=copy.deepcopy(e.state.variables)
        e.execute_turn('off');e.undo()
        self.assertEqual(e.state.variables,before)
        e.reset()
        self.assertEqual(e.state.variables['__network_net']['counters']['n'],0)

    def test_latch_holds_and_reset_wins(self):
        g,l=fixture();c=g['systems'][0]['config']
        c['inputs'].append('reset')
        c['nodes'][0].update(op='latch',inputs=['p','reset'])
        c['controls']['on']['inputs']['reset']=0
        c['controls']['off']['inputs']['reset']=0
        c['controls']['clear']={'type':'pulse','inputs':{'p':1,'reset':1}}
        g['actions'].append({'id':'clear','params':{}})
        e=TurnEngine(GameDef(g),l)
        for a in ['on','off','off']:e.execute_turn(a)
        self.assertEqual(e.state.variables['reading'],1)
        e.execute_turn('clear')
        self.assertEqual(e.state.variables['reading'],0)

    def test_validation(self):
        g,_=fixture();c=g['systems'][0]['config'];c['nodes'][0]['inputs']=['missing']
        with self.assertRaises(ValueError):StateNetworkSystem('net',c)

if __name__=='__main__':unittest.main()
