#!/usr/bin/env python3
"""Selective static hunter animation catalog; no game/provider execution or input writes."""
import argparse
import collections
import hashlib
import json
import math
import re
import struct
from pathlib import Path

import hunter_clip_probe as clip_probe

ROOT = Path(__file__).resolve().parents[1]
BASE, ORIGIN = 0x08804000, 0x25B4
OVL_BASE = 0x09A5A580
REPORT = ROOT / 'analysis/hunter_animation_catalog.json'


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_record(data, fmt, pos, end=None):
    end = len(data) if end is None else end
    require(0 <= pos <= pos + struct.calcsize(fmt) <= end <= len(data), 'record outside owner')
    return struct.unpack_from(fmt, data, pos)


def evidence(path, data, start=0, end=None):
    end = len(data) if end is None else end
    require(0 <= start <= end <= len(data), 'evidence outside file')
    return {'path': str(path), 'file_sha256': digest(data), 'byte_range': [start, end],
            'range_sha256': digest(data[start:end])}


def directory(data):
    first = read_record(data, '<I', 4)[0]
    require(first > 0 and first % 8 == 0 and first <= len(data), 'directory boundary invalid')
    groups, offsets, ends = [], set(), []
    for pos in range(0, first, 8):
        count, table = read_record(data, '<2I', pos, first)
        require(count <= 100 and first <= table <= table + count * 4 <= len(data), 'group capacity invalid')
        values = list(read_record(data, '<' + 'i' * count, table))
        offsets.update(v for v in values if v != -1)
        ends.append(table + count * 4)
        groups.append({'count': count, 'table_offset': table, 'entries': values})
    require(all(max(ends) <= offset <= len(data)-20 for offset in offsets), 'payload overlaps tables')
    return groups, sorted(offsets)


def locate(data, groups, offsets, animation_id):
    group, entry = divmod(animation_id % 1000, 100)
    result = {'normalized_id': animation_id % 1000, 'directory_group': group, 'entry': entry}
    if group >= len(groups) or entry >= groups[group]['count']:
        return {**result, 'status': 'absent', 'reason': 'group/entry outside stored directory'}
    start = groups[group]['entries'][entry]
    result['entry_byte_range'] = [groups[group]['table_offset']+4*entry, groups[group]['table_offset']+4*entry+4]
    if start == -1:
        return {**result, 'status': 'absent', 'reason': 'signed offset -1'}
    size = read_record(data, '<I', start+8)[0]
    boundary = next((offset for offset in offsets if offset > start), len(data))
    require(size >= 20 and start+size <= boundary, 'clip overlaps next indexed payload')
    return {**result, 'status': 'present', 'byte_range': [start, start+size],
            'range_sha256': digest(data[start:start+size]), 'next_payload_boundary': boundary,
            'gap_after_declared_clip': boundary-start-size}


def decode(data, start, type_map):
    flags, count, size, loop, loop_start = read_record(data, '<5I', 0)
    require(size == len(data) and count <= (size-20)//12, 'clip header capacity/size invalid')
    nodes, pos, unsupported = [], 20, []
    for ordinal in range(count):
        mask, channels, length = read_record(data, '<3I', pos)
        end = pos+length
        require(length >= 12 and end <= size and channels <= (length-12)//12, 'node capacity invalid')
        cursor, records, seen = pos+12, [], set()
        for _ in range(channels):
            raw_type, nkeys, clen = read_record(data, '<3I', cursor, end)
            require(clen >= 12 and cursor+clen <= end, 'channel outside node')
            kind = raw_type & 0xffff
            require(kind not in seen, 'duplicate channel component')
            seen.add(kind)
            channel = {'type_word': hex(raw_type), 'component_type': kind,
                       'byte_range': [start+cursor, start+cursor+clen],
                       'range_sha256': digest(data[cursor:cursor+clen]), 'declared_key_count': nkeys}
            # Both readers use literal signed shorts, stride8 and Hermite; high bits
            # are not a codec selector in 08863190/088630c8/08863660.
            if kind not in type_map or clen != 12+8*nkeys or nkeys == 0:
                channel.update(status='unsupported', reason='unknown component or non-stride8 key representation')
                unsupported.append(channel['byte_range'])
            else:
                require(nkeys <= (clen-12)//8, 'key allocation exceeds channel')
                keys = [list(read_record(data, '<4h', cursor+12+8*k, cursor+clen)) for k in range(nkeys)]
                require(all(a[1] < b[1] for a,b in zip(keys, keys[1:])), 'key times not strictly increasing')
                require(keys[0][1] >= 0, 'negative consumer key time')
                channel.update(status='parsed', component_index=type_map[kind],
                               component=clip_probe.COMPONENTS[type_map[kind]],
                               factor=0.0625 if kind & 0x38 == 0 else clip_probe.ROTATION_FACTOR,
                               high_flags=hex(raw_type & 0xffff0000), high_flags_meaning='unknown; ignored by selected scalar readers',
                               key_layout=['value', 'time', 'in_tangent', 'out_tangent'], keys=keys,
                               time_range=[keys[0][1], keys[-1][1]],
                               keys_byte_range=[start+cursor+12, start+cursor+clen],
                               keys_range_sha256=digest(data[cursor+12:cursor+clen]))
            records.append(channel)
            cursor += clen
        require(cursor == end, 'unconsumed node bytes')
        require(mask & 0x1ff == sum(seen), 'node mask mismatch')
        nodes.append({'ordinal': ordinal, 'flags': hex(mask), 'byte_range': [start+pos,start+end],
                      'range_sha256': digest(data[pos:end]), 'channels': records})
        pos = end
    require(pos == size, 'unconsumed clip bytes')
    channels = [c for n in nodes for c in n['channels']]
    parsed = [c for c in channels if c['status'] == 'parsed']
    times = [c['time_range'] for c in parsed]
    return {'status': 'unsupported' if unsupported else 'parsed',
            'header': {'flags': hex(flags), 'node_count': count, 'declared_size': size,
                       'loop_enabled_raw': loop, 'loop_start_raw_u32': loop_start},
            'nodes': nodes, 'summary': {'node_records': count, 'channel_records': len(channels),
                                      'key_count': sum(len(c['keys']) for c in parsed),
                                      'time_range': [min(t[0] for t in times),max(t[1] for t in times)] if times else None,
                                      'end_time_consumer_max_last_key': max(t[1] for t in times) if times and not unsupported else None,
                                      'unsupported_channel_ranges': unsupported,
                                      'bytes_structurally_consumed': pos, 'bytes_unconsumed': size-pos}}


def run():
    resources_path = ROOT/'analysis/hunter_resources.json'
    actions_path = ROOT/'analysis/hunter_actions.json'
    resources = json.loads(resources_path.read_text())
    actions = json.loads(actions_path.read_text())
    clip_prior = json.loads((ROOT/'analysis/hunter_clip.json').read_text())
    require(clip_prior['report_contract_version'] == 2, 'clip input must be v2')
    eboot_path = ROOT/'sysdir/PSP_GAME/SYSDIR/ULJM05500_EBOOT.BIN'
    eboot = eboot_path.read_bytes()
    require(digest(eboot) == clip_probe.EXPECTED['sysdir/PSP_GAME/SYSDIR/ULJM05500_EBOOT.BIN'], 'EBOOT identity mismatch')
    ovl_path = ROOT/'databin/0051.bin'
    ovl = ovl_path.read_bytes()
    require(digest(ovl) == actions['artifact']['sha256'], 'handler overlay identity mismatch')
    source_records = [evidence(resources_path, resources_path.read_bytes()), evidence(actions_path, actions_path.read_bytes()),
                      evidence(ROOT/'analysis/hunter_clip.json', (ROOT/'analysis/hunter_clip.json').read_bytes())]
    code_sources = []
    def code(name, resident=False):
        path = ROOT/('decomp' if resident else 'decomp_ovl')/(name+'.c')
        data = path.read_bytes()
        text = data.decode()
        size = int(re.search(r'size=(\d+)', text)[1])
        address = int(name,16)
        owner, origin, base = (eboot_path, ORIGIN, BASE) if resident else (ovl_path,0,OVL_BASE)
        raw = eboot if resident else ovl
        offset = address-base+origin
        code_sources.append({'function': '0x'+name, 'pseudocode': evidence(path,data),
                             'machine_source': evidence(owner,raw,offset,offset+size)})
        return text
    shared_writer = code('088c37ac',True)
    task_shared_writer = code('09a5dbe8')
    require('7,0x3d,0' in task_shared_writer and '+ 0x40) = uVar4' in task_shared_writer,
            'game_task shared animation writer changed')
    code('088e0ec0',True)
    code('088e11f8',True)
    for name in ('088d8a50','0886524c','088d857c','088d85c4','08863190','088630c8','08863660','08863644','088633c4','0885f998','0885f920','0885f840','08866fa8'):
        code(name,True)
    require('7,0x14f8,0' in shared_writer and '+ 0x40) = uVar12' in shared_writer, 'shared writer changed')
    # Preserve the literal loader table, including inconsistency with the earlier report.
    table_pos = 0x089b16dc-BASE+ORIGIN
    animation_bases = list(read_record(eboot,'<6H',table_pos))
    loader_words = read_record(eboot, '<22I', 0x08866fa8-BASE+ORIGIN)
    require(loader_words[3:5] == (0x3c02089b, 0x244216dc) and loader_words[7] == 0x94460000,
            'animation base address/load instructions changed')
    source_records.append(evidence(eboot_path,eboot,table_pos,table_pos+12))
    type_map = {kind: read_record(eboot,'<i',0x089a2ce4+4*kind-BASE+ORIGIN)[0] for kind in (1,2,4,8,16,32,64,128,256)}
    require(list(type_map.values()) == list(range(9)), 'component type table changed')
    for kind in type_map:
        offset = 0x089a2ce4+4*kind-BASE+ORIGIN
        source_records.append(evidence(eboot_path,eboot,offset,offset+4))
    helper_path = ROOT/'tools/hunter_clip_probe.py'
    source_records.append(evidence(helper_path,helper_path.read_bytes()))
    pair_raw = read_record(eboot,'<16I',0x088d857c-BASE+ORIGIN)
    require(any(w>>26 == 9 and w&0xffff == 100 and (w>>21)&31 == 5 for w in pair_raw), 'pair add100 missing')
    reviewed = {r['handler'][2:] for r in actions['reviewed_handler_matrix']}
    gs = {r['handler'][2:] for r in actions['greatsword_variants'] if r['handler']}
    selected = reviewed | gs | {'09a62cd8','09a884c0','09a8a0b0','09a8a438','09a9bd80'}
    references, handler_rows = [], []
    for name in sorted(selected):
        text = code(name)
        calls = list(re.finditer(r'(?:thunk_)?FUN_088d857c\(param_1,(.*?)\);',text,re.S))
        row = {'handler': '0x'+name, 'scope': 'greatsword' if name in gs else 'ordinary/guard selected handler',
               'literal_call_count': len(calls), 'unresolved_calls': []}
        for match in calls:
            arguments = ' '.join(match[1].split())
            literal = re.match(r'(0x[0-9a-f]+|\d+)\s*,',arguments)
            line = text[:match.start()].count('\n')+1
            if literal:
                references.append({'handler': '0x'+name, 'animation_id': int(literal[1],0),
                                   'arguments': arguments, 'lines': [line, text[:match.end()].count('\n')+1],
                                   'classification': 'static conditional reference; not executed/reachable-state proof'})
            elif name != '09a97360':
                row['unresolved_calls'].append({'arguments': arguments, 'line': line})
        if name == '09a62cd8':
            for match in re.finditer(r'\*\(undefined2 \*\)\(param_1 \+ 0xc9\) = (0x[0-9a-f]+|\d+);',text):
                references.append({'handler':'0x'+name,'animation_id':int(match[1],0),
                                   'lines':[text[:match.start()].count('\n')+1]*2,
                                   'arguments':'direct primary field store; secondary verified +100 in source',
                                   'classification':'static conditional reference'})
        if name == '09a97360':
            for weapon in range(11):
                offset = 0x09bb29b0+6*weapon-OVL_BASE
                aid, blend, reset = read_record(ovl,'<3h',offset)
                require(aid >= 0, 'negative table animation ID')
                references.append({'handler':'0x'+name,'animation_id':aid,'lines':[41,47],
                                   'arguments':f'weapon_type={weapon}, blend={blend}, start={10 if weapon == 8 else 0}, reset_blend={reset}',
                                   'classification':'static table reference; other weapon types not claimed as GS',
                                   'table_source':evidence(ovl_path,ovl,offset,offset+6)})
        handler_rows.append(row)
    selected_ids = sorted({r['animation_id'] for r in references})
    requests = sorted({(aid+100*track,track) for aid in selected_ids for track in (0,1)})
    packs, buffers, directories = [], {}, {}
    for pack in (61,5368,3377,3378,3945,3941,1877,225):
        path = ROOT/'databin'/f'{pack:04d}.bin'
        data = path.read_bytes()
        offset = 0x08976d00-BASE+ORIGIN+20*pack
        expected = eboot[offset:offset+20]
        require(len(expected)==20 and any(expected) and hashlib.sha1(data).digest()==expected, f'pack{pack} SHA1 mismatch')
        packs.append({'pack_id':pack,'source':evidence(path,data),'expected_sha1':expected.hex(),
                      'actual_sha1':hashlib.sha1(data).hexdigest(),'sha1_match':True,
                      'sha1_table_source':evidence(eboot_path,eboot,offset,offset+20)})
        buffers[pack] = data
        if pack not in (1877,225):
            try:
                directories[pack] = directory(data)
            except ValueError as error:
                require(pack in (3945,3941), f'pack{pack}: {error}')
                packs[-1]['directory_status'] = 'unsupported'
                packs[-1]['directory_reason'] = str(error)
                packs[-1]['header_hex'] = data[:20].hex()
    skeletons = []
    for pack in (1877,225):
        member_count = read_record(buffers[pack], '<I', 0)[0]
        require(2 <= member_count <= (len(buffers[pack])-4)//8, 'model member table capacity invalid')
        start,length = read_record(buffers[pack], '<2I', 12)
        end = start+length
        require(4+8*member_count <= start <= end <= len(buffers[pack]), 'skeleton member outside model container')
        prior = next((p for p in resources['resources'] if p['pack_id']==pack), None)
        if prior:
            member = next(m for m in prior['members'] if m['index']==1)
            require(digest(buffers[pack][start:end]) == member['source']['range_sha256'],'skeleton member changed')
        skeleton = clip_probe.decode_skeleton(buffers[pack][start:end],start)
        for node in skeleton['nodes']:
            require(all(math.isfinite(v) for v in node['bind_components_S_R_T']), 'nonfinite bind')
            seen, current = set(), node['index']
            while current != -1:
                require(current not in seen,'cyclic parent chain')
                seen.add(current)
                current = skeleton['nodes'][current]['parent']
        orders = {str(g):clip_probe.binding_order(skeleton,g) for g in (0,1)}
        skeletons.append({'pack_id':pack,'member':1,'source':evidence(ROOT/'databin'/f'{pack:04d}.bin',buffers[pack],start,end),
                          'node_count':len(skeleton['nodes']),'group_binding_orders':orders})
    clips, validation = [], collections.Counter()
    for animation_id,track in requests:
        targets = (61,5368) if animation_id<1000 else (3377,3378,3945,3941)
        for pack in targets:
            identity = (locate(buffers[pack],*directories[pack],animation_id) if pack in directories else
                        {'status':'unsupported','reason':'loader base candidate is not a validated grouped animation directory',
                         'normalized_id':animation_id%1000})
            item = {'animation_id':animation_id,'animation_id_hex':hex(animation_id),
                    'track_group':track,'pack_id':pack,'lookup':identity,'status':identity['status']}
            if identity['status']=='present':
                start,end = identity['byte_range']
                parsed = decode(buffers[pack][start:end],start,type_map)
                item.update(parsed)
                item['bone_mappings'] = []
                for skeleton in skeletons:
                    order = skeleton['group_binding_orders'][str(track)]
                    compatible = len(order)==len(parsed['nodes'])
                    item['bone_mappings'].append({'skeleton_pack':skeleton['pack_id'],'resource_track_group':track,
                                                 'status':'matched' if compatible else 'unsupported',
                                                 'reason':None if compatible else 'record count differs from selected group-filtered traversal',
                                                 'clip_to_skeleton_nodes':order if compatible else None,
                                                 'coverage':[len(order),skeleton['node_count']] if compatible else None})
                for node in parsed['nodes']:
                    for channel in node['channels']:
                        if channel['status'] != 'parsed':
                            continue
                        keys = channel['keys']
                        validation['keys'] += len(keys)
                        require(all(clip_probe.sample(keys,k[1]) == k[0] for k in keys),'key endpoint mismatch')
                        for a,b in zip(keys,keys[1:]):
                            for fraction in (0.25,0.5,0.75):
                                time = a[1]+fraction*(b[1]-a[1])
                                require(abs(clip_probe.hermite(time,a,b)-clip_probe.consumer_equation(time,a,b))<1e-7,'Hermite scalar mismatch')
                                validation['scalar_comparisons'] += 1
                        validation['channels'] += 1
                        validation['high_flags_'+channel['high_flags']] += 1
                validation['node_records'] += len(parsed['nodes'])
                validation['clip_bytes'] += end-start
            clips.append(item)
            validation['status_'+item['status']] += 1
    prior_matches = 0
    for previous in clip_prior['clips']:
        aid = previous['identity']['decimal_id']
        current = next(c for c in clips if c['pack_id']==3377 and c['animation_id']==aid)
        require(current['lookup']['byte_range']==previous['identity']['source']['byte_range'], 'v2 clip range changed')
        require([[c['keys'] for c in n['channels']] for n in current['nodes']] ==
                [[c['keys'] for c in n['channels']] for n in previous['nodes']], 'v2 keys changed')
        prior_matches += 1
    fixture = next(c for c in clips if c['pack_id']==3377 and c['animation_id']==1428)
    start,end = fixture['lookup']['byte_range']
    fixture_bytes = buffers[3377][start:end]
    channel = next(c for n in fixture['nodes'] for c in n['channels'] if len(c.get('keys',[]))>1)
    channel_pos = channel['byte_range'][0]-start
    mutations = [('truncated',fixture_bytes[:-1]), ('node_count',bytearray(fixture_bytes)),
                 ('node_length',bytearray(fixture_bytes)), ('channel_length',bytearray(fixture_bytes)),
                 ('key_time',bytearray(fixture_bytes))]
    struct.pack_into('<I',mutations[1][1],4,0xffffffff)
    struct.pack_into('<I',mutations[2][1],28,0xffffffff)
    struct.pack_into('<I',mutations[3][1],channel_pos+8,0xffffffff)
    struct.pack_into('<h',mutations[4][1],channel_pos+22,channel['keys'][0][1])
    for name,raw in mutations:
        try:
            decode(raw,start,type_map)
        except ValueError:
            validation['malformed_rejected'] += 1
        else:
            raise ValueError(f'malformed {name} accepted')
    unknown = bytearray(fixture_bytes)
    struct.pack_into('<I',unknown,channel_pos+4,0)
    require(decode(unknown,start,type_map)['status']=='unsupported','unknown layout must retain unsupported')
    validation['unsupported_layout_preserved'] += 1
    validation['v2_release_tracks_key_equal'] = prior_matches
    validation['per_pack'] = {str(pack):dict(collections.Counter(c['status'] for c in clips if c['pack_id']==pack))
                              for pack in buffers if pack not in (1877,225)}
    validation['bone_mapping_status'] = dict(collections.Counter(m['status'] for c in clips for m in c.get('bone_mappings',[])))
    matrix = []
    guard_dispatch = [{'handler':'0x09a88e90','category':2,'subaction':sub,'arguments':f'param_1,{p}'} for sub,p in ((3,0),(12,1))]
    guard_dispatch += [{'handler':'0x09a884c0','category':2,'subaction':sub,'arguments':f'param_1,{p}'} for sub,p in ((1,0),(10,1))]
    guard_dispatch += [{'handler':'0x09a8a0b0','category':2,'subaction':8}, {'handler':'0x09a8a438','category':2,'subaction':11}]
    code('09a87fc0')
    dispatch = actions['ordinary_dispatch'] + actions['greatsword_variants'] + guard_dispatch
    for reference in references:
        primary = reference['animation_id']
        matching = [r for r in dispatch if r['handler']==reference['handler']]
        for track in (0,1):
            for item in clips:
                if item['animation_id']!=primary+track*100 or item['track_group']!=track:
                    continue
                summary = item.get('summary',{})
                header = item.get('header',{})
                parts = reference['arguments'].split(',')
                start_value = parts[2].strip() if len(parts)==3 else None
                start_time = int(start_value,0) if start_value and re.fullmatch(r'0x[0-9a-f]+|\d+', start_value) else None
                end_time = summary.get('end_time_consumer_max_last_key')
                matrix.append({'action_handler':reference['handler'], 'dispatch_candidates':[{'category':r.get('category',1 if r in actions['greatsword_variants'] else 0),'subaction':r['subaction'],'arguments':r.get('arguments')} for r in matching],
                               'reference':reference,'primary_animation_id':primary,'animation_id':item['animation_id'],
                               'track_group':track,'pack_id':item['pack_id'],'status':item['status'],
                               'byte_range':item['lookup'].get('byte_range'),'time_range':summary.get('time_range'),
                               'end':summary.get('end_time_consumer_max_last_key'),'loop_raw':header.get('loop_enabled_raw'),
                               'loop_start_raw':header.get('loop_start_raw_u32'),
                               'start_time_literal':start_time,
                               'duration_units_from_zero':end_time,
                               'duration_units_from_literal_start':max(0,end_time-start_time) if end_time is not None and start_time is not None else None,
                               'duration_semantics':'Clip units to terminal time, not FSM lifetime; loop repeats or early transitions may alter action duration.',
                               'duration_seconds':None,'bone_coverage':item.get('bone_mappings')})
    paired_coverage = []
    for primary in selected_ids:
        for pack in ((61,5368) if primary<1000 else (3377,3378,3945,3941)):
            tracks = [next(c for c in clips if c['animation_id']==primary+100*t and c['track_group']==t and c['pack_id']==pack) for t in (0,1)]
            bindings = []
            if all(c['status']=='parsed' for c in tracks):
                for skeleton in skeletons:
                    orders = skeleton['group_binding_orders']
                    require(not set(orders['0']).intersection(orders['1']), 'paired binding overlaps')
                    covered = sorted(set(orders['0'])|set(orders['1']))
                    require(covered==list(range(skeleton['node_count'])), 'paired mapping leaves bones unbound')
                    bindings.append({'skeleton_pack':skeleton['pack_id'],'covered_nodes':covered,'coverage':[len(covered),skeleton['node_count']]})
            paired_coverage.append({'primary_animation_id':primary,'paired_animation_id':primary+100,'pack_id':pack,
                                    'track_statuses':[c['status'] for c in tracks],
                                    'track_end_times':[c.get('summary',{}).get('end_time_consumer_max_last_key') for c in tracks],
                                    'bone_coverage':bindings})
    return {'report_contract_version':1,'target':'ULJM05500 MHP2G','evidence_kind':'offline bytes and retained static pseudocode; no live Evidence ID',
            'scope':'Only selected handlers and their literal/table-referenced IDs plus100. Not an all-pack dump or all-state verification.',
            'input_sources':source_records,'code_sources':code_sources,'packs':packs,
            'component_type_map':{str(kind):{'index':index,'component':clip_probe.COMPONENTS[index],
                                           'virtual_address':hex(0x089a2ce4+4*kind)} for kind,index in type_map.items()},
            'shared_manager':{'global':'0x09a4ae04','field':'+0x40','game_task_pack_id':61,'resident_alternate_pack_id':5368,
                              'producer':'09a5dbe8 game_task initialization requests088e0ec0(loader,7,0x3d,0);088c37ac separately requests slot7 resource0x14f8. Both wait088e11f8(slot7), copy loader+0x58 if ready bit2 at+0x54, else0 into manager+0x40.',
                              'authority':'Resource request ID and completed slot pointer, not magic. 088e0ec0 records resource ID and calls resource provider vtable+0x34.',
                              'consumer':'088d8a50 ID<1000 uses shared pointer; -1/out-of-entry yields0 (no per-entry fallback); only null manager/pointer falls back to0886524c.',
                              'actual_live_manager':None},
            'entity_animation_identity':{'literal_08866fa8_table_address':'0x089b16dc','literal_u16_bases':animation_bases,
                                         'selection_formula':'base[u8 row]+u8 appearance; slot=player_index*8+7',
                                         'previous_report_claim':'3377/3378 are row0/1 bases',
                                         'correction':'MIPS lui/addiu/lhu verifies base table089b16dc: row0/1=3945/3941,row2/3=3377/3378.3945/3941 are SHA1-valid but not grouped animation directories.3377/3378 are loader-addressable candidates at row2/3 appearance0, not proven current player selection. Body skeleton row correspondence remains unresolved.',
                                         'actual_selection':None},
            'skeletons':skeletons,'handler_coverage':handler_rows,'primary_ids':selected_ids,
            'animation_directories':[{'pack_id':pack,'groups':[{'group':i,'count':g['count'],'table_offset':g['table_offset']} for i,g in enumerate(groups)],
                                      'examined_indexed_payload_starts':len(offsets),'rule':'All directory offsets used only to bound selected payloads; unselected clips not decoded.'}
                                     for pack,(groups,offsets) in directories.items()],
            'action_labels_inferred':{'0x09a62cd8':'待机/环境待机','0x09a96c48':'走跑/持武移动/慢行',
                                     '0x09a97360':'收拔刀及变体','0x09a99488':'冲刺','0x09a99890':'危险奔跑候选',
                                     '0x09a98dc0':'前回避/变体','0x09a9aae8':'侧回避','0x09a9bd80':'飞扑候选',
                                     '0x09a88e90':'持R防御','0x09a884c0':'中重格挡反应','0x09a8a438':'轻格挡反应',
                                     '0x09a8a0b0':'防御释放','0x09b9be88':'上捞及变体','0x09b9c2b8':'横斩及变体',
                                     '0x09b9d210':'蓄力及变体','0x09b9d7b8':'蓄力释放及变体'},
            'labels_authority':'Action names are inherited static behavior inferences, not visual animation identifications.',
            'greatsword_dispatch_coverage':[{k:r.get(k) for k in ('subaction','handler','arguments','behavior','animation_plan')} for r in actions['greatsword_variants']],
            'ordinary_dispatch_coverage':[{'subaction':r['subaction'],'handler':r['handler'],
                                           'status':'selected handler references scanned' if r['handler'] and r['handler'][2:] in selected else 'out_of_selected_scope'} for r in actions['ordinary_dispatch']],
            'clips':clips,'paired_id_bone_coverage':paired_coverage,'action_id_pack_time_bone_matrix':matrix,'validation':dict(validation),
            'codec_policy':'Independent parser: literal8-byte signed-short/Hermite reader, type table1..256. High flags retained, not required to equal0x80120000 because selected consumers never branch on them. Unknown layouts/components remain unsupported; no invented keys.',
            'unknowns':['No actual player resource selection or live manager observation; each pack remains a statically loader-addressable candidate.',
                        'Handler call inventory includes conditional branches for other weapon types; not all IDs apply simultaneously to GS.',
                        'Matching node count and consumer group traversal establish compatibility, not active equipment identity.',
                        'All referenced IDs parsed is not all states verified; d/17 remain empty, cross-module transitions and global feasibility unverified.',
                        'High flag semantic labels, rendered/world pose, VFPU exact rounding, real Hz and seconds unknown.',
                        'No game/Ghidra/Godot execution; no original files modified.'],
            'reproduce':{'write':'python3 -B mh/tools/hunter_animation_catalog.py --write-report',
                         'check':'python3 -B mh/tools/hunter_animation_catalog.py --check'}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--write-report',action='store_true')
    group.add_argument('--check',action='store_true')
    options = parser.parse_args()
    report = run()
    if options.check:
        require(json.loads(REPORT.read_text()) == report,'catalog differs from regenerated evidence')
    elif options.write_report:
        REPORT.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'primary_id_count':len(report['primary_ids']),'validation':report['validation'],
                      'entity_animation_identity':report['entity_animation_identity'],
                      'unresolved_calls':[r for r in report['handler_coverage'] if r['unresolved_calls']],
                      'selected_handler_count':len(report['handler_coverage']),
                      'matrix_rows':len(report['action_id_pack_time_bone_matrix']),
                      'absent_ids_by_pack':{str(pack):[c['animation_id'] for c in report['clips'] if c['pack_id']==pack and c['status']=='absent'] for pack in (5368,3377,3378)},
                      'report_bytes':REPORT.stat().st_size if options.write_report or options.check else None,
                      'output':str(REPORT) if options.write_report or options.check else None},ensure_ascii=False))


if __name__ == '__main__':
    main()
