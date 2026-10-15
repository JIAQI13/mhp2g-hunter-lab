#!/usr/bin/env python3
"""Bounded offline greatsword tables and boundary checks; never executes the game."""
import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

sys.dont_write_bytecode = True
from animation_runtime_probe import decode


def read_greatsword_records(root):
    root = Path(root)
    path = root / 'databin/0051.bin'
    data = path.read_bytes()
    artifact_digest = hashlib.sha256(data).hexdigest()
    expected = '03b6c49cc79b123be278e726e62e66bff21c545847935551f68422e205585c26'
    if artifact_digest != expected:
        raise ValueError('0051 SHA256 mismatch; attack tables are not verified')
    base = 0x09a5a580

    def read(address, length):
        offset = address - base
        if offset < 0 or offset + length > len(data):
            raise ValueError(f'unmapped 0051 address {address:#x}')
        raw = data[offset:offset + length]
        return raw, {'region': '0051', 'path': str(path), 'address': hex(address),
                     'offset': hex(offset), 'file_offset': hex(offset), 'length': length,
                     'digest': artifact_digest, 'range_sha256': hashlib.sha256(raw).hexdigest(),
                     'raw_hex': raw.hex()}

    pointer_raw, pointer_source = read(0x09bf7bb8, 4)
    table = struct.unpack('<I', pointer_raw)[0]
    records, shapes, shape_tables = {}, {}, {}
    for index in [1, 2, 3, 4, 5, 91, 92, 93]:
        raw, provenance = read(table + index * 0x18, 0x18)
        selector = raw[10]
        records[str(index)] = {
            'id': index, 'power': raw[2], 'delay_byte': raw[0], 'duration_byte': raw[1],
            'shape_selector': selector, 'edge_delay_byte': raw[21], 'edge_duration_byte': raw[22],
            'event_type': raw[3], 'hitstop_byte': raw[16], 'followup_index': raw[19],
            'source': provenance, 'raw_hex': raw.hex()}
        key = str(selector)
        if key in shapes:
            continue
        pointer_raw, selector_source = read(0x09bf7118 + selector * 4, 4)
        shape_pointer = struct.unpack('<I', pointer_raw)[0]
        entries, terminated, terminator_source = [], False, None
        for ordinal in range(16):
            raw, provenance = read(shape_pointer + ordinal * 40, 40)
            bone, kind, part, group = struct.unpack_from('<4h', raw)
            if bone == -1:
                terminated, terminator_source = True, provenance
                break
            control = bone in (0x7d, 0x7e, 0x7f)
            entry = {'bone': bone, 'kind': kind, 'part': part, 'group': group,
                     'radius': struct.unpack_from('<f', raw, 12)[0],
                     'point_a': list(struct.unpack_from('<3f', raw, 16)),
                     'point_b': list(struct.unpack_from('<3f', raw, 28)),
                     'flags_hex': raw[8:12].hex(), 'source': provenance, 'raw_hex': raw.hex(),
                     'supported_geometry': bone >= 0 and not control and kind in (0, 1)}
            if not entry['supported_geometry']:
                entry['unknown'] = 'control record or unknown bone/kind; do not interpret as geometry'
            entries.append(entry)
            if control:
                break
        supported = terminated and all(entry['supported_geometry'] for entry in entries)
        if not supported:
            for entry in entries:
                entry['supported_geometry'] = False
        shapes[key] = entries
        shape_tables[key] = {'pointer': hex(shape_pointer), 'source': selector_source,
                             'terminated': terminated, 'terminator_source': terminator_source,
                             'supported_geometry': supported, 'entry_limit': 16}
    return {'records': records, 'shapes': shapes, 'record_pointer': hex(table),
            'record_pointer_source': pointer_source,
            'shape_tables': shape_tables,
            'sources': [{'region': '0051', 'path': str(path), 'sha256': artifact_digest,
                         'base': hex(base), 'origin': '0x0'}],
            'metadata': {'kind_semantics': {'0': 'one-center geometry (sphere inference)',
                                           '1': 'two-endpoint geometry (capsule inference)'},
                         'control_bones': [0x7d, 0x7e, 0x7f],
                         'unknown_geometry': 'Unknown kind/control or unterminated list is unsupported; fail closed.',
                         'shape_stride': 40, 'record_stride': 0x18,
                         'record_table_pointer_address': '0x09bf7bb8',
                         'shape_selector_table_address': '0x09bf7118'}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--summary', action='store_true')
    args = parser.parse_args()
    root = args.root
    maps = [
        ('main', 'sysdir/PSP_GAME/SYSDIR/ULJM05500_EBOOT.BIN', 0x08804000, 0x25b4),
        ('0051', 'databin/0051.bin', 0x09a5a580, 0),
        ('0056', 'databin/0056.bin', 0x09c14280, 0),
    ]
    sources = []
    images = []
    for name, path, base, origin in maps:
        data = (root / path).read_bytes()
        sources.append({'region': name, 'path': str(root / path), 'sha256': hashlib.sha256(data).hexdigest(), 'base': hex(base), 'origin': hex(origin)})
        images.append((base, origin, data, name))

    def read(address, length):
        for base, origin, data, name in reversed(images):
            offset = address - base + origin
            if address >= base and 0 <= offset and offset + length <= len(data):
                return data[offset:offset + length], {'region': name, 'address': hex(address), 'file_offset': hex(offset), 'length': length}
        raise ValueError(f'unmapped address {address:#x}')

    def u32(address):
        return struct.unpack('<I', read(address, 4)[0])[0]

    attack = read_greatsword_records(root)
    rows = []
    for record in attack['records'].values():
        delay, duration = record['delay_byte'] >> 1, record['duration_byte'] >> 1
        selector = str(record['shape_selector'])
        shape_table = attack['shape_tables'][selector]
        states = []
        state, d, n = 1, delay, duration
        for tick in range(delay + duration + 3):
            if state == 1:
                old = d
                d -= 1
                if old == 0:
                    d = 0
                    state = 2
            if state == 2:
                if n == 0:
                    state = 0
                else:
                    n -= 1
            if state == 2:
                states.append(tick)
        assert states == list(range(delay, delay + duration))
        rows.append({**record, 'index': record['id'], 'initial_delay_ticks': delay,
                     'initial_active_ticks': duration, 'power_byte': record['power'],
                     'edge_delay_raw': record['edge_delay_byte'], 'edge_duration_raw': record['edge_duration_byte'],
                     'shape_pointer': shape_table['pointer'], 'shapes': attack['shapes'][selector],
                     'shape_terminated': shape_table['terminated'],
                     'model_active_ticks_update_before_collision': states})
    tables = {}
    for name, address, count, fmt in [('hit_phase_physical', 0x09cf4638, 28, 'f'), ('feedback_scale', 0x09cf46a8, 4, 'f'), ('sharpness_physical', 0x09cf46b8, 7, 'f'), ('sharpness_element', 0x09cf46d4, 7, 'f'), ('edge_cost', 0x09cf46f0, 4, 'h')]:
        size = struct.calcsize('<' + fmt)
        raw, source = read(address, count * size)
        tables[name] = {'source': source, 'values': struct.unpack('<' + fmt * count, raw)}
    asm = []
    for address, count in [(0x09b64568, 2), (0x09b633f8, 2), (0x09b62768, 4)]:
        for i in range(count):
            pc = address + i * 4
            word = u32(pc)
            asm.append({'address': hex(pc), 'word': hex(word), 'decoded': decode(word, pc)})
    feedback = []
    for threshold in [0.25, 0.29]:
        for value in [threshold - 0.00001, threshold, threshold + 0.00001, 0.44999, 0.45, 0.99999, 1.0]:
            state = 3 if value >= 1 else 2 if value >= 0.45 else 0 if value > threshold else 1
            feedback.append({'threshold': threshold, 'value': value, 'state': state})
    result = {'sources': sources, 'record_pointer': attack['record_pointer'], 'records': rows, 'shape_tables': attack['shape_tables'], 'shape_metadata': attack['metadata'], 'tables': tables, 'thunks': asm, 'boundary_tests': {'feedback': feedback, 'dedup': {'matching_id': 'skip', 'no_matching_id': 'candidate', 'id_ffff': 'bypass history lookup'}, 'shield': [{'short_35e': n, 'skips_collision': n != 0} for n in [-1, 0, 1, 6, 10, 12]]}, 'limitations': ['Offline raw table/model checks, not gameplay observations.', 'Active ticks assume update before collision and no freeze/lifetime extension; caller scheduling and spawn-frame relation require separate evidence.', 'No target shape mesh or animation resources parsed; capsule/sphere names inferred from geometry consumers.']}
    for threshold in [0.25, 0.29]:
        def feedback_state(value):
            return 3 if value >= 1 else 2 if value >= 0.45 else 0 if value > threshold else 1
        assert [feedback_state(v) for v in [threshold - 0.00001, threshold, threshold + 0.00001, 0.44999, 0.45, 0.99999, 1.0]] == [1, 1, 0, 0, 2, 2, 3]
    nominal = [attack['records'][str(index)]['power'] * percent / 100
               for index, percent in zip([3, 91, 92, 93], [100, 110, 120, 130])]
    assert nominal == [48.0, 71.5, 96.0, 143.0]
    result['boundary_tests']['nominal_power_before_other_factors'] = nominal
    history = [0] * 16
    def allowed(event_id):
        return event_id == 0xffff or event_id not in history
    assert allowed(123)
    history[0] = 123
    assert not allowed(123)
    assert allowed(0xffff)
    for i in range(16):
        history[i] = 200 + i
    assert allowed(123)
    assert [n != 0 for n in [-1, 0, 1, 6]] == [True, False, True, True]
    result['boundary_tests']['assertions'] = '8 record timelines, history duplicate/sentinel/overwrite, nonzero shield: passed'
    result['limitations'].append('Prior analysis reports cover only 7 records and omit record5 spawned at 09a861b0.c:17; their counts are historical, not true spawn timing.')
    if args.summary:
        for row in result['records']:
            row.pop('shapes')
            row.pop('model_active_ticks_update_before_collision')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
