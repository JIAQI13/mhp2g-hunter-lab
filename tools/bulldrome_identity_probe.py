#!/usr/bin/env python3
"""Bounded offline ULJM05500 identity probe; no target execution or network."""
import argparse
import hashlib
import json
import resource
import struct
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EBOOT = 'sysdir/PSP_GAME/SYSDIR/ULJM05500_EBOOT.BIN'
MESSAGE = 'databin/0015.bin'
TASK = 'databin/0051.bin'
OUTPUT = ROOT / 'analysis/bulldrome_identity.json'
TYPES = (5, 68, 7, 50)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def bounded(path):
    path = ROOT / path
    if path.stat().st_size > 4 * 1024 * 1024:
        raise ValueError(f'input exceeds 4 MiB inspection bound: {path}')
    return path.read_bytes()


def span(path, data, start, length):
    if not 0 <= start <= start + length <= len(data):
        raise ValueError(f'invalid source range: {path}:{start}+{length}')
    raw = data[start:start + length]
    return {'path': str(ROOT / path), 'file_sha256': sha(data),
            'start': start, 'end_exclusive': start + length,
            'raw_hex': raw.hex(), 'range_sha256': sha(raw)}


def u32(data, offset):
    if not 0 <= offset <= len(data) - 4:
        raise ValueError('u32 outside input')
    return struct.unpack_from('<I', data, offset)[0]


def eoff(address):
    return 0x25b4 + address - 0x08804000


def cstring(data, start, end):
    if not 0 <= start < end <= len(data):
        raise ValueError('invalid string range')
    stop = data.find(b'\0', start, end)
    if stop < 0:
        raise ValueError('unterminated bounded string')
    return data[start:stop], stop + 1


def message_entry(data, group, index):
    count = u32(data, 0)
    if not 0 < count <= 32 or u32(data, 4) != 8 or not 0 <= group < count:
        raise ValueError('unsupported message directory')
    table_end = 8 + count * 4
    offsets = [u32(data, 8 + i * 4) for i in range(count)]
    if not all(table_end <= a < b <= len(data) for a, b in zip(offsets, offsets[1:] + [len(data)])):
        raise ValueError('invalid message group bounds')
    base = offsets[group]
    end = offsets[group + 1] if group + 1 < count else len(data)
    first = u32(data, base)
    if first % 4 or not 0 < first <= end - base or not 0 <= index < first // 4:
        raise ValueError('message index outside pointer directory')
    pointer_offset = base + index * 4
    relative = u32(data, pointer_offset)
    if not first <= relative < end - base:
        raise ValueError('message pointer outside group strings')
    raw, stop = cstring(data, base + relative, min(end, base + relative + 4096))
    return {'group': group, 'message_index': index, 'text': raw.decode('utf-8'),
            'directory': span(MESSAGE, data, 0, table_end),
            'group_base': base, 'pointer': span(MESSAGE, data, pointer_offset, 4),
            'relative_string_offset': relative,
            'string': span(MESSAGE, data, base + relative, stop - base - relative)}


def decrypt(raw, seed, substitution):
    if len(raw) % 4 or len(substitution) != 256:
        raise ValueError('invalid encrypted word range or substitution table')
    s1, s2 = seed & 0xffff, seed >> 16
    s1, s2 = s1 or 0x7f8d, s2 or 0x2345
    translated = raw.translate(substitution)
    output = bytearray(len(raw))
    for offset in range(0, len(raw), 4):
        s1 = s1 * 0x7f8d % 0xfff1
        s2 = s2 * 0x2345 % 0xffd9
        struct.pack_into('<I', output, offset, u32(translated, offset) ^ (s2 << 16 | s1))
    return bytes(output)


def iso_entries(handle, extent, length):
    if not 0 < length <= 1024 * 1024:
        raise ValueError('ISO directory exceeds 1 MiB bound')
    handle.seek(extent * 2048)
    data = handle.read(length)
    if len(data) != length:
        raise ValueError('truncated ISO directory')
    entries = {}
    cursor = 0
    while cursor < length:
        size = data[cursor]
        if size == 0:
            cursor = (cursor // 2048 + 1) * 2048
            continue
        if size < 34 or cursor + size > length:
            raise ValueError('invalid ISO directory record')
        record = data[cursor:cursor + size]
        if 33 + record[32] > size:
            raise ValueError('invalid ISO name range')
        name = record[33:33 + record[32]]
        if name not in (b'\x00', b'\x01'):
            name = name.decode('ascii').split(';')[0]
            lba, byte_length = u32(record, 2), u32(record, 10)
            if lba != struct.unpack_from('>I', record, 6)[0] or byte_length != struct.unpack_from('>I', record, 14)[0]:
                raise ValueError('inconsistent ISO dual-endian fields')
            entries[name] = (lba, byte_length)
        cursor += size
    return entries


def parse_sfo(data):
    if len(data) < 20 or data[:4] != b'\0PSF':
        raise ValueError('invalid PARAM.SFO header')
    keys, values, count = u32(data, 8), u32(data, 12), u32(data, 16)
    if count > 128 or not 20 + count * 16 <= keys <= values <= len(data):
        raise ValueError('invalid SFO directory range')
    selected = {}
    for index in range(count):
        key_offset, fmt, length, capacity, value_offset = struct.unpack_from('<HHIII', data, 20 + index * 16)
        key, _ = cstring(data, keys + key_offset, values)
        start = values + value_offset
        if not length <= capacity or start + capacity > len(data):
            raise ValueError('invalid SFO value range')
        if key in (b'DISC_ID', b'TITLE', b'APP_VER', b'DISC_VERSION', b'PSP_SYSTEM_VER'):
            if fmt != 0x204:
                raise ValueError('unsupported selected SFO string format')
            selected[key.decode('ascii')] = data[start:start + length].rstrip(b'\0').decode('utf-8')
    return selected


def original_validation(eboot, indices):
    iso = ROOT / 'Monster Hunter Portable 2nd G (Japan) (PSP) (PSN).iso'
    substitution = eboot[eoff(0x089970c8):eoff(0x089970c8) + 256]
    with iso.open('rb') as handle:
        digest = hashlib.sha256()
        while block := handle.read(1024 * 1024):
            digest.update(block)
        handle.seek(16 * 2048)
        pvd = handle.read(2048)
        if len(pvd) != 2048 or pvd[:7] != b'\x01CD001\x01':
            raise ValueError('unsupported ISO primary descriptor')
        root = iso_entries(handle, u32(pvd, 158), u32(pvd, 166))
        game = iso_entries(handle, *root['PSP_GAME'])
        sfo_lba, sfo_length = game['PARAM.SFO']
        if sfo_length > 65536:
            raise ValueError('SFO exceeds 64 KiB bound')
        handle.seek(sfo_lba * 2048)
        sfo = handle.read(sfo_length)
        sfo_values = parse_sfo(sfo)
        usrdir = iso_entries(handle, *game['USRDIR'])
        data_lba, data_length = usrdir['DATA.BIN']
        handle.seek(data_lba * 2048)
        cipher_header = handle.read(0x672c)
        if len(cipher_header) != 0x672c:
            raise ValueError('truncated DATA.BIN header')
        header = decrypt(cipher_header, 0, substitution)
        starts = struct.unpack('<%dI' % (len(header) // 4), header)
        verified = []
        for index in indices:
            start, end = starts[index] * 2048, starts[index + 1] * 2048
            if not 0 <= start < end <= data_length or end - start > 4 * 1024 * 1024:
                raise ValueError('selected DATA.BIN extent exceeds bound')
            handle.seek(data_lba * 2048 + start)
            cipher = handle.read(end - start)
            if len(cipher) != end - start:
                raise ValueError('truncated selected DATA.BIN extent')
            plain = decrypt(cipher, starts[index], substitution)
            local = bounded(f'databin/{index:04d}.bin')
            verified.append({'runtime_file_id': index, 'local_path': str(ROOT / f'databin/{index:04d}.bin'),
                             'data_bin_range': [start, end], 'iso_range': [data_lba * 2048 + start, data_lba * 2048 + end],
                             'cipher_sha256': sha(cipher), 'decrypted_sha256': sha(plain),
                             'equals_existing_extract': plain == local,
                             'header_entries_range': [index * 4, (index + 2) * 4],
                             'header_entries_hex': header[index * 4:(index + 2) * 4].hex()})
    if not all(row['equals_existing_extract'] for row in verified):
        raise ValueError('existing extract differs from original selected extent')
    return {'iso_path': str(iso), 'iso_sha256': digest.hexdigest(), 'iso_size': iso.stat().st_size,
            'data_bin_lba': data_lba, 'data_bin_size': data_length,
            'encrypted_header_sha256': sha(cipher_header), 'decrypted_header_sha256': sha(header),
            'substitution_source': span(EBOOT, eboot, eoff(0x089970c8), 256), 'selected_chunks': verified,
            'param_sfo': {'iso_range': [sfo_lba * 2048, sfo_lba * 2048 + sfo_length],
                          'sha256': sha(sfo), 'raw_hex': sfo.hex(), 'selected_values': sfo_values}}


def digest_validation(path, data, index, eboot):
    off = eoff(0x08976d00) + index * 20
    expected = eboot[off:off + 20]
    actual = hashlib.sha1(data).digest()
    return {'path': str(ROOT / path), 'runtime_file_id': index, 'size': len(data), 'sha256': sha(data),
            'sha1_table_source': span(EBOOT, eboot, off, 20), 'actual_sha1': actual.hex(),
            'expected_sha1_nonzero': bool(any(expected)),
            'sha1_status': 'matches' if any(expected) and expected == actual else 'zero_expected_unavailable' if not any(expected) else 'mismatch',
            'sha1_matches': expected == actual if any(expected) else None}


def run():
    eboot, message, task = bounded(EBOOT), bounded(MESSAGE), bounded(TASK)
    mapping_offset = eoff(0x089a965c)
    mapping = list(struct.unpack_from('<90H', eboot, mapping_offset))
    rows = []
    for monster_type in TYPES:
        name = message_entry(message, 0, mapping[monster_type])
        pack_id = monster_type + 0x17ab
        path = f'databin/{pack_id:04d}.bin'
        pack = bounded(path)
        count = u32(pack, 0)
        if not 0 < count <= 16 or 4 + count * 8 > len(pack):
            raise ValueError('invalid monster package directory')
        members = []
        for index in range(count):
            off, length = struct.unpack_from('<II', pack, 4 + index * 8)
            if off == length == 0:
                members.append({'index': index, 'status': 'zero_directory_pair', 'raw_pair': [off, length]})
                continue
            if not 4 + count * 8 <= off <= off + length <= len(pack):
                raise ValueError('invalid monster package member bounds')
            members.append({'index': index, 'offset': off, 'length': length,
                            'sha256': sha(pack[off:off + length]), 'prefix_hex': pack[off:off + min(length, 32)].hex()})
        tables = {}
        for label, address, size in [('monster_record', 0x09bb3d2c + monster_type * 0x1d0, 0x1d0),
                                      ('model_selector', 0x09bc8ec0 + monster_type, 1),
                                      ('pointer_selector', 0x09bce9f0 + monster_type * 4, 4)]:
            tables[label] = span(TASK, task, address - 0x09a5a580, size)
            tables[label]['address'] = hex(address)
        rows.append({'classification': 'observed_static_name_mapping', 'type': monster_type, 'type_hex': hex(monster_type),
                     'name': name, 'name_id_source': span(EBOOT, eboot, mapping_offset + monster_type * 2, 2),
                     'tables': tables, 'package': digest_validation(path, pack, pack_id, eboot),
                     'package_directory': span(path, pack, 0, 4 + count * 8), 'members': members})
    code_specs = [('decomp/088510a0.c', 5, 11), ('decomp/088513ac.c', 3, 7),
                  ('decomp/088513cc.c', 3, 22), ('decomp/0885143c.c', 3, 7),
                  ('decomp/08877dd0.c', 19, 35), ('decomp/0887444c.c', 125, 148),
                  ('decomp_ovl/09aac8a8.c', 76, 131), ('decomp_ovl/09aac8a8.c', 576, 591),
                  ('decomp_ovl/09aadc28.c', 13, 34), ('decomp_ovl/09ac08b0.c', 3, 9),
                  ('decomp/088e127c.c', 3, 18), ('decomp/088e0ec0.c', 39, 44),
                  ('decomp/0884d77c.c', 30, 46), ('decomp/0884ed0c.c', 10, 30),
                  ('decomp_ovl/09aaef80.c', 23, 81), ('tools/databin.py', 16, 82)]
    code = []
    for path, first, last in code_specs:
        data = bounded(path)
        lines = data.splitlines(keepends=True)
        start = sum(map(len, lines[:first - 1]))
        end = sum(map(len, lines[:last]))
        item = span(path, data, start, end - start)
        item['line_range'] = [first, last]
        code.append(item)
    if [r['name']['text'] for r in rows] != ['ブルファンゴ', 'ドスファンゴ', 'ラオシャンロン', 'ラオシャンロン']:
        raise ValueError('selected original name table differs from the identity claim')
    original = original_validation(eboot, [15, 51, 56] + [r['package']['runtime_file_id'] for r in rows])
    if original['param_sfo']['selected_values'].get('DISC_ID') != 'ULJM05500' or original['param_sfo']['selected_values'].get('DISC_VERSION') != '1.01':
        raise ValueError(f'original image identity differs: {original["param_sfo"]["selected_values"]}')
    validations = [digest_validation(MESSAGE, message, 15, eboot), digest_validation(TASK, task, 51, eboot),
                   digest_validation('databin/0056.bin', bounded('databin/0056.bin'), 56, eboot)]
    if any(v['sha1_status'] == 'mismatch' for v in validations + [r['package'] for r in rows]):
        differences = [(v['runtime_file_id'], v['actual_sha1'], v['sha1_table_source']['raw_hex'])
                       for v in validations + [r['package'] for r in rows] if not v['sha1_matches']]
        raise ValueError(f'selected extracted SHA-1 differences: {differences}')
    return {'target': 'MHP2G Japan ULJM05500 v1.01; ISO filename carries PSN',
            'evidence_kind': 'original image/extract bytes and existing static pseudocode; no dynamic Evidence IDs',
            'identity': {'status': 'closed_static_name_to_type', 'support_level': '原版本名称表+实际读取/装载代码+原镜像范围一致+原SHA-1表',
                         'bulldrome': {'type': 68, 'hex': '0x44', 'japanese': 'ドスファンゴ', 'vtable': '0x089b8100', 'runtime_package_id': 6127},
                         'bullfango': {'type': 5, 'hex': '0x05', 'japanese': 'ブルファンゴ', 'vtable': '0x089b723c', 'runtime_package_id': 6064},
                         'english_alias_authority': 'Bulldrome/Bullfango采用请求中给定别名；日版原字节只证明对应日文名称，不冒充英文在盘文本。'},
            'chain': ['088510a0 loads runtime file0x0f to089c7510; original extent and SHA-1 prove this is local0015.bin.',
                      '08877dd0:33 indexes u16 table089a965c by the monster index; 0887444c:137-148 produces that index unchanged.',
                      '0885143c selects group0; 088513ac selects relative group base; 088513cc adds indexed relative string offset.',
                      'The original name-ID table gives type5 -> message108 -> UTF-8ブルファンゴ and type68 -> message171 -> UTF-8ドスファンゴ.',
                      '09aadc28 passes spawn byte0 to09aac8a8 and stores it at entity+1e8; constructor type5 and68 select different vtables.',
                      '088e127c/088e0ec0 bind runtime resource ID=(type&ff)+17ab; 0884ed0c indexes original start table without inferred +/-1 adjustment.'],
            'rejected_prior_candidate': {'classification': 'observed_static', 'types': [7, 50],
                                        'names_from_original_table': [r['name']['text'] for r in rows[2:]],
                                        'vtable': '0x089b98bc', 'conclusion': '两个原名称均为ラオシャンロン；不是ドスファンゴ，也不是ブルファンゴ。表名不带亚种，不由此单独宣称type50的亚种全名。'},
            'original_validation': original, 'extracted_validation': validations,
            'digest_scope': '0015及四个怪物包的5个非零预期SHA-1全部吻合；0051/0056原SHA-1槽全零，不能称SHA-1验证成功，但两者原ISO选定范围解密与已有文件逐字节一致。',
            'name_id_table': {'address': '0x089a965c', 'u16': mapping, 'source': span(EBOOT, eboot, mapping_offset, 180)},
            'selected_types': rows, 'code_sources': code,
            'unknowns': ['未解析具体ドスファンゴ任务配置/任务spawn记录；名称表链已独立闭合身份，不以此声称任务验收。',
                         '未核实社区extract file50/file55的产生实现或固定commit；只保留用户给定0-based vs本地1-based区别，不给整表加固定偏移。',
                         '未恢复猪王AI、动作、肉质状态可达性、模型可视效果；包目录/选择关系不等于完整模型验收。',
                         '未执行模拟器、Ghidra或原程序；无动态物种生成观测。'],
            'coverage': {'binary_name_discovery': '仅先检查EBOOT/0051/0056，再有界检查早期0..21资源；名称命中0015，最后probe只读取必要包与已知表。',
                         'whole_disk_scan': False, 'whole_iso_reextract': False, 'original_selected_chunk_count': 7,
                         'community_source_dependency': '本次读到目录时两份vendor源码尚未存在；闭合不依赖其enum。',
                         'semantic_search': '项目语义索引不可用，已改用文本与原字节边界调查。'},
            'command': 'python3 /Users/jiaqi.liu/rea/mh/tools/bulldrome_identity_probe.py --write'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--write', action='store_true', help='write only analysis/bulldrome_identity.json')
    args = parser.parse_args()
    started, cpu = time.perf_counter(), time.process_time()
    report = run()
    report['measurement'] = {'elapsed_seconds': time.perf_counter() - started, 'cpu_seconds': time.process_time() - cpu,
                             'peak_process_rss_bytes_macos': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                             'limits': '单次离线probe；不是完整任务token/进程族或等价冷暖性能比较。'}
    if args.write:
        if not OUTPUT.parent.is_dir():
            raise ValueError('selected report parent does not exist')
        OUTPUT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'identity': report['identity'], 'prior_candidate': report['rejected_prior_candidate'],
                      'original_ranges_verified': True, 'digest_scope': report['digest_scope'],
                      'output': str(OUTPUT) if args.write else None,
                      'measurement': report['measurement']}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
