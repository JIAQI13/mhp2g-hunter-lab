#!/usr/bin/env python3
"""Decode loader-selected pack3377 release clips0x594/0x5f8; no target execution."""
import argparse
import hashlib
import json
import math
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
START, END = 125412, 132640
BASE, ORIGIN = 0x08804000, 0x25B4
COMPONENTS = ['S0', 'S1', 'S2', 'R0', 'R1', 'R2', 'T0', 'T1', 'T2']
ROTATION_FACTOR = struct.unpack('<f', struct.pack('<I', 0x39C90FDB))[0]
EXPECTED = {
    'databin/3377.bin': '4ec4d921e8da9eb916d2721f0e074b3633edd9cdb2d56f869e64a5a97e6e03eb',
    'databin/1877.bin': '65fe3366f70c6936d55965856ac8e8c0a3cfd914056d011a1b1a3ea988879e7c',
    'sysdir/PSP_GAME/SYSDIR/ULJM05500_EBOOT.BIN': '3ae65e26416eaa2a23d21492030803fdb8c54935b41d259f72a0a63d39dfd6d9',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def identity(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def source_range(path, start, end, digest):
    require(0 <= start <= end <= path.stat().st_size, 'source range outside file')
    with path.open('rb') as source:
        source.seek(start)
        data = source.read(end - start)
    require(len(data) == end - start, 'short source read')
    return data, {'path': str(path), 'file_sha256': digest,
                  'byte_range': [start, end], 'range_sha256': sha(data)}


def unpack(data, fmt, pos, end=None):
    limit = len(data) if end is None else end
    require(0 <= pos and pos + struct.calcsize(fmt) <= limit <= len(data), 'record outside owner range')
    return struct.unpack_from(fmt, data, pos)


def hermite(time, left, right):
    v0, t0, _, m0 = left
    v1, t1, m1, _ = right
    dt = t1 - t0
    require(dt > 0, 'non-positive key interval')
    u = (time - t0) / dt
    return ((2*u**3 - 3*u**2 + 1)*v0 + (u**3 - 2*u**2 + u)*dt*m0
            + (-2*u**3 + 3*u**2)*v1 + (u**3 - u**2)*dt*m1)


def consumer_equation(time, left, right):
    # Literal scalar interpretation of 08862fd8.c lines17..47, not VFPU emulation.
    v0, t0, _, m0 = left
    v1, t1, m1, _ = right
    x = time - t0
    reciprocal = 1 / (t1 - t0)
    square = x*x
    a = square * reciprocal
    b = square*x * reciprocal*reciprocal
    c = 2*b*reciprocal
    d = 3*square*reciprocal*reciprocal
    return v0*(1+c-d) + v1*(d-c) + m0*(b-a-a+x) + m1*(b-a)


def sample(keys, time):
    if time <= keys[0][1]:
        return float(keys[0][0])
    if time >= keys[-1][1]:
        return float(keys[-1][0])
    for left, right in zip(keys, keys[1:]):
        if time == left[1]:
            return float(left[0])
        if left[1] < time < right[1]:
            return hermite(time, left, right)
    raise ValueError('no key interval')


def curve_range(keys):
    values = [float(key[0]) for key in keys]
    for left, right in zip(keys, keys[1:]):
        v0, t0, _, m0 = left
        v1, t1, m1, _ = right
        dt = t1 - t0
        a = 2*v0 - 2*v1 + dt*(m0+m1)
        b = -3*v0 + 3*v1 - dt*(2*m0+m1)
        c = dt*m0
        roots = []
        if a:
            discriminant = 4*b*b - 12*a*c
            if discriminant >= 0:
                roots = [(-2*b + sign*math.sqrt(discriminant))/(6*a) for sign in (-1, 1)]
        elif b:
            roots = [-c/(2*b)]
        values.extend(hermite(t0 + u*dt, left, right) for u in roots if 0 < u < 1)
    return [min(values), max(values)]


def decode_clip(data, type_map, source_start):
    flags, count, size, loop, loop_start = unpack(data, '<5I', 0)
    require(size == len(data), 'declared clip size mismatch')
    require(count <= (len(data)-20)//12, 'node count exceeds capacity')
    nodes, pos = [], 20
    for index in range(count):
        mask, channels, length = unpack(data, '<3I', pos)
        require(length >= 12 and pos+length <= len(data), 'invalid node length')
        end = pos+length
        require(channels <= (length-12)//12, 'channel count exceeds capacity')
        cursor, parsed, seen = pos+12, [], set()
        for _ in range(channels):
            raw_type, nkeys, clen = unpack(data, '<3I', cursor, end)
            kind = raw_type & 0xFFFF
            require(raw_type & 0xFFFF0000 == 0x80120000, 'unsupported channel codec flags')
            require(kind in type_map and kind not in seen, 'unknown or duplicate channel type')
            seen.add(kind)
            require(clen >= 12 and cursor+clen <= end, 'invalid channel length')
            require(0 < nkeys <= (clen-12)//8, 'key count exceeds capacity or empty channel')
            require(clen == 12+8*nkeys, 'unsupported channel trailing representation')
            keys = [list(unpack(data, '<4h', cursor+12+8*k, cursor+clen)) for k in range(nkeys)]
            require(all(a[1] < b[1] for a, b in zip(keys, keys[1:])), 'key times not strictly increasing')
            component = type_map[kind]
            factor = 0.0625 if kind & 0x38 == 0 else ROTATION_FACTOR
            ranges = curve_range(keys)
            parsed.append({'type_word': hex(raw_type), 'type': kind, 'component_index': component,
                           'component': COMPONENTS[component], 'factor': factor,
                           'byte_range': [source_start+cursor, source_start+cursor+clen],
                           'range_sha256': sha(data[cursor:cursor+clen]), 'key_count': nkeys,
                           'keys_byte_range': [source_start+cursor+12, source_start+cursor+clen],
                           'keys_range_sha256': sha(data[cursor+12:cursor+clen]),
                           'key_layout': ['value', 'time', 'in_tangent', 'out_tangent'],
                           'keys': keys, 'time_range': [keys[0][1], keys[-1][1]],
                           'key_value_range_raw': [min(k[0] for k in keys), max(k[0] for k in keys)],
                           'continuous_curve_range_raw': ranges,
                           'continuous_curve_range_scaled': [v*factor for v in ranges]})
            cursor += clen
        require(cursor == end, 'unconsumed node bytes')
        require(mask & 0x1FF == sum(seen), 'node component mask mismatch')
        nodes.append({'clip_node_ordinal': index, 'flags': hex(mask), 'channel_count': channels,
                      'byte_range': [source_start+pos, source_start+end], 'range_sha256': sha(data[pos:end]),
                      'channels': parsed})
        pos = end
    require(pos == len(data), 'unconsumed clip bytes')
    return {'header': {'flags': hex(flags), 'node_count': count, 'declared_size': size,
                       'loop_enabled_raw': loop, 'loop_start_raw_u32': loop_start,
                       'byte_range': [source_start, source_start+20],
                       'range_sha256': sha(data[:20])}, 'nodes': nodes,
            'byte_coverage': {'total': len(data), 'header': 20, 'node_headers': 12*count,
                              'channel_headers': sum(12*n['channel_count'] for n in nodes),
                              'keys': sum(8*c['key_count'] for n in nodes for c in n['channels']),
                              'unparsed': 0}}


def decode_skeleton(data, source_start):
    flags, count, size = unpack(data, '<3I', 0)
    count -= bool(flags & 0x80000000)
    require(size <= len(data), 'skeleton declared size out of range')
    root_count, offset = unpack(data, '<2I', 16)
    require(root_count <= (len(data)-24)//4, 'root count exceeds capacity')
    roots = list(unpack(data, '<' + 'I'*root_count, 24))
    pos, nodes = offset+12, []
    require(0 <= count <= (size-pos)//84, 'skeleton node count exceeds capacity')
    for index in range(count):
        length = unpack(data, '<I', pos+8)[0]
        require(length >= 84 and pos+length <= size, 'invalid skeleton node length')
        parent, child, sibling = unpack(data, '<3i', pos+16, pos+length)
        require(all(link == -1 or 0 <= link < count for link in (parent, child, sibling)), 'invalid skeleton link')
        s = list(unpack(data, '<3f', pos+28))
        r = list(unpack(data, '<3f', pos+44))
        t = list(unpack(data, '<3f', pos+60))
        group = unpack(data, '<I', pos+80)[0]
        nodes.append({'index': index, 'parent': parent, 'first_child': child, 'next_sibling': sibling,
                      'track_group': group, 'bind_components_S_R_T': s+r+t,
                      'byte_range': [source_start+pos, source_start+pos+length],
                      'range_sha256': sha(data[pos:pos+length])})
        pos += length
    require(pos == size, 'unconsumed declared skeleton bytes')
    require(all(root < count for root in roots), 'invalid root')
    return {'roots': roots, 'nodes': nodes, 'declared_size': size,
            'member_trailing_bytes': len(data)-size}


def binding_order(skeleton, group):
    # 0885f998 first uses 0885f920's unfiltered search to select a matching subtree.
    searched = set()
    def find(index, anchor):
        if index == -1:
            return None
        require(index not in searched, 'cyclic or repeated skeleton root search')
        searched.add(index)
        node = skeleton['nodes'][index]
        if node['track_group'] == group:
            return index
        found = find(node['first_child'], anchor)
        if found is not None:
            return found
        return find(node['next_sibling'], anchor) if index != anchor else None
    root = find(skeleton['roots'][0], skeleton['roots'][0])
    require(root is not None, 'no matching track subtree')
    order, visited = [], set()
    def visit(index):
        if index == -1:
            return
        require(index not in visited, 'cyclic or repeated skeleton traversal')
        visited.add(index)
        node = skeleton['nodes'][index]
        if node['track_group'] == group:
            order.append(index)
            visit(node['first_child'])
        if index != root:
            visit(node['next_sibling'])
    visit(root)
    return order


def tests(clip_data, clip, type_map, source_start):
    endpoints = comparisons = derivatives = 0
    error = 0.0
    for node in clip['nodes']:
        for channel in node['channels']:
            keys = channel['keys']
            for key in keys:
                require(sample(keys, key[1]) == key[0], 'exact key sampling failed')
                endpoints += 1
            require(sample(keys, keys[0][1]-1) == keys[0][0], 'left clamp failed')
            require(sample(keys, keys[-1][1]+1) == keys[-1][0], 'right clamp failed')
            for left, right in zip(keys, keys[1:]):
                dt = right[1]-left[1]
                a = 2*left[0]-2*right[0]+dt*(left[3]+right[2])
                b = -3*left[0]+3*right[0]-dt*(2*left[3]+right[2])
                c = dt*left[3]
                require(c/dt == left[3] and (3*a+2*b+c)/dt == right[2], 'tangent derivative mismatch')
                derivatives += 2
                for fraction in (0.125, 0.25, 0.5, 0.875):
                    time = left[1]+fraction*dt
                    difference = abs(hermite(time, left, right)-consumer_equation(time, left, right))
                    error = max(error, difference)
                    require(difference < 1e-7, 'Hermite vs literal scalar consumer mismatch')
                    comparisons += 1
    bad_inputs = [('truncated', clip_data[:-1]), ('excessive_node_count', bytearray(clip_data)),
                  ('empty_key_channel', bytearray(clip_data)), ('duplicate_key_time', bytearray(clip_data)),
                  ('channel_length_outside_node', bytearray(clip_data)),
                  ('channel_count_outside_node', bytearray(clip_data)),
                  ('unknown_channel_type', bytearray(clip_data)),
                  ('unsupported_codec_flags', bytearray(clip_data))]
    struct.pack_into('<I', bad_inputs[1][1], 4, 0xFFFFFFFF)
    owner = next(n for n in clip['nodes'] if any(c['key_count'] >= 2 for c in n['channels']))
    channel = next(c for c in owner['channels'] if c['key_count'] >= 2)
    first = channel['byte_range'][0]-source_start
    struct.pack_into('<I', bad_inputs[2][1], first+4, 0)
    struct.pack_into('<h', bad_inputs[3][1], first+12+8+2, channel['keys'][0][1])
    struct.pack_into('<I', bad_inputs[4][1], first+8, len(clip_data))
    struct.pack_into('<I', bad_inputs[5][1], owner['byte_range'][0]-source_start+4, 0xFFFFFFFF)
    struct.pack_into('<H', bad_inputs[6][1], first, 0xFFFF)
    struct.pack_into('<H', bad_inputs[7][1], first+2, 0)
    coverage = clip['byte_coverage']
    require(coverage['total'] == sum(coverage[k] for k in ('header', 'node_headers', 'channel_headers', 'keys')),
            'clip byte partition mismatch')
    rejected = []
    for label, data in bad_inputs:
        try:
            decode_clip(data, type_map, source_start)
        except ValueError:
            rejected.append(label)
        else:
            raise ValueError('malformed input accepted: '+label)
    return {'exact_key_checks': endpoints, 'literal_consumer_interior_comparisons': comparisons,
            'endpoint_derivative_checks': derivatives, 'max_float64_equation_difference': error,
            'rejected_malformed_inputs': rejected, 'status': 'passed',
            'limits': 'Mathematical float64 equations only; not PSP VFPU reciprocal/rounding or gameplay/visual conformance.'}


def run():
    hashes = {name: identity(ROOT/name) for name in EXPECTED}
    require(hashes == EXPECTED, 'selected artifact identity differs from prior evidence')
    prior_path = ROOT/'analysis/hunter_resources.json'
    prior = json.loads(prior_path.read_text())
    pack = next(p for p in prior['resources'] if p['pack_id'] == 1877)
    member = next(m for m in pack['members'] if m['index'] == 1)
    animation = next(p for p in prior['greatsword_release_clip_index_probes'] if p['pack_id'] == 3377)
    require(animation['entry']['source']['range'] == {'start': START, 'end_exclusive': END}, 'prior clip range changed')
    sources = []
    def selected(name, start, end):
        data, evidence = source_range(ROOT/name, start, end, hashes[name])
        sources.append(evidence)
        return data
    eboot = 'sysdir/PSP_GAME/SYSDIR/ULJM05500_EBOOT.BIN'
    def raw(address, length):
        data = selected(eboot, address-BASE+ORIGIN, address-BASE+ORIGIN+length)
        sources[-1]['virtual_address_range'] = [hex(address), hex(address+length)]
        return data
    pack_name = 'databin/3377.bin'
    file_size = (ROOT/pack_name).stat().st_size
    first_table = unpack(selected(pack_name, 0, 8), '<2I', 0)[1]
    require(first_table % 8 == 0 and 0 < first_table <= file_size, 'invalid directory boundary')
    directory = selected(pack_name, 0, first_table)
    groups, offsets, tables = [], set(), []
    for group in range(first_table//8):
        count, table = unpack(directory, '<2I', group*8)
        require(count <= 100 and first_table <= table <= table+count*4 <= file_size,
                'invalid animation group table')
        values = list(unpack(selected(pack_name, table, table+count*4), '<'+'i'*count, 0))
        require(all(v == -1 or table+count*4 <= v <= file_size-20 for v in values),
                'animation entry outside payload')
        offsets.update(v for v in values if v != -1)
        tables.append([table, table+count*4])
        groups.append({'group': group, 'count': count, 'table_offset': table, 'entries': values})
    require(all(v >= max(end for _, end in tables) for v in offsets), 'clip overlaps directory tables')
    def locate(animation_id):
        normalized = animation_id % 1000
        group, entry = divmod(normalized, 100)
        require(group < len(groups) and entry < groups[group]['count'], 'animation entry absent')
        table = groups[group]
        start = table['entries'][entry]
        require(start != -1, 'animation entry marked absent')
        header = selected(pack_name, start, start+20)
        size = unpack(header, '<I', 8)[0]
        end = start+size
        boundary = min((v for v in offsets if v > start), default=file_size)
        require(size >= 20 and end <= boundary, 'declared clip overlaps next indexed payload')
        data = selected(pack_name, start, end)
        return data, {'animation_id': hex(animation_id), 'decimal_id': animation_id,
                      'normalized_id': normalized, 'group': group, 'entry': entry,
                      'entry_offset': table['table_offset']+entry*4,
                      'directory_record_range': [group*8, group*8+8],
                      'source': dict(sources[-1]), 'next_indexed_payload_boundary': boundary,
                      'gap_after_declared_clip': boundary-end}
    clip_data, clip_identity = locate(0x594)
    require(clip_identity['source']['byte_range'] == [START, END], 'prior clip range mismatch')
    require(sha(clip_data) == animation['entry']['source']['range_sha256'], 'prior clip digest mismatch')
    pair_code = unpack(raw(0x088d857c, 64), '<16I', 0)
    pair_add = next(word for word in pair_code if word >> 26 == 9 and word & 0xFFFF == 100)
    pair_register = (pair_add >> 16) & 31
    require((pair_add >> 21) & 31 == 5 and any(word >> 26 == 41
            and (word >> 21) & 31 == 4 and (word >> 16) & 31 == pair_register
            and word & 0xFFFF == 0x326 for word in pair_code), 'paired ID setter changed')
    pair_id = clip_identity['decimal_id'] + (pair_add & 0xFFFF)
    paired_data, paired_identity = locate(pair_id)
    entry_offset = clip_identity['entry_offset']
    type_map = {}
    for kind in (8, 16, 32, 64, 128, 256):
        type_map[kind] = struct.unpack('<i', raw(0x089A2CE4+kind*4, 4))[0]
    require(list(type_map.values()) == [3, 4, 5, 6, 7, 8], 'type table differs from checked consumer')
    constants = struct.unpack('<2I', raw(0x0886325C, 8))
    require(constants == (0x3C0239C9, 0x34420FDB), 'rotation scale instructions changed')
    require(struct.unpack('<I', raw(0x08863278, 4))[0] == 0x3C023D80, 'translation scale instruction changed')
    clip = decode_clip(clip_data, type_map, clip_identity['source']['byte_range'][0])
    paired_clip = decode_clip(paired_data, type_map, paired_identity['source']['byte_range'][0])
    clip['identity'], paired_clip['identity'] = clip_identity, paired_identity
    clips = [clip, paired_clip]
    bounds = member['source']['range']
    skeleton_data = selected('databin/1877.bin', bounds['start'], bounds['end_exclusive'])
    require(sha(skeleton_data) == member['source']['range_sha256'], 'prior skeleton digest mismatch')
    skeleton = decode_skeleton(skeleton_data, bounds['start'])
    prior_nodes = member['skeleton']['nodes']
    require(len(skeleton['nodes']) == len(prior_nodes) == 21, 'prior skeleton count mismatch')
    for actual, previous in zip(skeleton['nodes'], prior_nodes):
        require(actual['track_group'] == previous['animation_channel'] and actual['byte_range'][0] == previous['offset'], 'prior skeleton record mismatch')
    orders, bound_nodes = [], {}
    for group, current_clip in enumerate(clips):
        order = binding_order(skeleton, group)
        require(len(order) == len(current_clip['nodes']), f'group{group} binding count mismatch')
        require(set(order) == {n['index'] for n in skeleton['nodes'] if n['track_group'] == group},
                'tree traversal does not cover all nodes of selected group')
        orders.append(order)
        current_clip['track_group'] = group
        for node, bone in zip(current_clip['nodes'], order):
            require(bone not in bound_nodes, 'dual clips bind the same skeleton node')
            node['bound_skeleton_node'] = bone
            bound_nodes[bone] = node
    require(set(bound_nodes) == {n['index'] for n in skeleton['nodes']}, 'dual clips leave skeleton nodes unbound')
    samples = []
    for time in (0, 2.5, 3, 6, 40, 82, 120, 164):
        bones = []
        for bone in skeleton['nodes']:
            node = bound_nodes[bone['index']]
            bind = bone['bind_components_S_R_T']
            pose, continuous = list(bind), list(bind)
            for channel in node['channels']:
                component = channel['component_index']
                pose[component] = sample(channel['keys'], int(time))*channel['factor']
                continuous[component] = sample(channel['keys'], time)*channel['factor']
            keyed = {c['component_index'] for c in node['channels']}
            require(all(pose[i] == bind[i] and continuous[i] == bind[i]
                        for i in range(9) if i not in keyed), 'omitted component lost bind value')
            bones.append({'skeleton_node': bone['index'], 'track_group': bone['track_group'],
                          'animation_id': clips[bone['track_group']]['identity']['animation_id'],
                          'omitted_components_preserved_from_bind': [COMPONENTS[i] for i in range(9) if i not in keyed],
                          'local_pose_components': pose,
                          'float_time_curve_components': continuous,
                          'component_difference_from_bind_NOT_animation_delta': [p-b for p,b in zip(pose, bind)]})
        samples.append({'requested_clip_time': time, 'pose_consumer_uint_time': int(time), 'bones': bones})
    root_index = skeleton['nodes'][skeleton['roots'][0]]['first_child']
    root_clip = next(node for node in clip['nodes'] if node['bound_skeleton_node'] == root_index)
    root_t2 = next(c for c in root_clip['channels'] if c['component_index'] == 8)
    require([c['component_index'] for c in root_clip['channels']] == [6, 7, 8]
            and all(all(key[0] == 0 and key[2:] == [0, 0] for key in c['keys'])
                    for c in root_clip['channels'][:2])
            and skeleton['nodes'][root_index]['bind_components_S_R_T'][3:6] == [0, 0, 0],
            'local root difference simplification not applicable')
    root_differences = []
    for previous, current in ((0, 2), (2, 4), (0, 6), (40, 42), (82, 84), (162, 164)):
        before = sample(root_t2['keys'], previous)*root_t2['factor']
        after = sample(root_t2['keys'], current)*root_t2['factor']
        root_differences.append({'previous': previous, 'current': current,
                                 'local_T2_previous': before, 'local_T2_current': after,
                                 'local_translation_difference': [0.0, 0.0, after-before]})
    examples = {'root_skeleton_node': root_index, 'T2_channel_byte_range': root_t2['byte_range'],
                'T2_first_keys_raw': root_t2['keys'][:3], 'T2_last_key_raw': root_t2['keys'][-1],
                'T2_continuous_curve_range_scaled': root_t2['continuous_curve_range_scaled'],
                'local_root_translation_differences': root_differences,
                'limit': 'Node1 has only translation channels with zero T0/T1 and bind rotation zero. Differences follow 0885ffb4 subtraction, not world-space entity motion or a player update schedule.'}
    attachment_changes = []
    for index, role in ((10, 'type0 weapon attachment'), (14, 'attack attachment (caller-supplied identity)')):
        node = bound_nodes[index]
        changes = []
        for channel in node['channels']:
            first_key = channel['keys'][0]
            different = next((k for k in channel['keys'] if k[0] != first_key[0]), None)
            if different is not None:
                before = sample(channel['keys'], first_key[1])*channel['factor']
                after = sample(channel['keys'], different[1])*channel['factor']
                require(before != after, 'attachment sample did not vary')
                changes.append({'component': channel['component'], 'channel_byte_range': channel['byte_range'],
                                'channel_range_sha256': channel['range_sha256'],
                                'raw_keys': [first_key, different], 'clip_times': [first_key[1], different[1]],
                                'local_component_values_scaled': [before, after], 'difference': after-before})
        require(changes, f'attachment node{index} has no observed nontrivial keyed component')
        attachment_changes.append({'skeleton_node': index, 'role': role, 'track_group': 1,
                                   'animation_id': paired_identity['animation_id'], 'changing_components': changes,
                                   'limit': 'Local scalar components only; not an attachment world position or attack trajectory.'})
    examples['attachment_local_component_changes'] = attachment_changes
    validation = {'status': 'passed', 'clips': [
        {'animation_id': current_clip['identity']['animation_id'],
         **tests(data, current_clip, type_map, current_clip['identity']['source']['byte_range'][0])}
        for data, current_clip in zip((clip_data, paired_data), clips)],
        'bone_coverage': 'Disjoint group-filtered tree traversals exhaust the selected skeleton; no arithmetic concatenation.',
        'omitted_component_checks': 'All sampled omitted components equal bind/current-base components.',
        'attachment_nodes_nontrivial_local_components': [10, 14]}
    code = []
    references = {
        '0885f998': (8, 10, 108), '0885f920': (9, 29, 120), '0885f840': (10, 58, 160),
        '08860254': (14, 41, 204), '08860054': (21, 42, 512),
        '08867894': (32, 106, 664), '0885fa04': (18, 41, 328),
        '08863190': (12, 31, 320), '088630c8': (13, 22, 200),
        '08863660': (13, 55, 348), '08863644': (3, 6, 28), '08862fd8': (17, 47, 240),
        '0885ffb4': (14, 27, 160),
        '088633c4': (28, 59, 640), '088632d0': (39, 88, 244),
        '0886524c': (11, 29, 136), '08866fa8': (8, 10, 88),
        '088d857c': (8, 18, 64), '088d85c4': (63, 80, 628),
        '08863e68': (14, 30, 648), '088d68b0': (234, 251, 7148),
    }
    for function, (first, last, size) in references.items():
        path = ROOT/'decomp'/f'{function}.c'
        contents = path.read_bytes()
        lines = contents.splitlines(keepends=True)
        start = sum(map(len, lines[:first-1]))
        end = sum(map(len, lines[:last]))
        _, evidence = source_range(path, start, end, sha(contents))
        evidence.update({'function_address': '0x'+function, 'lines_1based_inclusive': [first, last]})
        machine = raw(int(function, 16), size)
        evidence['machine_source'] = sources.pop()
        evidence['machine_source']['raw_sha256'] = sha(machine)
        code.append(evidence)
    prior_sources = []
    for name, first, last in [('hunter_resources.json', 9488, 9512), ('animation_runtime.json', 7, 18)]:
        path = ROOT/'analysis'/name
        contents = path.read_bytes()
        lines = contents.splitlines(keepends=True)
        start, end = sum(map(len, lines[:first-1])), sum(map(len, lines[:last]))
        _, evidence = source_range(path, start, end, sha(contents))
        evidence['lines_1based_inclusive'] = [first, last]
        prior_sources.append(evidence)
    all_nodes = [node for current_clip in clips for node in current_clip['nodes']]
    all_channels = [channel for node in all_nodes for channel in node['channels']]
    for current_clip in clips:
        nodes = current_clip['nodes']
        channels = [c for n in nodes for c in n['channels']]
        current_clip['summary'] = {'node_count': len(nodes), 'channel_count': len(channels),
                                   'key_count': sum(c['key_count'] for c in channels),
                                   'end_time_consumer_max_last_key': max(c['time_range'][1] for c in channels)}
    return {
        'report_contract_version': 2,
        'previous_contract': {'report_sha256': '626fd1bf83f9313955c1ad93c25135590a073d950c329387fd960946a697418f',
                              'script_sha256': 'aec02efa469523605d62bb6ec8a0297c0959e5c78c874858961ac305a421accd',
                              'original_check': 'passed before edits',
                              'migration': 'clips replaces singular clip; summary/samples/validation cover both tracks. Original primary keys, bind and scalar equations preserved; no extra backup file.'},
        'target': 'ULJM05500 MHP2G', 'evidence_kind': 'offline observation and static derivation; no live REA session/Evidence ID',
        'selection': {'animation_pack': 3377, 'animation_id': '0x594', 'decimal_id': 1428,
                      'lookup': {'normalized_id': 428, 'group': 4, 'entry': 28, 'entry_offset': entry_offset},
                      'purpose': '蓄力释放；沿用前轮动作身份，本轮仅解析指定资源',
                      'skeleton_pack': 1877, 'skeleton_member': 1, 'tracks': [0, 1],
                      'pairing': {'setter': '0x088d857c', 'primary_id_field': 'entity+0x324',
                                  'paired_id_field': 'entity+0x326', 'paired_id_addend': 100,
                                  'paired_animation_id': hex(pair_id), 'paired_decimal_id': pair_id,
                                  'consumer': '088d85c4 dispatches entity+0x324/0x326 to 08863e68 tracks0/1; 08863e68 passes track to 0885f998.'},
                      'authority': 'Loader-derived default row0 slot0 variant162 and animation row0 appearance0, not magic-only attribution.',
                      'actual_player_selection': None, 'selection_limit': 'Default candidate chosen explicitly for offline validation; no save-state supplied, not proof of current player sex/equipment/appearance.'},
        'sources': sources, 'code_sources': code, 'prior_report_sources': prior_sources,
        'eboot_mapping': {'base': hex(BASE), 'file_origin': hex(ORIGIN), 'status': 'prior supplied mapping, fixed artifact SHA verified'},
        'component_type_map': {hex(k): {'index': v, 'name': COMPONENTS[v]} for k,v in type_map.items()},
        'clips': clips, 'skeleton': skeleton,
        'animation_directory': {'group_count': len(groups), 'directory_byte_range': [0, first_table],
                                'groups': [{k: v for k,v in group.items() if k != 'entries'} for group in groups],
                                'lookup_rule': '0886524c: group=(id%1000)//100; entry=(id%1000)%100; signed offset -1 means absent; clip end from declared size, checked against all later indexed payload starts.'},
        'binding': {'method': '0885f998/0885f920 first search the full tree from runtime root0 for the first matching group. 0885f840 binds a group-filtered depth-first traversal of that subtree; unmatched children skipped, non-root siblings visited. No numeric concatenation or node ID lookup.',
                    'matching_subtree_roots': [order[0] for order in orders],
                    'group0_clip_to_skeleton': orders[0], 'group1_clip_to_skeleton': orders[1],
                    'unbound_skeleton_nodes': [], 'duplicate_bound_skeleton_nodes': [],
                    'covered_skeleton_nodes': sorted(bound_nodes), 'all_21_nodes_covered': True,
                    'root_motion_candidate_node': skeleton['nodes'][skeleton['roots'][0]]['first_child'],
                    'identity_limit': 'Ordinal mapping verified against this selected skeleton only; no anatomical bone names assigned.'},
        'summary': {'clip_count': len(clips), 'node_count': len(all_nodes),
                    'channel_count': len(all_channels), 'key_count': sum(c['key_count'] for c in all_channels),
                    'end_time_consumer_max_last_key': max(c['time_range'][1] for c in all_channels),
                    'clip_bytes_consumed': len(clip_data)+len(paired_data), 'clip_bytes_unparsed': 0,
                    'skeleton_nodes_covered': len(bound_nodes),
                    'channel_types_present': sorted({c['type'] for c in all_channels}),
                    'scale_channels_present': any(c['component_index'] < 3 for c in all_channels)},
        'sampling_semantics': {'component_order': COMPONENTS,
                               'axis_names': '0/1/2 are consumer storage components, not verified world axes',
                               'curve': 'dt=t1-t0,u=(t-t0)/dt; H00*v0+H10*dt*out0+H01*v1+H11*dt*in1',
                               'tangent_units': 'raw value per clip time unit; multiply dt in normalized Hermite',
                               'rotation_factor_exact_f32': ROTATION_FACTOR, 'rotation_factor_bits': '0x39c90fdb',
                               'translation_factor': 0.0625,
                               'binding_rule': '0885fa04 copies node base S/R/T (initialized bind here), then overwrites only keyed components. Missing channels retain that base, not zero or invented keys; unmatched groups are not evaluated and retain their existing pose. Transition old-pose buffers/blending are not reconstructed.',
                               'dual_track_time': 'Samples explicitly request equal clip time on both tracks; setter copies timing fields, but no live schedule or independent track clock/blend state is asserted.',
                               'pose_time': '0885fa04 truncates nonnegative float to uint; float_time_curve_components is neutral curve/root-consumer-style sampling, not a rendered pose.',
                               'root_motion': 'No entity transform or final gameplay trajectory applied; local root displacement must remain separate from world movement.'},
        'samples': samples, 'real_examples': examples, 'validation': validation,
        'corrections_to_previous_scope': [
            '0x594单独仅覆盖9条group0记录；本轮通过真实目录、+100配对setter和同树group1遍历验证0x5f8的12条记录，两轨不重复且穷尽此默认骨架21节点，不依据9+12算术强拼。',
            '通道映射表不是仅连续九个值：consumer以ushort type直接索引int表；本轮定点读取索引8/16/32/64/128/256。',
            '0885f998伪代码0885f920(param1,param1)遗漏第三参数：raw a2保留原track，wrapper随后把clip/track/oldFlag分别置a2/a3/t0传0885f840。',
            '动画值覆盖绑定组件，不把curve或pose-bind误叫绑定上叠加的动画delta。',
            '088632d0直接pose矩阵路径未读取S0..S2；无scale频道不能据此声称完整TRS矩阵已还原。'],
        'unknowns': ['实际玩家资源选择需要存档或明确的player设备/appearance值；本轮只有默认候选。',
                     '双clip覆盖默认21节点，但装备独立骨架、完整解剖命名、实际transition旧pose/混合状态和运行时双轨时钟仍未覆盖。',
                     '完整高位channel codec标志意义未知；本轮只验证所选0x801200xx的8-byte signed-short consumer路径。',
                     '轴手性、世界上下/前方向、Euler矩阵约定与scale应用未验证；不输出引擎矩阵或四元数。',
                     '时间单位对wall-clock频率未证实；164不是秒或已验证显示帧率。',
                     '双精度中立采样不模拟VFPU近似/舍入；离线静态一致性不等于原游戏画面对照。'],
        'next_steps': ['先提供/确认实际保存的row、slot0与appearance选择，检查骨架兼容和group0遍历。',
                       '若要world挂接坐标，先证实矩阵乘序、轴约定、parent组合及装备挂接局部变换；本报告只提供真实局部组件。',
                       '定点核对088632d0和矩阵消费者的VFPU轴/scale约定；如获许可，再被动画面或pose记录对照。'],
        'reproduce': {'command': 'python3 mh/tools/hunter_clip_probe.py --write-report',
                      'check_only': 'python3 mh/tools/hunter_clip_probe.py --check',
                      'requirements': 'Python3 standard library only; no target execution, Ghidra or Godot',
                      'writes_only': str(ROOT/'analysis/hunter_clip.json'),
                      'script': str(Path(__file__).resolve()), 'script_sha256': identity(Path(__file__).resolve())},
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--write-report', action='store_true')
    mode.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        report = run()
        destination = ROOT/'analysis/hunter_clip.json'
        if args.write_report:
            require(destination.parent.is_dir(), 'report parent missing')
            previous_bytes = destination.read_bytes()
            previous = json.loads(previous_bytes)
            if 'report_contract_version' not in previous:
                require(sha(previous_bytes) == report['previous_contract']['report_sha256'],
                        'unexpected original report; refusing migration')
                primary = report['clips'][0]
                preserved_nodes = [{**node, 'channels': [
                    {k: v for k,v in channel.items() if k != 'keys_range_sha256'}
                    for channel in node['channels']]} for node in primary['nodes']]
                require(previous['clip']['nodes'] == preserved_nodes
                        and all(primary['header'][k] == v for k,v in previous['clip']['header'].items())
                        and previous['skeleton'] == report['skeleton'], 'original clip/skeleton evidence changed')
                for old_sample, new_sample in zip(previous['samples'], report['samples']):
                    require(old_sample['requested_clip_time'] == new_sample['requested_clip_time']
                            and all(all(new_bone[k] == v for k,v in old_bone.items())
                                    for old_bone, new_bone in zip(old_sample['bones'], new_sample['bones'])),
                            'original group0 static samples changed')
            encoded = json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False)+'\n'
            require(json.loads(encoded) == report, 'serialized report contract mismatch')
            destination.write_text(encoded)
        elif args.check:
            require(json.loads(destination.read_text()) == report, 'stored report differs from reproduced evidence')
        print(json.dumps({'summary': report['summary'], 'binding': report['binding'],
                          'real_examples': report['real_examples'],
                          'validation': report['validation']}, ensure_ascii=False, indent=2))
    except (ValueError, OSError, KeyError, StopIteration) as error:
        parser.exit(2, f'probe failed: {error}\n')
