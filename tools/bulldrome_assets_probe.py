#!/usr/bin/env python3
"""Offline original-PAC export using the pinned, independently installed GPL format tool."""
import hashlib
import json
import math
import resource
import struct
import subprocess
import sys
import time
from dataclasses import asdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'vendor/mhfu-modkit'
COMMIT = 'bac9955a2ffaa33cc308106a9026e22bbd2d4fcd'
sys.dont_write_bytecode = True
sys.path.insert(0, str(VENDOR / 'packages/mhp-formats/src'))
from mhp_formats import Pac, Skeleton, Pmo, Tmh
from mhp_formats.fu.anim import Anim
from mhp_formats.anim import _layout, EMPTY
from mhp_formats._base import FormatError
import bulldrome_identity_probe as identity
from PIL import Image, ImageDraw
import hunter_action_assets_probe as pose_owner

clip_parser = pose_owner.clip_parser
world = pose_owner.world_parser
skin = pose_owner.skin_parser


def runtime_semantics(eboot):
    eboot_sha = digest(eboot)
    clip_parser.require(eboot_sha == clip_parser.EXPECTED[identity.EBOOT], 'original EBOOT identity mismatch')
    def evidence(address, size):
        start = address - clip_parser.BASE + clip_parser.ORIGIN
        data = eboot[start:start + size]
        clip_parser.require(len(data) == size, 'EBOOT source outside file')
        return {'path': str(ROOT / identity.EBOOT), 'file_sha256': eboot_sha,
                'virtual_address': hex(address), 'range': [start, start + size],
                'range_sha256': digest(data), 'raw_hex': data.hex()}
    types, entries = {}, []
    for kind in (1, 2, 4, 8, 16, 32, 64, 128, 256):
        item = evidence(0x089a2ce4 + kind * 4, 4)
        component = struct.unpack('<i', bytes.fromhex(item['raw_hex']))[0]
        clip_parser.require(0 <= component < 9, 'invalid original SRT component')
        types[kind] = component
        entries.append({'kind': kind, 'component_index': component,
                        'component': clip_parser.COMPONENTS[component], 'source': item})
    # These original instructions establish the factors, independently of community dequantization.
    checks = {0x08863250: 0x30420038, 0x08863254: 0x50400008,
              0x0886325c: 0x3c0239c9, 0x08863260: 0x34420fdb,
              0x0886326c: 0x46010002, 0x08863278: 0x3c023d80,
              0x08863280: 0x46010002}
    for address, expected in checks.items():
        clip_parser.require(struct.unpack('<I', bytes.fromhex(evidence(address, 4)['raw_hex']))[0] == expected,
                            'original scale instruction mismatch')
    functions = {0x08863190: 320, 0x088633c4: 640, 0x08862fd8: 240,
                 0x0885f840: 160, 0x0885fa04: 328, 0x08860054: 512,
                 0x088637bc: 940, 0x088632d0: 244, 0x08860320: 532,
                 0x08860534: 268, 0x08860640: 136}
    programs = {address: list(struct.unpack('<' + 'I' * (size // 4),
                bytes.fromhex(evidence(address, size)['raw_hex']))) for address, size in functions.items()}
    semantics = {
        'channel': {'semantics_owner': 'original_08863190', 'type_table': entries,
                    'factor_nonrotation_bits': '0x3d800000', 'factor_nonrotation': 0.0625,
                    'factor_rotation_bits': '0x39c90fdb', 'factor_rotation': clip_parser.ROTATION_FACTOR,
                    'factor_rule': '(kind & 0x38) == 0 ? 0.0625 : float32(0x39c90fdb); S and T share 1/16, not community S 1/256',
                    'normalized_key_columns': ['value_source_units', 'time_s16', 'in_tangent_source_units_per_time', 'out_tangent_source_units_per_time']},
        'sampling': {'semantics_owner': 'shared_hunter_action_assets_probe',
                     'pose_time': '0885fa04 converts nonnegative float time to uint; 08863190 samples at that unsigned integral time',
                     'root_time': '088633c4 samples floating time separately; no integer truncation',
                     'interpolation': 'hunter_clip_probe.sample/hermite: raw s16 in/out derivatives times key interval; factor applied after sampling',
                     'precision': 'offline float64 mathematical model, not PSP VFPU rounding/reciprocal execution'},
        'binding': {'semantics_owner': 'original_08860054_0885f840_0885fa04',
                    'rule': 'skeleton bone +0x50 group u32 -> runtime +0x114 low ushort; bind next clip track on matching parent-first child/sibling traversal; sample same group/traversal'},
        'loop': {'semantics_owner': 'original_header_088637bc',
                 'rule': 'preserve loop u32 and float32 loop_start bit pattern; 088637bc active bit1/end clamp vs bit2 wrap, end overshoot discarded, reset current to loop_start; do not infer display FPS'},
        'mesh': {'semantics_owner': 'shared_hunter_skin_probe',
                 'rule': 'original 08860054 bind -> 08860534 inverse producer with inverse PMO scale; 08860320 animated hierarchy -> 08860640 current*inverse; GE normalized positions weighted once',
                 'entity_world_transform': 'preview identity entity rotation/translation, body scale 1; bone/root translation retained, not applied again to entity'},
        'sources': [evidence(address, size) for address, size in functions.items()],
        'shared_owner_sources': [{'path': str(ROOT / 'tools' / name), 'sha256': digest((ROOT / 'tools' / name).read_bytes())}
                                for name in ('hunter_clip_probe.py', 'hunter_action_assets_probe.py', 'hunter_world_probe.py', 'hunter_skin_probe.py')]
    }
    return types, programs, semantics


def digest(data):
    return hashlib.sha256(data).hexdigest()


def plain(value):
    if isinstance(value, bytes):
        return {'raw_hex': value.hex()}
    if isinstance(value, dict):
        return {str(k): plain(v) for k, v in value.items()}
    if isinstance(value, (tuple, list)):
        return [plain(v) for v in value]
    return value


def source(pack_id, raw, off, size):
    if not 0 <= off <= off + size <= len(raw):
        raise ValueError('invalid member source range')
    return {'path': str(ROOT / f'databin/{pack_id:04d}.bin'),
            'range': [off, off + size], 'range_sha256': digest(raw[off:off + size])}


def bounds(points):
    if not points:
        return None
    lo = [min(p[k] for p in points) for k in range(3)]
    hi = [max(p[k] for p in points) for k in range(3)]
    return {'min': lo, 'max': hi, 'size': [b - a for a, b in zip(lo, hi)]}


def animations(anim, data, pack_id, raw, member_offset, type_map):
    # The format owner validates and parses the directory; retain original table IDs, not labels.
    tables, table_end = _layout(data)
    clips, streams = {}, []
    for stream_id, (offsets, stream) in enumerate(zip(tables, anim.streams, strict=True)):
        slots = []
        for slot_id, (offset, clip) in enumerate(zip(offsets, stream, strict=True)):
            slots.append({'slot_id': slot_id, 'raw_offset_id': offset,
                          'clip_id': None if offset == EMPTY else str(offset)})
            if clip is None or str(offset) in clips:
                continue
            size = struct.unpack_from('<I', data, offset + 8)[0]
            decoded = clip_parser.decode_clip(data[offset:offset + size], type_map, member_offset + offset)
            clip_parser.require(len(clip.tracks) == len(decoded['nodes']), 'community/runtime track count mismatch')
            clip_parser.require(clip.loop == decoded['header']['loop_enabled_raw'] and
                                struct.pack('<f', clip.loop_start) == struct.pack('<I', decoded['header']['loop_start_raw_u32']),
                                'community/runtime header mismatch')
            track_at = offset + 20
            tracks = []
            for track_id, track in enumerate(clip.tracks):
                track_size = struct.unpack_from('<I', data, track_at + 8)[0]
                channel_at = track_at + 12
                channels = []
                node = decoded['nodes'][track_id]
                clip_parser.require(track.mask == int(node['flags'], 16) & 0x1ff, 'community/runtime node mask mismatch')
                for channel, parsed in zip(track.channels, node['channels'], strict=True):
                    channel_size = 12 + 8 * len(channel.keyframes)
                    keys = [list(key) for key in channel.keyframes]
                    clip_parser.require(channel.bit == parsed['type'] and keys == parsed['keys'] and
                                        parsed['byte_range'] == [member_offset + channel_at, member_offset + channel_at + channel_size],
                                        'community/runtime per-key or channel range mismatch')
                    channels.append({'raw_bit': channel.bit, 'component_index': parsed['component_index'],
                                     'component': parsed['component'], 'factor': parsed['factor'],
                                     'semantics_owner': 'channel',
                                     'source': source(pack_id, raw, member_offset + channel_at, channel_size),
                                     'key_columns': ['value_s16', 'time_s16', 'in_tangent_s16', 'out_tangent_s16'],
                                     'keys_raw': keys,
                                     'keys_source_units': [[v * parsed['factor'], t, mi * parsed['factor'], mo * parsed['factor']]
                                                           for v, t, mi, mo in keys]})
                    channel_at += channel_size
                tracks.append({'track_id': track_id, 'mask_raw': int(node['flags'], 16),
                               'source': source(pack_id, raw, member_offset + track_at, track_size),
                               'channels': channels})
                track_at += track_size
            frames = [k.frame for t in clip.tracks for c in t.channels for k in c.keyframes]
            clips[str(offset)] = {'source': source(pack_id, raw, member_offset + offset, size),
                                  'semantics_owner': 'sampling', 'loop_semantics_owner': 'loop',
                                  'header_raw': decoded['header'],
                                  'loop_raw': clip.loop, 'loop_start_raw_u32': decoded['header']['loop_start_raw_u32'],
                                  'loop_start_float32': clip.loop_start,
                                  'key_frame_range': [min(frames), max(frames)] if frames else None,
                                  'duration_frames_derived': max(frames) if frames else None,
                                  'duration_seconds': None, 'fps': None,
                                  'tracks': tracks}
        streams.append({'stream_id': stream_id, 'slots': slots})
    return {'directory_source': source(pack_id, raw, member_offset, table_end),
            'streams': streams, 'clips': clips,
            'tail_source': source(pack_id, raw, member_offset + len(data) - len(anim.tail), len(anim.tail)),
            'time_semantics': 'Duration is maximum source key frame, not a separate duration field. FPS and gameplay speed not established.',
            'semantics_owner': 'sampling',
            'root_translation_scope': 'T channels belong to their original bone; float root sample is separate from uint pose sample. Preview retains bone T with identity entity, not gameplay root extraction.'}


def model_data(pmo):
    groups = []
    for g, group in enumerate(pmo.groups()):
        vertex = group.block.vertices
        mesh = pmo.mesh_of(g)
        positions = pmo.positions(g)
        triangles = pmo.triangles(g)
        if not all(0 <= i < len(vertex) for tri in triangles for i in tri):
            raise ValueError('triangle index outside vertex buffer')
        groups.append({'group_id': g, 'mesh_id': next(i for i, m in enumerate(pmo.meshes) if m is mesh),
                       'material_slot_raw': group.material,
                       'material_index': mesh.materials[group.material] if group.material < len(mesh.materials) else None,
                       'bone_palette_patches': list(group.bones), 'bone_palette_resolved': pmo.palette(g),
                       'vertex_type_word': vertex.vtype.to_word(), 'vertex_type': asdict(vertex.vtype),
                       'morph_count': vertex.vtype.morph_count,
                       'vertices_raw': {key: getattr(vertex, key) for key in ('position', 'normal', 'texture', 'weight', 'color')},
                       'positions_source_units': positions,
                       'positions_ge_normalized': vertex.positions((1.0, 1.0, 1.0)),
                       'normals': vertex.normals(), 'uvs': vertex.uvs(),
                       'influences': pmo.influences(g), 'indices_raw': group.block.indices,
                       'triangles': triangles, 'commands_relocated_by_library': list(group.block.commands),
                       'uv_scale_source': mesh.uv_scale, 'lighting_raw': mesh.lighting, 'blend_raw': mesh.blend})
    return {'scale_source': pmo.scale, 'clip_cull_radius_source': pmo.clip,
            'materials': [asdict(m) for m in pmo.materials], 'groups': groups,
            'bounds_source_units': bounds([p for g in groups for p in g['positions_source_units']]),
            'semantics_owner': 'mesh',
            'bind_geometry_note': 'positions_source_units use PMO dequantization/header scale only; animated positions use GE normalized vertices with original inverse/current producers once.',
            'display_scale': 0.01, 'axis_conversion': 'none; source axes retained'}


def map_tracks(skeleton, animation):
    nodes = skeleton['nodes']
    groups = {}
    for node in nodes:
        groups.setdefault(node['track_group'], []).append(node['index'])
    # Validate links rather than using matching counts as proof of order.
    roots = skeleton['roots']
    clip_parser.require(roots == [n['index'] for n in nodes if n['parent'] == -1], 'original roots/parents disagree')
    visited, order = set(), []
    def visit(index, parent):
        while index != -1:
            clip_parser.require(0 <= index < len(nodes) and index not in visited, 'invalid/repeated skeleton traversal')
            node = nodes[index]
            clip_parser.require(node['parent'] == parent, 'child/sibling parent mismatch')
            visited.add(index)
            order.append(index)
            visit(node['first_child'], index)
            index = node['next_sibling']
    for root in roots:
        visit(root, -1)
    clip_parser.require(len(visited) == len(nodes), 'unreachable skeleton bones')
    mappings = []
    for stream in animation['streams']:
        group = stream['stream_id']
        counts = sorted({len(animation['clips'][s['clip_id']]['tracks']) for s in stream['slots'] if s['clip_id'] is not None})
        if not counts:
            mappings.append({'stream_id': group, 'status': 'empty_original_stream', 'track_to_bone': None})
            continue
        binding = clip_parser.binding_order(skeleton, group)
        clip_parser.require(counts == [len(binding)], 'track count differs from original group traversal')
        clip_parser.require(binding == [i for i in order if nodes[i]['track_group'] == group], 'binding/group traversal differs')
        clip_parser.require(all(nodes[i]['track_group'] <= 65535 for i in binding), 'group u32 loses information at runtime ushort')
        mappings.append({'stream_id': group, 'clip_track_counts': counts, 'track_to_bone': binding,
                         'status': 'static_group_link_traversal_verified', 'semantics_owner': 'binding'})
    return {'semantics_owner': 'binding', 'bone_group_members': groups, 'streams': mappings,
            'parent_first_link_traversal': order, 'source_order_matches_traversal': order == list(range(len(nodes))),
            'roots': roots, 'runtime_binding_verified': False}


def inspect(pack_id, raw, type_map):
    pac = Pac.from_bytes(raw)
    count = struct.unpack_from('<I', raw)[0]
    original_table = [struct.unpack_from('<II', raw, 4 + 8 * i) for i in range(count)]
    if pac.table() != original_table:
        raise ValueError('library PAC layout differs from original directory')
    result = {'runtime_pack_id': pack_id, 'originalpacksha': {'sha256': digest(raw), 'sha1': hashlib.sha1(raw).hexdigest()},
              'pac_byte_identical': pac.to_bytes() == raw, 'members': [], 'resources': {}}
    objects = {}
    for i, ((off, size), entry) in enumerate(zip(original_table, pac.entries, strict=True)):
        row = {'member_id': i, 'offset_raw': off, 'length_raw': size, 'source': source(pack_id, raw, off, size)}
        result['members'].append(row)
        if not size:
            row['status'] = 'empty_original_pair'
            continue
        fmt = next((f for f in (Skeleton, Pmo, Tmh, Anim) if f.sniff(entry)), None)
        if fmt is None:
            row.update(status='opaque_preserved', prefix_hex=entry[:32].hex())
            continue
        row['format'] = fmt.__name__
        try:
            obj = fmt.from_bytes(entry)
            rebuilt = obj.to_bytes()
            row.update(status='decoded', reencoded_sha256=digest(rebuilt), byte_identical=rebuilt == entry,
                       verification='conditional_pass_decode_reencode' if rebuilt == entry else 'decoded_nonidentical_reencode')
        except (FormatError, ValueError, NotImplementedError, struct.error) as exc:
            row.update(status='unsupported_preserved', reason=str(exc))
            continue
        objects[fmt.__name__] = obj
        if fmt is Skeleton:
            parsed_skeleton = clip_parser.decode_skeleton(entry, off)
            for bone, node in zip(obj.bones, parsed_skeleton['nodes'], strict=True):
                clip_parser.require((bone.parent, bone.child, bone.sibling, bone.stream) ==
                                    (node['parent'], node['first_child'], node['next_sibling'], node['track_group']) and
                                    list(bone.scale + bone.rotation + bone.position) == node['bind_components_S_R_T'],
                                    'community/original skeleton group, links or SRT differ')
            result['resources']['skeleton'] = {'member_id': i, 'semantics_owner': 'binding',
                                               'bones': [dict(bone_id=j, group_raw=b.stream, **asdict(b)) for j, b in enumerate(obj.bones)],
                                               'original_parsed': parsed_skeleton,
                                               'params_raw': obj.params, 'params_count_raw_override': obj.params_count,
                                               'magic_raw': obj.magic, 'roots': obj.roots(),
                                               'bind_units': 'position: source units; rotation: source Euler radians; scale: source factors; no normalization'}
        elif fmt is Pmo:
            result['resources']['model'] = dict(member_id=i, **model_data(obj))
        elif fmt is Anim:
            result['resources']['animation'] = dict(member_id=i, **animations(obj, entry, pack_id, raw, off, type_map))
        elif fmt is Tmh:
            images = []
            for j, image in enumerate(obj.images):
                info = {'image_id': j, 'mode_raw': image.mode, 'width': image.width, 'height': image.height,
                        'swizzled_library_inference': image.swizzled, 'pixels_sha256': digest(image.pixels),
                        'clut_mode': image.clut.mode if image.clut else None,
                        'clut_entries': image.clut.entries if image.clut else None,
                        'clut_sha256': digest(image.clut.data) if image.clut else None}
                try:
                    rgba = image.decode(palette=0)
                    if len(rgba) != image.width * image.height * 4:
                        raise ValueError('decoded RGBA length mismatch')
                    path = ROOT / f'analysis/bulldrome_texture_{pack_id}_{j}.png'
                    with Image.open(path) as retained:
                        clip_parser.require(retained.size == (image.width, image.height) and
                                            retained.convert('RGBA').tobytes() == rgba, 'retained texture differs from original decode')
                    info.update(decode_status='decoded_palette0', preview_path=str(path), rgba_sha256=digest(rgba))
                except (FormatError, ValueError, NotImplementedError) as exc:
                    info.update(decode_status='unsupported_preserved', reason=str(exc))
                images.append(info)
            result['resources']['texture_bank'] = {'member_id': i, 'images': images}
    if 'Skeleton' in objects and 'animation' in result['resources']:
        result['resources']['animation_binding'] = map_tracks(result['resources']['skeleton']['original_parsed'], result['resources']['animation'])
    return result, objects


def render_panel(model, texture_bank, angle, size=(640, 480), frame_bounds=None):
    # Orthographic, two-sided, flat-lit triangle raster, source geometry at display scale .01.
    w, h = size
    image = Image.new('RGB', size, (30, 34, 40))
    pixels = image.load()
    zbuffer = [-math.inf] * (w * h)
    theta, pitch = angle, -0.17
    ct, st, cp, sp = math.cos(theta), math.sin(theta), math.cos(pitch), math.sin(pitch)
    def view(p):
        x, y, z = [v * 0.01 for v in p]
        a, b = ct * x + st * z, -st * x + ct * z
        return (a, cp * y - sp * b, sp * y + cp * b)
    all_points = [view(p) for g in model['groups'] for p in g['positions_source_units']]
    box = bounds([view(p) for p in frame_bounds]) if frame_bounds else bounds(all_points)
    factor = min((w - 60) / max(box['size'][0], 1e-9), (h - 80) / max(box['size'][1], 1e-9))
    center = [(a + b) / 2 for a, b in zip(box['min'], box['max'])]
    def screen(p):
        x, y, z = view(p)
        return ((x - center[0]) * factor + w / 2, h / 2 - (y - center[1]) * factor, z)
    textures = {}
    for info in texture_bank['images']:
        if info['decode_status'] == 'decoded_palette0':
            textures[info['image_id']] = Image.open(info['preview_path']).convert('RGBA')
    triangles_drawn = 0
    for group in model['groups']:
        vertices = [screen(p) for p in group['positions_source_units']]
        material = model['materials'][group['material_index']] if group['material_index'] is not None else None
        if material and material['color'] >> 24 == 0:
            continue
        tex = textures.get(material['texture']) if material else None
        uv = group['uvs']
        for ia, ib, ic in group['triangles']:
            a, b, c = vertices[ia], vertices[ib], vertices[ic]
            denom = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
            if abs(denom) < 1e-8:
                continue
            triangles_drawn += 1
            va, vb, vc = [view(group['positions_source_units'][i]) for i in (ia, ib, ic)]
            ab, ac = [vb[k] - va[k] for k in range(3)], [vc[k] - va[k] for k in range(3)]
            normal = [ab[1]*ac[2]-ab[2]*ac[1], ab[2]*ac[0]-ab[0]*ac[2], ab[0]*ac[1]-ab[1]*ac[0]]
            length = math.sqrt(sum(n*n for n in normal))
            shade = 0.4 + 0.6 * abs(sum(n*l for n, l in zip(normal, (0.3, 0.7, 0.64))) / max(length, 1e-9))
            xmin, xmax = max(0, math.floor(min(a[0], b[0], c[0]))), min(w - 1, math.ceil(max(a[0], b[0], c[0])))
            ymin, ymax = max(0, math.floor(min(a[1], b[1], c[1]))), min(h - 1, math.ceil(max(a[1], b[1], c[1])))
            for y in range(ymin, ymax + 1):
                for x in range(xmin, xmax + 1):
                    s = ((b[1] - c[1])*(x+.5-c[0]) + (c[0]-b[0])*(y+.5-c[1])) / denom
                    t = ((c[1] - a[1])*(x+.5-c[0]) + (a[0]-c[0])*(y+.5-c[1])) / denom
                    u = 1 - s - t
                    if min(s, t, u) < -1e-7:
                        continue
                    z = s*a[2] + t*b[2] + u*c[2]
                    at = y*w+x
                    if z <= zbuffer[at]:
                        continue
                    color = (180, 140, 98, 255)
                    if tex is not None and uv:
                        tx = (s*uv[ia][0] + t*uv[ib][0] + u*uv[ic][0]) * group['uv_scale_source'][0]
                        ty = (s*uv[ia][1] + t*uv[ib][1] + u*uv[ic][1]) * group['uv_scale_source'][1]
                        color = tex.getpixel((int(tx*tex.width) % tex.width, int(ty*tex.height) % tex.height))
                    if color[3] < 128:
                        continue
                    zbuffer[at] = z
                    pixels[x, y] = tuple(min(255, int(v*shade)) for v in color[:3])
    return image, {'projected_nondegenerate_triangles': triangles_drawn,
                   'covered_pixels': sum(z != -math.inf for z in zbuffer),
                   'source_angle_radians': angle, 'display_scale': 0.01}


def summary(pack):
    resources = pack['resources']
    skel, model, anim = resources.get('skeleton', {}), resources.get('model', {}), resources.get('animation', {})
    clips = anim.get('clips', {})
    kinds = sorted({c['raw_bit'] for clip in clips.values() for track in clip['tracks'] for c in track['channels']})
    return {'runtime_pack_id': pack['runtime_pack_id'], 'originalpacksha': pack['originalpacksha'],
            'members': pack['members'], 'counts': {'bones': len(skel.get('bones', [])),
            'groups': len(model.get('groups', [])), 'vertices_including_group_references': sum(len(g['positions_source_units']) for g in model.get('groups', [])),
            'triangles_including_degenerate': sum(len(g['triangles']) for g in model.get('groups', [])),
            'textures': len(resources.get('texture_bank', {}).get('images', [])), 'streams': len(anim.get('streams', [])),
            'slots_per_stream': [len(s['slots']) for s in anim.get('streams', [])], 'unique_clips': len(clips),
            'keys': sum(len(c['keys_raw']) for clip in clips.values() for t in clip['tracks'] for c in t['channels'])},
            'bounds_source_units': model.get('bounds_source_units'), 'normalized_channel_kinds': kinds,
            'all_channels_normalized': True,
            'channel_kind_coverage': [{'kind': kind, 'channels': sum(c['raw_bit'] == kind for clip in clips.values() for t in clip['tracks'] for c in t['channels']),
                                       'keys': sum(len(c['keys_raw']) for clip in clips.values() for t in clip['tracks'] for c in t['channels'] if c['raw_bit'] == kind)} for kind in kinds],
            'animation_binding': resources.get('animation_binding'),
            'stream_occupancy': [{'stream_id': s['stream_id'],
                                  'occupied_slots': [slot['slot_id'] for slot in s['slots'] if slot['clip_id'] is not None],
                                  'empty_slot_count': sum(slot['clip_id'] is None for slot in s['slots'])}
                                 for s in anim.get('streams', [])],
            'clips': [{'clip_id': cid, 'track_count': len(clip['tracks']), 'loop_raw': clip['loop_raw'],
                       'loop_start_raw_u32': clip['loop_start_raw_u32'], 'loop_start_float32': clip['loop_start_float32'],
                       'duration_frames_derived': clip['duration_frames_derived'],
                       'stream_slots': [[s['stream_id'], slot['slot_id']] for s in anim['streams'] for slot in s['slots'] if slot['clip_id'] == cid],
                       'all_channels_normalized': True}
                      for cid, clip in clips.items()], 'pac_byte_identical': pack['pac_byte_identical']}


def sampling_clip(cid, clip, binding, group=0):
    loop, start = clip['loop_raw'], clip['loop_start_float32']
    end = clip['duration_frames_derived']
    clip_parser.require(loop in (0, 1), 'unsupported original loop word; do not coerce unknown to bool')
    clip_parser.require(math.isfinite(start) and end is not None and 0 <= start <= end,
                        'unsupported original loop start; do not invent a fallback')
    clip_parser.require(loop == clip['header_raw']['loop_enabled_raw'] and
                        struct.pack('<f', start) == struct.pack('<I', clip['loop_start_raw_u32']) and
                        clip['loop_start_raw_u32'] == clip['header_raw']['loop_start_raw_u32'],
                        'loop/start interpreted fields differ from original header bits')
    for track in clip['tracks']:
        bits = [c['raw_bit'] for c in track['channels']]
        clip_parser.require(len(set(bits)) == len(bits) and track['mask_raw'] & 0x1ff == sum(bits),
                            'missing or duplicate channel; retain original mask, do not silently fill defaults')
    nodes = [{'channels': [dict(component_index=c['component_index'], factor=c['factor'], keys=c['keys_raw'])
                           for c in track['channels']]} for track in clip['tracks']]
    clip_parser.require(len(nodes) == len(binding), 'incomplete animation binding')
    return pose_owner.AnimationClip(cid, group, tuple(nodes), tuple(binding), float(end), bool(loop), start)


def animated_model(model, matrices):
    groups = []
    for group in model['groups']:
        points = []
        for p, influences in zip(group['positions_ge_normalized'], group['influences'], strict=True):
            clip_parser.require(influences and sum(w for _, w in influences) == 1, 'missing/nonunit original influences')
            points.append([sum(weight * world.transform(matrices[bone], p)[axis]
                               for bone, weight in influences if weight) for axis in range(3)])
        clip_parser.require(all(math.isfinite(v) for p in points for v in p), 'nonfinite animated mesh')
        groups.append(dict(group, positions_source_units=points))
    return dict(model, groups=groups)


def animation_geometry(pack, programs):
    resources = pack['resources']
    bones = resources['skeleton']['bones']
    nodes = [{'parent_candidate': b['parent'], 'scale': b['scale'],
              'rotation_euler': b['rotation'], 'translation': b['position']} for b in bones]
    defaults = [n['bind_components_S_R_T'] for n in resources['skeleton']['original_parsed']['nodes']]
    model = resources['model']
    rests, inverses, globals_ = skin.rest_hierarchy(programs, {'bind_nodes': nodes, 'pmo_scale': model['scale_source']})
    inverse_residual = max(skin.error(world.multiply(rests[i], inverses[i]), world.identity_matrix()) for i in rests)
    binding = next(s['track_to_bone'] for s in resources['animation_binding']['streams'] if s['stream_id'] == 0)
    samples, meshes = [], {}
    pose_error = hierarchy_error = world_error = 0.0
    entity = world.rotation((0.17, -0.31, 0.23))
    entity = world.multiply(entity, skin.diagonal([1.3, 0.8, 1.1]))
    for axis, value in enumerate((123.0, -47.0, 83.0)):
        entity[axis][3] = value
    vertex_checks = 0
    for cid, clip in resources['animation']['clips'].items():
        parsed = sampling_clip(cid, clip, binding)
        for display_time in (0.0, parsed.end / 2 + 0.5, parsed.end):
            display_time = min(display_time, parsed.end)
            channels = pose_owner.sample_channels(parsed, defaults, display_time)
            floating = pose_owner.sample_channels(parsed, defaults, display_time, floating=True)
            root = pose_owner.sample_root(pose_owner.RootSample(parsed, display_time, defaults))
            clip_parser.require(tuple(floating[1][6:9]) == root, 'float root sample differs from original node channels')
            poses = pose_owner.make_pose(channels)
            matrices, scales = {i: p.matrix for i, p in poses.items()}, {i: p.scale for i, p in poses.items()}
            for i, pose in poses.items():
                observed = world.pose_word(programs, channels[i])
                difference = skin.error(observed, pose.matrix)
                pose_error = max(pose_error, difference)
                clip_parser.require(difference < 1e-8, 'shared make_pose differs from original matrix words')
            currents, collisions = skin.hierarchy(programs, nodes, matrices, scales, [1.0]*3,
                                                  world.identity_matrix(), world.identity_matrix())
            expected = {}
            for i in resources['animation_binding']['parent_first_link_traversal']:
                parent = nodes[i]['parent_candidate']
                local = world.multiply(matrices[i], skin.diagonal(scales[i]))
                expected[i] = world.multiply(world.identity_matrix() if parent == -1 else expected[parent], local)
                difference = skin.error(currents[i], expected[i])
                hierarchy_error = max(hierarchy_error, difference)
                clip_parser.require(difference < 1e-7, 'raw-word animated hierarchy differs from independent SRT composition')
                world.close(collisions[i], currents[i], 1e-7)
            render = {i: skin.render_producer(programs, inverses[i], currents[i]) for i in currents}
            for i in render:
                world.close(render[i], world.multiply(currents[i], inverses[i]), 1e-7)
            animated = animated_model(model, render)
            entity_render = {i: world.multiply(entity, render[i]) for i in render}
            moved = animated_model(model, entity_render)
            for group, moved_group in zip(animated['groups'], moved['groups'], strict=True):
                for p, actual in zip(group['positions_source_units'], moved_group['positions_source_units'], strict=True):
                    desired = world.transform(entity, p)
                    difference = max(abs(a-b) for a, b in zip(actual, desired))
                    world_error = max(world_error, difference)
                    clip_parser.require(difference < 1e-7, 'animated mesh entity world transform double-applied or omitted')
                    vertex_checks += 1
            points = [p for g in animated['groups'] for p in g['positions_source_units']]
            sample = {'clip_id': cid, 'display_time_source_units': display_time, 'pose_time_uint': math.floor(display_time),
                      'root_time_float': display_time, 'root_translation_source_units': root,
                      'semantics_owner': 'sampling', 'mesh_semantics_owner': 'mesh',
                      'bone_components_S_R_T': channels, 'bone_model_matrices': currents,
                      'bone_render_matrices': render, 'bounds_source_units': bounds(points)}
            samples.append(sample)
            meshes[(cid, display_time)] = animated
    return samples, meshes, {'semantics_owner': 'mesh', 'clips': len(resources['animation']['clips']),
                            'finite_pose_and_mesh_samples': len(samples), 'animated_vertex_world_transform_checks': vertex_checks,
                            'make_pose_vs_original_words_max_error': pose_error,
                            'hierarchy_vs_independent_SRT_max_error': hierarchy_error,
                            'animated_world_transform_max_error': world_error,
                            'original_bind_inverse_residual': inverse_residual,
                            'inverse_applicability': 'approximate_original_producer_not_generic_inverse' if inverse_residual > 1e-8 else 'orthogonal_verified',
                            'runtime_vfpu_verified': False}


def animation_preview(pack, samples, meshes, behavior):
    records = {r['selection']: r for r in behavior['derivations']['animation_selection_records']}
    selected = (15, 16, 18, 19, 24, 60, 61, 62, 63, 64)
    canvas = Image.new('RGB', (1440, 320 * len(selected)), (30, 34, 40))
    panels = []
    animation = pack['resources']['animation']
    for row, selection in enumerate(selected):
        record = records[selection]
        slot = animation['streams'][record['resource_stream']]['slots'][record['resource_slot']]
        cid = slot['clip_id']
        clip_parser.require(cid is not None and int(cid) == int(record['resource']['raw_offset'], 16), 'behavior/asset selection mismatch')
        clip = animation['clips'][cid]
        clip_parser.require(clip['source']['range_sha256'] == record['resource']['clip']['sha256'], 'behavior selected clip identity differs')
        poses = [s for s in samples if s['clip_id'] == cid]
        framing = [p for s in poses for g in meshes[(cid, s['display_time_source_units'])]['groups'] for p in g['positions_source_units']]
        for column, sample in enumerate(poses):
            panel, stats = render_panel(meshes[(cid, sample['display_time_source_units'])], pack['resources']['texture_bank'],
                                        0.9, size=(480, 320), frame_bounds=framing)
            canvas.paste(panel, (column * 480, row * 320))
            label = f"sel {selection} / runtime {record['channel0_runtime_id']} / clip {cid}"
            draw = ImageDraw.Draw(canvas)
            draw.text((column*480+10, row*320+8), label, fill=(235, 235, 235))
            draw.text((column*480+10, row*320+24),
                      f"time={sample['display_time_source_units']:g}  pose_uint={sample['pose_time_uint']}  source units", fill=(235,235,235))
            panels.append(dict(selection=selection, runtime_id=record['channel0_runtime_id'], clip_id=cid,
                               panel=[column, row], display_time_source_units=sample['display_time_source_units'],
                               pose_time_uint=sample['pose_time_uint'], **stats))
    path = ROOT / 'analysis/bulldrome_animation_preview.png'
    canvas.save(path)
    return {'path': str(path), 'sha256': digest(path.read_bytes()), 'panels': panels,
            'semantics_owner': 'mesh', 'framing': 'same framing for three times of each clip; identity entity; no FPS or gameplay sequence simulation',
            'behavior_source': {'path': str(ROOT / 'analysis/bulldrome_behavior.json'),
                                'sha256': digest((ROOT / 'analysis/bulldrome_behavior.json').read_bytes()),
                                'json_pointer': '/derivations/animation_selection_records'}}


def validate_export(path):
    exported = json.loads(path.read_bytes())
    if exported['schema'] != 2 or exported['community_commit'] != COMMIT:
        raise ValueError('export schema or provenance mismatch')
    type_map, programs, semantics = runtime_semantics(identity.bounded(identity.EBOOT))
    clip_parser.require(exported['semantics'] == semantics, 'exported semantics differ from original/shared owners')
    channels_checked = keys_checked = clips_checked = intervals_checked = 0
    equation_error = 0.0
    rejections = []
    for pack in exported['packs']:
        raw = identity.bounded(f"databin/{pack['runtime_pack_id']:04d}.bin")
        if digest(raw) != pack['originalpacksha']['sha256']:
            raise ValueError('export pack hash mismatch')
        bones = pack['resources']['skeleton']['bones']
        for bone in bones:
            if bone['parent'] != -1 and not 0 <= bone['parent'] < len(bones):
                raise ValueError('bone parent outside skeleton')
        for group in pack['resources']['model']['groups']:
            for influences in group['influences']:
                if any(not 0 <= bone_id < len(bones) for bone_id, weight in influences if weight):
                    raise ValueError('active influence has unresolved bone')
        anim = pack['resources']['animation']
        skel_member = pack['members'][pack['resources']['skeleton']['member_id']]
        skel_start, skel_end = skel_member['source']['range']
        original_skeleton = clip_parser.decode_skeleton(raw[skel_start:skel_end], skel_start)
        clip_parser.require(pack['resources']['skeleton']['original_parsed'] == original_skeleton, 'retained parsed skeleton differs')
        clip_parser.require(pack['resources']['animation_binding'] == plain(map_tracks(original_skeleton, anim)), 'export mapping differs from original group/link traversal')
        for group in pack['resources']['model']['groups']:
            vtype = group['vertex_type']
            clip_parser.require(vtype['position'] == 2 and vtype['morph_count'] == 1 and not vtype['through'], 'unverified GE vertex representation')
            for original, ge, source_units in zip(group['vertices_raw']['position'], group['positions_ge_normalized'], group['positions_source_units'], strict=True):
                clip_parser.require(ge == [v / 32768 for v in original], 'GE normalized position differs from original s16 words')
                clip_parser.require(source_units == [v * s for v, s in zip(ge, pack['resources']['model']['scale_source'])], 'PMO scale applied inconsistently')
        for stream in anim['streams']:
            for slot in stream['slots']:
                if slot['clip_id'] is not None and slot['clip_id'] not in anim['clips']:
                    raise ValueError('slot points to missing exported clip')
        for cid, clip in anim['clips'].items():
            begin, finish = clip['source']['range']
            decoded = clip_parser.decode_clip(raw[begin:finish], type_map, begin)
            clip_parser.require(clip['header_raw'] == decoded['header'], 'export header bit patterns differ')
            binding = next(s['track_to_bone'] for s in pack['resources']['animation_binding']['streams'] if s['stream_id'] == 0)
            sampling_clip(cid, clip, binding)
            clips_checked += 1
            for track, node in zip(clip['tracks'], decoded['nodes'], strict=True):
                for channel, parsed in zip(track['channels'], node['channels'], strict=True):
                    clip_parser.require(channel['component_index'] == parsed['component_index'] and
                                        channel['component'] == parsed['component'] and channel['factor'] == parsed['factor'] and
                                        channel['keys_raw'] == parsed['keys'], 'export normalized channel differs from independent decoder')
                    expected = [[v*parsed['factor'], t, mi*parsed['factor'], mo*parsed['factor']] for v, t, mi, mo in parsed['keys']]
                    clip_parser.require(channel['keys_source_units'] == expected, 'normalized values/tangents differ from EBOOT factors')
                    for key in channel['keys_raw']:
                        clip_parser.require(clip_parser.sample(channel['keys_raw'], key[1]) * channel['factor'] == key[0] * channel['factor'], 'exact original key sample differs')
                    for left, right in zip(channel['keys_raw'], channel['keys_raw'][1:]):
                        t = left[1] + (right[1]-left[1]) * 0.375
                        difference = abs(clip_parser.hermite(t, left, right) - clip_parser.consumer_equation(t, left, right))
                        equation_error = max(equation_error, difference)
                        clip_parser.require(difference < 1e-7, 'Hermite differs from original consumer equation')
                        intervals_checked += 1
                    start, end = channel['source']['range']
                    original = raw[start:end]
                    if digest(original) != channel['source']['range_sha256']:
                        raise ValueError('export channel source hash mismatch')
                    keys = channel['keys_raw']
                    encoded = struct.pack('<3I', 0x80120000 | channel['raw_bit'], len(keys), 12 + len(keys)*8)
                    encoded += b''.join(struct.pack('<4h', *key) for key in keys)
                    if encoded != original:
                        raise ValueError('exported raw animation keys differ from original channel bytes')
                    channels_checked += 1
                    keys_checked += len(keys)
        # Fail closed on missing channel authority, changed groups, and opaque loop/start words.
        representative = next(c for c in anim['clips'].values() if any(len(ch['keys_raw']) >= 2 for t in c['tracks'] for ch in t['channels']))
        begin, finish = representative['source']['range']
        decoded = clip_parser.decode_clip(raw[begin:finish], type_map, begin)
        malformed = clip_parser.tests(raw[begin:finish], decoded, type_map, begin)
        rejections.append({'pack_id': pack['runtime_pack_id'], 'raw_clip_malformed_tests': malformed})
        import copy
        bad_skeleton = copy.deepcopy(original_skeleton)
        bad_skeleton['nodes'][0]['track_group'] = 1
        mapping = next(s['track_to_bone'] for s in pack['resources']['animation_binding']['streams'] if s['stream_id'] == 0)
        missing_kind = decoded['nodes'][0]['channels'][0]['type'] if decoded['nodes'][0]['channels'] else next(c['type'] for n in decoded['nodes'] for c in n['channels'])
        bad_map = dict(type_map)
        del bad_map[missing_kind]
        missing_channel = copy.deepcopy(representative)
        next(t for t in missing_channel['tracks'] if t['channels'])['channels'].pop()
        checks = [('missing_channel_authority', lambda: clip_parser.decode_clip(raw[begin:finish], bad_map, begin)),
                  ('missing_channel_record', lambda: sampling_clip('invalid', missing_channel, mapping)),
                  ('wrong_bone_group', lambda: map_tracks(bad_skeleton, anim)),
                  ('unknown_loop_word', lambda: sampling_clip('invalid', dict(representative, loop_raw=3), mapping)),
                  ('unknown_loop_start', lambda: sampling_clip('invalid', dict(representative, loop_start_float32=float('nan')), mapping)),
                  ('missing_bone_binding', lambda: sampling_clip('invalid', representative, mapping[:-1]))]
        rejected = []
        for label, check in checks:
            try:
                check()
            except ValueError:
                rejected.append(label)
            else:
                raise ValueError('unsupported input accepted: ' + label)
        rejections[-1]['fail_closed_rejections'] = rejected
    return {'schema2_json_reloaded': True, 'source_channels_byte_identical': channels_checked,
            'source_key_records_byte_identical': keys_checked, 'independent_decoder_clips_checked': clips_checked,
            'all_normalized_values_and_tangents_checked': True, 'hermite_original_equation_interval_checks': intervals_checked,
            'hermite_max_float64_equation_error': equation_error,
            'bone_parent_group_link_and_active_influence_indices_valid': True, 'negative_checks': rejections}


def run():
    start, cpu = time.perf_counter(), time.process_time()
    actual_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=VENDOR, text=True).strip()
    if actual_commit != COMMIT:
        raise ValueError('community checkout does not match pinned commit')
    identity_raw = (ROOT / 'analysis/bulldrome_identity.json').read_bytes()
    identity_report = json.loads(identity_raw)
    if identity_report['identity']['bulldrome']['type'] != 68 or identity_report['identity']['bulldrome']['runtime_package_id'] != 6127:
        raise ValueError('identity report target disagrees with task')
    eboot = identity.bounded(identity.EBOOT)
    type_map, programs, semantics = runtime_semantics(eboot)
    original = identity.original_validation(eboot, [6127, 6064])
    if original['iso_sha256'] != identity_report['original_validation']['iso_sha256']:
        raise ValueError('original ISO changed since identity proof')
    packs = []
    validations = []
    for pack_id in (6127, 6064):
        raw = identity.bounded(f'databin/{pack_id:04d}.bin')
        verification = identity.digest_validation(f'databin/{pack_id:04d}.bin', raw, pack_id, eboot)
        if verification['sha1_status'] == 'mismatch':
            raise ValueError('original executable SHA1 table mismatch')
        validations.append(verification)
        pack, _ = inspect(pack_id, raw, type_map)
        packs.append(pack)
    provenance = {'identity_path': str(ROOT / 'analysis/bulldrome_identity.json'), 'identity_sha256': digest(identity_raw),
                  'community_path': str(VENDOR), 'community_commit': actual_commit,
                  'community_license': 'GPL-3.0-or-later; independent offline tool imports only, no library code copied',
                  'format_source_sha256': {str(p.relative_to(VENDOR)): digest(p.read_bytes()) for p in [
                      VENDOR / f'packages/mhp-formats/src/mhp_formats/{f}' for f in ('pac.py', 'skeleton.py', 'pmo.py', 'anim.py', 'fu/anim.py', 'tmh.py')]},
                  'original_validation': original, 'original_sha1_validation': validations,
                  'evidence_kind': 'original local bytes observed; community decoding and derived geometry, no game execution'}
    limits = ['No game/PPSSPP/Ghidra/network/installer execution; static verification is not runtime verification.',
              'Selection/runtime IDs are cross-referenced to existing behavior evidence; no new gameplay labels inferred.',
              'All original channel kinds1/2/4 (S0/S1/S2) and6 others normalized using EBOOT factors. Hermite is the shared mathematical consumer, not VFPU precision equivalence.',
              'Track/bone mapping is statically verified from original group and child/sibling/parent links, not just counts; actual VFPU/runtime binding remains unobserved.',
              'Loop/start original header bits retained; common088637bc clamp/wrap facts only. FPS, playback speed and complete gameplay root-motion application remain unknown.',
              'Animated preview retains bone-root T under identity entity; does not simulate FSM/blend/ground movement or remove root T and apply it again to entity.',
              'Original inverse producer and its measured residual are preserved; unsupported nonorthogonal transforms are not repaired with a generic inverse. GE precision remains unverified.',
              'Preview uses original mesh and bone animation at display scale0.01, two-sided flat shading/nearest palette0; GE precision/material/render states not equivalent.',
              'Original packs remain authoritative for opaque bytes/padding. Only this probe, its two JSON outputs and new animation preview are written.',
              'No performance before/after baseline or token accounting available; cold/warm state unknown; Python CPU/RSS exclude child git.']
    samples, meshes, geometry_validation = animation_geometry(packs[0], programs)
    behavior = json.loads((ROOT / 'analysis/bulldrome_behavior.json').read_bytes())
    preview = animation_preview(packs[0], samples, meshes, behavior)
    asset = {'schema': 2, 'provenance': provenance, 'community_commit': actual_commit, 'semantics': semantics,
             'originalpacksha': packs[0]['originalpacksha'], 'packs': packs, 'limits': limits,
             'animation_pose_samples': samples, 'animation_geometry_validation': geometry_validation,
             'animation_preview': preview}
    summaries = [summary(p) for p in packs]
    report = {'schema': 2, 'provenance': provenance, 'community_commit': actual_commit, 'semantics': semantics,
              'originalpacksha': packs[0]['originalpacksha'], 'packs': summaries,
              'counts': summaries[0]['counts'], 'coverage': {'selected_pack_ids': [6127,6064],
              'all_original_pac_directory_entries_examined': True, 'decoded_member_counts': [sum(m['status']=='decoded' for m in p['members']) for p in packs],
              'runtime_verified': False, 'full_curve_data': str(ROOT / 'analysis/bulldrome_asset_data.json')},
              'comparison': {'size_ratio_6127_over_6064': [a/b for a,b in zip(summaries[0]['bounds_source_units']['size'], summaries[1]['bounds_source_units']['size'])],
                             'identity_authority': 'Original type/name table in identity report; geometry only corroborates, never assigns name.'},
              'preview': preview, 'animation_geometry_validation': geometry_validation, 'limits': limits}
    asset['counts'] = report['counts']
    asset['coverage'] = report['coverage']
    data_path = ROOT / 'analysis/bulldrome_asset_data.json'
    data_path.write_text(json.dumps(plain(asset), separators=(',', ':'), ensure_ascii=False, allow_nan=False))
    report['export_validation'] = validate_export(data_path)
    report['asset_data_sha256'] = digest(data_path.read_bytes())
    report['asset_data_bytes'] = data_path.stat().st_size
    report['measurement'] = {'elapsed_seconds': time.perf_counter()-start, 'cpu_seconds_single_process': time.process_time()-cpu,
                             'max_rss_bytes_single_process': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                             'platform': sys.platform, 'cache_state': 'unknown', 'cpu_and_rss_exclude_child_git': True,
                             'scope': 'ISO streaming hash, original decrypt, format parse/reencode, JSON export/reload byte validation, texture and triangle previews; report serialization excluded'}
    (ROOT / 'analysis/bulldrome_assets.json').write_text(json.dumps(plain(report), ensure_ascii=False, indent=2, allow_nan=False)+'\n')
    print(json.dumps({'counts': report['counts'], 'members': summaries[0]['members'], 'measurement': report['measurement'],
                      'all_channel_kinds': summaries[0]['normalized_channel_kinds'], 'animation_geometry_validation': geometry_validation,
                      'preview_path': preview['path'], 'export_validation': report['export_validation']}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    run()
