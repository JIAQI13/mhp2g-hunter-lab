#!/usr/bin/env python3
"""Bounded offline PMO/GE probe; never executes target code."""
import argparse
import hashlib
import json
import math
import struct
import time
from pathlib import Path
from hunter_resource_probe import skeleton

ROOT = Path(__file__).resolve().parents[1]
PACKS = (1877, 3389)


class Unsupported(ValueError):
    pass


def need(condition, reason):
    if not condition:
        raise Unsupported(reason)


def unpack(data, fmt, off):
    size = struct.calcsize('<' + fmt)
    need(0 <= off <= len(data) - size, f'out of range: {off}+{size}/{len(data)}')
    return struct.unpack_from('<' + fmt, data, off)


def u32(data, off):
    return unpack(data, 'I', off)[0]


def source(path, data, start=0, end=None):
    end = len(data) if end is None else end
    need(0 <= start <= end <= len(data), 'invalid source range')
    return {'path': str(path), 'file_sha256': hashlib.sha256(data).hexdigest(),
            'range': [start, end], 'range_sha256': hashlib.sha256(data[start:end]).hexdigest()}


def bounds(points):
    return {'min': [min(p[k] for p in points) for k in range(3)],
            'max': [max(p[k] for p in points) for k in range(3)]} if points else None


def layout(vtype):
    need(vtype & ~0x1dfff == 0,
         f'unsupported through/reserved/morph vtype {vtype:#x}')
    codes = {'weights': (vtype >> 9) & 3, 'uv': vtype & 3,
             'color': (vtype >> 2) & 7, 'normal': (vtype >> 5) & 3,
             'position': (vtype >> 7) & 3}
    need(codes['position'] != 0, 'missing position')
    need(codes['color'] in (0, 4, 5, 6, 7), 'reserved color encoding')
    count = 1 + ((vtype >> 14) & 7) if codes['weights'] else 0
    fields, cursor, biggest = {}, 0, 1
    for name, n in [('weights', count), ('uv', 2), ('color', 1), ('normal', 3), ('position', 3)]:
        code = codes[name]
        if not code:
            continue
        size = (4 if code == 7 else 2) if name == 'color' else (0, 1, 2, 4)[code]
        cursor = (cursor + size - 1) // size * size
        fields[name] = {'offset': cursor, 'code': code, 'count': n, 'size': size}
        cursor += n * size
        biggest = max(biggest, size)
    return {'vtype': hex(vtype), 'stride': (cursor + biggest - 1) // biggest * biggest,
            'index_code': (vtype >> 11) & 3, 'weight_count': count, 'fields': fields}


def vertex(data, off, fmt, palette, scale):
    out = {'pmo_offset': off}
    for name, f in fmt['fields'].items():
        code, n = f['code'], f['count']
        if name == 'color':
            out['color_raw'] = unpack(data, 'I' if code == 7 else 'H', off + f['offset'])[0]
            continue
        unsigned = name in ('weights', 'uv')
        scalar = ('', 'B' if unsigned else 'b', 'H' if unsigned else 'h', 'f')[code]
        raw = list(unpack(data, scalar * n, off + f['offset']))
        divisor = (1, 128, 32768, 1)[code]
        values = [v / divisor for v in raw]
        need(all(math.isfinite(v) for v in values), 'nonfinite vertex attribute')
        out[name + '_raw'] = raw
        out[name] = values
    out['weighted_nodes'] = []
    for slot, weight in enumerate(out.get('weights', [])):
        if weight:
            need(slot in palette, f'unknown active GU bone slot {slot}')
            out['weighted_nodes'].append({'gu_slot': slot, 'node': palette[slot], 'weight': weight})
    out['pmo_scaled_position'] = [p * s for p, s in zip(out['position'], scale)]
    return out


def triangles(indices, primitive):
    if primitive == 3:
        need(len(indices) % 3 == 0, 'triangle-list remainder')
        return [indices[i:i + 3] for i in range(0, len(indices), 3)]
    if primitive == 4:
        need(len(indices) >= 3, 'short triangle strip')
        return [[indices[i + (i & 1)], indices[i + 1 - (i & 1)], indices[i + 2]]
                for i in range(len(indices) - 2)]
    if primitive == 5:
        need(len(indices) >= 3, 'short triangle fan')
        return [[indices[0], indices[i], indices[i + 1]] for i in range(1, len(indices) - 1)]
    raise Unsupported(f'unsupported primitive {primitive}')


def decode_list(pmo, dl, stop, palette, scale, expected_index=None, stream_end=None):
    state = {'origin': None, 'base': None, 'vertex': None, 'index': None, 'format': None}
    draws, words = [], []
    cursor = dl
    while cursor + 4 <= stop:
        word = u32(pmo, cursor)
        op, arg = word >> 24, word & 0xffffff
        words.append({'offset': cursor, 'word': hex(word)})
        if op == 0x14:
            need(arg == 0, 'nonzero ORIGIN argument')
            state['origin'] = cursor
        elif op == 0x10:
            need(arg == 0, 'nonzero BASE outside local PMO profile')
            state['base'] = 0
        elif op in (1, 2):
            need(state['origin'] is not None and state['base'] == 0, 'unknown relative address state')
            address = state['origin'] + arg
            need(op != 1 or address == stop, 'VADDR does not match descriptor+8')
            need(op != 2 or expected_index is None or address == expected_index,
                 'IADDR does not match descriptor+0xc')
            state['vertex' if op == 1 else 'index'] = address
        elif op == 0x12:
            state['format'] = layout(arg)
        elif op == 4:
            fmt = state['format']
            need(fmt is not None and state['vertex'] is not None, 'incomplete draw state')
            count, prim = arg & 0xffff, (arg >> 16) & 7
            need(count > 0 and arg >> 19 == 0, 'empty/reserved PRIM')
            code = fmt['index_code']
            idx_off = state['index']
            if code:
                need(idx_off is not None, 'missing IADDR')
                width = (0, 1, 2, 4)[code]
                indices = list(unpack(pmo, ('', 'B', 'H', 'I')[code] * count, idx_off))
                state['index'] += width * count
                need(state['index'] <= (len(pmo) if stream_end is None else stream_end),
                     'indices cross descriptor stream boundary')
            else:
                indices = list(range(count))
                width = 0
            maximum = max(indices)
            need(maximum < 65536, 'vertex resource bound exceeded')
            end = state['vertex'] + (maximum + 1) * fmt['stride']
            need(end <= len(pmo), 'vertex range exceeds PMO')
            need(not code or end <= idx_off, 'overlapping vertex/index streams')
            vertices = {str(i): vertex(pmo, state['vertex'] + i * fmt['stride'], fmt, palette, scale)
                        for i in sorted(set(indices))}
            tris = triangles(indices, prim)
            draws.append({'command_offset': cursor, 'primitive': prim,
                          'primitive_name': {3: 'triangles', 4: 'triangle_strip', 5: 'triangle_fan'}[prim],
                          'count': count, 'layout': fmt, 'vertex_base': state['vertex'],
                          'vertex_examined_range': [state['vertex'], end],
                          'index_range': [idx_off, state['index']] if code else None,
                          'indices': indices, 'triangles': tris, 'vertices': vertices,
                          'validation': {'triangle_count': len(tris),
                                         'expected_triangle_count': count // 3 if prim == 3 else count - 2,
                                         'degenerate_index_triangles': sum(len(set(t)) < 3 for t in tris)}})
            if not code:
                state['vertex'] += count * fmt['stride']
        elif op == 0x13:
            need(arg == 0, 'unsupported OFFSETADDR')
            state['origin'] = 0
        elif op == 0xb:
            need(arg == 0, 'unsupported RET')
            return {'status': 'decoded', 'commands': words, 'draws': draws, 'end': cursor + 4}
        elif op == 0x9b:
            pass  # TEXFUNC does not change vertex format or addresses.
        else:
            raise Unsupported(f'unsupported GE opcode {op:#x} at {cursor:#x}')
        cursor += 4
    raise Unsupported('RET not found before descriptor vertex data')


def parse_pack(pack, eboot):
    path = ROOT / f'databin/{pack:04d}.bin'
    data = path.read_bytes()
    count = u32(data, 0)
    need(1 <= count <= 16, 'unsupported member count')
    pairs = [unpack(data, 'II', 4 + i * 8) for i in range(count)]
    need(all(4 + count * 8 <= o <= o + s <= len(data) for o, s in pairs), 'invalid container')
    off, size = pairs[0]
    pmo = data[off:off + size]
    need(pmo[:8] == b'pmo\x001.0\x00', 'unsupported PMO version')
    need(u32(pmo, 8) == size, 'PMO size mismatch')
    scale = list(unpack(pmo, 'fff', 0x10))
    need(all(math.isfinite(x) and x > 0 for x in scale), 'invalid PMO scale')
    skoff, sksize = pairs[1]
    parsed_skeleton = skeleton(data, skoff, sksize)
    need(parsed_skeleton['status'] == 'parsed' and all(parsed_skeleton['validation'].values()),
         'skeleton owner validation failed')
    nodes = parsed_skeleton['node_count']
    scales = [n['scale'] for n in parsed_skeleton['nodes']]
    ngroups, materials = unpack(pmo, 'HH', 0x1c)
    need(ngroups <= 256, 'group resource bound')
    result = {'pack_id': pack, 'identity': 'slot0 default candidate, not current player' if pack == 1877 else
              'equipment ID1 / type0 model, not current player',
              'source': source(path, data), 'pmo_source': source(path, data, off, off + size),
              'skeleton_source': source(path, data, skoff, skoff + sksize),
              'node_count': nodes, 'pmo_scale': scale, 'group_count': ngroups,
              'material_count': materials, 'groups': [], 'bone_uploads': [],
              'skeleton_validation': parsed_skeleton['validation'],
              'bind_nodes': parsed_skeleton['nodes'],
              'all_bind_node_scales_unit': all(s == [1, 1, 1] for s in scales)}
    shaoff = 0x25b4 + 0x08976d00 - 0x08804000 + pack * 20
    result['sha1_matches_eboot'] = hashlib.sha1(data).digest() == eboot[shaoff:shaoff + 20]
    need(result['sha1_matches_eboot'], 'pack identity SHA1 mismatch')
    result['sha1_table_source'] = source(ROOT / 'sysdir/PSP_GAME/SYSDIR/ULJM05500_EBOOT.BIN',
                                        eboot, shaoff, shaoff + 20)
    palette = {}
    for g in range(ngroups):
        goff = u32(pmo, 0x20) + g * 24
        uploads = []
        ndesc, first = unpack(pmo, 'HH', goff + 0x14)
        need(ndesc <= 1024, 'descriptor resource bound')
        group = {'index': g, 'pmo_offset': goff, 'raw_u32': list(unpack(pmo, 'IIIIII', goff)), 'batches': []}
        for j in range(ndesc):
            at = u32(pmo, 0x24) + (first + j) * 16
            mat, nmap, mapfirst, relative, field8, fieldc = unpack(pmo, 'BBHIII', at)
            need(nmap <= 8, 'unsupported signed bone-upload count')
            for k in range(nmap):
                mapoff = u32(pmo, 0x2c) + 2 * (mapfirst + k)
                slot, node = unpack(pmo, 'BB', mapoff)
                need(slot < 8 and node < nodes, 'bone mapping out of range')
                palette[slot] = node
                uploads.append({'descriptor': j, 'pmo_offset': mapoff, 'gu_slot': slot, 'node': node})
            dl = u32(pmo, 0x34) + relative
            vertexstart = u32(pmo, 0x34) + field8
            batch = {'index': j, 'descriptor_offset': at, 'material_lookup_index': mat,
                     'bone_upload_count': nmap, 'bone_pair_first': mapfirst,
                     'dl_offset': dl, 'field_8': field8, 'field_c': fieldc,
                     'palette_after_upload': dict(palette)}
            try:
                next_dl = (u32(pmo, 0x34) + u32(pmo, at + 16 + 4)) if j + 1 < ndesc else len(pmo)
                need(dl < vertexstart <= u32(pmo, 0x34) + fieldc <= next_dl, 'unordered descriptor streams')
                batch.update(decode_list(pmo, dl, vertexstart, palette, scale,
                                         u32(pmo, 0x34) + fieldc, next_dl))
                batch_vertices = {v['pmo_offset']: v for d in batch['draws'] for v in d['vertices'].values()}
                batch['unique_referenced_vertex_count'] = len(batch_vertices)
                batch['referenced_bounds'] = bounds([v['pmo_scaled_position'] for v in batch_vertices.values()])
                last_vertex = max((d['vertex_examined_range'][1] for d in batch['draws']), default=vertexstart)
                batch['vertex_tail_uninterpreted_bytes'] = u32(pmo, 0x34) + fieldc - last_vertex
                batch['vertex_tail_interpretation'] = 'alignment/unreferenced bytes, not guessed as extra vertices'
            except Unsupported as exc:
                batch.update({'status': 'unknown', 'reason': str(exc), 'draws': []})
            group['batches'].append(batch)
        result['bone_uploads'].extend(uploads)
        result['groups'].append(group)
    draws = [d for g in result['groups'] for b in g['batches'] for d in b['draws']]
    verts = [v for d in draws for v in d['vertices'].values()]
    sums = [sum(v['weights']) for v in verts if 'weights' in v]
    weighted_nodes = [x['node'] for v in verts for x in v['weighted_nodes']]
    unique_count = len({v['pmo_offset'] for v in verts})
    result['validation'] = {'decoded_batches': sum(b['status'] == 'decoded' for g in result['groups'] for b in g['batches']),
                            'unknown_batches': sum(b['status'] != 'decoded' for g in result['groups'] for b in g['batches']),
                            'draw_count': len(draws), 'vertex_records_per_draw': len(verts),
                            'unique_referenced_vertex_records': unique_count,
                            'index_count': sum(d['count'] for d in draws),
                            'assembled_triangle_count': sum(len(d['triangles']) for d in draws),
                            'weight_sum_min': min(sums) if sums else None, 'weight_sum_max': max(sums) if sums else None,
                            'all_weight_sums_exact_one': all(s == 1 for s in sums),
                            'weighted_node_range': [min(weighted_nodes), max(weighted_nodes)] if weighted_nodes else None,
                            'primitive_counts_match': all(d['validation']['triangle_count'] == d['validation']['expected_triangle_count'] for d in draws),
                            'bind_shape_status': 'PMO-scaled input geometry decoded; final runtime bind shape unknown (matrix convention not instruction-verified)'}
    result['ge_input_bounds'] = bounds([v['position'] for v in verts])
    result['pmo_scaled_input_bounds'] = bounds([v['pmo_scaled_position'] for v in verts])
    return result


def geometric_candidates(resource):
    rows = []
    for g in resource['groups']:
        for b in g['batches']:
            for di, d in enumerate(b['draws']):
                for index, v in d['vertices'].items():
                    rows.append({'ref': [g['index'], b['index'], di, int(index)],
                                 'position': v['pmo_scaled_position'], 'weighted_nodes': v['weighted_nodes']})
    if not rows:
        return {'status': 'unknown', 'reason': 'no decoded geometry'}
    box = bounds([r['position'] for r in rows])
    spans = [box['max'][k] - box['min'][k] for k in range(3)]
    axis = max(range(3), key=lambda k: spans[k])
    extent = spans[axis]
    candidates = []
    for end in ('min', 'max'):
        boundary = box[end][axis]
        band = [r for r in rows if abs(r['position'][axis] - boundary) <= extent * .01]
        candidates.append({'end': end, 'coordinate': boundary, 'band_width': extent * .01,
                           'bounds': bounds([r['position'] for r in band]), 'vertices': band})
    return {'status': 'geometric_candidates_only', 'space': 'PMO-scaled GE input, not weapon/world pose',
            'rule': 'Choose longest AABB axis; retain BOTH endpoint bands within 1% of full span. No max-z anatomical label. Outer 25% bands are longitudinal blade/tip candidates, not proven cutting edges.',
            'longest_axis': axis, 'spans': spans, 'endpoint_candidates': candidates,
            'longitudinal_segment_candidates': [[box['min'][axis], box['min'][axis] + .25 * extent],
                                                 [box['max'][axis] - .25 * extent, box['max'][axis]]],
            'unknowns': ['Which endpoint is sword tip versus handle; requires topology/material or weapon attach alignment.',
                         'Actual blade edges, rendered pose and world sword-tip trajectory; collision bone14 Z intervals are not mesh vertices.']}


def checks():
    rejected = 0
    for value in (0, 0x800000 | 0x100, 0x40000 | 0x100, 0x104, 0x2100, 0x20100):
        try:
            layout(value)
        except Unsupported:
            rejected += 1
    need(rejected == 6, 'unsupported vtype test failed')
    for action in (lambda: vertex(b'\x80' + b'\x00' * 15, 0, layout(0xb22), {}, [1, 1, 1]),
                   lambda: vertex(b'\x00' * 15, 0, layout(0xb22), {0: 0}, [1, 1, 1]),
                   lambda: triangles([0, 1], 4), lambda: triangles([0, 1, 2, 3], 3)):
        try:
            action()
        except Unsupported:
            rejected += 1
        else:
            raise AssertionError('malformed mesh accepted')
    need(layout(0x4b22)['stride'] == 16, 'observed two-weight stride mismatch')
    need(layout(0xcb22)['stride'] == 18, 'observed four-weight stride mismatch')
    need(len(triangles([0, 1, 2, 3], 4)) == 2, 'strip count')
    need(triangles([0, 1, 2, 3], 4)[1] == [2, 1, 3], 'strip alternating winding')
    try:
        decode_list(b'\x00' * 32, 0, 32, {}, [1, 1, 1])
    except Unsupported:
        rejected += 1
    else:
        raise AssertionError('unknown DL accepted')
    return {'unsupported_cases_rejected': rejected, 'observed_stride_checks': 2,
            'strip_count_and_winding': True, 'runtime_or_visual_validation': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='parse and validate without writing outputs')
    args = parser.parse_args()
    started = time.perf_counter()
    eboot = (ROOT / 'sysdir/PSP_GAME/SYSDIR/ULJM05500_EBOOT.BIN').read_bytes()
    resources = [parse_pack(p, eboot) for p in PACKS]
    if args.check:
        for r, expected in zip(resources, ((916, 178, 798), (481, 137, 372))):
            v = r['validation']
            need(v['unknown_batches'] == 0 and v['all_weight_sums_exact_one'] and v['primitive_counts_match'],
                 'selected mesh regression validation failed')
            need((v['unique_referenced_vertex_records'], v['draw_count'], v['assembled_triangle_count']) == expected,
                 'selected mesh count regression failed')
    codepaths = ['decomp/' + p + '.c' for p in ('088623d4', '08862708', '08862724', '08862760', '088627ac',
                 '08864774', '08861714', '0886822c', '08867894', '08860534', '08860640')]
    codepaths += ['tools/hunter_resource_probe.py']
    codepaths += ['vendor/ppsspp-1.20.4/GPU/' + p for p in ('ge_constants.h', 'GPUCommon.cpp', 'GPUCommon.h', 'Common/VertexDecoderCommon.cpp')]
    report = {'target': 'ULJM05500 MHP2G', 'evidence_kind': 'existing pseudocode / offline original resource bytes / local PPSSPP source, no REA Evidence ID',
              'code_sources': [source(ROOT / p, (ROOT / p).read_bytes()) for p in codepaths],
              'prior_resource_report': source(ROOT / 'analysis/hunter_resources.json', (ROOT / 'analysis/hunter_resources.json').read_bytes()),
              'resources': [], 'weapon_geometry_candidates': geometric_candidates(resources[1]),
              'evidence_locations': [{'path': 'decomp/08864774.c', 'lines': [45, 105], 'claim': 'bone pairs, persistent slots and list call'},
                                     {'path': 'decomp/08860534.c', 'lines': [32, 131], 'claim': 'rest/inverse-like producer'},
                                     {'path': 'decomp/08860640.c', 'lines': [9, 25], 'claim': 'skin-matrix producing multiplication'},
                                     {'path': 'vendor/ppsspp-1.20.4/GPU/GPUCommon.cpp', 'lines': [886, 900], 'claim': 'GE address origin'},
                                     {'path': 'vendor/ppsspp-1.20.4/GPU/Common/VertexDecoderCommon.cpp', 'lines': [219, 324], 'claim': 'weight scaling and skin equation'},
                                     {'path': 'vendor/ppsspp-1.20.4/GPU/Common/VertexDecoderCommon.cpp', 'lines': [854, 891], 'claim': 'compressed GE position decoding'},
                                     {'path': 'vendor/ppsspp-1.20.4/GPU/Common/VertexDecoderCommon.cpp', 'lines': [1213, 1430], 'claim': 'field encoding/alignment/stride'}],
              'facts': ['PMO+0x20 group directory stride24; group+0x14 count and+0x16 first descriptor; +0x24 descriptors stride16 (08862724/088627ac).',
                        'Descriptor byte1 counts uploads; u16+2 indexes PMO+0x2c byte pairs (GU slot,node). 08864774 writes slot*12 to BONE MATRIX NUMBER then runtime node+0x50..0x88 twelve f32 words as GE float24 (word>>8).',
                        'Bone palette persists across descriptors: upload_count=0 REUSES prior palette; never interpret it as unskinned.',
                        'Display list base=PMO+u32(+0x34) (08862708); descriptor+4 selects relative list. GE ORIGIN0x14 sets current PC; VADDR/IADDR relative to it, vtype from command0x12, PRIM0x04 count low16/type bits16..18.',
                        'Indexed PRIM advances IADDR, not VADDR (PPSSPP GPUCommon.h); triangle strips alternate winding and restart at each PRIM.',
                        'GE fixed-point weights u8/128, u16/32768 (NOT /255 or /65535); positions and normals signed /128 or /32768; float untouched. Field order weights,UV,color,normal,position with per-field alignment and largest-alignment stride.',
                        'Both selected files use real GE s16 vertex data; no speculative proprietary compression decoder or fabricated assets.'],
              'skinning': {'established_GE_equation': 'p_skin = sum_j w_j * B_j * [p_GE,1]; B_j is the twelve-word GU matrix uploaded from runtime node+0x50; final model/view/projection are separate.',
                           'game_producer': '08860534 constructs runtime+0x10 inverse-like rest matrix from +0x90 (rest +0x150 composed with reciprocal PMO scales); 08860640 multiplies +0x10 and current +0x90 into +0x50. Euler/VFPU operand convention remains instruction-verification work.',
                           'pmo_scaled_input': 'diag(PMO f32+0x10/+0x14/+0x18) * p_GE, retained as explicit derived geometry; NOT claimed final bind/world pose.',
                           'bind_check': 'Raw attributes finite, skeleton range and unit local scale checked, weights sum checked. Actual rest-pose cancellation and final bind shape remain unknown; do not substitute guessed Euler matrices.',
                           'PSP_precision': 'Matrix uploads drop low8 mantissa bits (GE float24); Python decoded positions/weights are not a PSP instruction-level pose reproduction.'},
              'unknowns': ['Current player identity/equipment unavailable;1877 is only slot0, not a full six-part hunter mesh.',
                           'Matrix convention, final bind shape, exact sword tip/edge semantic assignment, attachment/world trajectory not verified.',
                           'Texture pixels/material visibility not decoded; descriptors are decoded independent of draw suppression by material state.',
                           'Unsupported reserved/morph/through vtypes, nonlocal control flow and unknown GE commands rejected with reason, no fallback geometry.'],
              'next_entries': ['08860054/08860534/08860640 VFPU instructions: prove rest/current matrix convention and cancellation with PMO scaling.',
                               '088d68b0 + node10 and089aa6dc: align weapon mesh endpoint candidates with actual attachment; do not equate them to bone14 hitboxes.',
                               '3389 member1 four-node rest/current matrices (mesh weights use nodes1/2); correlate palette with blade/handle topology.'],
              'verification': checks(), 'coverage': {'pack_ids': list(PACKS), 'all_six_body_parts': False, 'game_execution': False, 'Ghidra_opened': False, 'rendering': False}}
    for r in resources:
        report['resources'].append({k: v for k, v in r.items() if k != 'groups'} | {
            'batches': [{k: v for k, v in b.items() if k not in ('draws', 'commands')} |
                        {'draw_summary': {'count': len(b['draws']),
                                          'index_count': sum(d['count'] for d in b['draws']),
                                          'triangle_count': sum(len(d['triangles']) for d in b['draws']),
                                          'vtypes': sorted({d['layout']['vtype'] for d in b['draws']}),
                                          'primitives': sorted({d['primitive_name'] for d in b['draws']})}}
                        for g in r['groups'] for b in g['batches']]})
    report['measurement'] = {'elapsed_seconds': time.perf_counter() - started,
                             'scope': 'parsing and report preparation, excludes JSON serialization/output',
                             'token_usage': 'unmeasured', 'process_family_CPU_and_peak_memory': 'unmeasured'}
    if not args.check:
        (ROOT / 'analysis/hunter_mesh_data.json').write_text(json.dumps({'contract_version': 1,
            'space': 'GE input plus separately labelled PMO-scaled input; not posed render assets', 'resources': resources},
            ensure_ascii=False, indent=2, allow_nan=False) + '\n')
        (ROOT / 'analysis/hunter_mesh.json').write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + '\n')
    if args.check:
        saved_data = ROOT / 'analysis/hunter_mesh_data.json'
        saved_report = ROOT / 'analysis/hunter_mesh.json'
        if saved_data.exists() and saved_report.exists():
            loaded = json.loads(saved_data.read_text())
            retained_report = json.loads(saved_report.read_text())
            need(loaded['resources'] == json.loads(json.dumps(resources)), 'retained mesh data mismatch')
            need([r['validation'] for r in retained_report['resources']] == [r['validation'] for r in resources],
                 'retained mesh report validation mismatch')
            print('retained JSON outputs parsed and match fresh decode')
    for r in resources:
        print(r['pack_id'], json.dumps(r['validation'], ensure_ascii=False))
        print('scaled_input_bounds', r['pmo_scaled_input_bounds'])
    print('checks', report['verification'], 'elapsed', report['measurement']['elapsed_seconds'])


if __name__ == '__main__':
    main()
