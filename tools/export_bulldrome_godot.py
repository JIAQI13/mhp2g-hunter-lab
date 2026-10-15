#!/usr/bin/env python3
"""Author standalone Godot curves/skin from the verified offline facts owner."""
import copy
import hashlib
import json
import math
import resource
import struct
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
import bulldrome_assets_probe as owner
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'godot-hunter-lab'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, reason):
    if not condition:
        raise ValueError('unsupported: ' + reason)


def export():
    started, cpu = time.perf_counter(), time.process_time()
    path = ROOT / 'analysis/bulldrome_asset_data.json'
    asset = json.loads(path.read_bytes())
    summary = json.loads((ROOT / 'analysis/bulldrome_assets.json').read_bytes())
    behavior_path = ROOT / 'analysis/bulldrome_behavior.json'
    behavior = json.loads(behavior_path.read_bytes())
    require(asset['schema'] == 2 and digest(path) == summary['asset_data_sha256'], 'schema2 facts identity')
    validation = owner.validate_export(path)
    pack = asset['packs'][0]
    require(pack['runtime_pack_id'] == 6127, 'target identity')
    resources = pack['resources']
    skeleton = resources['skeleton']['original_parsed']
    roots = skeleton['roots']
    # 08867894: model+110 selects first root; root+14c is source first_child.
    require(len(roots) == 1, 'unverified model root selection')
    root = skeleton['nodes'][roots[0]]['first_child']
    require(root >= 0 and skeleton['nodes'][root]['track_group'] == 0, 'disabled/unbound root extraction')
    bones = [{'parent': n['parent'], 'group': n['track_group'], 'defaults': n['bind_components_S_R_T']}
             for n in skeleton['nodes']]
    require(all(-1 <= b['parent'] < i and b['group'] == 0 for i, b in enumerate(bones)), 'parent-first single group')
    require(behavior['observations']['playback_channel_count']['raw_hex'] == '01', 'runtime track count')
    binding = next(s['track_to_bone'] for s in resources['animation_binding']['streams'] if s['stream_id'] == 0)
    require(root in binding, 'root binding')
    clips, canonical, slots = {}, {}, []
    evaluations = keys_checked = 0
    curve_goldens = []
    for stream in resources['animation']['streams']:
        for slot in stream['slots']:
            cid = slot['clip_id']
            runtime = 1000 + slot['slot_id'] + 200 * stream['stream_id']
            slots.append({'runtime_id': runtime, 'group': stream['stream_id'], **slot})
            if cid is None:
                continue
            require(stream['stream_id'] == 0, 'unexpected live secondary stream')
            parsed = owner.sampling_clip(cid, resources['animation']['clips'][cid], binding)
            key = f'{runtime}:0'
            if cid not in canonical:
                canonical[cid] = key
                nodes = []
                for raw_node in resources['animation']['clips'][cid]['tracks']:
                    channels = []
                    for channel in raw_node['channels']:
                        keys = channel['keys_source_units']
                        require(keys == [[v * channel['factor'], t, mi * channel['factor'], mo * channel['factor']]
                                         for v, t, mi, mo in channel['keys_raw']], 'normalized key provenance')
                        times = [k[1] for k in keys] + [(a[1] + b[1]) / 2 for a, b in zip(keys, keys[1:])]
                        samples = []
                        for t in times:
                            expected = owner.clip_parser.sample(channel['keys_raw'], t) * channel['factor']
                            actual = owner.clip_parser.sample(keys, t)
                            require(math.isclose(actual, expected, abs_tol=1e-9, rel_tol=1e-10), 'curve normalization')
                            samples.append([t, expected])
                        curve_goldens.append({'key': key, 'node': len(nodes), 'channel': len(channels), 'samples': samples})
                        evaluations += len(times)
                        keys_checked += len(keys)
                        channels.append({'component': channel['component_index'], 'keys': keys, 'source': channel['source']})
                    nodes.append({'channels': channels})
                clips[key] = {'end': parsed.end, 'loop': parsed.loop, 'loop_start': parsed.loop_start,
                              'bindings': list(parsed.bindings), 'nodes': nodes,
                              'source_clip_id': cid, 'source': resources['animation']['clips'][cid]['source']}
            else:
                clips[key] = clips[canonical[cid]]
    require(len(canonical) == 31 and len(clips) == 31 and keys_checked == 30061, 'clip/slot/key coverage')
    selections = []
    for record in behavior['derivations']['animation_selection_records']:
        stream, slot_id = record['resource_stream'], record['resource_slot']
        slot = resources['animation']['streams'][stream]['slots'][slot_id]
        cid = slot['clip_id']
        require(record['channel0_runtime_id'] == 1000 + slot_id and stream == 0, 'behavior runtime/slot mapping')
        require(int(record['resource']['raw_offset'], 16) == slot['raw_offset_id'], 'behavior original clip offset')
        if cid is not None:
            require(record['resource']['clip']['sha256'] == resources['animation']['clips'][cid]['source']['range_sha256'], 'behavior selected clip digest')
        selections.append(dict(record, clip_key=f"{record['channel0_runtime_id']}:0" if cid is not None else None,
                               supported=cid is not None))
    require(sum(r['supported'] for r in selections) == 31, 'resolved behavior/resource selection coverage')
    model = resources['model']
    programs = {int(s['virtual_address'], 16): list(struct.unpack('<' + 'I' * (len(bytes.fromhex(s['raw_hex'])) // 4), bytes.fromhex(s['raw_hex'])))
                for s in asset['semantics']['sources']}
    bind_nodes = [{'parent_candidate': b['parent'], 'scale': b['scale'], 'rotation_euler': b['rotation'], 'translation': b['position']}
                  for b in resources['skeleton']['bones']]
    _, inverses, _ = owner.skin.rest_hierarchy(programs, {'bind_nodes': bind_nodes, 'pmo_scale': model['scale_source']})
    surfaces = {}
    for group in model['groups']:
        material = group['material_index']
        require(material is not None and group['morph_count'] == 1, 'unresolved material/morph')
        surface = surfaces.setdefault(material, {'material': material, 'vertices': [], 'uvs': [], 'indices': [], 'source_groups': []})
        offset = len(surface['vertices'])
        surface['source_groups'].append({k: group[k] for k in ('group_id', 'bone_palette_patches', 'bone_palette_resolved', 'vertex_type_word')})
        require(len(group['uvs']) == len(group['positions_ge_normalized']), 'missing UV')
        for point, influences in zip(group['positions_ge_normalized'], group['influences'], strict=True):
            require(influences and sum(w for _, w in influences) == 1, 'nonunit weights')
            vertex = []
            for bone, weight in influences:
                if weight:
                    require(0 <= bone < len(bones), 'unresolved bone palette')
                    vertex.append({'bone': bone, 'local_bind': owner.world.transform(inverses[bone], point)[:3], 'weight': weight})
            surface['vertices'].append(vertex)
        surface['uvs'].extend([[uv[i] * group['uv_scale_source'][i] for i in range(2)] for uv in group['uvs']])
        surface['indices'].extend(offset + index for triangle in group['triangles'] for index in triangle)
    texture = resources['texture_bank']['images'][0]
    require(len(resources['texture_bank']['images']) == 1 and texture['decode_status'] == 'decoded_palette0', 'texture decode')
    texture_path = Path(texture['preview_path'])
    with Image.open(texture_path) as image:
        require(owner.digest(image.convert('RGBA').tobytes()) == texture['rgba_sha256'], 'texture RGBA identity')
        image.save(PROJECT / 'assets/bulldrome_texture.png')
    mesh = {'schema_version': 1, 'display_scale': 0.01, 'axis_conversion': 'none',
            'surfaces': list(surfaces.values()), 'materials': model['materials'],
            'textures': [{'path': 'res://assets/bulldrome_texture.png', 'source': texture,
                          'png_sha256': digest(PROJECT / 'assets/bulldrome_texture.png')}],
            'skin_rule': 'sum(weight * world_pose[bone] * local_bind); local_bind=original_inverse*GE_normalized_position; root T cleared by Animator, entity delta only by controller',
            'source_members': [pack['members'][model['member_id']], pack['members'][resources['texture_bank']['member_id']]],
            'vertex_count': 1578, 'triangle_count': 1336}
    geometry = behavior['derivations']['attack_geometry']
    artifacts = {}
    for artifact in behavior['provenance']['artifacts']:
        artifact_path = Path(artifact['path'])
        require(digest(artifact_path) == artifact['sha256'], 'behavior artifact identity')
        artifacts[artifact['region']] = artifact_path.read_bytes()
    def verify_evidence(evidence):
        begin = int(evidence['file_offset'], 16)
        raw = artifacts[evidence['region']][begin:begin + evidence['size']]
        require(raw.hex() == evidence['raw_hex'] and owner.digest(raw) == evidence['sha256'], 'behavior original byte range')
    verify_evidence(behavior['observations']['playback_channel_count'])
    for record in behavior['observations']['attack_records']:
        verify_evidence(record['evidence'])
    for volume in behavior['observations']['hitshape_raw_ranges']:
        verify_evidence(volume['pointer_source'])
        verify_evidence(volume['evidence'])
        verify_evidence(volume['terminator']['source'])
        for entry in volume['entries']:
            verify_evidence(entry['source'])
    records = {}
    aligned = {r['record']: r for r in geometry['record_sourcegeometry']}
    for record in behavior['observations']['attack_records']:
        index, raw = record['index'], record['bytes_u8']
        require(bytes(raw).hex() == record['evidence']['raw_hex'], 'record raw bytes')
        supported = index != 0 and aligned[index]['selector'] == index - 1
        records[str(index)] = {'id': index, 'bytes_u8': raw, 'raw_hex': record['evidence']['raw_hex'],
                              'delay_byte': raw[0], 'duration_byte': raw[1], 'byte2_raw': raw[2],
                              'shape_selector': record['volume_set_byte10'] if supported else None,
                              'supported': supported, 'unsupported_reason': None if supported else 'record0 has no verified nonnegative selector; no event/geometry inferred',
                              'selector': aligned[index]['selector'], 'verified_actor_spawn': aligned[index]['verified_actor_spawn'],
                              'transforms': record['transforms'], 'source': record['evidence']}
    shapes = {}
    for volume in behavior['observations']['hitshape_raw_ranges']:
        require(volume['terminated'] and volume['supported_geometry'], 'unclosed/unsupported shape list')
        shapes[str(volume['index'])] = volume['entries']
    require(len(records) == 7 and len(shapes) == 3, 'combat facts coverage')
    combat = {'schema_version': 1, 'records': records, 'shapes': shapes,
              'sources': behavior['provenance']['artifacts'], 'shape_lists': behavior['observations']['hitshape_raw_ranges'],
              'neutral_profile': {'sandbox_only': True, 'hp': None, 'enemy_attack': None,
                                  'rule': 'controller-configured sandbox HP/enemy attack, not original damage formula; byte2_raw is not established power'},
              'field_semantics': {'delay_byte': 'byte0 raw; node1c=raw>>1 then conditional initialization adjustments',
                                  'duration_byte': 'byte1 raw; node1d=raw>>1 with shell24 lifetime refresh',
                                  'byte2_raw': 'literal source byte2; no established power semantics',
                                  'shape_selector': 'byte10 volume set; selector field separately indexes record(selector+1)'},
              'limits': [geometry['lifetime']['boundary'], geometry['model']['boundary']]}
    sources = {str(p.relative_to(ROOT)): {'path': str(p), 'file_sha256': digest(p)} for p in
               [path, ROOT / 'analysis/bulldrome_assets.json', behavior_path, Path(__file__), ROOT / 'tools/bulldrome_assets_probe.py',
                ROOT / 'decomp/08867894.c', ROOT / 'decomp/088637bc.c']}
    data = {'schema_version': 1, 'body_pack': 6127, 'track_count': 1, 'clip_id_stride': 200, 'root_bone': root,
            'root_selection': {'model_root': roots[0], 'source_first_child': root, 'rule': '08867894 model+110 first source root; 088637bc selects root+14c, clears +180/+184/+188 once'},
            'bones': bones, 'clips': clips, 'slots': slots, 'mesh': mesh, 'combat': combat, 'initial_animation': 1001,
            'animation_selection_records': selections,
            'sources': sources, 'provenance': asset['provenance'], 'semantics': asset['semantics'],
            'limits': asset['limits'] + ['Godot CPU geometry uses recomputed normals/nearest RGBA texture, not GE render-state equivalence.',
                                        '31 occupied original resource slots; behavior selections are separate indirection metadata, not modern action names.'],
            'validation': {'unique_clips': 31, 'occupied_slots': len(clips), 'keys': keys_checked, 'normalized_evaluations': evaluations,
                           'source_validation': validation}}
    goldens = []
    for sample in asset['animation_pose_samples']:
        cid = sample['clip_id']
        channels = {int(k): copy.deepcopy(v) for k, v in sample['bone_components_S_R_T'].items()}
        channels[root][6:9] = [0.0] * 3
        poses = owner.pose_owner.make_pose(channels)
        currents, _ = owner.skin.hierarchy(programs, bind_nodes, {i: p.matrix for i, p in poses.items()},
                                           {i: p.scale for i, p in poses.items()}, [1.0] * 3,
                                           owner.world.identity_matrix(), owner.world.identity_matrix())
        render = {i: owner.skin.render_producer(programs, inverses[i], currents[i]) for i in currents}
        animated = owner.animated_model(model, render)
        # Reconstruct original retained mesh, proving the cleared-root/entity split once.
        original_render = {int(k): v for k, v in sample['bone_render_matrices'].items()}
        original = owner.animated_model(model, original_render)
        shift = [sample['bone_model_matrices'][str(root)][i][3] - currents[root][i][3] for i in range(3)]
        by_material = {}
        for group, old_group in zip(animated['groups'], original['groups'], strict=True):
            for p, old in zip(group['positions_source_units'], old_group['positions_source_units'], strict=True):
                require(max(abs(p[i] + shift[i] - old[i]) for i in range(3)) < 1e-7, 'root split/original mesh mismatch')
            by_material.setdefault(group['material_index'], []).extend(group['positions_source_units'])
        goldens.append({'key': canonical[cid], 'time': sample['display_time_source_units'],
                        'world_pose': [currents[i] for i in range(len(bones))],
                        'vertices': [by_material[m] for m in surfaces],
                        'root_float': sample['root_translation_source_units'], 'root_pose_shift': shift})
    require(len(goldens) == 93, '93 original animation poses')
    standing = next(s for s in goldens if s['key'] == '1001:0' and s['time'] == 0)
    mesh['standing_min_y'] = min(p[1] for surface in standing['vertices'] for p in surface)
    mesh['standing_calibration'] = {'runtime_id': 1001, 'pose_time': 0, 'root_cleared': True, 'scope': 'display lift only, no asset skeleton/bone mutation'}
    (PROJECT / 'assets/bulldrome_data.json').write_text(json.dumps(data, separators=(',', ':'), ensure_ascii=False, allow_nan=False) + '\n')
    (PROJECT / 'tests/bulldrome_goldens.json').write_text(json.dumps({'schema_version': 1, 'sources': sources, 'samples': goldens, 'curves': curve_goldens}, separators=(',', ':'), allow_nan=False) + '\n')
    result = {'schema_version': 1, 'unique_clips': 31, 'occupied_slots': len(clips), 'keys': keys_checked,
              'normalized_evaluations': evaluations, 'mesh_poses': len(goldens), 'vertices_per_pose': 1578,
              'root_bone': root, 'surfaces': len(surfaces), 'output_sha256': digest(PROJECT / 'assets/bulldrome_data.json'),
              'elapsed_seconds': time.perf_counter() - started, 'cpu_seconds': time.process_time() - cpu,
              'peak_rss_bytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
              'measurement_scope': 'single offline exporter; cache state unknown; tokens and before/after baseline unmeasured; no PSP runtime verification'}
    (PROJECT / 'tests/bulldrome_export_results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    export()
