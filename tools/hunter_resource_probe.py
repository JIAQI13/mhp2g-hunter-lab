#!/usr/bin/env python3
"""Small offline ULJM05500 resource probe. Does not execute game or open Ghidra."""
import argparse
import hashlib
import json
import math
import struct
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EBOOT = 'sysdir/PSP_GAME/SYSDIR/ULJM05500_EBOOT.BIN'


def u32(data, offset):
    return struct.unpack_from('<I', data, offset)[0]


def i32(data, offset):
    return struct.unpack_from('<i', data, offset)[0]


def va_offset(address):
    return 0x25b4 + address - 0x08804000


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source(path, data, start=0, end=None):
    end = len(data) if end is None else end
    assert 0 <= start <= end <= len(data)
    return {'path': str(ROOT / path), 'file_sha256': digest(data),
            'range': {'start': start, 'end_exclusive': end},
            'range_sha256': digest(data[start:end])}


def skeleton(data, off, size):
    end = off + size
    flags, stored_count, declared_size, _, root_count, first = struct.unpack_from('<6I', data, off)
    count = stored_count - bool(flags & 0x80000000)
    if not 0 < count <= 512 or root_count > 4:
        return {'status': 'unsupported_header', 'stored_count': stored_count}
    roots = list(struct.unpack_from('<' + 'I' * root_count, data, off + 24))
    cursor = off + first + 12
    nodes = []
    for index in range(count):
        if cursor < off or cursor + 0x54 > end:
            return {'status': 'invalid_record_range', 'nodes_examined': len(nodes)}
        links = struct.unpack_from('<3i', data, cursor + 0x10)
        step = u32(data, cursor + 8)
        node = {'index': index, 'offset': cursor, 'record_size': step,
                'id': u32(data, cursor), 'field_0xc': u32(data, cursor + 12),
                'parent_candidate': links[0], 'first_child_candidate': links[1],
                'next_sibling_candidate': links[2],
                'scale': list(struct.unpack_from('<3f', data, cursor + 0x1c)),
                'rotation_euler': list(struct.unpack_from('<3f', data, cursor + 0x2c)),
                'translation': list(struct.unpack_from('<3f', data, cursor + 0x3c)),
                'field_0x4c': u32(data, cursor + 0x4c),
                'animation_channel': u32(data, cursor + 0x50)}
        nodes.append(node)
        cursor += step
    valid_links = all(-1 <= n[k] < count for n in nodes for k in
                      ['parent_candidate', 'first_child_candidate', 'next_sibling_candidate'])
    finite = all(math.isfinite(x) for n in nodes for k in
                 ['scale', 'rotation_euler', 'translation'] for x in n[k])
    acyclic = True
    for node in nodes:
        seen = set()
        current = node['index']
        while current != -1 and valid_links:
            if current in seen:
                acyclic = False
                break
            seen.add(current)
            current = nodes[current]['parent_candidate']
    return {'status': 'parsed', 'flags': flags, 'stored_count': stored_count,
            'node_count': count, 'declared_size': declared_size,
            'roots': roots, 'nodes': nodes,
            'validation': {'size_matches': declared_size == size,
                           'record_walk_end_matches': cursor == end,
                           'indices_in_range': valid_links,
                           'parent_candidates_acyclic': acyclic,
                           'finite_bind_components': finite,
                           'roots_in_range': all(r < count for r in roots)},
            'interpretation': 'TRS fields established by 08860054; parent/child/sibling labels inferred from 08867894 links, not anatomical names.'}


def animation_table(data):
    groups = []
    first_table = u32(data, 4)
    group_count = first_table // 8
    if first_table % 8 or not 1 <= group_count <= 10:
        return {'status': 'invalid_group_directory_size', 'first_table': first_table}
    for group in range(group_count):
        count, table = struct.unpack_from('<II', data, group * 8)
        if count > 100 or table + count * 4 > len(data):
            return {'status': 'invalid_group_table', 'group': group}
        entries = []
        for item in range(count):
            offset = i32(data, table + item * 4)
            entry = {'id': group * 100 + item, 'table_offset': table + item * 4,
                     'offset': offset}
            if offset != -1:
                entry['in_range'] = 0 <= offset <= len(data) - 20
                if entry['in_range']:
                    entry['header_u32'] = list(struct.unpack_from('<5I', data, offset))
            entries.append(entry)
        groups.append({'group': group, 'count': count, 'offset': table, 'entries': entries})
    return {'status': 'parsed_group_index', 'groups': groups,
            'limitations': 'Index only, following 0886524c. Clip/keyframe encoding not restored.'}


def inspect(index, eboot):
    path = f'databin/{index:04d}.bin'
    data = (ROOT / path).read_bytes()
    result = {'pack_id': index, 'source': source(path, data), 'size': len(data),
              'magic_prefix_hex': data[:16].hex(), 'members': []}
    expected_sha1 = eboot[va_offset(0x08976d00) + index * 20:va_offset(0x08976d00) + (index + 1) * 20]
    result['original_digest_validation'] = {
        'expected_sha1': expected_sha1.hex(), 'actual_sha1': hashlib.sha1(data).hexdigest(),
        'matches': expected_sha1 == hashlib.sha1(data).digest(),
        'expected_nonzero': any(expected_sha1)}
    count = u32(data, 0)
    if 0 < count <= 16 and 4 + count * 8 <= len(data):
        pairs = [struct.unpack_from('<II', data, 4 + member * 8) for member in range(count)]
        if all(4 + count * 8 <= off <= off + size <= len(data) for off, size in pairs):
            for member, (off, size) in enumerate(pairs):
                item = {'index': member, 'source': source(path, data, off, off + size)}
                if data[off:off + 4] == b'pmo\0':
                    item['pmo'] = {'version': data[off + 4:off + 8].decode('ascii').rstrip('\0'),
                                   'declared_size': u32(data, off + 8),
                                   'mesh_group_count': struct.unpack_from('<H', data, off + 0x1c)[0],
                                   'material_count': struct.unpack_from('<H', data, off + 0x1e)[0]}
                elif member == 1 and data[off:off + 4] == b'\0\0\0\xc0':
                    item['skeleton'] = skeleton(data, off, size)
                elif data[off:off + 4] == b'.TMH':
                    item['texture_header'] = {'magic': '.TMH', 'version_bytes': data[off + 4:off + 8].decode('ascii'),
                                              'count_candidate': u32(data, off + 8), 'decoded': False}
                result['members'].append(item)
    if index in (3377, 3378):
        result['animation_index'] = animation_table(data)
        for group in result['animation_index'].get('groups', []):
            for entry in group['entries']:
                if entry.get('in_range'):
                    clip_size = entry['header_u32'][2]
                    if entry['offset'] + clip_size <= len(data):
                        entry['source'] = source(path, data, entry['offset'], entry['offset'] + clip_size)
    return result


def main():
    started = time.perf_counter()
    parser = argparse.ArgumentParser()
    parser.add_argument('--inspect', type=int, nargs='*', default=[57, 1715, 1877, 2027, 2059, 2400, 2742, 3080, 3377, 3378, 3388, 3941])
    args = parser.parse_args()
    if any(not 0 <= index <= 6601 for index in args.inspect):
        parser.error('pack IDs must be 0..6601')
    eboot = (ROOT / EBOOT).read_bytes()
    addresses = [(0x089b6378, 0x84), (0x089b16ac, 0x48), (0x089b1804, 8),
                 (0x089b1784, 0x20), (0x089b17c4, 0x20), (0x089ad860, 0x28), (0x089acad0, 0x50), (0x08975984, 4), (0x089aa6dc, 0x18)]
    tables = [{'virtual_address': hex(address), 'source': source(EBOOT, eboot, va_offset(address), va_offset(address) + size),
               'u16': list(struct.unpack_from('<' + 'H' * (size // 2), eboot, va_offset(address)))} for address, size in addresses]
    weapon_types = eboot[va_offset(0x08975984):va_offset(0x08975984) + 550]
    first_type0 = weapon_types.index(0)
    selected_ids = list(dict.fromkeys(args.inspect + [3388 + first_type0]))
    files = [inspect(index, eboot) for index in selected_ids]
    code_names = ['decomp_ovl/09a605a0.c', 'decomp_ovl/09a60698.c', 'decomp_ovl/09a607f0.c',
                  'decomp/088ddf50.c', 'decomp/088de504.c', 'decomp/08866e08.c', 'decomp/088d8cd0.c',
                  'decomp/08866f64.c', 'decomp/08866fa8.c', 'decomp/088673c4.c', 'decomp/08867f2c.c',
                  'decomp/0886822c.c', 'decomp/088bb748.c', 'decomp/088623d4.c', 'decomp/08867894.c',
                  'decomp/08860054.c', 'decomp/0886524c.c', 'decomp/088d8a50.c', 'decomp/08863e68.c',
                  'decomp/088dd6a0.c', 'decomp/088d1b58.c', 'decomp/088d1c10.c', 'decomp/088d321c.c', 'decomp/088d68b0.c', 'decomp/0885ccc8.c']
    report = {'target': 'ULJM05500 MHP2G', 'evidence_kind': 'offline bytes and existing pseudocode, no REA Evidence ID',
              'code_sources': [source(path, (ROOT / path).read_bytes()) for path in code_names],
              'eboot_tables': tables, 'resources': files,
              'facts': [
                  '088ddf50 constructs 09a605a0 hunter, then 08867ec0 loads six components and 0886822c loads weapon component slot6.',
                  'Each component package is count:u32, then (absolute member offset:u32,length:u32) pairs, established by 088bb748. Members0/1/2 feed mesh/skeleton/texture consumers.',
                  '088de504 -> 08866e08 chooses component base + equipment/display variant; rows089b16ac are [1715,2027,2059,2400,2742,3080] and [62,376,406,746,1086,1419]. Override rows089b16c4 are [-1,-1,2373,-1,-1,-1] and [-1,-1,719,-1,-1,-1]. Exact active selection requires player equipment data.',
                  '088d8cd0 selects slot0 default variant162 from089b1784 for row0 (slot0 pack1877); row1 default variant163 from089b17c4 (slot0 pack225). Other slots use supplied equipment variant except slots3/4 special default lookup.',
                  '08866f64 weapon model package=3388+weapon equipment ID; 08866fa8 slot7 animation package base3377(row0) or3378(row1)+u8 appearance value.',
                  '08867894 skeleton count=u32@+4 minus one if header bit31 set; roots count@+0x10; roots indices@+0x18; first node=base+u32@+0x14+0xc; next node +=u32@node+8.',
                  '08860054 consumes node scale:f32x3@+0x1c, Euler rotation:f32x3@+0x2c, translation:f32x3@+0x3c, and builds local matrix with VFPU rotations; these are rest/bind TRS, not an inverse-bind matrix file.',
                  '08867894 maps node links@+0x10/+0x14/+0x18 to runtime+0x144/+0x14c/+0x148, node channel@+0x50; runtime node stride0x250.',
                  '0886524c animations use decimal group=(id%1000)/100, entry=id%100, (count,offset) stride8, signed entry offset -1 means absent. Selected3377/3378 have seven directory records inferred from first table offset0x38; do not assume ten physically stored groups.',
                  '088d8a50 uses shared manager+0x40 for IDs<1000 when nonzero, otherwise entity+0x1ac; greatsword0x594=1428 maps group4 entry28 in entity-local animation index.',
                  '088d1b58 passes flags0x11(state0)/0x12(otherwise), NOT bone indices; 088d1c10 consumes bitmasks. Actual attach matrix is in088d68b0: type0 uses hunter runtime node10 (10*0x250+0x90=0x17b0), with type0 offset/Euler table089aa6dc; weapon root=entity+0x1090.'
              ],
              'inferences': [
                  'Pack1877 and225 are default slot0 hunter component candidates, identified from loader formulas rather than PMO magic; verified sample skeletons can be shared with equipment-specific PMOs.',
                  'Greatsword is type0 by existing charge/action evidence; first type0 equipment ID and its actual model package are derived below from owning table08975984. Pack3388 is type7, not greatsword.',
                  'Node links likely parent/first-child/next-sibling; anatomical names not assigned.',
                  'Type0 attach node10 likely weapon-hand joint; anatomy and sheathed relocation remain unverified. Flags0x11/0x12 must not be named back/hand bones.'
              ],
              'unknowns': [
                  'Databin57 has valid PMO/skeleton/TMH container but is not attributed to hunter by any traced package ID.',
                  'Actual current hunter equipment/sex/weapon equipmentID are unavailable without a saved state; candidates do not select user current appearance.',
                  'Clip keyframe codec, root motion, full animation reconstruction and animation visualization not performed.',
                  'Shared animation manager+0x40 producer/package ID not traced; Head/dbsT not identified as hunter skeleton formats.',
                  'PMO vertices/weights and TMH pixels not decoded; coordinate handedness, Euler order/units require assembly or further consumer verification.'
              ],
              'next_entries': ['0885f998 and08860254 for clip node/keyframes', '088dd6a0 ->089ad874 records (stride20) for weapon override attach descriptors',
                               '089ad860 fallback has zero descriptors: trace why entity+0x7f4 is overridden for actual weapon',
                               'Find producer of hunter manager+0x40 (09a4ae04) for shared animation pack',
                               'Confirm concrete type0 weapon display/name via equipment table, then decode only its selected PMO vertices'],
              'coverage': {'selected_pack_ids': selected_ids, 'full_archive_scan': False,
                           'skeletons': 'All node records in selected supported member1, not all game skeletons.',
                           'animation': 'Group index only in3377/3378; no keyframe decode.',
                           'head_dbst': 'No semantic parser or global claim.', 'game_execution': False, 'ghidra_opened': False},
              'measurement': {'elapsed_seconds': time.perf_counter() - started, 'token_usage': 'unmeasured', 'peak_process_family_memory': 'unmeasured'}}
    report['first_greatsword_type0'] = {'equipment_id': first_type0, 'model_pack_id': 3388 + first_type0,
                                        'source': source(EBOOT, eboot, va_offset(0x08975984), va_offset(0x08975984) + first_type0 + 1)}
    clip_probes = []
    for resource in files:
        groups = resource.get('animation_index', {}).get('groups', [])
        if len(groups) > 4:
            entries = groups[4]['entries']
            clip_probes.append({'pack_id': resource['pack_id'], 'requested_animation_id': 1428,
                                'status': 'in_range' if len(entries) > 28 else 'absent_by_group_count',
                                'entry': entries[28] if len(entries) > 28 else None})
    report['greatsword_release_clip_index_probes'] = clip_probes
    report['weapon_id0'] = {'equipment_id': 0, 'model_pack_id': 3388,
                            'type_from_08975984': eboot[va_offset(0x08975984)],
                            'attach_node_index_type0': 10,
                            'type0_attach_translation': list(struct.unpack_from('<3f', eboot, va_offset(0x089aa6dc))),
                            'type0_attach_euler': list(struct.unpack_from('<3f', eboot, va_offset(0x089aa6dc) + 12))}
    output = ROOT / 'analysis/hunter_resources.json'
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + '\n')
    print('output', output)
    for resource in files:
        print(resource['pack_id'], 'sha1_ok', resource['original_digest_validation']['matches'],
              [(m['index'], m.get('skeleton', {}).get('node_count'), m.get('skeleton', {}).get('validation')) for m in resource['members'] if 'skeleton' in m])
    print('elapsed', report['measurement']['elapsed_seconds'])


if __name__ == '__main__':
    main()
