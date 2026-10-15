#!/usr/bin/env python3
"""MHP2G bounded offline MIPS/table probe; no target execution or database access."""
import argparse
import hashlib
import json
import struct
from pathlib import Path

REG = ['$zero', '$at', '$v0', '$v1', '$a0', '$a1', '$a2', '$a3', '$t0', '$t1', '$t2', '$t3', '$t4', '$t5', '$t6', '$t7', '$s0', '$s1', '$s2', '$s3', '$s4', '$s5', '$s6', '$s7', '$t8', '$t9', '$k0', '$k1', '$gp', '$sp', '$fp', '$ra']


def decode(w, pc):
    op, rs, rt, rd = w >> 26, (w >> 21) & 31, (w >> 16) & 31, (w >> 11) & 31
    imm = w & 65535
    signed = imm if imm < 32768 else imm - 65536
    if not w:
        return 'nop'
    if op in (2, 3):
        return f"{'jal' if op == 3 else 'j'} 0x{((pc + 4) & 0xf0000000) | ((w & 0x3ffffff) << 2):08x}"
    if op == 0:
        fn = w & 63
        if fn in (0, 2, 3):
            return f"{ {0:'sll',2:'srl',3:'sra'}[fn]} {REG[rd]}, {REG[rt]}, {(w >> 6) & 31}"
        if fn in (8, 9):
            return f"{'jr' if fn == 8 else 'jalr'} {REG[rs]}"
        names = {0x21:'addu',0x23:'subu',0x24:'and',0x25:'or',0x26:'xor',0x2a:'slt',0x2b:'sltu'}
        if fn in names:
            return f'{names[fn]} {REG[rd]}, {REG[rs]}, {REG[rt]}'
    names = {9:'addiu',10:'slti',11:'sltiu',12:'andi',13:'ori',14:'xori',15:'lui',32:'lb',33:'lh',35:'lw',36:'lbu',37:'lhu',40:'sb',41:'sh',43:'sw',49:'lwc1',57:'swc1'}
    if op in names:
        dst = f'$f{rt}' if op in (49,57) else REG[rt]
        if op >= 32:
            return f'{names[op]} {dst}, {signed:+#x}({REG[rs]})'
        if op == 15:
            return f'lui {dst}, 0x{imm:04x}'
        return f'{names[op]} {dst}, {REG[rs]}, {signed if op < 12 else hex(imm)}'
    if op == 1 and rt in (0,1,2,3):
        return f"{ {0:'bltz',1:'bgez',2:'bltzl',3:'bgezl'}[rt]} {REG[rs]}, 0x{pc + 4 + signed * 4:08x}"
    if op in (4,5,6,7,20,21,22,23):
        name = {4:'beq',5:'bne',6:'blez',7:'bgtz',20:'beql',21:'bnel',22:'blezl',23:'bgtzl'}[op]
        operands = f'{REG[rs]}, {REG[rt]}' if op in (4,5,20,21) else REG[rs]
        return f'{name} {operands}, 0x{pc + 4 + signed * 4:08x}'
    if op == 17:
        if rs in (0,4):
            return f"{'mfc1' if rs == 0 else 'mtc1'} {REG[rt]}, $f{rd}"
        if rs == 8:
            return f"bc1{'t' if rt & 1 else 'f'}{'l' if rt & 2 else ''} 0x{pc + 4 + signed * 4:08x}"
        fn, fd = w & 63, (w >> 6) & 31
        fmt = {16:'s',17:'d',20:'w'}.get(rs, str(rs))
        names = {0:'add',1:'sub',2:'mul',3:'div',4:'sqrt',5:'abs',6:'mov',7:'neg',50:'c.eq',60:'c.lt',61:'c.nge',62:'c.le'}
        if fn in (32,36):
            return f"cvt.{'s' if fn == 32 else 'w'}.{fmt} $f{fd}, $f{rd}"
        if fn in names:
            operands = f'$f{rd}, $f{rt}' if fn >= 48 else (f'$f{fd}, $f{rd}' if fn >= 4 else f'$f{fd}, $f{rd}, $f{rt}')
            return f'{names[fn]}.{fmt} {operands}'
    return f'raw 0x{w:08x} (unimplemented/VFPU)'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--region', choices=['main', '0051', '0056'], default='main')
    parser.add_argument('--address', type=lambda x: int(x, 0), required=True)
    parser.add_argument('--words', type=int, default=16)
    parser.add_argument('--table', action='store_true')
    args = parser.parse_args()
    if not 1 <= args.words <= 1024:
        parser.error('--words must be 1..1024 (bounded focused probe)')
    mapping = {'main': ('sysdir/PSP_GAME/SYSDIR/ULJM05500_EBOOT.BIN', 0x08804000, 0x25b4), '0051': ('databin/0051.bin', 0x09a5a580, 0), '0056': ('databin/0056.bin', 0x09c14280, 0)}
    rel, base, origin = mapping[args.region]
    path = args.root / rel
    offset = args.address - base + origin
    size = path.stat().st_size
    if args.address < base or offset < 0 or offset + args.words * 4 > size:
        parser.error('requested range outside supplied mapping')
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
        stream.seek(offset)
        data = stream.read(args.words * 4)
    rows = []
    for n, (w,) in enumerate(struct.iter_unpack('<I', data)):
        pc = args.address + 4 * n
        row = {'address': f'0x{pc:08x}', 'file_offset': hex(offset + 4 * n), 'word': f'0x{w:08x}'}
        if args.table:
            row['float32'] = str(struct.unpack('<f', struct.pack('<I', w))[0])
        else:
            row['instruction'] = decode(w, pc)
        rows.append(row)
    print(json.dumps({'artifact': str(path), 'sha256': digest.hexdigest(), 'mapping': {'base': hex(base), 'file_origin': hex(origin)}, 'coverage_bytes': len(data), 'limitations': 'Focused static bytes; decoder is partial; raw VFPU instructions and delay slots require manual interpretation.', 'rows': rows}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
