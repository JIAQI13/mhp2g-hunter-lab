#!/usr/bin/env python3
"""Export verified scalar curves; Python is an authoring tool, not a runtime dependency."""
import hashlib
import json
import math
import sys
import struct
from pathlib import Path

sys.dont_write_bytecode = True
from greatsword_combat_probe import read_greatsword_records
import hunter_action_assets_probe as source
import hunter_clip_probe as curves

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'godot-hunter-lab/assets/hunter_data.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def metadata(value):
    if isinstance(value, dict):
        return {k: metadata(v) for k, v in value.items()
                if k not in ('clip_evidence', 'byte_range', 'range_sha256', 'entry_source')}
    if isinstance(value, list):
        return [metadata(v) for v in value]
    return value


def export():
    contract_path = ROOT / 'analysis/hunter_action_assets.json'
    contract = json.loads(contract_path.read_text())
    state = source.AnimationState.from_contract(contract_path, verify=True)
    sources = dict(contract['input_sources'])
    for name in ('hunter_action_assets', 'hunter_normal_contract', 'hunter_action_contract',
                 'hunter_resource_selection', 'hunter_world', 'hunter_skin'):
        path = ROOT / 'analysis' / (name + '.json')
        sources['analysis/' + path.name] = {'path': str(path), 'file_sha256': digest(path)}
    sources['tools/hunter_action_assets_probe.py'] = {
        'path': str(ROOT / 'tools/hunter_action_assets_probe.py'),
        'file_sha256': digest(ROOT / 'tools/hunter_action_assets_probe.py')}
    normal = json.loads((ROOT / 'analysis/hunter_normal_contract.json').read_text())
    bones = [{'parent': n['parent'], 'defaults': n['bind_components_S_R_T']}
             for n in contract['skeletons']['1877']['nodes']]
    for i, bone in enumerate(bones):
        source.require(-1 <= bone['parent'] < i, 'skeleton must be parent-first')
        source.require(len(bone['defaults']) == 9 and all(isinstance(x, (int, float))
                       and math.isfinite(x) for x in bone['defaults']), 'unresolved bind component')
    # 原118项保持独立黄金子集；恢复资源从原pack解析，不修改历史合同。
    original_keys = set(state.clips)
    source.require(len(original_keys) == 118, 'original clip subset regression')
    recovery_primaries = (201, 202, 204, 207, 210, 216, 1211)
    catalog = json.loads((ROOT / 'analysis/hunter_animation_catalog.json').read_text())
    type_map = {int(k): v['index'] for k, v in catalog['component_type_map'].items()}
    recovery_sources = ('analysis/hunter_recovery_contract.json',
                        'tools/hunter_recovery_reference.py', 'analysis/hunter_animation_catalog.json',
                        'decomp_ovl/09a88370.c', 'decomp_ovl/09a89730.c',
                        'decomp_ovl/09a8a1d0.c', 'decomp_ovl/09a68138.c',
                        'decomp_ovl/09a8cc70.c', 'decomp_ovl/09a8cd10.c',
                        'decomp_ovl/09a66330.c', 'decomp_ovl/09a8c180.c')
    for relative in recovery_sources:
        path = ROOT / relative
        sources.setdefault(relative, {'path': str(path), 'file_sha256': digest(path)})
    recovery_clips = {}
    recovery_packs = {}
    for pack in (61, 3377):
        relative = f'databin/{pack:04d}.bin'
        raw = (ROOT / relative).read_bytes()
        source.require(source.sha(raw) == sources[relative]['file_sha256'], 'recovery pack SHA mismatch')
        recovery_packs[pack] = (raw, source.catalog_parser.directory(raw))
    for primary in recovery_primaries:
        for aid, group in ((primary, 0), (primary + 100, 1)):
            key = f'{aid}:{group}'
            pack = 61 if aid < 1000 else 3377
            raw, directory = recovery_packs[pack]
            lookup = source.catalog_parser.locate(raw, *directory, aid)
            source.require(lookup['status'] == 'present', 'missing recovery resource: ' + key)
            start, end = lookup['byte_range']
            decoded = source.catalog_parser.decode(raw[start:end], start, type_map)
            source.require(decoded['status'] == 'parsed', 'unparsed recovery resource: ' + key)
            bindings = contract['skeletons']['1877']['group_binding_orders'][str(group)]
            source.require(len(bindings) == len(decoded['nodes']), 'recovery skeleton mapping mismatch')
            duration = decoded['summary']['end_time_consumer_max_last_key']
            loop_start = struct.unpack_from('<f', raw, start + 16)[0]
            source.require(math.isfinite(loop_start) and 0 <= loop_start <= duration, 'invalid recovery loop')
            clip = source.AnimationClip(key, group, tuple(decoded['nodes']), tuple(bindings),
                                        source.f32(duration), bool(decoded['header']['loop_enabled_raw']), loop_start)
            if key not in state.clips:
                state.clips[key] = clip
            recovery_clips[key] = {'pack': pack, 'byte_range': [start, end],
                                   'range_sha256': hashlib.sha256(raw[start:end]).hexdigest(),
                                   'end': clip.end, 'loop': clip.loop, 'loop_start': loop_start}
    clips = {}
    key_count = evaluations = 0
    for key, clip in state.clips.items():
        nodes = []
        for raw_node in clip.nodes:
            channels = []
            for channel in raw_node['channels']:
                component, factor = channel['component_index'], channel['factor']
                source.require(0 <= component <= 8 and math.isfinite(factor), 'unknown channel')
                keys = [[v * factor, t, incoming * factor, outgoing * factor]
                        for v, t, incoming, outgoing in channel['keys']]
                source.require(keys and len(keys) == channel['declared_key_count'], 'key capacity mismatch')
                source.require(all(len(k) == 4 and all(math.isfinite(x) for x in k)
                                   and 0 <= k[1] <= clip.end for k in keys), 'invalid/beyond-end key')
                source.require(all(a[1] < b[1] for a, b in zip(keys, keys[1:])), 'unordered keys')
                # Every retained key and interval midpoint, bounded by the parsed key count.
                times = [k[1] for k in keys] + [(a[1] + b[1]) / 2 for a, b in zip(keys, keys[1:])]
                for time in times:
                    expected = curves.sample(channel['keys'], time) * factor
                    actual = curves.sample(keys, time)
                    source.require(math.isclose(actual, expected, rel_tol=1e-10, abs_tol=1e-9),
                                   'normalization changed Hermite interpolation')
                evaluations += len(times)
                key_count += len(keys)
                channels.append({'component': component, 'keys': keys})
            nodes.append({'channels': channels})
        clips[key] = {'end': clip.end, 'loop': clip.loop, 'loop_start': clip.loop_start,
                      'bindings': list(clip.bindings), 'nodes': nodes}
    source.require(original_keys <= clips.keys() and clips['403:0']['loop_start'] == 62.0,
                   'original clip coverage/float loop regression')
    absent = {c['key']: metadata(c) for c in contract['clips'] if c['status'] != 'parsed'}
    actions = []
    gs_variants = []
    for row in contract['actions']:
        if row['kind'] == 'GS_type0_dispatch' and row['phases']:
            gs_variants.append(metadata(row))
        for phase in row['phases']:
            refs = phase.get('clips', [])
            source.require(all(ref in clips or ref in absent for ref in refs), 'dangling action clip reference')
            actions.append({'category': row['cate'], 'subaction': row['sub'], 'label': row['id'],
                            'primary': phase['primary'], 'blend': phase['blend_argument'],
                            'start': phase['start'] if row['kind'] == 'GS_type0_dispatch' else phase['start_frame_units'],
                            'parameter': row.get('handler_parameter'), 'role': row['kind'],
                            'when': phase['condition'] if row['kind'] == 'GS_type0_dispatch' else phase['when'], 'clips': refs,
                            'supported': all(ref in clips for ref in refs),
                            'required_runtime_arguments': phase.get('required_runtime_arguments', [])})
    source.require(len(gs_variants) == 28, 'all 28 executable GS dispatch variants required')
    attach = contract['matrix_binds']['attachment']
    attack = read_greatsword_records(ROOT)
    combat_documents = {}
    for name in ('analysis/greatsword_combat.json', 'analysis/hunter_damage_complete.json',
                 'decomp_ovl/09a861b0.c'):
        path = ROOT / name
        combat_documents[name] = {'path': str(path), 'file_sha256': digest(path)}
    citations = [
        'decomp_ovl/09b625e0.c:21-65 (record copy, shift and selector)',
        'decomp_ovl/09b635c0.c:181-205,296-305 (critical and initial delay adjustment)',
        'decomp_ovl/09b9be88.c:95-100 (record2 spawn)',
        'decomp_ovl/09b9c2b8.c:125-130 (record1 spawn)',
        'decomp_ovl/09b9d168.c:14-18 (record4 spawn)',
        'decomp_ovl/09a861b0.c:14-18 (record5 spawn, not record4)',
        'decomp_ovl/09b9e3b0.c:11-32 (release record3/91/92/93 and hunter10f0)',
        'decomp_ovl/09c32788.c:11-44 (bone-space shape transforms and kind0/1)',
        'decomp_ovl/09c3d640.c:52-108,111-209 (geometry consumers and control records)',
        'decomp_ovl/09b62940.c:11-48 (object countdown, not animation spawn timing)',
        'analysis/hunter_damage_complete.json:greatsword_to_pending_damage,target_hp_tail',
        'analysis/hunter_damage_complete.json:corrections_to_prior_reports']
    combat = {'schema_version': 1, **attack,
              'sources': {'artifacts': attack['sources'], 'documents': combat_documents,
                          'citations': citations},
              'neutral_profile': {'raw_attack': 100, 'hitzone': 100, 'physical_sharpness': 1,
                                  'hit_phase': 1, 'target_multiplier': 1, 'element': 0,
                                  'critical_multiplier': 1},
              'limits': [
                  'Neutral sandbox only: no complete original HP, equipment, hitzone, sharpness or hit-phase system.',
                  'All record bytes are raw, unshifted integers; caller converts JSON numbers to int at the runtime boundary.',
                  'Event scale belongs to the controller, never a record: base100; charged release110/120/130.',
                  'Source geometry retains original units; scene applies coordinate scale0.01 once. Collision bone poses are approximations.',
                  'Use only supported_geometry lists/entries; unknown kinds/controls and unterminated lists fail closed without guessed geometry.',
                  'Raw delay is not a true spawn frame: initialization adjustments, scheduling and lifetime extension remain caller responsibilities.',
                  'Prior D/D2 seven-record counts omit record5; these are historical reports, not verified spawn timelines.',
                  'D2 corrections apply: record+15 is event+2b visual/critical feedback, not new damage flags; local hunter attack producer is 088db81c/0885d2f8.'],
              'validation': {'record_count': len(attack['records']),
                             'shape_selector_count': len(attack['shapes']),
                             'shape_count': sum(len(v) for v in attack['shapes'].values()),
                             'artifact_sha_verified': len(attack['sources']),
                             'document_sha_verified': len(combat_documents),
                             'citation_count': len(citations)}}
    source.require(list(attack['records']) == ['1', '2', '3', '4', '5', '91', '92', '93'],
                   'greatsword record coverage mismatch')
    previous = json.loads(OUTPUT.read_text()) if OUTPUT.exists() else None
    data = {'schema_version': 1, 'sources': sources, 'body_pack': 1877, 'bones': bones,
            'clips': clips, 'absent_clips': absent, 'actions': actions, 'gs_variants': gs_variants,
            'normal_actions': metadata(normal['states']),
            'normal_metadata': metadata({k: normal[k] for k in ('variables', 'inputs', 'update_rules', 'external_events', 'unknowns')}),
            'weapon_attach': {'bone': attach['node'], 'translation': attach['translation'],
                              'Euler': attach['rotation_radians'], 'Euler_unit': 'radians',
                              'rotation_order': 'Rz * Ry * Rx', 'translation_rule': 'bone_world * R_attachment * translation',
                              'display_scale': 0.8, 'weapon_node2_z_scale': 0.73},
            'tick_rate_default': 30,
            'limits': ['tick_rate_default=30 is a configurable sandbox assumption, not original Hz.',
                       'Actor supplies raw playback_step: normal=2*rate, slow=0.2, hard freeze=0. No extra factor in animator.',
                       'Numeric source axes and units retained; scene applies uniform 0.01 once.',
                       'Animation/root math is scalar reconstruction, not VFPU bit-exact pose emulation.',
                       'Rough skeleton only; no original mesh, texture, task, monster, or weapon skin.',
                       'Main drawn weapon attachment is derived; full original sheath switching is not decoded.',
                       'Labels are static inferences; action phases/conditions are metadata, not automatically executable FSM.',
                       '1010:0 and 1110:1 are absent, end/loop unknown; no replacement animation.'],
            'validation': {'clip_count': len(clips), 'keys': key_count, 'normalized_evaluations': evaluations,
                           'source_sha_verified': len(sources), 'original_source_sha_verified': len(contract['input_sources']),
                           'original_clip_subset_count': len(original_keys), 'gs_variants': len(gs_variants)}}
    if previous is not None:
        stable = set(data) - {'sources', 'clips', 'validation'}
        source.require(all(previous[k] == data[k] for k in stable), 'existing action/skeleton data changed')
        source.require(all(previous['clips'][k] == clips[k] for k in original_keys),
                       'original 118 clip goldens changed')
        source.require(all(sources[k] == v for k, v in previous['sources'].items()),
                       'existing source provenance changed')
    data['recovery'] = {'clips': recovery_clips, 'original_clip_subset_count': len(original_keys),
                        'incoming_kind': 0, 'power_range': [0, 255],
                        'limits': ['Selected kind0 ground light/heavy only; heavy labelled sandbox down, not kind2 launch.',
                                   'Flat-ground death entry210 only; task failure/cart/respawn and subsequent223 branch unsupported.',
                                   'Guard chip sandbox: power<15 zero, power<40 floor(damage/4), otherwise floor(damage/2); not full original formula.',
                                   'HP100 and external damage are neutral sandbox values, not original equipment damage equivalence.',
                                   'Recovery locks use existing per-task internal_window timer; light adds no immunity.']}
    data['combat'] = combat
    OUTPUT.write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':'), allow_nan=False) + '\n')
    # Recheck serialized representation, not just the in-memory normalization.
    saved = json.loads(OUTPUT.read_text())
    source.require(saved['clips'] == clips, 'serialized curve mismatch')
    source.require(saved['combat'] == combat, 'serialized combat mismatch')
    for identity in combat_documents.values():
        source.require(digest(Path(identity['path'])) == identity['file_sha256'], 'combat document changed during export')
    for identity in attack['sources']:
        source.require(digest(Path(identity['path'])) == identity['sha256'], 'combat artifact changed during export')
    for identity in sources.values():
        source.require(digest(Path(identity['path'])) == identity['file_sha256'], 'source changed during export')
    print(json.dumps({'output': str(OUTPUT), 'bytes': OUTPUT.stat().st_size, **data['validation'],
                      'combat': combat['validation'], 'original_118_subset_unchanged': previous is not None,
                      'added_recovery_clips': len(set(clips) - original_keys)}))


if __name__ == '__main__':
    export()
