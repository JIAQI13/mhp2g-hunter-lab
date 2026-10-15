#!/usr/bin/env python3
"""Offline selected PMO skinning; bounded raw-word mathematics, no target execution."""
import argparse
import json
import math
import struct
import time
from pathlib import Path
from types import SimpleNamespace

import hunter_clip_probe as clip
import hunter_mesh_probe as mesh
import hunter_world_probe as world

ROOT = Path(__file__).resolve().parents[1]


def error(a, b):
    return max(abs(x-y) for ra, rb in zip(a, b) for x, y in zip(ra, rb))


def diagonal(values):
    result = world.identity_matrix()
    for i, value in enumerate(values):
        result[i][i] = value
    return result


class SkinWords(world.WordModel):
    def step(self, word, pc):
        vd, vs, vt = word & 127, (word >> 8) & 127, (word >> 16) & 127
        n = 1 + ((word >> 7) & 1) + 2*((word >> 15) & 1)
        code = word & 0xff800000
        if code in (0x63800000, 0x64800000):
            s, t = self.read_vf(world.vector_regs(vs, n)), self.read_vf(world.vector_regs(vt, n))
            if code == 0x64800000:
                self.write_vf(world.vector_regs(vd, 1), [sum(x*y for x, y in zip(s, t))])
            else:
                clip.require(all(x != 0 for x in t), 'zero inverse producer divisor')
                self.write_vf(world.vector_regs(vd, n), [x/y for x, y in zip(s, t)])
        elif word & 0xffff0000 in (0xd0160000, 0xd0460000):
            s = self.read_vf(world.vector_regs(vs, n))
            if word & 0xffff0000 == 0xd0160000:
                clip.require(all(x >= 0 for x in s), 'negative sqrt')
                self.write_vf(world.vector_regs(vd, n), [math.sqrt(x) for x in s])
            else:
                self.write_vf(world.vector_regs(vd, 1), [sum(s)])
        else:
            return super().step(word, pc)
        self.executed.add((pc, word))


def inverse_producer(programs, local, parent):
    model = SkinWords(programs)
    model.gpr[4], model.gpr[5] = 0x2000, 0x3000
    model.put_matrix(0x2150, local)
    model.put_matrix(0x3000, parent)
    model.run(0x08860534, stop=0x08860604)
    return model.matrix(0x2090), model.matrix(0x2010)


def render_producer(programs, inverse, current):
    model = SkinWords(programs)
    model.gpr[4] = 0x2000
    model.put_matrix(0x2010, inverse)
    model.put_matrix(0x2090, current)
    model.run(0x08860640, stop=0x08860690)
    return model.matrix(0x2050)


def hierarchy_producer(programs, pose_matrix, node_scale, parent_collision, parent_model, body_scale):
    model = SkinWords(programs)
    model.gpr[4], model.gpr[5], model.gpr[6] = 0x2000, 0x3000, 0x4000
    model.fpr[12:15] = list(body_scale)
    model.put_matrix(0x2150, pose_matrix)
    model.put_matrix(0x3000, parent_collision)
    model.put_matrix(0x4000, parent_model)
    for i, value in enumerate(node_scale):
        model.mem[0x2190+4*i] = float(value)
    model.run(0x08860320, stop=0x088604c8)
    return model.matrix(0x2090), model.matrix(0x20d0)


def weapon_type0_word(programs, nodes):
    model = SkinWords(programs)
    model.gpr[19] = 0x2000
    model.gpr[9], model.gpr[8], model.gpr[7] = 0x25f0, 0x2840, 0x3f800000
    model.fpr[2], model.fpr[1], model.fpr[0] = nodes[2]['translation']
    model.fpr[5], model.fpr[4], model.fpr[3] = nodes[3]['translation']
    for offset in (0xf0,0xf4,0xf8):
        model.mem[model.gpr[29]+offset] = 1.0
    model.run(0x088d68b0,start=0x088d7174,stop=0x088d71e0)
    model.step(programs[0x088d68b0][(0x088d71e4-0x088d68b0)//4],0x088d71e4)
    return {2:model.matrix(0x25f0),3:model.matrix(0x2840)}


def ge_float24(matrix):
    result = world.identity_matrix()
    for j in range(4):
        for i in range(3):
            bits = struct.unpack('<I', struct.pack('<f', matrix[i][j]))[0]
            result[i][j] = struct.unpack('<f', struct.pack('<I', bits & 0xffffff00))[0]
    return result


def skin(vertex, matrices):
    clip.require(vertex['weighted_nodes'] and sum(vertex['weights']) == 1, 'missing or nonunit real weights')
    p = [0.0]*3
    for weight in vertex['weighted_nodes']:
        q = world.transform(matrices[weight['node']], vertex['position'])
        p = [x+weight['weight']*y for x, y in zip(p, q)]
    return p


def bind_pose(node):
    return node['scale']+node['rotation_euler']+node['translation']


def hierarchy(programs, nodes, matrices, scales, body_scale, collision_parent, model_parent):
    currents, collisions = {}, {}
    visiting = set()
    def visit(i):
        if i in currents:
            return
        clip.require(i not in visiting, 'cyclic skin hierarchy')
        visiting.add(i)
        parent = nodes[i]['parent_candidate']
        if parent != -1:
            visit(parent)
        currents[i], collisions[i] = hierarchy_producer(programs, matrices[i], scales[i],
            collision_parent if parent == -1 else collisions[parent],
            model_parent if parent == -1 else currents[parent], body_scale)
        visiting.remove(i)
    for i in range(len(nodes)):
        visit(i)
    return currents, collisions


def rest_hierarchy(programs, resource):
    rests, inverses, globals_ = {}, {}, {}
    nodes = resource['bind_nodes']
    p_inv = diagonal([1/x for x in resource['pmo_scale']])
    def visit(i):
        if i in rests:
            return
        parent = nodes[i]['parent_candidate']
        if parent != -1:
            visit(parent)
        local = world.bind_word(programs, bind_pose(nodes[i]))
        rests[i], inverses[i] = inverse_producer(programs, local, p_inv if parent == -1 else rests[parent])
        globals_[i] = world.multiply(world.identity_matrix() if parent == -1 else globals_[parent], local)
        world.close(rests[i], world.multiply(p_inv, globals_[i]), 1e-8)
    for i in range(len(nodes)):
        visit(i)
    return rests, inverses, globals_


def matrix_tests(programs):
    results = []
    cases = [('rotated anisotropic orthogonal columns', world.bind_word(programs,[2,3,4,.31,-.57,.92,1,2,3]), world.identity_matrix()),
             ('rotated parent rigid + child anisotropic', world.bind_word(programs,[2,3,4,.31,-.57,.92,1,2,3]), world.bind_word(programs,[1,1,1,.7,.2,-.4,7,8,9])),
             ('anisotropic PMO inverse + rotated child (nonorthogonal)', world.bind_word(programs,[1,1,1,.31,-.57,.92,1,2,3]),diagonal([.5,1/3, .25])),
             ('anisotropic rotated parent + rotated child (shear)',world.bind_word(programs,[1,1,1,.31,-.57,.92,1,2,3]),world.bind_word(programs,[2,3,4,.7,.2,-.4,7,8,9]))]
    for name, local, parent in cases:
        rest, inverse = inverse_producer(programs, local, parent)
        expected_rest = world.multiply(parent, local)
        world.close(rest, expected_rest)
        norm2 = [sum(rest[k][i]**2 for k in range(3)) for i in range(3)]
        formula = world.identity_matrix()
        for i in range(3):
            for j in range(3):
                formula[i][j] = rest[j][i]/norm2[i]
            formula[i][3] = -sum(formula[i][j]*rest[j][3] for j in range(3))
        world.close(inverse, formula)
        residual = error(world.multiply(rest,inverse),world.identity_matrix())
        results.append({'case':name,'raw_formula_error':error(inverse,formula),'inverse_residual':residual,
                        'inverse_applicability':'supported' if residual < 1e-8 else 'unknown_nonorthogonal_not_general_inverse'})
    clip.require(all(r['inverse_residual'] < 1e-8 for r in results[:2]), 'orthogonal inverse case failed')
    clip.require(all(r['inverse_residual'] > .01 for r in results[2:]), 'nonorthogonal inverse limitation missed')
    pose = world.bind_word(programs,[1,1,1,.31,-.57,.92,1,2,3])
    model_parent = world.bind_word(programs,[2,3,4,.7,.2,-.4,7,8,9])
    collision_parent = world.bind_word(programs,[1,1,1,-.2,.1,.9,100,200,300])
    body = [1.5,.75,2]
    current, collision = hierarchy_producer(programs,pose,[2,3,4],collision_parent,model_parent,body)
    local = world.multiply(world.multiply(diagonal([1/x for x in body]),pose),diagonal([x*y for x,y in zip([2,3,4],body)]))
    # Translation is loaded independently after scale compensation.
    for i in range(3):
        local[i][3] = pose[i][3]
    world.close(current,world.multiply(model_parent,local))
    world.close(collision,world.multiply(collision_parent,local))
    render = render_producer(programs,model_parent,collision_parent)
    world.close(render,world.multiply(collision_parent,model_parent))
    rejected = False
    try:
        inverse_producer(programs,diagonal([0,1,1]),world.identity_matrix())
    except ValueError:
        rejected = True
    clip.require(rejected,'singular inverse accepted')
    return {'inverse_cases':results,'nonuniform_body_scale_and_distinct_parent_checks':'passed',
            'render_order_current_times_inverse':'passed','singular_rejected':True,
            'precision':'float64 raw-word equations; not PSP execution/rounding conformance'}


def run(args):
    started = time.perf_counter()
    prior_names = ('hunter_world','hunter_mesh','hunter_mesh_data','hunter_clip','hunter_resources')
    prior = {name:json.loads((ROOT/'analysis'/f'{name}.json').read_text()) for name in prior_names}
    clip.require(prior['hunter_clip']['report_contract_version'] == 2,'requires clip v2')
    eboot = (ROOT/world.EBOOT).read_bytes()
    clip.require(clip.identity(ROOT/world.EBOOT) == clip.EXPECTED[world.EBOOT],'EBOOT identity mismatch')
    programs, sources = {}, []
    for address,size in (list(world.FUNCTIONS.items())+[(0x08860534,268),(0x088d68b0,7148),(0x08864774,2248),(0x08867894,664)]):
        begin = address-clip.BASE+clip.ORIGIN
        data, provenance = clip.source_range(ROOT/world.EBOOT,begin,begin+size,clip.EXPECTED[world.EBOOT])
        programs[address] = list(struct.unpack('<'+'I'*(size//4),data))
        provenance.update({'virtual_address_range':[hex(address),hex(address+size)],'words':[hex(w) for w in programs[address]]})
        sources.append(provenance)
    validation = matrix_tests(programs)
    resources = [mesh.parse_pack(p,eboot) for p in mesh.PACKS]
    clip.require(json.loads(json.dumps(resources)) == prior['hunter_mesh_data']['resources'],'retained mesh data mismatch')
    params = prior['hunter_world']['parameters']
    args_world = SimpleNamespace(angles=params['entity_angles_radians'],position=params['initial_entity_position'],
                                scale=params['entity_uniform_scale'],step=params['step_animation_units'])
    fresh_world = world.run(args_world)
    clip.require(fresh_world['trajectory'] == prior['hunter_world']['trajectory'],'retained world trajectory mismatch')
    states, summaries = [], []
    for resource, expected in zip(resources,((916,178,798),(481,137,372))):
        v = resource['validation']
        clip.require(v['unknown_batches'] == 0 and v['all_weight_sums_exact_one'] and v['primitive_counts_match'],'incomplete mesh')
        clip.require((v['unique_referenced_vertex_records'],v['draw_count'],v['assembled_triangle_count']) == expected,'mesh coverage regression')
        refs, vertices, topology = [], [], []
        for group in resource['groups']:
            for batch in group['batches']:
                for di,draw in enumerate(batch['draws']):
                    start = len(vertices)
                    ids = {int(key):start+i for i,key in enumerate(draw['vertices'])}
                    for key,vertex in draw['vertices'].items():
                        refs.append([group['index'],batch['index'],di,int(key)])
                        vertices.append(vertex)
                    topology.append({'ref':[group['index'],batch['index'],di],'primitive':draw['primitive'],
                                     'count':draw['count'],'triangles':[[ids[i] for i in tri] for tri in draw['triangles']]})
        rests,inverses,globals_ = rest_hierarchy(programs,resource)
        residual = max(error(world.multiply(rests[i],inverses[i]),world.identity_matrix()) for i in rests)
        exact_inverse = residual < 1e-12
        matrices = [world.pose_word(programs,bind_pose(n)) for n in resource['bind_nodes']]
        scales = [n['scale'] for n in resource['bind_nodes']]
        currents,_ = hierarchy(programs,resource['bind_nodes'],matrices,scales,[1]*3,world.identity_matrix(),world.identity_matrix())
        bind_skin = {i:render_producer(programs,inverses[i],currents[i]) for i in inverses}
        ideal = [skin(v,bind_skin) for v in vertices]
        quantized = [skin(v,{i:ge_float24(m) for i,m in bind_skin.items()}) for v in vertices]
        bind_error = max(math.dist(p,v['pmo_scaled_position']) for p,v in zip(ideal,vertices))
        if exact_inverse:
            clip.require(bind_error < 1e-7,'exact-inverse bind recovery failed')
        negative = [skin(v,currents) for v in vertices]
        wrong_error = max(math.dist(p,v['pmo_scaled_position']) for p,v in zip(negative,vertices))
        clip.require(wrong_error > 1,'negative control unexpectedly passes')
        summaries.append({'pack_id':resource['pack_id'],'status':'conditional_producer_model',
                          'inverse_applicability':'verified' if exact_inverse else 'unknown_exact_inverse_nonorthogonal_rest',
                          'bind_recovery':'exact_within_float64_error' if exact_inverse else 'measured_approximation_not_exact',
                          'identity':resource['identity'],
                          'coverage':v,'referenced_vertex_records':len(vertices),'bind_inverse_max_residual':residual,
                          'bind_geometry_max_error':bind_error,'bind_GE_float24_max_error':max(math.dist(p,q) for p,q in zip(ideal,quantized)),
                          'bind_GE_float24_geometry_recovery_max_error':max(math.dist(p,v['pmo_scaled_position']) for p,v in zip(quantized,vertices)),
                          'negative_control_current_or_collision_direct_skin_max_error':wrong_error,
                          'pmo_scale':resource['pmo_scale'],'bind_bounds':mesh.bounds(ideal),
                          'nodes':[{'index':i,'parent':n['parent_candidate'],'bind_local_rows':world.bind_word(programs,bind_pose(n)),
                                    'normalized_rest_plus90_rows':rests[i],'inverse_bind_plus10_rows':inverses[i],
                                    'inverse_residual':error(world.multiply(rests[i],inverses[i]),world.identity_matrix()),
                                    'source_scale_rotation_translation':bind_pose(n)} for i,n in enumerate(resource['bind_nodes'])]})
        states.append({'resource':resource,'refs':refs,'vertices':vertices,'topology':topology,'inverses':inverses,'globals':globals_,
                       'bind_matrices':matrices,'scales':scales})
    weapon = states[1]
    candidates = mesh.geometric_candidates(weapon['resource'])
    axis = candidates['longest_axis']
    endpoint_indices = {end:[i for i,v in enumerate(weapon['vertices']) if v['pmo_scaled_position'][axis] ==
                           weapon['resource']['pmo_scaled_input_bounds'][end][axis]] for end in ('min','max')}
    offset = fresh_world['attachment']['translation']
    angles = fresh_world['attachment']['rotation_radians']
    display_scale = struct.unpack('<f',struct.pack('<I',0x3f4ccccd))[0]
    blade_scale = struct.unpack('<f',struct.pack('<I',0x3f3ae148))[0]
    type0_nodes = weapon_type0_word(programs,weapon['resource']['bind_nodes'])
    for node,values in ((2,[1,1,blade_scale]),(3,[1,1,1])):
        expected_matrix = diagonal(values)
        for i in range(3):
            expected_matrix[i][3] = weapon['resource']['bind_nodes'][node]['translation'][i]
        world.close(type0_nodes[node],expected_matrix)
    validation['weapon_type0_raw_node2_node3_checks'] = '088d7174..088d71e4 passed; translations preserved, node2 z=.73'
    decoded_clip = clip.run()
    bound = {n['bound_skeleton_node']:n for c in decoded_clip['clips'] for n in c['nodes']}
    def components(time):
        poses = []
        for bone in decoded_clip['skeleton']['nodes']:
            pose = list(bone['bind_components_S_R_T'])
            for channel in bound[bone['index']]['channels']:
                pose[channel['component_index']] = clip.sample(channel['keys'],time)*channel['factor']
            poses.append(pose)
        root = decoded_clip['skeleton']['nodes'][decoded_clip['skeleton']['roots'][0]]['first_child']
        poses[root][6:9] = [0.0]*3
        return poses
    frames, endpoints = [], []
    scale = params['entity_uniform_scale']
    for source_frame in fresh_world['trajectory']:
        entity = world.entity_word(programs,args_world.angles,scale,source_frame['entity_position_unconstrained_model'])
        poses = components(source_frame['pose_uint_time'])
        body_rotations = [world.pose_word(programs,pose) for pose in poses]
        body_scales = [pose[:3] for pose in poses]
        current_body, collision_body = hierarchy(programs,states[0]['resource']['bind_nodes'],body_rotations,body_scales,
                                                 [scale]*3,entity,world.identity_matrix())
        for i in current_body:
            world.close(collision_body[i],source_frame['nodes'][i]['world_matrix_rows'],1e-7)
        attach = [list(row) for row in current_body[10]]
        attach_origin = world.transform(attach,offset)
        for i in range(3):
            attach[i][3] = attach_origin[i]
        weapon_matrices = [[list(row) for row in m] for m in weapon['bind_matrices']]
        weapon_matrices[0] = world.rotation(angles)
        for i in range(3):
            for j in range(3):
                weapon_matrices[0][i][j] *= display_scale
        # Runtime type0 branch replaces node2 +150 with identity and z=.73,
        # preserving its +180 translation; node3 is identity, preserving translation.
        for node,matrix in type0_nodes.items():
            weapon_matrices[node] = matrix
        current_weapon, _ = hierarchy(programs,weapon['resource']['bind_nodes'],weapon_matrices,weapon['scales'],[1]*3,
                                       entity,attach)
        packs = []
        for state,current in zip(states,(current_body,current_weapon)):
            matrices = {i:render_producer(programs,state['inverses'][i],current[i]) for i in current}
            quantized = {i:ge_float24(m) for i,m in matrices.items()}
            posed = [world.transform(entity,skin(v,quantized)) for v in state['vertices']]
            ideal = [world.transform(entity,skin(v,matrices)) for v in state['vertices']]
            clip.require(all(math.isfinite(x) for p in posed for x in p),'nonfinite skin output')
            packs.append({'pack_id':state['resource']['pack_id'],'skin_plus50_model_rows':[matrices[i] for i in current],
                          'GU_float24_model_rows':[quantized[i] for i in current],'world_positions':posed,
                          'world_bounds':mesh.bounds(posed),'GE_float24_vs_ideal_max_error':max(math.dist(a,b) for a,b in zip(posed,ideal))})
        frames.append({'call_index':source_frame['call_index'],'requested_clip_position':source_frame['requested_clip_position'],
                       'pose_uint_time':source_frame['pose_uint_time'],'end_clamped':source_frame['end_clamped'],
                       'entity_matrix_rows':entity,'packs':packs})
        endpoints.append({'call_index':source_frame['call_index'],'pose_uint_time':source_frame['pose_uint_time'],
                          'candidates':{end:[{'vertex_frame_index':i,'ref':weapon['refs'][i],
                                             'world_position':packs[1]['world_positions'][i]} for i in ids]
                                        for end,ids in endpoint_indices.items()}})
    clip.require(any(math.dist(endpoints[0]['candidates']['max'][0]['world_position'],f['candidates']['max'][0]['world_position']) > 1
                     for f in endpoints[1:]),'constant endpoint trajectory')
    validation.update({'resources':summaries,'frames':len(frames),'vertex_skin_evaluations':sum(len(s['vertices']) for s in states)*len(frames),
                       'primitive_triangles_per_frame':sum(s['resource']['validation']['assembled_triangle_count'] for s in states),
                       'all_finite':True,'endpoint_trajectory_nonconstant':True})
    code_names = ('08860054','08860534','08860640','08860320','088640f0','08867894','08864774','088d68b0','088d849c','088d1c10')
    report = {'report_contract_version':1,'task':'S','status':'conditional_producer_model_with_inverse_unknowns',
              'evidence_kind':'original selected PMO and raw MIPS/VFPU word mathematical interpretation; not native execution; no REA Evidence ID',
              'selection':fresh_world['selection'],'sources':sources,
              'prior_reports':[{'path':str(ROOT/'analysis'/f'{n}.json'),'sha256':clip.identity(ROOT/'analysis'/f'{n}.json')} for n in prior_names],
              'code_sources':[{'path':str(ROOT/'decomp'/f'{n}.c'),'sha256':clip.identity(ROOT/'decomp'/f'{n}.c')} for n in code_names],
              'script':{'path':str(Path(__file__).resolve()),'sha256':clip.identity(Path(__file__).resolve())},
              'matrix_math':{'storage':'columns in artifact, rows in JSON; column vectors',
                             'rest':'P=diag(PMO scales); G_i=parent bind global * local bind TRS; rest+90=P^-1*G_i',
                             'inverse_producer':'A=rest linear; q_i=dot(column_i,column_i); inverse+10 linear=diag(1/q_i)*transpose(A); t_inv=-linear*t_rest',
                             'applicability':'Exact inverse only for orthogonal nonzero columns. 3389 verifies; 1877 has tiny nonzero source rest rotations with anisotropic PMO scaling: NOT exact, residual and geometry error retained. Nonorthogonal/sheared inverse unknown; no generic inverse substituted.',
                             'current':'local=T * D(1/bodyS) * R * D(nodeS*bodyS); current+90=parent+90*local; collision+d0=parent+d0*local',
                             'skin':'drawing+50=current+90 * inverse+10; p_model=sum weights*GU_float24(+50)*[p_GE,1]; p_world=entity*p_model',
                             'bind_cancellation':'With exact inverse and unit body scale: G_i*inverse(P^-1*G_i)=P; restores P*p_GE for every real weight. 1877 producer is only approximate, measured on every vertex without snapping source rotations. Entity scale/transform applied exactly once outside GU skin.',
                             'weapon':'own 4-bone skeleton, own PMO inverse binds; parent model=node10 current+90 with rotated offset translation; node0 local=.8*R_attachment; node2 local diag(1,1,.73) with retained rest T; node3 identity with retained rest T; own +50 skins vertices before entity transform'},
              'evidence_locations':['08867894:121-128 reciprocal PMO scales ->08860534','08860534 raw 08860574 normalized rest multiply, 088605a4..08860600 inverse producer',
                                    '08860320 raw 088604c8 is end of both distinct hierarchy outputs','08860640 raw 08860640..08860690 current*inverse ->+50',
                                    '08864774 +50 twelve-float GU upload; float32 bits>>8',
                                    '088d68b0:235-250,299-339 current+90 node10 attachment (NOT+d0)',
                                    '088d68b0:488-566 node0 attachment rotation/.8; 567-630 type0 node2 .73/node3 identity;1293-1294 own hierarchy then+50'],
              'parameters':fresh_world['parameters'],'conditions':fresh_world['parameters']['conditions']+[
                  'selected 1877 slot0 only, selected 3389 equipmentID1/type0; not current live player',
                  'weapon own remaining nodes use resource rest pose; no accessory/effect mutation by 088d1c10, no sheath switching',
                  'GE matrix float24 truncation model applied after mathematical f32 conversion; PSP intermediate rounding not emulated'],
              'validation':validation,'weapon_endpoints':{'status':'端点候选非已证解剖剑尖','longest_axis':axis,'input_spans':candidates['spans'],
                  'selection_rule':'BOTH exact extrema along longest AABB axis in PMO-scaled GE input; every tied referenced vertex retained, no collision capsule substituted',
                  'vertices':{end:[{'vertex_frame_index':i,'ref':weapon['refs'][i],'source':weapon['vertices'][i]} for i in ids] for end,ids in endpoint_indices.items()},
                  'trajectory':endpoints},
              'unknowns':['actual equipment/body identity, other five body parts and materials/visibility','weapon effects/resource+7f4 dynamic inputs not verified; conditional no-mutation pose only',
                          'nonorthogonal rest inverse applicability explicitly unknown; synthetic limitation checks retained',
                          'PSP float32/VFPU trig/dot intermediate rounding; GE float24 output alone is not hardware conformance',
                          'anatomical sword-tip/handle assignment, world constraints, orientation/front/up and time Hz'],
              'unsupported_matrix_operations':[], 'measurement':{'elapsed_seconds_before_serialization':time.perf_counter()-started,
                  'tokens':None,'cold_warm_comparison':None,'CPU_and_process_family_peak_memory':None,'performance_improvement_claim':False}}
    frame_report = {'contract_version':1,'space':'conditional unconstrained entity world, numeric axes, GE float24 skin matrices; no engine conversion',
                    'selection':report['selection'],'conditions':report['conditions'],'mesh_owner':str(ROOT/'analysis/hunter_mesh_data.json'),
                    'resources':[{'pack_id':s['resource']['pack_id'],'vertex_refs':s['refs'],'topology':s['topology']} for s in states],
                    'frames':frames}
    return report,frame_report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check',action='store_true',help='validate without writing outputs')
    args = parser.parse_args()
    try:
        report,frames = run(args)
    except (world.UnsupportedWord,mesh.Unsupported,ValueError) as exc:
        print(json.dumps({'task':'S','status':'unknown','reason':str(exc),'trajectory':None},ensure_ascii=False))
        raise SystemExit(2)
    if not args.check:
        frame_path = ROOT/'analysis/hunter_skin_frames.json'
        frame_path.write_text(json.dumps(frames,ensure_ascii=False,separators=(',',':'),allow_nan=False)+'\n')
        report['neutral_mesh_frames'] = {'path':str(frame_path),'sha256':clip.identity(frame_path),'frame_count':len(frames['frames'])}
        (ROOT/'analysis/hunter_skin.json').write_text(json.dumps(report,ensure_ascii=False,indent=2,allow_nan=False)+'\n')
    else:
        retained = json.loads((ROOT/'analysis/hunter_skin.json').read_text())
        saved_frames = json.loads((ROOT/'analysis/hunter_skin_frames.json').read_text())
        clip.require(saved_frames == frames,'retained frame mismatch')
        clip.require(retained['validation'] == report['validation'] and retained['weapon_endpoints'] == report['weapon_endpoints'],'retained validation/endpoint mismatch')
    print(json.dumps({'status':report['status'],'frames':report['validation']['frames'],
                      'resources':[{'pack_id':r['pack_id'],'bind_error':r['bind_geometry_max_error'],'GE_float24_bind_error':r['bind_GE_float24_max_error'],
                                    'referenced_vertices':r['coverage']['unique_referenced_vertex_records']} for r in report['validation']['resources']],
                      'matrix_tests':report['validation']['inverse_cases'],'first_endpoints':report['weapon_endpoints']['trajectory'][0],
                      'last_endpoints':report['weapon_endpoints']['trajectory'][-1]},ensure_ascii=False))


if __name__ == '__main__':
    main()
