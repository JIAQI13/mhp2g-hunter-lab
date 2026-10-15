#!/usr/bin/env python3
"""Bounded static word interpretation and neutral world sampling; never runs the game."""
import argparse
import json
import math
import struct
from pathlib import Path

import hunter_clip_probe as clip

ROOT = Path(__file__).resolve().parents[1]
EBOOT = 'sysdir/PSP_GAME/SYSDIR/ULJM05500_EBOOT.BIN'
FUNCTIONS = {0x088632d0: 244, 0x08860054: 512, 0x08865528: 176,
             0x08865478: 176, 0x088653c8: 176, 0x08860320: 532,
             0x08860640: 136, 0x088652d4: 244, 0x088637bc: 940}


def identity_matrix():
    return [[float(i == j) for j in range(4)] for i in range(4)]


def multiply(a, b):
    return [[sum(a[i][k]*b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def transform(m, p, w=1):
    return [sum(m[i][j]*v for j, v in enumerate(list(p)+[w])) for i in range(3)]


def from_columns(values):
    return [[values[4*j+i] for j in range(4)] for i in range(4)]


def rotation(r):
    sx, sy, sz = [math.sin(x) for x in r]
    cx, cy, cz = [math.cos(x) for x in r]
    return [[cz*cy, cz*sy*sx-sz*cx, sx*sz+cz*sy*cx, 0.0],
            [sz*cy, cz*cx+sz*sy*sx, sy*sz*cx-sx*cz, 0.0],
            [-sy, cy*sx, cy*cx, 0.0], [0.0, 0.0, 0.0, 1.0]]


def vector_regs(reg, n):
    m, col = (reg >> 2) & 7, reg & 3
    trans = (reg >> 5) & 1
    row = ((reg >> 5) & 3) if n == 1 else (((reg >> 6) & 1) if n == 3 else ((reg >> 5) & 2))
    if n == 1:
        trans = 0
    return [m*4 + (((row+i) & 3)+col*32 if trans else col+((row+i) & 3)*32) for i in range(n)]


def matrix_regs(reg, n):
    m, col, trans = (reg >> 2) & 7, reg & 3, (reg >> 5) & 1
    row = (reg >> 6) & 1 if n == 3 else (reg >> 5) & 2
    return [m*4 + (((row+i) & 3)+((col+j) & 3)*32 if trans else ((col+j) & 3)+((row+i) & 3)*32)
            for j in range(n) for i in range(n)]


class UnsupportedWord(ValueError):
    pass


class WordModel:
    """Only encountered straight-line MIPS/VFPU operations, in mathematical float64."""
    def __init__(self, programs):
        self.programs = programs
        self.mem, self.gpr, self.fpr, self.vf = {}, [0]*32, [0.0]*32, [None]*128
        self.gpr[29] = 0x100000
        self.executed = set()

    def get(self, address):
        clip.require(address in self.mem, f'uninitialized model memory {address:#x}')
        return self.mem[address]

    def floating(self, address):
        x = self.get(address)
        return x if isinstance(x, float) else struct.unpack('<f', struct.pack('<I', x & 0xffffffff))[0]

    def put_matrix(self, address, matrix):
        for j in range(4):
            for i in range(4):
                self.mem[address+16*j+4*i] = float(matrix[i][j])

    def matrix(self, address):
        return from_columns([self.floating(address+4*i) for i in range(16)])

    def read_vf(self, regs):
        result = [self.vf[i] for i in regs]
        clip.require(all(v is not None for v in result), 'uninitialized VFPU source')
        return result

    def write_vf(self, regs, values):
        for reg, value in zip(regs, values):
            self.vf[reg] = value

    def step(self, word, pc):
        self.executed.add((pc, word))
        op, rs, rt, rd = word >> 26, (word >> 21) & 31, (word >> 16) & 31, (word >> 11) & 31
        imm = word & 65535
        signed = imm if imm < 32768 else imm-65536
        vd, vs, vt = word & 127, (word >> 8) & 127, (word >> 16) & 127
        n = 1 + ((word >> 7) & 1) + 2*((word >> 15) & 1)
        if word == 0:
            return
        if op == 9:
            self.gpr[rt] = (self.gpr[rs]+signed) & 0xffffffff
        elif op == 15:
            self.gpr[rt] = imm << 16
        elif op == 13:
            self.gpr[rt] = self.gpr[rs] | imm
        elif op == 0 and word & 63 == 0x21:
            self.gpr[rd] = (self.gpr[rs]+self.gpr[rt]) & 0xffffffff
        elif op in (35, 43, 41):
            address = self.gpr[rs]+signed
            if op == 35:
                self.gpr[rt] = self.get(address)
            else:
                self.mem[address] = self.gpr[rt] & (65535 if op == 41 else 0xffffffff)
        elif op in (49, 57):
            address = self.gpr[rs]+signed
            if op == 49:
                self.fpr[rt] = self.floating(address)
            else:
                self.mem[address] = float(self.fpr[rt])
        elif op == 17 and rs == 4:
            self.fpr[rd] = struct.unpack('<f', struct.pack('<I', self.gpr[rt]))[0]
        elif op == 17 and rs == 16 and word & 63 in (2, 3, 6):
            fn, fd = word & 63, (word >> 6) & 31
            self.fpr[fd] = (self.fpr[rd]*self.fpr[rt] if fn == 2 else
                            self.fpr[rd]/self.fpr[rt] if fn == 3 else self.fpr[rd])
        elif op in (50, 54, 58, 62):
            # lv.s/sv.s carry two register bits; lv.q/sv.q carry one.
            scalar = op in (50, 58)
            reg = rt | ((word & (3 if scalar else 1)) << 5)
            offset = word & 0xfffc
            offset = offset if offset < 32768 else offset-65536
            address = self.gpr[rs]+offset
            regs = vector_regs(reg, 1 if scalar else 4)
            if op in (50, 54):
                self.write_vf(regs, [self.floating(address+4*i) for i in range(len(regs))])
            else:
                for i, value in enumerate(self.read_vf(regs)):
                    self.mem[address+4*i] = float(value)
        elif word & 0xffff0000 == 0xf3830000:
            regs = matrix_regs(vd, n)
            self.write_vf(regs, [float(i == j) for j in range(n) for i in range(n)])
        elif word & 0xffff0000 == 0xf3800000:
            self.write_vf(matrix_regs(vd, n), self.read_vf(matrix_regs(vs, n)))
        elif word & 0xffe00000 == 0xf3a00000:
            angle = self.read_vf(vector_regs(vs, 1))[0]*math.pi/2
            code = (word >> 16) & 31
            sine_lane, cosine_lane = (code >> 2) & 3, code & 3
            sine = math.sin(angle)*(-1 if code & 16 else 1)
            values = [sine if sine_lane == cosine_lane else 0.0 for _ in range(4)]
            values[sine_lane], values[cosine_lane] = sine, math.cos(angle)
            self.write_vf(vector_regs(vd, n), values)
        elif word & 0xff800000 == 0xf0000000:
            # PPSSPP Int_Vmmul: d[a*4+b] = dot(s[b*4],t[a*4]).
            s, t = self.read_vf(matrix_regs(vs, n)), self.read_vf(matrix_regs(vt, n))
            values = [sum(s[b*n+c]*t[a*n+c] for c in range(n)) for a in range(n) for b in range(n)]
            self.write_vf(matrix_regs(vd, n), values)
        elif word & 0xff800000 in (0xf1000000,0xf1800000):
            side = 3 if word & 0xff800000 == 0xf1000000 else 4
            clip.require(n == side, 'unimplemented homogeneous transform size')
            s = self.read_vf(matrix_regs(vs,side))
            t = self.read_vf(vector_regs(vt,side))
            self.write_vf(vector_regs(vd,side),[sum(s[i*side+k]*t[k] for k in range(side)) for i in range(side)])
        elif word & 0xffff0000 == 0xd0650000:
            clip.require((word >> 16) & 31 == 5, 'unimplemented VFPU constant')
            self.write_vf(vector_regs(vd, n), [2/math.pi]*n)
        elif word & 0xffff0000 in (0xd0000000, 0xd0020000, 0xd0030000, 0xd0120000, 0xd0130000):
            code = word & 0xffff0000
            if code == 0xd0030000:
                values = [float(i == (vd & 3)) for i in range(n)]
            else:
                source = self.read_vf(vector_regs(vs, n))
                values = [v if code == 0xd0000000 else -v if code == 0xd0020000 else
                          math.sin(v*math.pi/2) if code == 0xd0120000 else math.cos(v*math.pi/2) for v in source]
            self.write_vf(vector_regs(vd, n), values)
        elif word & 0xff800000 in (0x60000000, 0x60800000, 0x64000000, 0x65000000):
            code = word & 0xff800000
            s = self.read_vf(vector_regs(vs, n))
            t = self.read_vf(vector_regs(vt, 1 if code == 0x65000000 else n))
            values = [v+t[i] if code == 0x60000000 else v-t[i] if code == 0x60800000 else
                      v*t[0 if code == 0x65000000 else i] for i, v in enumerate(s)]
            self.write_vf(vector_regs(vd, n), values)
        else:
            raise UnsupportedWord(f'{pc:#010x}: {word:#010x}')
        self.gpr[0] = 0

    def run(self, address, stop=None, start=None):
        data = self.programs[address]
        for i, word in enumerate(data):
            pc = address+i*4
            if start is not None and pc < start:
                continue
            if pc == stop:
                return
            if word == 0x03e00008:
                self.step(data[i+1], pc+4)
                return
            self.step(word, pc)
        if stop is not None:
            raise ValueError('stop outside selected program')


def pose_word(programs, pose):
    model = WordModel(programs)
    model.gpr[5], model.gpr[6] = 0x2000, 0x3000
    model.mem.update({0x3000+4*i: float(v) for i, v in enumerate(pose)})
    model.run(0x088632d0)
    return model.matrix(0x2000)


def bind_word(programs, pose):
    model = WordModel(programs)
    model.gpr[4], model.gpr[5] = 0x2000, 0x3000
    model.mem.update({0x3000+4*i: 0 for i in range(21)})
    for start, values in ((28,pose[:3]),(44,pose[3:6]),(60,pose[6:9])):
        for i, value in enumerate(values):
            model.mem[0x3000+start+4*i] = float(value)
    model.run(0x08860054)
    return model.matrix(0x2150)


def hierarchy_word(programs, pose, parent, entity_scale):
    model = WordModel(programs)
    model.gpr[4], model.gpr[5], model.gpr[6] = 0x2000, 0x3000, 0x4000
    model.fpr[12:15] = [entity_scale]*3
    model.put_matrix(0x2150, pose_word(programs, pose))
    for i in range(3):
        model.mem[0x2190+4*i] = float(pose[i])
    model.put_matrix(0x3000, parent)
    model.put_matrix(0x4000, parent)
    model.run(0x08860320, stop=0x088604c8)
    return model.matrix(0x2090), model.matrix(0x20d0)


def entity_word(programs, angles, scale, position):
    model = WordModel(programs)
    address = 0x2000
    model.put_matrix(address, identity_matrix())
    # The caller 088652d4 rotates Y(+1f4), X(+1f0), Z(+1f8), then multiplies scale.
    for function, angle in ((0x08865528, angles[1]), (0x08865478, angles[0]), (0x088653c8, angles[2])):
        model.gpr[4] = model.gpr[5] = address
        model.fpr[12] = angle
        model.run(function)
    result = model.matrix(address)
    for i in range(3):
        for j in range(3):
            result[i][j] *= scale
        result[i][3] = position[i]
    return result


def attachment_word(programs, matrix, offset):
    model = WordModel(programs)
    model.gpr[3], model.gpr[7], model.gpr[2] = 0x2000,0x3000,0x4000
    model.put_matrix(0x2000,matrix)
    for i, value in enumerate(offset+[0.0]):
        model.mem[0x3000+4*i] = float(value)
    model.run(0x088d68b0,start=0x088d6b3c,stop=0x088d6b58)
    return [matrix[i][3]+model.floating(0x4000+4*i) for i in range(3)]


def capsule_word(programs, matrix, shape, scale):
    model = WordModel(programs)
    model.gpr[3], model.gpr[4], model.gpr[5], model.gpr[6] = 0x2000,0x3000,0x4000,0x5000
    model.put_matrix(0x2000,matrix)
    model.mem[0x3220], model.mem[0x400c] = float(scale),float(shape['radius'])
    for start, values in ((16,shape['a']),(28,shape['b'])):
        for i, value in enumerate(values):
            model.mem[0x4000+start+4*i] = float(value)
    # Exact kind1 body after the branch-selected bone matrix pointer has been established.
    model.run(0x09c32788,start=0x09c32854,stop=0x09c3292c)
    return {'part':shape['part'],'a':[model.floating(0x5010+4*i) for i in range(3)],
            'b':[model.floating(0x5020+4*i) for i in range(3)],'radius':model.floating(0x5030)}


def close(a, b, tolerance=1e-9):
    error = max(abs(x-y) for rowa, rowb in zip(a, b) for x, y in zip(rowa, rowb))
    clip.require(error <= tolerance, f'matrix mismatch {error}')
    return error


def tests(programs):
    checks, error = [], 0.0
    def check(name, actual, expected):
        nonlocal error
        error = max(error, close(actual, expected))
        checks.append(name)
    bind = [1.0]*3+[0.0]*6
    check('identity basis', pose_word(programs, bind), identity_matrix())
    basis_cases = [([math.pi/2, 0, 0], [[1,0,0,0],[0,0,-1,0],[0,1,0,0],[0,0,0,1]]),
                   ([0, math.pi/2, 0], [[0,0,1,0],[0,1,0,0],[-1,0,0,0],[0,0,0,1]]),
                   ([0, 0, math.pi/2], [[0,-1,0,0],[1,0,0,0],[0,0,1,0],[0,0,0,1]])]
    for i, (angles, expected) in enumerate(basis_cases):
        check(f'local R{i} positive 90deg basis', pose_word(programs, [1]*3+angles+[0]*3), expected)
        check(f'entity angle{i} positive 90deg basis', entity_word(programs, angles, 1.0, [0]*3), expected)
    for angles in ([0.31,-0.57,0.92], [1.1,0.7,-0.4], [-1.8,2.2,0.13]):
        check('mixed local RzRyRx', pose_word(programs, [1]*3+list(angles)+[0]*3), rotation(angles))
        # Entity functions right-compose Y, X, Z: Ry * Rx * Rz.
        expected = multiply(multiply(rotation([0,angles[1],0]), rotation([angles[0],0,0])), rotation([0,0,angles[2]]))
        check('mixed entity RyRxRz', entity_word(programs, angles, 1.0, [0]*3), expected)
    parent = rotation([0,0,math.pi/2])
    parent[0][3], parent[1][3], parent[2][3] = 10.0, 20.0, 30.0
    local, world = hierarchy_word(programs, [2,3,4,0,0,0,1,2,3], parent, 1.0)
    expected = [[2,0,0,1],[0,3,0,2],[0,0,4,3],[0,0,0,1]]
    check('scale producing boundary', local, multiply(parent, expected))
    check('parent rotation + translated child', world, multiply(parent, expected))
    clip.require(transform(world, [0,0,0]) == [8.0,21.0,33.0], 'parent translation incorrect')
    for scale in (0.75,1.5,2.0):
        _, world = hierarchy_word(programs, [2,3,4,0,0,0,1,2,3], parent, scale)
        check('uniform scale cancellation at local boundary', world, multiply(parent,expected))
    check('bind initializer identity', bind_word(programs,bind), identity_matrix())
    for angles, expected_rotation in basis_cases:
        check('bind initializer 90deg', bind_word(programs,[1]*3+angles+[0]*3), expected_rotation)
    check('bind initializer mixed angles', bind_word(programs,[1]*3+[0.31,-0.57,0.92]+[0]*3),rotation([0.31,-0.57,0.92]))
    anisotropic_pose = [2,3,4,0.31,-0.57,0.92,1,2,3]
    expected_anisotropic = rotation(anisotropic_pose[3:6])
    expected_bind = rotation(anisotropic_pose[3:6])
    for i in range(3):
        for j in range(3):
            expected_anisotropic[i][j] *= anisotropic_pose[j]
            expected_bind[i][j] *= anisotropic_pose[j]
        expected_anisotropic[i][3] = expected_bind[i][3] = anisotropic_pose[6+i]
    _, world = hierarchy_word(programs,anisotropic_pose,parent,1.5)
    check('rotated anisotropic scale belongs to column basis in sampled hierarchy',world,multiply(parent,expected_anisotropic))
    check('bind initializer scale precedes left rotations',bind_word(programs,anisotropic_pose),expected_bind)
    model = WordModel(programs)
    model.gpr[4] = 0x2000
    model.put_matrix(0x2010,parent)
    model.put_matrix(0x2090,expected)
    model.run(0x08860640,stop=0x08860690)
    check('render matrix composition',model.matrix(0x2050),multiply(expected,parent))
    rejected = False
    try:
        WordModel(programs).step(0xffffffff, 0)
    except UnsupportedWord:
        rejected = True
    clip.require(rejected, 'unknown opcode did not fail closed')
    return {'status':'passed', 'checks':checks, 'maximum_float64_error':error,
            'unsupported_word_rejection':True, 'scope':'Mathematical raw-word interpretation; not native execution or PSP rounding.'}


def run(args):
    prior = {name: json.loads((ROOT/'analysis'/f'{name}.json').read_text()) for name in
             ('hunter_clip','hunter_resources','animation_runtime','greatsword_combat')}
    clip.require(prior['hunter_clip']['report_contract_version'] == 2, 'requires clip contract v2')
    decoded = clip.run()
    expected = dict(clip.EXPECTED)
    for source in prior['greatsword_combat']['sources']:
        expected[source['path']] = source['sha256']
    hashes = {name: clip.identity(ROOT/name) for name in expected}
    clip.require(hashes == expected, 'artifact identity mismatch')
    sources, programs = [], {}
    def raw(name, base, origin, address, size):
        data, source = clip.source_range(ROOT/name, address-base+origin, address-base+origin+size, hashes[name])
        source['virtual_address_range'] = [hex(address), hex(address+size)]
        sources.append(source)
        return data
    for address, size in FUNCTIONS.items():
        data = raw(EBOOT, clip.BASE, clip.ORIGIN, address, size)
        programs[address] = list(struct.unpack('<'+'I'*(size//4), data))
        sources[-1]['words'] = [hex(w) for w in programs[address]]
    for address, size in ((0x088d68b0,7148), (0x0885fa04,328), (0x0885ffb4,160), (0x0885f8e0,64)):
        data = raw(EBOOT, clip.BASE, clip.ORIGIN, address, size)
        if address == 0x088d68b0:
            programs[address] = list(struct.unpack('<'+'I'*(size//4),data))
    attachment_data = raw(EBOOT, clip.BASE, clip.ORIGIN, 0x089aa6dc,24)
    offset, attachment_angles = list(struct.unpack('<3f',attachment_data[:12])), list(struct.unpack('<3f',attachment_data[12:]))
    shape_data = raw('databin/0051.bin',0x09a5a580,0,0x09bf6a10,124)
    shapes = []
    for i in range(3):
        record = shape_data[i*40:(i+1)*40]
        bone, kind, part = struct.unpack_from('<3h',record)
        radius = struct.unpack_from('<f',record,12)[0]
        a, b = list(struct.unpack_from('<3f',record,16)), list(struct.unpack_from('<3f',record,28))
        clip.require(bone == 14 and kind == 1 and radius == 52, 'unexpected shape format or identity')
        shapes.append({'bone':bone,'kind':kind,'part':part,'radius':radius,'a':a,'b':b})
    clip.require(struct.unpack_from('<h',shape_data,120)[0] == -1, 'shape terminator missing')
    shape_code = raw('databin/0056.bin',0x09c14280,0,0x09c32788,440)
    programs[0x09c32788] = list(struct.unpack('<110I',shape_code))
    sources[-1]['words'] = [hex(w) for w in programs[0x09c32788]]
    validation = tests(programs)
    skeleton = decoded['skeleton']
    bound = {n['bound_skeleton_node']: n for c in decoded['clips'] for n in c['nodes']}
    def components(time):
        result = []
        for bone in skeleton['nodes']:
            pose = list(bone['bind_components_S_R_T'])
            for channel in bound[bone['index']]['channels']:
                pose[channel['component_index']] = clip.sample(channel['keys'],time)*channel['factor']
            result.append(pose)
        return result
    root_index = skeleton['nodes'][skeleton['roots'][0]]['first_child']
    clip.require(root_index == 1, 'selected root identity changed')
    def root_delta(position):
        previous, current = position-args.step, position
        if previous < 0:
            current -= previous
            previous = 0.0
        a, b = components(previous)[root_index], components(current)[root_index]
        return [b[i]-a[i] for i in (6,7,8)]
    trajectory, accumulated, max_error = [], list(args.position), 0.0
    count = math.ceil(164/args.step)+1
    clip.require(count <= 1000, 'step requires more than 1000 bounded samples')
    position = 0.0
    for call in range(count):
        end_clamped = position+args.step > 164.0
        pose_position = 164.0 if end_clamped else position
        delta = root_delta(position)
        entity_before = entity_word(programs,args.angles,args.scale,accumulated)
        world_delta = transform(entity_before,delta,w=0)
        accumulated = [a+b for a,b in zip(accumulated,world_delta)]
        entity = entity_word(programs,args.angles,args.scale,accumulated)
        poses = components(int(pose_position))
        root_before_zero = poses[root_index][6:9]
        poses[root_index][6:9] = [0.0]*3
        worlds, locals_ = {}, {}
        visiting = set()
        def visit(index):
            nonlocal max_error
            if index in worlds:
                return worlds[index]
            clip.require(index not in visiting,'cyclic parent tree')
            visiting.add(index)
            bone = skeleton['nodes'][index]
            parent = entity if bone['parent'] == -1 else visit(bone['parent'])
            _, world = hierarchy_word(programs,poses[index],parent,args.scale)
            conventional = pose_word(programs,poses[index])
            for i in range(3):
                for j in range(3):
                    conventional[i][j] *= poses[index][j]
            max_error = max(max_error, close(world,multiply(parent,conventional),1e-7))
            # Uniform entity scale cancels at the local boundary; parent carries world scale.
            locals_[index], worlds[index] = conventional, world
            visiting.remove(index)
            return world
        for bone in skeleton['nodes']:
            visit(bone['index'])
        capsule = [capsule_word(programs,worlds[14],s,args.scale) for s in shapes]
        for original, actual in zip(shapes,capsule):
            close([actual['a'],actual['b']], [transform(worlds[14],original['a']),transform(worlds[14],original['b'])])
            clip.require(actual['radius'] == original['radius']*args.scale, 'radius scale mismatch')
        weapon = multiply(worlds[10],rotation(attachment_angles))
        weapon_origin = attachment_word(programs,worlds[10],offset)
        close([weapon_origin],[transform(worlds[10],offset)])
        for i in range(3):
            weapon[i][3] = weapon_origin[i]
            for j in range(3):
                weapon[i][j] *= struct.unpack('<f',struct.pack('<I',0x3f4ccccd))[0]
        trajectory.append({'call_index':call,'requested_clip_position':position,'pose_uint_time':int(pose_position),'end_clamped':end_clamped,
                           'root_local_before_zero':root_before_zero,'root_local_delta':delta,
                           'root_world_delta':world_delta,'entity_position_unconstrained_model':list(accumulated),
                           'nodes':[{'index':i,'parent':skeleton['nodes'][i]['parent'],
                                     'local_matrix_rows':locals_[i],'world_matrix_rows':worlds[i]} for i in range(21)],
                           'node10_origin':transform(worlds[10],[0,0,0]),'node14_origin':transform(worlds[14],[0,0,0]),
                           'type0_weapon_attachment_matrix_rows':weapon,'weapon_attachment_origin':weapon_origin,
                           'sword_mesh_tip':None,'capsules':capsule})
        if end_clamped:
            break
        position += args.step
    clip.require(all(math.isfinite(v) for s in trajectory for node in s['nodes'] for row in node['world_matrix_rows'] for v in row),'non-finite trajectory')
    capsule_error = 0.0
    for frame in trajectory:
        matrix = frame['nodes'][14]['world_matrix_rows']
        axis_length = math.sqrt(sum(matrix[i][2]**2 for i in range(3)))
        for original, capsule in zip(shapes,frame['capsules']):
            actual = math.dist(capsule['a'],capsule['b'])
            wanted = math.dist(original['a'],original['b'])*axis_length
            capsule_error = max(capsule_error,abs(actual-wanted))
            clip.require(abs(actual-wanted) < 1e-7,'capsule segment length mismatch')
    clip.require(any(math.dist(trajectory[0]['weapon_attachment_origin'],f['weapon_attachment_origin']) > 1 for f in trajectory[1:]),'attachment trajectory unexpectedly constant')
    validation['real_resource_checks'] = {'frames':len(trajectory),'nodes_per_frame':21,'matrix_equation_checks':21*len(trajectory),
                                          'maximum_hierarchy_error':max_error,'raw_vtfm3_attachment_checks':len(trajectory),
                                          'raw_vtfm4_capsule_endpoint_checks':6*len(trajectory),'capsule_length_checks':3*len(trajectory),
                                          'maximum_capsule_length_error':capsule_error,'all_finite':True,'nonconstant_attachment':True}
    code_sources = []
    for name in ('088632d0','08860054','08865528','08865478','088653c8','08860320','08860640','088652d4','088637bc','088d68b0','0885fa04'):
        path = ROOT/'decomp'/f'{name}.c'
        code_sources.append({'path':str(path),'sha256':clip.identity(path)})
    code_sources.append({'path':str(ROOT/'decomp_ovl/09c32788.c'),'sha256':clip.identity(ROOT/'decomp_ovl/09c32788.c')})
    for name, lines in (('MIPSVFPUUtils.cpp',[39,89]),('MIPSIntVFPU.cpp',[467,520]),('MIPSIntVFPU.cpp',[1588,1748])):
        path = ROOT/'vendor/ppsspp-1.20.4/Core/MIPS'/name
        code_sources.append({'path':str(path),'sha256':clip.identity(path),'lines':lines,
                             'role':'register selection / instruction interpretation reference, not hardware conformance'})
    return {'report_contract_version':1,'task':'W','evidence_kind':'offline byte observation / static mathematical derivation; no REA Evidence ID or runtime observation',
            'selection':decoded['selection'],'prior_reports':[{'path':str(ROOT/'analysis'/f'{name}.json'),'sha256':clip.identity(ROOT/'analysis'/f'{name}.json')} for name in prior],
            'sources':sources,'resource_sources':[s for s in decoded['sources'] if '/databin/' in s['path']],
            'findings':[
                {'kind':'static_derivation','claim':'Local numeric-axis positive 90deg maps: R0 axis1->axis2, R1 axis2->axis0, R2 axis0->axis1. Local RzRyRx and entity RyRxRz are distinct.',
                 'evidence':['088632d0.c:39-88','088652d4.c:46-50','08865528 raw f3b88480/f3a28482/f0288420','08865478/088653c8 corresponding raw words','validation basis and mixed-angle checks']},
                {'kind':'static_derivation','claim':'Use collision matrix node+0xd0, not rendering matrix +0x50. Child receives parent+0xd0 and parent+0x90; neutral column world=parent*local.',
                 'evidence':['08860320.c:105-148','08860320 raw 0886045c..0886050c','09c32788.c:12-28','08860640.c:9-25']},
                {'kind':'static_observation','claim':'Node1 sampled translation is zeroed before hierarchy; adding both absolute clip root translation and integrated entity root motion would double count.',
                 'evidence':['088637bc.c:34-50,101-108','0885f8e0.c:6-10','0885ffb4.c:14-27']},
                {'kind':'static_derivation','claim':'Type0 sword main attachment uses node10 plus rotated [-47,51,-19]; collision uses distinct node14 and three source-owned capsule segments. Mesh sword tip remains unknown.',
                 'evidence':['088d68b0.c:235-250,299-339,488-566,1293','09c32788 raw kind1 body 09c32854..09c3292c','09bf6a10 3*40-byte records and terminator']}],
            'code_sources':code_sources,'script':{'path':str(Path(__file__).resolve()),'sha256':clip.identity(Path(__file__).resolve())},
            'conventions':{'axes':'artifact numeric axes 0/1/2; no engine mapping or anatomical labels',
                           'storage':'artifact float[16] is columns; JSON matrices are rows, column vectors, translation in column3',
                           'local_rotation':'Rz(R2) * Ry(R1) * Rx(R0), radians; vcst5=2/pi, VFPU sin/cos input in quarter-turn units',
                           'entity_rotation':'Ry(angle+1f4) * Rx(angle+1f0) * Rz(angle+1f8), then scale; NOT local Euler order',
                           'scale':'088632d0 ignores S; 08860320 raw words build R*D(nodeS*entityScale), compensate D(1/entityScale), preserve unscaled T, then parent*local; uniform case local=T*R*D(nodeS). Nonuniform node scale tested; nonuniform entity scale outside this CLI.',
                           'root':'088637bc clears node1 translation after pose; root delta comes from floating curves and negative-previous wrapper',
                           'world':'parameterized unconstrained entity-coordinate model; not an observed quest-world path'},
            'parameters':{'entity_angles_radians':args.angles,'entity_uniform_scale':args.scale,'initial_entity_position':args.position,
                          'step_animation_units':args.step,'pose_time':'uint floor','root_time':'float',
                          'conditions':['normal nonblend tracks synchronized','no root-disable flag','no loop','no alternative pose overlay','fixed entity angles and scale','no terrain/FSM position corrections'],
                          'time_unit_hz':None,'final_end_pose_note':'Samples stop after the first end-clamped pose; do not extrapolate indefinite root integration.'},
            'attachment':{'node':10,'translation':offset,'rotation_radians':attachment_angles,'type0_display_scale_word':'0x3f4ccccd',
                          'status':'static type0 main attachment model only; weapon skin/mesh vertex transform and sheath switching not decoded'},
            'shape_records':shapes,'skeleton':skeleton,'validation':validation,'trajectory':trajectory,
            'unknowns':['PSP VFPU sin/cos/reciprocal/dot rounding and prefixes outside selected straight-line operations',
                        'actual player skeleton/equipment and weapon tip vertex; no sword mesh tip invented',
                        'actual task-world entity transform, terrain/collision constraints, root suppression and blend/loop/live event state',
                        'anatomical/front/up mapping and Hz require visual/runtime comparison'],
            'unsupported_matrix_operations':[], 'costs':{'token_usage':None,'cold_warm_comparison':None,'process_family_peak_memory':None,
                                                         'note':'No performance improvement claim; externally measured single process costs only.'}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check',action='store_true',help='run all checks without writing the report')
    parser.add_argument('--angles',type=float,nargs=3,default=[0.0]*3,help='entity radians for numeric axes 0/1/2')
    parser.add_argument('--position',type=float,nargs=3,default=[0.0]*3)
    parser.add_argument('--scale',type=float,default=1.0,help='positive uniform entity scale')
    parser.add_argument('--step',type=float,default=2.0,help='animation units per normal nonblend call')
    args = parser.parse_args()
    if not all(math.isfinite(x) for x in args.angles+args.position+[args.scale,args.step]) or args.scale <= 0 or not 0.165 <= args.step <= 164:
        parser.error('finite inputs, positive scale, and step in [0.165,164] required by the 1000 sample bound')
    try:
        report = run(args)
    except UnsupportedWord as error:
        report = {'task':'W','status':'unknown','unsupported_matrix_operations':[str(error)],'trajectory':None,
                  'limit':'No complete trajectory manufactured after an unsupported real matrix word.'}
        if not args.check:
            (ROOT/'analysis/hunter_world.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report,ensure_ascii=False))
        raise SystemExit(2)
    if not args.check:
        (ROOT/'analysis/hunter_world.json').write_text(json.dumps(report,ensure_ascii=False,indent=2,allow_nan=False)+'\n')
    print(json.dumps({'status':'passed','output':None if args.check else str(ROOT/'analysis/hunter_world.json'),
                      'validation':report['validation'],'first_attachment':report['trajectory'][0]['weapon_attachment_origin'],
                      'last_attachment':report['trajectory'][-1]['weapon_attachment_origin']},ensure_ascii=False))


if __name__ == '__main__':
    main()
