#!/usr/bin/env python3
"""离线hunter/type0 GS资产行动合同；只写自己的报告，不执行游戏/provider。"""
import argparse
import collections
import hashlib
import json
import math
import re
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

import hunter_world_probe as world_parser
import hunter_skin_probe as skin_parser
import hunter_animation_catalog as catalog_parser
import hunter_clip_probe as clip_parser

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'analysis/hunter_action_assets.json'
EBOOT = 'sysdir/PSP_GAME/SYSDIR/ULJM05500_EBOOT.BIN'
BASE, ORIGIN, OVERLAY_BASE = 0x08804000, 0x25b4, 0x09a5a580


def require(value, reason):
    if not value:
        raise ValueError(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


class UnsupportedAnimation(ValueError):
    """缺失资源/未知输入不转换为零长动画或静默默认值。"""


@dataclass(frozen=True)
class AnimationClip:
    key: str
    group: int
    nodes: tuple
    bindings: tuple
    end: float
    loop: bool
    loop_start: float


@dataclass(frozen=True)
class RootSample:
    clip: AnimationClip
    time: float
    defaults: tuple
    bone: int = 1


@dataclass(frozen=True)
class NodePose:
    scale: tuple
    matrix: tuple


@dataclass
class AnimationTrack:
    clip: Optional[AnimationClip] = None
    currentframe: float = 0.0
    step: float = 2.0
    end: Optional[float] = None
    loop: Optional[bool] = None
    loop_start: Optional[float] = None
    active: Optional[bool] = None
    blendphase: float = 0.0
    blend_delta: float = 0.0
    blend_remaining: int = 0
    blend_sign: int = 0
    old_clip: Optional[AnimationClip] = None
    old_frame: float = 0.0
    old_pose: dict = field(default_factory=dict)
    captured_this_tick: bool = False


def bind_clips(contract, retained, body_pack):
    clips = {}
    for item in contract['clips']:
        if item['status'] != 'parsed':
            continue
        reference = item['rawkeys']
        if 'inline_nodes' in reference:
            nodes = reference['inline_nodes']
        else:
            nodes = retained[reference['source']]
            for token in reference['json_pointer'].strip('/').split('/'):
                nodes = nodes[int(token)] if isinstance(nodes, list) else nodes[token]
        mapping = item['bone_mappings'][str(body_pack)]
        require(len(nodes) == len(mapping), 'parsed mapping count mismatch')
        loop_start = item['parsed_loop_start']
        require(math.isfinite(loop_start) and 0 <= loop_start <= item['end_time'], 'parsed loop start outside clip range')
        clips[item['key']] = AnimationClip(item['key'], item['track_group'], tuple(nodes), tuple(mapping),
                                           f32(item['end_time']), bool(item['loop_enabled_raw']), loop_start)
    return clips


def sample_node(node, defaults, time):
    values = list(defaults)
    for channel in node['channels']:
        values[channel['component_index']] = clip_parser.sample(channel['keys'], time) * channel['factor']
    return tuple(values)


def sample_channels(clip, defaults, time, *, floating=False):
    require(math.isfinite(time) and time >= 0, 'sample time must be finite/nonnegative')
    time = time if floating else math.floor(time)
    result = {}
    for node, bone in zip(clip.nodes, clip.bindings):
        values = sample_node(node, defaults[bone], time)
        if any(value is None for value in values):
            raise UnsupportedAnimation(f'unknown skeleton base component: bone {bone}')
        result[bone] = values
    return result


def sample_root(request: RootSample) -> tuple:
    """088633c4浮点channel样本的node1 T；不施加entity/地面变换。"""
    require(math.isfinite(request.time) and request.time >= 0, 'root time must be finite/nonnegative')
    if request.bone not in request.clip.bindings:
        raise UnsupportedAnimation('root bone not bound to selected track')
    node = request.clip.nodes[request.clip.bindings.index(request.bone)]
    values = sample_node(node, request.defaults[request.bone], request.time)[6:9]
    if None in values:
        raise UnsupportedAnimation('unknown skeleton base root translation')
    return values


def root_delta(clip, defaults, previous, current, sampler: Callable[[RootSample], tuple] = sample_root):
    if previous < 0:
        previous, current = 0.0, f32(current - previous)
    a = sampler(RootSample(clip, previous, defaults))
    b = sampler(RootSample(clip, current, defaults))
    require(len(a) == len(b) == 3 and all(math.isfinite(x) for x in a+b), 'root callback must return finite xyz tuple')
    return tuple(y-x for x, y in zip(a, b))


def make_pose(channels):
    result = {}
    for bone, values in channels.items():
        matrix = world_parser.rotation(values[3:6])
        for axis in range(3):
            matrix[axis][3] = values[6+axis]
        result[bone] = NodePose(values[:3], tuple(tuple(row) for row in matrix))
    return result


def blend_weight(phase):
    return clip_parser.hermite(phase, (0, 0, 0, 0), (1, 1, 0, 0))


def blend_pose(old, new, weight):
    """0885fc94/0885fe3c数学模型：混合basis后重建，不线性混合Euler。"""
    def normalize(vector):
        length = math.sqrt(sum(x*x for x in vector))
        return tuple(x/length for x in vector) if length else (0.0, 0.0, 0.0)

    def cross(a, b):
        return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])

    result = {}
    for bone, current in new.items():
        previous = old[bone]
        matrix = [[weight*x+(1-weight)*y for x, y in zip(a, b)]
                  for a, b in zip(current.matrix, previous.matrix)]
        x = normalize([matrix[i][0] for i in range(3)])
        y = normalize([matrix[i][1] for i in range(3)])
        z = normalize(cross(x, y))
        y = cross(z, x)
        for i in range(3):
            matrix[i][:3] = [x[i], y[i], z[i]]
        result[bone] = NodePose(tuple(weight*x+(1-weight)*y for x, y in zip(current.scale, previous.scale)),
                                tuple(tuple(row) for row in matrix))
    return result


class AnimationState:
    """纯离线两轨adapter；FSM/地面/yaw及+90/+d0矩阵生产属于调用者。"""
    def __init__(self, clips, defaults, *, root_sampler: Callable[[RootSample], tuple] = sample_root):
        self.clips = clips
        self.defaults = tuple(tuple(row) for row in defaults)
        require(all(len(row) == 9 for row in self.defaults), 'defaults must contain S/R/T nine-tuples')
        self.root_sampler = root_sampler
        self.tracks = [AnimationTrack(), AnimationTrack()]
        self.pose = make_pose({i: row for i, row in enumerate(self.defaults) if None not in row})
        self.captured_root = (0.0, 0.0, 0.0)

    @classmethod
    def from_contract(cls, path=OUTPUT, *, body_pack=1877, verify=True, root_sampler=sample_root):
        contract = json.loads(Path(path).read_text())
        require(contract['schema_version'] == 2, 'adapter requires contract schema2')
        if verify:
            for source in contract['input_sources'].values():
                require(clip_parser.identity(Path(source['path'])) == source['file_sha256'], 'adapter sourceSHA mismatch: '+source['path'])
        retained = {}
        for item in contract['clips']:
            reference = item.get('rawkeys')
            if reference and 'source' in reference and reference['source'] not in retained:
                owner_path = Path(contract['input_sources'][reference['source']]['path'])
                require(clip_parser.identity(owner_path) == reference['file_sha256'], 'rawkeys owner SHA mismatch')
                retained[reference['source']] = json.loads(owner_path.read_text())
        clips = bind_clips(contract, retained, body_pack)
        defaults = [node['bind_components_S_R_T'] for node in contract['skeletons'][str(body_pack)]['nodes']]
        return cls(clips, defaults, root_sampler=root_sampler)

    def set_animation(self, primary, blend, start):
        require(isinstance(primary, int) and isinstance(blend, int) and isinstance(start, int), 'setter arguments must be integers')
        primary = ((primary+32768) % 65536)-32768
        secondary = ((primary+100+32768) % 65536)-32768
        keys = (f'{primary}:0', f'{secondary}:1')
        missing = [key for key in keys if key not in self.clips]
        if missing:
            raise UnsupportedAnimation('unsupported clip: '+','.join(missing)+'; existing tracks unchanged, null-bind runtime unknown')
        count = math.trunc(blend/2)
        count = ((count+32768) % 65536)-32768
        start &= 65535
        for track, key in zip(self.tracks, keys):
            if count and not track.captured_this_tick:
                track.old_clip, track.old_frame = track.clip, track.currentframe
                if track.clip and not track.blend_remaining:
                    track.old_pose = make_pose(sample_channels(track.clip, self.defaults, track.currentframe))
                else:
                    track.old_pose = {bone: self.pose[bone] for bone in self.clips[key].bindings if bone in self.pose}
                require(set(track.old_pose) == set(self.clips[key].bindings), 'blend requires resolved old pose')
                track.captured_this_tick = True
            track.clip = self.clips[key]
            track.currentframe, track.end = f32(start), track.clip.end
            track.loop, track.loop_start, track.active = track.clip.loop, track.clip.loop_start, True
            track.blend_remaining = abs(count)+1 if count else 0
            track.blend_delta = f32(1.0/f32(track.blend_remaining)) if count else 0.0
            track.blendphase = track.blend_delta
            track.blend_sign = -1 if count < 0 else (1 if count else 0)
        self.captured_root = (0.0, 0.0, 0.0)

    def reset(self, primary, *, blend=0, start=0):
        self.set_animation(primary, blend, start)

    def animation_ended(self, group=0):
        track = self.tracks[group]
        if track.active is None:
            raise UnsupportedAnimation('track has no bound animation')
        return not track.active

    def tick(self, playback_step, *, root_enabled=True, direction_transform=None):
        require(math.isfinite(playback_step) and playback_step >= 0, 'playback_step must be finite/nonnegative raw step')
        require(all(track.clip for track in self.tracks), 'both tracks must be bound before tick')
        playback_step = f32(playback_step)
        require(math.isfinite(playback_step), 'playback_step must fit finite binary32')
        for track in self.tracks:
            track.step = playback_step
        primary = self.tracks[0]
        if not root_enabled or primary.blend_sign < 0:
            delta = (0.0, 0.0, 0.0)
        elif primary.blend_remaining:
            weight = blend_weight(primary.blendphase)
            new = root_delta(primary.clip, self.defaults, primary.currentframe, f32(primary.currentframe+primary.step), self.root_sampler)
            old = root_delta(primary.old_clip, self.defaults, primary.old_frame, f32(primary.old_frame+primary.step), self.root_sampler) if primary.old_clip else (0.0, 0.0, 0.0)
            delta = tuple(weight*x+(1-weight)*y for x, y in zip(new, old))
        else:
            delta = root_delta(primary.clip, self.defaults, f32(primary.currentframe-primary.step), primary.currentframe, self.root_sampler)
        if direction_transform is not None:
            delta = tuple(direction_transform(delta))
            require(len(delta) == 3 and all(math.isfinite(x) for x in delta), 'direction_transform must return xyz (w=0)')
        events = []
        for group, track in enumerate(self.tracks):
            track.captured_this_tick = False
            next_frame = f32(track.currentframe+track.step)
            if track.blend_remaining:
                sampled = make_pose(sample_channels(track.clip, self.defaults, track.currentframe))
                sampled = blend_pose(track.old_pose, sampled, blend_weight(track.blendphase))
                track.blendphase = f32(track.blendphase+track.blend_delta)
                track.blend_remaining -= 1
                if not track.blend_remaining:
                    track.blend_sign = 0
                    track.currentframe = next_frame
                event = 'blend'
            elif next_frame <= track.end:
                sampled = make_pose(sample_channels(track.clip, self.defaults, track.currentframe))
                track.currentframe = next_frame
                track.active, event = True, 'sample_then_advance'
            elif track.loop:
                reset_time = f32(track.loop_start-1.0) if track.loop_start >= 1 else track.loop_start
                reset_pose = make_pose(sample_channels(track.clip, self.defaults, reset_time))
                if group == 0:
                    self.captured_root = tuple(reset_pose[1].matrix[i][3] for i in range(3))
                sampled = make_pose(sample_channels(track.clip, self.defaults, track.end))
                track.currentframe, track.active, event = track.loop_start, False, 'loop_reset_no_overshoot'
            else:
                track.currentframe = track.end
                sampled = make_pose(sample_channels(track.clip, self.defaults, track.end))
                track.active, event = False, 'end'
            if group == 0:
                root = sampled[1]
                if event not in ('blend', 'loop_reset_no_overshoot'):
                    self.captured_root = tuple(root.matrix[i][3] for i in range(3))
                matrix = [list(row) for row in root.matrix]
                for axis in range(3):
                    matrix[axis][3] = 0.0
                sampled[1] = NodePose(root.scale, tuple(tuple(row) for row in matrix))
            self.pose.update(sampled)
            events.append(event)
        return {'root_delta': delta, 'captured_root': self.captured_root, 'events': tuple(events),
                'currentframe': tuple(track.currentframe for track in self.tracks),
                'active': tuple(track.active for track in self.tracks), 'pose': self.pose.copy()}


def adapter_selftests(contract, catalog, skin, mesh_data):
    clips = bind_clips(contract, {'analysis/hunter_animation_catalog.json': catalog}, 1877)
    samples = 0
    defaults = [node['bind_components_S_R_T'] for node in contract['skeletons']['1877']['nodes']]
    for clip in clips.values():
        for time in (0.0, clip.end/2, clip.end):
            sample_channels(clip, defaults, time)
            sample_channels(clip, defaults, time, floating=True)
            samples += 2
        if clip.group == 0:
            require(root_delta(clip, tuple(map(tuple, defaults)), -2, 0) == root_delta(clip, tuple(map(tuple, defaults)), 0, 2), 'negative root interval wrapper')
    state = AnimationState(clips, defaults)
    key = next(clip.key for clip in clips.values() if clip.group == 0 and f'{int(clip.key.split(":")[0])+100}:1' in clips)
    primary = int(key.split(':')[0])
    state.set_animation(primary, 0, 0)
    first = state.tick(2)
    require(first['currentframe'][0] == 2 and first['pose'][1].matrix[0][3] == 0, 'sample before advance and clear root')
    old_frame = state.tracks[0].currentframe
    state.set_animation(primary, 6, 0)
    require(state.tracks[0].blend_remaining == 4 and state.tracks[0].old_frame == old_frame, 'blend argument narrowing/capture')
    for _ in range(4):
        state.tick(0)
    require(state.tracks[0].blend_remaining == 0 and state.tracks[0].currentframe == 0, 'frozen step still finishes blend')
    state.set_animation(primary, -6, 0)
    require(state.tick(2)['root_delta'] == (0.0, 0.0, 0.0), 'negative blend suppresses root')
    state.reset(primary)
    track = state.tracks[0]
    track.currentframe = track.end
    state.tick(0)
    require(not state.animation_ended(), 'strict >end boundary, equal end stays active')
    state.tick(2)
    require(state.animation_ended(), 'loop/end boundary is inactive feedback')
    if track.loop:
        require(track.currentframe == track.loop_start, 'loop discards overshoot')
        state.tick(0)
        require(not state.animation_ended(), 'loop inactive is not permanently ended')
    before = tuple(t.clip for t in state.tracks)
    try:
        state.set_animation(1010, 0, 0)
    except UnsupportedAnimation:
        require(tuple(t.clip for t in state.tracks) == before, 'unsupported setter must not change old tracks')
    else:
        raise ValueError('missing draw variant accepted')
    unknown = list(defaults)
    unknown[0] = [None]*9
    sparse = AnimationClip('fixture', 0, ({'channels': []},), (0,), 1, False, 0)
    try:
        sample_channels(sparse, unknown, 0)
    except UnsupportedAnimation:
        pass
    else:
        raise ValueError('unknown base silently zero-filled')
    a = make_pose({0: (1, 2, 3, 0, 0, 0, 10, 20, 30)})
    b = make_pose({0: (3, 4, 5, 0, 0, math.pi/2, 20, 30, 40)})
    middle = blend_pose(a, b, 0.5)[0]
    require(middle.scale == (2, 3, 4) and middle.matrix[0][3] == 15, 'basis blend scale/translation')
    require(abs(sum(middle.matrix[i][0]**2 for i in range(3))-1) < 1e-12, 'blend basis normalized')
    require(blend_weight(0.25) == 0.15625, 'Hermite weight is not linear')
    low_idle = next(item for item in contract['clips'] if item['key'] == '403:0')
    require(low_idle['selected_pack'] == 61 and low_idle['end_time'] == 264 and low_idle['parsed_loop_start'] == 62.0,
            'real low-stamina idle loop facts')
    require(low_idle['loop_start_raw_bits']['source']['byte_range'] == [479404, 479408]
            and low_idle['loop_start_raw_bits']['bytes_le'] == '00007842', 'real clip403 loop rawbytes')
    source_checks = 0
    for source in contract['input_sources'].values():
        require(clip_parser.identity(Path(source['path'])) == source['file_sha256'], 'selftest sourceSHA mismatch')
        source_checks += 1
    affected = [item for item in contract['clips'] if item['status'] == 'parsed'
                and item['loop_enabled_raw'] and item['loop_start_raw_bits']['u32'] != item['parsed_loop_start']]
    require(len(affected) == 20, 'real nonzero loop-start coverage changed')
    loop_cases, guard_cases, slow_cases = [], [], []
    phase_ticks = unsupported_phases = dynamic_phases = 0
    for body in (1877, 225):
        selected = bind_clips(contract, {'analysis/hunter_animation_catalog.json': catalog}, body)
        base = [node['bind_components_S_R_T'] for node in contract['skeletons'][str(body)]['nodes']]
        for item in affected:
            clip = selected[item['key']]
            runner = AnimationState(selected, base)
            runner.reset(int(clip.key.split(':')[0])-100*clip.group)
            track = runner.tracks[clip.group]
            for _ in range(2):
                track.currentframe = clip.end
                frame = runner.tick(2)
                require(frame['events'][clip.group] == 'loop_reset_no_overshoot'
                        and not track.active and track.currentframe == clip.loop_start, 'real clip loop reset failed: '+clip.key)
                frame = runner.tick(2)
                require(frame['events'][clip.group] == 'sample_then_advance'
                        and track.active and track.currentframe == f32(clip.loop_start+2), 'real clip next loop tick failed: '+clip.key)
            loop_cases.append({'clip': clip.key, 'body_pack': body, 'loop_start': clip.loop_start,
                               'cycles': 2, 'source': item['loop_start_raw_bits']['source']})
        for row_id, parameter, blend, start in (('guard', 0, 3, 0), ('guard_0c', 1, 6, 40)):
            row = next(row for row in contract['actions'] if row['id'] == row_id)
            phase = row['phases'][0]
            require(row['sub'] == (3 if parameter == 0 else 12) and row['handler_parameter'] == parameter
                    and phase['primary'] == 1412 and phase['secondary'] == 1512
                    and phase['blend_argument'] == blend and phase['start_frame_units'] == start, 'guard parameter phase reversed')
            runner = AnimationState(selected, base)
            runner.reset(1001)
            runner.tick(2)
            runner.set_animation(phase['primary'], phase['blend_argument'], phase['start_frame_units'])
            require(all(track.currentframe == start and track.blend_remaining == math.trunc(blend/2)+1
                        for track in runner.tracks), 'consumer did not take guard phase arguments')
            runner.tick(0)
            require(all(track.currentframe == start and track.blend_remaining == math.trunc(blend/2)
                        for track in runner.tracks), 'guard frozen blend countdown')
            guard_cases.append({'action': row_id, 'body_pack': body, 'parameter': parameter,
                                'primary': phase['primary'], 'blend_argument': blend, 'start': start})
        slowstep = struct.unpack('<f', bytes.fromhex('cdcc4c3e'))[0]
        for aid in (1001, 1401):
            runner = AnimationState(selected, base)
            runner.reset(aid)
            for _ in range(90):
                runner.tick(slowstep)
            require(tuple(track.currentframe for track in runner.tracks) == (17.999996185302734,)*2,
                    'binary32 slow accumulation differs from COP1 stores')
            require(all(math.floor(track.currentframe) == 17 and not track.currentframe >= 18 for track in runner.tracks),
                    'binary32 floor/GE18 feedback mismatch')
            runner.tick(slowstep)
            require(all(track.currentframe == 18.199996948242188 and track.currentframe >= 18 for track in runner.tracks),
                    'binary32 next tick threshold mismatch')
            slow_cases.append({'clips': [track.clip.key for track in runner.tracks], 'body_pack': body,
                               'sources': [next(item['source'] for item in contract['clips'] if item['key'] == track.clip.key)
                                           for track in runner.tracks],
                               'rawstep_bits': '0x3e4ccccd', 'ticks': 90, 'position': 17.999996185302734,
                               'next_position': 18.199996948242188})
        runner.reset(1001)
        for track in runner.tracks:
            track.currentframe = track.end
        tiny_step = 2**-20
        require(all(track.currentframe+tiny_step > track.end for track in runner.tracks), 'rounded-next fixture lacks double divergence')
        frame = runner.tick(tiny_step)
        require(frame['events'] == ('sample_then_advance',)*2
                and all(track.currentframe == track.end and track.active for track in runner.tracks),
                'end comparison used double next instead of COP1 binary32')
        frame = runner.tick(2)
        require(frame['events'] == ('loop_reset_no_overshoot',)*2
                and all(track.currentframe == 0 and not track.active for track in runner.tracks), 'real1001 zero-start loop reset')
        frame = runner.tick(2)
        require(frame['events'] == ('sample_then_advance',)*2
                and all(track.currentframe == 2 and track.active for track in runner.tracks), 'real1001 next loop advancement')
        runner.set_animation(1001, 10, 0)
        require(all(track.blend_delta == 0.1666666716337204 and track.blendphase == track.blend_delta
                    for track in runner.tracks), 'binary32 blend division/store')
        expected_progress = (0.3333333432674408, 0.5, 0.6666666865348816,
                             0.8333333730697632, 1.0, 1.1666666269302368)
        for progress in expected_progress:
            runner.tick(0)
            require(all(track.blendphase == progress and track.currentframe == 0 for track in runner.tracks),
                    'binary32 frozen blend progress/store')
        require(all(not track.blend_remaining for track in runner.tracks), 'frozen blend remains pending')
        runner.tick(slowstep)
        require(all(track.currentframe == slowstep for track in runner.tracks), 'rawstep doubled or frozen after blend')
        runner.set_animation(1001, 2, 200)
        runner.tick(0)
        runner.tick(tiny_step)
        require(all(track.blend_remaining == 0 and track.currentframe == 200 for track in runner.tracks),
                'blend completion position not stored as binary32')
        for row in contract['actions']:
            for phase in row['phases']:
                aid = phase['primary']
                if f'{aid}:0' not in selected or f'{aid+100}:1' not in selected:
                    unsupported_phases += 1
                    continue
                runner = AnimationState(selected, base)
                runner.reset(aid)
                runner.tick(2)
                start = phase.get('start_frame_units', phase.get('start'))
                if phase['blend_argument'] is None or start is None:
                    dynamic_phases += 1
                    continue
                runner.set_animation(aid, phase['blend_argument'], start)
                saved = runner.tracks[0].old_pose.copy()
                frame = runner.tick(struct.unpack('<f', struct.pack('<I', 0x3e4ccccd))[0])
                require(len(frame['pose']) == len(base), 'phase pose skeleton coverage incomplete')
                require(runner.tracks[0].old_pose == saved, 'old pose advanced instead of held')
                require(frame['pose'][1].matrix[0][3] == frame['pose'][1].matrix[1][3] == frame['pose'][1].matrix[2][3] == 0, 'phase root double-applied')
                phase_ticks += 1
    calls = []
    def callback(request: RootSample) -> tuple:
        calls.append(request)
        return (request.time, 2*request.time, 0.0)
    runner = AnimationState(clips, defaults, root_sampler=callback)
    runner.reset(primary)
    require(runner.tick(2.5, direction_transform=lambda xyz: tuple(3*x for x in xyz))['root_delta'] == (7.5, 15.0, 0.0), 'typed root/direction callback not used')
    require(len(calls) == 2 and calls[0].time == 0 and calls[1].time == 2.5, 'root callback sampling order')
    runner.set_animation(primary, 6, 10)
    saved_frame = runner.tracks[0].old_frame
    saved_pose = runner.tracks[0].old_pose.copy()
    runner.set_animation(primary, 6, 20)
    require(runner.tracks[0].old_frame == saved_frame and runner.tracks[0].old_pose == saved_pose, 'same tick setter recaptured old pose')
    runner.tick(0)
    displayed = {bone: runner.pose[bone] for bone in runner.tracks[0].clip.bindings}
    runner.set_animation(primary, 6, 0)
    require(runner.tracks[0].old_pose == displayed, 'interrupted blend must capture displayed pose')
    programs = {int(source['virtual_address_range'][0], 16): [int(word, 16) for word in source['words']]
                for source in skin['sources'] if 'words' in source}
    nodes = next(resource['bind_nodes'] for resource in mesh_data['resources'] if resource['pack_id'] == 1877)
    matrix_inputs = {bone: pose.matrix for bone, pose in runner.pose.items()}
    scales = {bone: pose.scale for bone, pose in runner.pose.items()}
    entity = world_parser.rotation((0.0, 0.0, math.pi/2))
    for axis, value in enumerate((10.0, 20.0, 30.0)):
        entity[axis][3] = value
    currents, collisions = skin_parser.hierarchy(programs, nodes, matrix_inputs, scales, [1.0]*3,
                                                  entity, world_parser.identity_matrix())
    for bone in currents:
        world_parser.close(collisions[bone], world_parser.multiply(entity, currents[bone]), 1e-7)
    require(currents[14] != collisions[14], 'collision and drawing matrices conflated')
    for invalid in (float('nan'), float('inf'), -1.0, low_idle['end_time']+1.0):
        malformed = {**contract, 'clips': [{**low_idle, 'parsed_loop_start': invalid}]}
        try:
            bind_clips(malformed, {'analysis/hunter_animation_catalog.json': catalog}, 1877)
        except ValueError:
            pass
        else:
            raise ValueError('invalid parsed loop start accepted')
    return {'parsed_clips_sampled': len(clips), 'pose_and_float_samples': samples,
            'verified_input_source_sha256': source_checks,
            'nonzero_loop_start_real_clips': len(affected), 'loop_boundary_cases_both_bodies': loop_cases,
            'loop_boundary_scope': 'two forced end-crossing/reset/next-advance cycles per real clip per body, not full-duration target playback',
            'invalid_loop_start_rejections': 4, 'guard_parameter_cases_both_bodies': guard_cases,
            'binary32_slowstep_cases_both_bodies': slow_cases,
            'binary32_blend_progress_ticks_both_bodies': 12,
            'binary32_rounded_end_comparisons_both_bodies': 4,
            'zero_start_loop_tracks_both_bodies': 4,
            'binary32_blend_completion_tracks_both_bodies': 4,
            'action_phase_ticks_both_bodies': phase_ticks, 'unsupported_action_phases_both_bodies': unsupported_phases,
            'dynamic_phase_arguments_require_caller_both_bodies': dynamic_phases,
            'owner_skin_hierarchy_nodes': len(currents),
            'semantics': ['sample-before-advance', 'strict-end', 'loop-inactive-feedback', 'no-overshoot',
                          'signed-blend', 'step0-blend-countdown', 'held-old-pose', 'negative-root-wrapper',
                          'unknown-base-unsupported', 'absent-transactional-unsupported', 'normalized-basis-blend',
                          'binary32-loop-bitcast', 'parameter-owned-guard-phases', 'binary32-time-stores-and-feedback']}


def build():
    sources, blobs, reports, citations = {}, {}, {}, {}
    checks = collections.Counter()

    def source(relative):
        if relative not in sources:
            raw = (ROOT / relative).read_bytes()
            blobs[relative] = raw
            sources[relative] = {'path': str(ROOT / relative), 'file_sha256': sha(raw),
                                 'byte_range': [0, len(raw)], 'range_sha256': sha(raw)}
        return sources[relative]

    def range_source(relative, start, end):
        identity = source(relative)
        raw = blobs[relative]
        require(0 <= start <= end <= len(raw), 'source range outside owner')
        checks['source_ranges'] += 1
        return {**identity, 'byte_range': [start, end], 'range_sha256': sha(raw[start:end])}

    def report(name):
        relative = 'analysis/' + name + '.json'
        source(relative)
        reports[name] = json.loads(blobs[relative])
        return reports[name]

    def cite(address):
        address = address.removeprefix('0x').removeprefix('FUN_')
        if address not in citations:
            resident = int(address, 16) < 0x09a00000
            relative = ('decomp/' if resident else 'decomp_ovl/') + address + '.c'
            source(relative)
            text = blobs[relative].decode()
            size = int(re.search(r'size=(\d+)', text)[1])
            owner = EBOOT if resident else 'databin/0051.bin'
            start = int(address, 16) - (BASE if resident else OVERLAY_BASE) + (ORIGIN if resident else 0)
            citations[address] = {'function': '0x' + address, 'pseudocode': sources[relative],
                                  'lines': [1, len(text.splitlines())],
                                  'machine_source': range_source(owner, start, start + size),
                                  'classification': 'retained static decompilation; no line-to-instruction or runtime proof'}
        return '0x' + address

    selection = report('hunter_resource_selection')
    catalog = report('hunter_animation_catalog')
    normal = report('hunter_normal_contract')
    gs = report('hunter_greatsword_contract')
    world = report('hunter_world')
    skin = report('hunter_skin')
    mesh = report('hunter_mesh')
    mesh_data = report('hunter_mesh_data')
    for resource in mesh_data['resources']:
        relative = f'databin/{resource["pack_id"]:04d}.bin'
        require(sha((ROOT / relative).read_bytes()) == resource['source']['file_sha256'], 'geometry sourceSHA mismatch')
        checks['geometry_source_sha_matches'] += 1
    actions = report('hunter_actions')
    for relative in ('tools/hunter_action_assets_probe.py', 'tools/hunter_animation_catalog.py',
                     'tools/hunter_clip_probe.py', 'tools/hunter_world_probe.py', 'tools/hunter_skin_probe.py'):
        source(relative)
    source(EBOOT)
    require(sources[EBOOT]['file_sha256'] == clip_parser.EXPECTED[EBOOT], 'EBOOT SHA mismatch')
    source('databin/0051.bin')
    require(sources['databin/0051.bin']['file_sha256'] == actions['artifact']['sha256'], 'overlay SHA mismatch')
    tables = {}
    for address, fmt in ((0x089b16dc, '<2H'), (0x089b16e0, '<11H')):
        start = address - BASE + ORIGIN
        raw = blobs[EBOOT][start:start + struct.calcsize(fmt)]
        values = list(struct.unpack(fmt, raw))
        require(values == selection['tables'][f'0x{address:08x}']['values'], 'owner table differs')
        tables[f'0x{address:08x}'] = {'values': values, 'format': fmt,
                               'source': range_source(EBOOT, start, start + len(raw))}
    require(tables['0x089b16dc']['values'] == [3945, 3941], 'TMH owner mismatch')
    require(tables['0x089b16e0']['values'][0] == 3377, 'GS owner mismatch')
    checks['owner_tables'] = 2
    packs, skeletons, directories = {}, {}, {}
    for pack_id in (61, 3377, 1877, 225, 3389, 3945, 3941):
        relative = f'databin/{pack_id:04d}.bin'
        identity = source(relative)
        raw = blobs[relative]
        start = 0x08976d00 - BASE + ORIGIN + 20 * pack_id
        expected = blobs[EBOOT][start:start + 20]
        require(hashlib.sha1(raw).digest() == expected, f'pack{pack_id} SHA1 mismatch')
        checks['pack_sha1_matches'] += 1
        item = {'pack_id': pack_id, 'source': identity, 'sha1': expected.hex(),
                'sha1_table_source': range_source(EBOOT, start, start + 20), 'members': []}
        if pack_id in (1877, 225, 3389):
            count = struct.unpack_from('<I', raw)[0]
            require(2 <= count <= (len(raw)-4)//8, 'container directory capacity')
            for index in range(count):
                offset, length = struct.unpack_from('<2I', raw, 4 + index * 8)
                item['members'].append({'index': index, 'kind': ['PMO', 'skeleton', 'TMH'][index] if index < 3 else 'unknown',
                                        'source': range_source(relative, offset, offset + length)})
            member = item['members'][1]['source']
            a, b = member['byte_range']
            skeleton = clip_parser.decode_skeleton(raw[a:b], a)
            orders = {str(g): clip_parser.binding_order(skeleton, g) for g in (0, 1)} if pack_id != 3389 else None
            if orders:
                require(not set(orders['0']) & set(orders['1']), 'track mappings overlap')
                require(sorted(orders['0'] + orders['1']) == list(range(len(skeleton['nodes']))), 'track coverage incomplete')
                checks['dual_track_complete_skeletons'] += 1
            skeletons[str(pack_id)] = {'pack_id': pack_id, 'source': member, **skeleton, 'group_binding_orders': orders}
        elif pack_id in (61, 3377):
            directories[pack_id] = catalog_parser.directory(raw)
        else:
            require(raw[:4] == b'.TMH', 'external texture magic mismatch')
            item['kind'] = 'external_texture_not_animation'
        packs[str(pack_id)] = item

    type_map = {int(k): v['index'] for k, v in catalog['component_type_map'].items()}
    for kind, index in type_map.items():
        start = 0x089a2ce4 + 4 * kind - BASE + ORIGIN
        require(struct.unpack_from('<i', blobs[EBOOT], start)[0] == index, 'component mapping mismatch')
        checks['component_table_matches'] += 1
    catalog_index = {(c['pack_id'], c['animation_id'], c['track_group']): (i, c)
                     for i, c in enumerate(catalog['clips'])}
    clips = {}

    def resolve(aid, group, shared_ready=True):
        pack_id = 61 if aid < 1000 and shared_ready else 3377
        relative = f'databin/{pack_id:04d}.bin'
        raw = blobs[relative]
        lookup = catalog_parser.locate(raw, *directories[pack_id], aid)
        return pack_id, relative, lookup

    def get_clip(aid, group):
        key = f'{aid}:{group}'
        if key in clips:
            return key
        pack_id, relative, lookup = resolve(aid, group)
        item = {'key': key, 'animation_id': aid, 'track_group': group, 'selected_pack': pack_id,
                'selection': 'ready task shared61' if aid < 1000 else 'ready entity GS3377',
                'lookup': lookup, 'status': lookup['status'], 'end_time': None,
                'loop_enabled_raw': None, 'loop_start_raw': None, 'parsed_loop_start': None, 'seconds': None,
                'selection_reason': 'shared present: absent entry NEVER falls back to entity' if aid < 1000 else 'ID>=1000: entity lookup ID%1000',
                'rawkeys': None, 'bone_mappings': None}
        if lookup['status'] == 'present':
            start, end = lookup['byte_range']
            raw = blobs[relative][start:end]
            retained = catalog_index.get((pack_id, aid, group))
            if retained:
                decoded = retained[1]
                owner = next(pack for pack in catalog['packs'] if pack['pack_id'] == pack_id)
                require(decoded['lookup'] == lookup and owner['source']['file_sha256'] == sources[relative]['file_sha256'], 'catalog parsed owner identity differs')
                header = decoded['header']
                require(struct.unpack_from('<5I', raw) == (int(header['flags'], 16), header['node_count'], header['declared_size'], header['loop_enabled_raw'], header['loop_start_raw_u32']), 'catalog header facts differ')
                for node in decoded['nodes']:
                    a, b = node['byte_range']
                    require(sha(blobs[relative][a:b]) == node['range_sha256'], 'catalog parsed node range SHA mismatch')
            else:
                decoded = catalog_parser.decode(raw, start, type_map)
            loop_bits = struct.unpack_from('<I', raw, 16)[0]
            loop_start = struct.unpack_from('<f', raw, 16)[0]
            end_time = decoded['summary']['end_time_consumer_max_last_key']
            require(loop_bits == decoded['header']['loop_start_raw_u32'], 'loop rawbits owner mismatch')
            require(math.isfinite(loop_start) and 0 <= loop_start <= end_time, 'loop start outside finite clip range')
            item.update(status=decoded['status'], source=range_source(relative, start, end),
                        header=decoded['header'], end_time=end_time,
                        time_range=decoded['summary']['time_range'],
                        loop_enabled_raw=decoded['header']['loop_enabled_raw'],
                        loop_start_raw=loop_start, parsed_loop_start=loop_start,
                        loop_start_raw_bits={'u32': loop_bits, 'bytes_le': raw[16:20].hex(),
                                             'source': range_source(relative, start+16, start+20),
                                             'interpretation': 'little-endian binary32 bitcast; 08863e68 copies bits to track+18, 088637bc reads float'})
            checks['loop_start_f32_source_matches'] += 1
            item['bone_mappings'] = {}
            for body in (1877, 225):
                order = skeletons[str(body)]['group_binding_orders'][str(group)]
                require(len(order) == len(decoded['nodes']), f'clip{aid} skeleton{body} mapping differs')
                item['bone_mappings'][str(body)] = order
                checks['clip_skeleton_mappings'] += 1
            if retained:
                ordinal, old = retained
                item['rawkeys'] = {'source': 'analysis/hunter_animation_catalog.json',
                                   'json_pointer': f'/clips/{ordinal}/nodes', 'file_sha256': sources['analysis/hunter_animation_catalog.json']['file_sha256'],
                                   'authority': 'ONLY raw nodes/keys; old owner interpretation overridden here'}
                checks['catalog_rawkey_matches'] += 1
            else:
                item['rawkeys'] = {'inline_nodes': decoded['nodes'], 'authority': 'fresh bounded original-byte decode'}
                checks['fresh_clip_decodes'] += 1
            for node in decoded['nodes']:
                for channel in node['channels']:
                    require(channel['status'] == 'parsed', 'selected unsupported channel')
                    ka, kb = channel['keys_byte_range']
                    keys = list(struct.iter_unpack('<4h', blobs[relative][ka:kb]))
                    require([list(k) for k in keys] == channel['keys'], 'source key mismatch')
                    require(sha(blobs[relative][ka:kb]) == channel['keys_range_sha256'], 'key digest mismatch')
                    for k in keys:
                        require(clip_parser.sample(keys, k[1]) == k[0], 'key endpoint mismatch')
                    for left, right in zip(keys, keys[1:]):
                        t = (left[1] + right[1]) / 2
                        require(abs(clip_parser.hermite(t, left, right) - clip_parser.consumer_equation(t, left, right)) < 1e-7,
                                'Hermite consumer mismatch')
                        checks['hermite_comparisons'] += 1
                    checks['keys_checked'] += len(keys)
        else:
            checks['selected_absent'] += 1
            item['asset_return'] = 'null; end/loop remain unknown, not zero or default clip'
            if 'entry_byte_range' in lookup:
                a, b = lookup['entry_byte_range']
                item['entry_source'] = range_source(relative, a, b)
        clips[key] = item
        return key

    guard_source = cite('09a88e90')
    guard_dispatch_source = cite('09a87fc0')
    guard_text = blobs['decomp_ovl/09a88e90.c'].decode()
    guard_branches = guard_text.split('    if (param_2 == 0) {', 1)[1].split('    else {\n      cVar1', 1)
    require(len(guard_branches) == 2, 'guard parameter branch boundary missing')
    guard_parameters = {}
    for parameter, branch in enumerate(guard_branches):
        match = re.search(r'088d857c\(param_1,0x584,(\d+),(0x[0-9a-f]+|\d+)\)', branch)
        require(match is not None, 'guard parameter type0 submission missing')
        blend, start = (int(value, 0) for value in match.groups())
        guard_parameters[parameter] = {'primary': 0x584, 'secondary': 0x5e8,
                                       'blend_argument': blend, 'blend_stored': math.trunc(blend/2),
                                       'start_frame_units': start}
    dispatch_text = blobs['decomp_ovl/09a87fc0.c'].decode()
    for sub, parameter in ((3, 0), (12, 1)):
        label = str(sub) if sub < 10 else hex(sub)
        require(re.search(r'case '+label+r':\s*FUN_09a88e90\(param_1,'+str(parameter)+r'\);', dispatch_text),
                'guard dispatcher parameter mismatch')
        checks['guard_dispatch_parameter_matches'] += 1
    action_rows = []
    for state in normal['states']:
        row = {k: state[k] for k in ('id', 'cate', 'sub', 'address', 'handler_parameter', 'reachability')}
        row['kind'] = 'normal_type0_conditional_action'
        row['handler_source'] = cite(state['address'])
        row['contract_ref'] = {'source': 'analysis/hunter_normal_contract.json', 'json_pointer': '/states/' + str(normal['states'].index(state))}
        row['phases'] = []
        for plan in state['animation']:
            phase = {k: plan.get(k) for k in ('when', 'primary', 'secondary', 'start_frame_units', 'blend_argument', 'blend_stored')}
            if row['address'] == guard_source:
                require(all(phase[k] == v for k, v in guard_parameters[row['handler_parameter']].items()),
                        'normal guard phase differs from parameter owner')
                phase['parameter_owner'] = {'handler': guard_source, 'parameter': row['handler_parameter'],
                                             'dispatcher': guard_dispatch_source}
                checks['guard_parameter_phase_matches'] += 1
            phase['clips'] = [get_clip(plan['primary'], 0), get_clip(plan['secondary'], 1)]
            row['phases'].append(phase)
        action_rows.append(row)
    for index, state in enumerate(gs['states']):
        row = {'id': f'gs_{state["subaction"]:02x}', 'cate': 1, 'sub': state['subaction'],
               'address': '0x' + state['handler'] if state['handler'] else None,
               'handler_parameter': state['parameter'], 'kind': 'GS_type0_dispatch',
               'empty_dispatch': state['empty_dispatch'], 'reachability': 'conditional handler; no executed-state proof',
               'contract_ref': {'source': 'analysis/hunter_greatsword_contract.json', 'json_pointer': f'/states/{index}'}, 'phases': []}
        if state['handler']:
            row['handler_source'] = cite(state['handler'])
        for plan in state['concrete_animation_phases']:
            row['phases'].append({**{k: plan.get(k) for k in ('stage_1d5', 'condition', 'primary', 'secondary', 'blend_argument', 'submitted_blend_s16', 'start', 'yaw_delta')},
                                  'clips': [get_clip(plan['primary'], 0), get_clip(plan['secondary'], 1)]})
        action_rows.append(row)
    # Successful/reaction guard state clips: exact type0 branches, not all-weapon literals.
    for sub, handler, param, aid, blend, start in ((12, '09a88e90', 1, guard_parameters[1]['primary'],
                                                   guard_parameters[1]['blend_argument'], guard_parameters[1]['start_frame_units']),
                                                  (1, '09a884c0', 0, 0x586, 2, 0),
                                                  (10, '09a884c0', 1, 0x587, 0, 0),
                                                  (8, '09a8a0b0', None, 0x586, 2, 0),
                                                  (11, '09a8a438', None, 0x585, 0, 0)):
        action_rows.append({'id': f'guard_{sub:02x}', 'cate': 2, 'sub': sub, 'address': '0x'+handler,
                            'handler_source': cite(handler), 'handler_parameter': param,
                            'kind': 'type0_guard_conditional', 'reachability': 'guard dispatcher; outcome is external',
                            'phases': [{'when': 'phase0 type0 branch', 'primary': aid, 'secondary': aid+100,
                                        'blend_argument': blend, 'blend_stored': math.trunc(blend/2), 'start_frame_units': start,
                                        'clips': [get_clip(aid, 0), get_clip(aid+100, 1)]}]})
        if handler == '09a88e90':
            phase = action_rows[-1]['phases'][0]
            require(all(phase[k] == v for k, v in guard_parameters[param].items()), 'guard phase differs from parameter owner')
            phase['parameter_owner'] = {'handler': guard_source, 'parameter': param, 'dispatcher': guard_dispatch_source}
            checks['guard_parameter_phase_matches'] += 1
    # Idle protection transition submits6 as well as reset alternatives24/403/431.
    for aid in (24, 124, 403, 503, 431, 531, 63, 163, 6, 106, 1010, 1110):
        get_clip(aid, int(aid in (124, 503, 531, 163, 106, 1110)))

    inventory = []
    for entry in actions['ordinary_dispatch']:
        matched = [r['id'] for r in action_rows if r['cate'] == 0 and r['sub'] == entry['subaction']]
        inventory.append({'subaction': entry['subaction'], 'handler': entry['handler'],
                          'action_rows': matched, 'coverage': 'selected_contract' if matched else 'external/non-flat context outside selected playable set'})
    # Validate retained action producer references against real handler literals/direct stores.
    for row in action_rows:
        if not row.get('address'):
            continue
        address = row['address'][2:]
        text = blobs['decomp_ovl/' + address + '.c'].decode()
        for phase in row['phases']:
            aid = phase['primary']
            literals = {int(m[1], 0) for m in re.finditer(r'088d857c\(param_1,\s*(0x[0-9a-f]+|\d+)\s*,', text)}
            table_or_reset = address in ('09a963e0', '09a97360')
            require(aid in literals or table_or_reset, f'phase primary{aid} not in producer{address}')
            require(phase['secondary'] == aid + 100, 'paired track ID mismatch')
            checks['action_mapping_matches'] += 1
    for address in ('088d8a50', '0886524c', '088d857c', '088d85c4', '08863e68', '08863644',
                    '0885f998', '0885f920', '0885fa04', '08863190', '088630c8', '088633c4',
                    '08863660', '088632d0', '088637bc', '08865640', '08863b68', '0885f8e0',
                    '0885ffb4', '0885ff54', '08860320', '08860534', '08860640', '08864774',
                    '088d68b0', '09a617f0', '09a62cd8', '09a95be0', '09a87fc0', '09b9bc90',
                    '09b9e018', '09a86300', '09b9dec0', '09aa0440', '09aa36a8',
                    '09b9f270', '09b9f300', '09ba1740', '0885fc94', '0885fe3c'):
        cite(address)
    time_operations = []
    for address, operations in (('088637bc', {'add.s': 0x46000000, 'sub.s': 0x46000001, 'c.le.s': 0x4600003e}),
                                ('08863e68', {'div.s': 0x46000003, 'cvt.s.w': 0x46800020}),
                                ('08863b68', {'add.s': 0x46000000, 'sub.s': 0x46000001})):
        owner = citations[address]['machine_source']
        start, end = owner['byte_range']
        words = list(struct.iter_unpack('<I', blobs[EBOOT][start:end]))
        offsets = {name: [start+4*i for i, (word,) in enumerate(words) if word & 0xffe0003f == opcode]
                   for name, opcode in operations.items()}
        require(all(offsets.values()), 'COP1 time operation absent from original bytes: '+address)
        time_operations.append({'function': '0x'+address, 'source': owner, 'instruction_file_offsets': offsets,
                                'scope': 'original single-precision opcode presence; operation order from retained decomp, not runtime proof'})
    # Test actual selector, including absent shared entries and null-manager fallback.
    for aid in (1010, 1110):
        item = clips[f'{aid}:{int(aid == 1110)}']
        require(item['selected_pack'] == 3377 and item['status'] == 'absent' and item['end_time'] is None,
                'draw variant absent must not invent endpoint')
        checks['draw_variant_null_assets'] += 1
    shared_groups = directories[61][0]
    absent_fixture_id = next(g * 100 + i for g, group in enumerate(shared_groups)
                             for i, offset in enumerate(group['entries']) if offset == -1)
    pack, relative, found = resolve(absent_fixture_id, 0)
    require(pack == 61 and found['status'] == 'absent', 'shared absent fallback invented')
    a, b = found['entry_byte_range']
    absent_fixture = {'animation_id': absent_fixture_id, 'lookup': found,
                      'entry_source': range_source(relative, a, b),
                      'rule': 'real shared61 signed -1 entry returns null, no entity fallback',
                      'scope': 'selector regression fixture, NOT selected action/clip'}
    checks['shared_absent_no_fallback'] = 1
    require(resolve(1, 0, False)[0] == 3377 and resolve(1428, 0)[0] == 3377, 'fallback routing mismatch')
    checks['null_shared_fallback_and_weapon_route'] = 2

    for row in action_rows:
        for phase in row['phases']:
            phase['required_runtime_arguments'] = [name for name, value in
                (('blend', phase.get('blend_argument')), ('start', phase.get('start_frame_units', phase.get('start'))))
                if value is None]
    geometry = []
    for resource in mesh['resources']:
        if resource['pack_id'] in (1877, 3389):
            geometry.append({k: resource[k] for k in ('pack_id', 'pmo_scale', 'node_count', 'bone_uploads')})
    pseudocode = """1. 校验profile条件与sourceSHA；读取skeleton和action.phases，不以包有clip代替handler门。FSM观察上一轮position/active；允许原调度最多一次again。\n2. ANIM(A,B,S)只提交A/A+100、u16(S)、s16(trunc(B/2))，清pending-bind位；按每条phase的有序条件选择，非一次播完所有variants。\n3. 对两轨分别resolve：ID<1000且shared61 ready时只查61；缺entry返回null；否则查entity3377的ID%1000。null不绑定，不生成替代clip/end/loop；088d85c4仍置已处理位，已有track后续情况不可推成崩溃或定格。\n4. 非null按group-filtered DFS绑定；保存previous pose，start转float，end=max(0,last signed key time)，loop_start由header+10的binary32位解释而非u32帧数；m=0无blend，m!=0 count=abs(m)+1，delta=f32(1/f32(count))，progress=delta。\n5. 原反馈/速度生产先决定step，默认2，sprint2.5/冻结0/slow float32(0x3e4ccccd)不得用固定秒速替换。08865640先更新entity旋转/尺度，再取root差，再optional overlays，再088637bc。\n6. root非blend取浮点曲线D(max(0,pos-step),pos)；负previous wrapper把区间改为[0,step]。root用于entity方向变换(w=0)并加位置，不受floor姿态时间替代。blend root按原progress Hermite加权old/new差；其ABI详见引用机器范围，不推成普通线性crossfade。\n7. 非blend先next=f32(pos+step)，若next<=end：用floor(pos)采样pose，再pos=next，active=1；越界nonloop：pos=end，采样floor(end)，active=0；越界loop：先采样(loop_start>=1?loop_start-1:loop_start)，捕获root，再采样end，pos=loop_start，active=0；不能简单modulo循环。\n8. blend每次采样当前pos并用原Hermite progress混合保存的base pose，root node1 T清零，progress=f32(progress+delta)，count--（step0也递减）；count到0才pos=f32(pos+step)。normal采样后捕获node1 T并清除，避免entity/root双重位移。\n9. 每node先复制bind S/R/T到默认channels，只覆写clip存在channels；keys=<4h value,time,in,out>，Hermite(t)*factor，rotation为原radians，S/T factor=1/16。缺channels不是0。\n10. 使用自己的parent bind/current矩阵并分别生成+90显示层级与+d0碰撞层级；+50=current90*原inverse10。上传GU float24再skin GE原坐标，最后entity变换一次。不能额外把PMO scale乘第二次。\n11. 武器使用3389自己的4-bone/inverse/palette和body node10 +90 attachment；blade capsule用body node14 +d0，不用武器skin顶点或attachment node10代替。\n12. 原地面/FSM修正、拔收刀武器姿态分支与网络/输入为显式接口；已存动作源合同解释转换，seconds/真实Hz未知，调用方选择engine尺度而非声称原包米制。"""
    result = {'schema_version': 2, 'target': 'ULJM05500 MHP2G',
            'scope': 'hunter+GS自身平地可开发资产合同及条件variants；离线原包/已有静态代码，无运行时/Ghidra/网络/Godot；不调查敌人/伤害',
            'profile': {'selected': selection['reproducible_configs'][0], 'alternative_body': selection['reproducible_configs'][1],
                        'body_pack': 1877, 'weapon_model_pack': 3389, 'weapon_type': 0, 'GS_animation_pack': 3377, 'shared_task_pack': 61,
                        'status': 'code-supported conditional configuration, NOT actual user/save/load observation',
                        'requires': ['normal constructor flags6af14&0x69==0', 'selected slot0 body and equipmentID1/type0',
                                     'weapon resource ready pointer bound entity+1ac', 'game_task shared61 ready pointer bound manager+40'],
                        'not_blockers': ['3378 is type1, not alternative body or GS support requirement', 'missing IDs for other weapon branches do not mean type0 clips absent'],
                        'visual_limit': 'slot0 only; other five equipment parts/full apparel not selected'},
            'owner_correction': {'tables': tables, 'facts': selection['observations'][:6],
                                 'corrections': selection['corrections_to_other_static_proxies'],
                                 'precedence': 'this report overrides catalog/resources owner interpretation ONLY; old reports remain unchanged'},
            'asset_sources': packs, 'input_sources': sources, 'code_sources': citations,
            'skeletons': skeletons, 'geometry': {'assets': geometry, 'units': 'original numeric axes0/1/2 and original model units; meter/axis conversion unknown',
                                               'geometry_ref': {'source': 'analysis/hunter_mesh_data.json', 'usage': 'raw GE vertices/weights/palette; preserve original data, do not pre-scale then apply inverse skin again'},
                                               'pmo_scale_role': 'P in rest90=P^-1*bind_global; not clip translation/time conversion'},
            'selection_rule': {'producer': ['0x088d857c', '0x088d8a50', '0x0886524c', '0x088d85c4'],
                               'pseudocode': 'ANIM submits primary A and secondary A+100 separately. resolve(ID): if ID<1000 and manager exists and shared pointer nonnull: lookup(shared61,ID/100,ID%100), absent returns null WITHOUT fallback; otherwise lookup(entity3377,(ID%1000)/100,ID%100).',
                               'null_bind_observation': '088d85c4 marks pending bit handled before lookup; calls08863e68 only for nonzero return. Existing track behavior after null is state-dependent; not inferred from absent asset.'},
            'clips': list(clips.values()), 'actions': action_rows, 'ordinary_dispatch_inventory': inventory,
            'coverage': {'ordinary_inventory_entries': len(inventory), 'selected_action_rows': len(action_rows),
                         'GS_dispatch': 'all0..1d; category1 sub0d/17 are no-op, unlike category0 sub17 draw variant',
                         'ordinary_limit': 'all dispatcher entries indexed; selected flat movement/idle/draw/sheath/crouch/kick/roll/guard plus retained danger variants exported. Other contextual category0 handlers are explicit out-of-scope, not falsely supported.',
                         'references_not_runtime': True},
            'special_cases': {'draw_1010_1110': {'producer': '09a97360 param5/category0 sub17 phase0 submits1010/1110; not GS category1 sub17',
                                               'type0_dispatch': 'category0 sub17直接分派param5，没有type检查；但已审普通输入type0不会经09b9f270进入17。静态可调用不等于正常GS输入可达。',
                                               'type2_related': '09aa0440 command1120==2/locks分支：type0调用09b9e360，type2调用09ba1740=>category1/sub8；type1/5调用09b9f270。09b9f270 type1或param0=>category0/sub4，否则=>category0/sub17，因此type5+param1是已见条件入口，不是type2。09b9f300资源计数失败分支也调用该helper；未闭合全局入口。',
                                               'asset_result': 'GS3377 signed-offset -1: null for both; no end/loop/duration invented; runtime consequence UNKNOWN'},
                              'low_stamina_idle': {'producer': 'RESET_IDLE uses stamina_max62e<76 =>403/503; idle can revert when max>75; not current stamina<76',
                                                  'clips': ['403:0', '503:1'], 'result': 'see actual selected61 lookup; only asset result, not runtime feasibility'},
                              'appearance_idle': {'producer': 'idle_counter>239 && entity4e0==1 =>63/163; 4e0 is body descriptor mirror, not weapon type', 'clips': ['63:0', '163:1']},
                              'side_roll': 'normal input producer reachability unproven in old normal report, but GS combo09b9e018 calls09a86300 and can submitcategory0 sub31/32; later attack setter can override. Preserve directional/camera predicates.'},
            'sampling_contract': {'key_layout': ['value', 'time', 'in_tangent', 'out_tangent'], 'storage': 'little-endian signed16 stride8; high flags retained, not codec selector in selected readers',
                                  'component_type_map': catalog['component_type_map'], 'rotation_factor_f32': clip_parser.ROTATION_FACTOR,
                                  'scale_translation_factor': 0.0625, 'time': 'raw key animation units; pose uint floor(nonnegative t), root floating t; Hz/seconds unknown',
                                  'hermite': 'dt=t1-t0;u=(t-t0)/dt; value=(2u^3-3u^2+1)v0+(u^3-2u^2+u)dt*out0+(-2u^3+3u^2)v1+(u^3-u^2)dt*in1; multiply factor after interpolation',
                                  'endpoint': 'clamp before first/after last; end=max(0,last time across bound channels), not last header word',
                                  'default_channels': '0885fa04 copies source bind S/R/T into pose each sample, overwrites only present channels; missing node channels preserve bind; alternate previous/base pose distinct from bind defaults',
                                  'base_blend': '08863e68 saves previous pose; m!=0 abs(m)+1 calls including step0, delta=f32(1/f32(count)); progress starts at delta and adds with binary32 stores; interpolation mathematical, not assumed linear',
                                  'loop_start': 'header+10 little-endian binary32, parsed_loop_start/loop_start_raw are time; header.loop_start_raw_u32 and loop_start_raw_bits retain raw bits/source separately',
                                  'time_precision': 'COP1 scalar time boundary: binary32 start/step/end, rounded next=position+step before comparison/store, rounded loop_start-1, root sample interval add/sub, blend_delta/progress; Hermite/pose/root vector math remains high-precision mathematical model, not PSP/VFPU bit-exact',
                                  'root_motion': 'node1 first-child T;08865640/08863b68 root before pose advance; nonblend previous=position-step;0885f8e0 negativeprevious=>[0,step];088633c4 uses float channel sample; node1 T later cleared',
                                  'pose_update': '<=end normal sample before increment; strict >end ends; loop last/end sequence and active0 boundary per088637bc, not continuous modulo'},
            'matrix_binds': {'world_conventions': world['conventions'], 'skin_producer': skin['matrix_math'],
                             'attachment': world['attachment'], 'blade_capsules': world['shape_records'],
                             'blade_vs_skin': 'blade is body bone14 +d0 collision capsules with local unscaled numeric endpoints/radius; visual weapon own3389 bones0..3/palette/+50 attaches body bone10 +90. Neither is the other.',
                             'inverse_limit': '3389 orthogonal inverse verified; 1877 original anisotropic scale/tiny rotation inverse producer approximate, do not substitute generic inverse or snap source rotation',
                             'weapon_scale': 'display .8, node2 Z .73; capsule has its own field geometry, not automatically visual scale',
                             'sheath_limit': 'selected skin neutral model covers main attachment only; complete088d68b0 sheath/accessory switching is not closed; consult original function, do not hold drawn attachment while claiming sheath equivalence'},
            'player_ordered_pseudocode': pseudocode,
            'reading': ['验证input_sources文件SHA；按actions[id].phases选条件而非顺序无条件播放。',
                        '用clips key找metadata/实际owner/end/loop/mapping；rawkeys.json_pointer只读旧catalog nodes，不读旧owner字段；inline_nodes为新补普通clip。',
                        '同rawkeys nodes[*].channels[*].keys/factor/time_range及bone_mappings[1877]构建播放器。骨架bind和geometry palette独立。',
                        '状态转移详见normal/GS contract_ref；动作名为静态推断，不是视觉识别。所有路径属于mh，导出文件未复制约17MBcatalog。'],
            'unknowns': ['未运行目标、Godot或provider；未知真实时钟/秒数、引擎轴向/米制、精确PSP逐步舍入。',
                         'profile不是用户实际角色或存档；身体row不标男女，不声称完整装备。',
                         '原包缺clip仅建立lookup null；不推断必然崩溃、定格或fallback动画。',
                         '普通dispatcher中其它场景/道具/地形/异常handler仍显式外部范围，不声称全场景播放器。',
                         'root/blend采用静态数学模型及typed root callback；保留伪代码缺参来源，不声称PSP ABI逐步/VFPU运行验证。',
                         '完整拔收刀可视武器attachment切换、其它装备部件、额外pose overlays仍需调用方明确实现边界。'],
            'validation': {**dict(checks), 'cop1_time_owner_operations': time_operations, 'shared_absent_fixture': absent_fixture}, 'reproduce': {'write': 'python3 -B mh/tools/hunter_action_assets_probe.py --write-report',
                                                     'check': 'python3 -B mh/tools/hunter_action_assets_probe.py --check'}}
    result['implementation'] = {
        'version': 2, 'module': 'mh/tools/hunter_action_assets_probe.py',
        'evidence': 'retained static consumer mathematical Python adapter, not target runtime/VFPU bit-exact proof',
        'api': {
            'AnimationState.from_contract(path=OUTPUT, body_pack=1877, verify=True, root_sampler=sample_root)': '加载选定parsed clip/mapping/default；SHA验证所有owner inputs；rawkeys按owner JSON pointer读一次，不重解原包',
            'state.set_animation(primary, blend, start)': 'ANIM原整数参数；secondary=s16(primary+100)，start=u16；stored=s16(trunc(blend/2))；非零abs(stored)+1次、phase=delta=1/count；保存oldclip/frame与oldpose；同tick重复setter不二次捕获',
            'state.reset(primary, blend=0, start=0)': '显式重绑当前或新ID；不猜RESET_IDLE配置或FSM条件',
            'state.tick(playback_step, root_enabled=True, direction_transform=None)': '本tick原始step，必须显式输入；先root差再pose采样推进。回调xyz->xyz仅方向变换(w=0)，不含平移；返回root_delta/captured_root/events/currentframe/active/pose',
            'state.animation_ended(group=0)': '!active feedback；loop reset当tick也True，下一采样可False，不能当永久clip终止或两轨all-ended',
            'sample_channels(clip, defaults, time, floating=False)': 'dict[bone]->9-tuple S/R/T；默认floor时间，floating用于root；缺channel保留bind；未覆盖None抛UnsupportedAnimation，不置零',
            'sample_root(request: RootSample) -> tuple[float,float,float]': 'node1 T浮点采样，RootSample包含clip/time/defaults/bone；可替换typed root callback，不接受猜测的米制/Hz',
            'root_delta(clip, defaults, previous, current, sampler=sample_root)': 'current-previous；previous<0则改[0,current-previous]；原channel factor保持',
            'make_pose(channels), blend_pose(old,new,weight), blend_weight(phase)': 'NodePose(scale, matrix)；复用world.rotation；blend以Hermite weight混合scale/T及rotation basis、normalize/cross重建，非Euler插值；保存oldpose不随tick推进'
        },
        'state_fields': ['tracks[0:2].clip/currentframe/step/end/loop/loop_start/active',
                         'tracks[0:2].blendphase/blend_delta/blend_remaining/blend_sign/old_clip/old_frame/old_pose',
                         'pose: dict[bone,NodePose(scale3,matrix4x4)]', 'captured_root: xyz'],
        'pose_boundary': 'matrix是不含node_scale的local pose，scale独立；node1 T清零。nodes复用hunter_mesh_data.resources所选pack.bind_nodes（parent_candidate），不把clip skeleton parent字段自行改名重解。matrices={i:p.matrix for i,p in frame["pose"].items()},scales={i:p.scale for i,p in frame["pose"].items()}交给skin.hierarchy(owner_programs,nodes,matrices,scales,body_scale,collision_parent,model_parent)，返回currents(+90),collisions(+d0)。原skin示例body_scale=[entity_scale]*3、collision_parent=entity matrix、model_parent=world.identity_matrix；不混用二者。render_producer另乘inverse(+10)得+50。不在adapter重实现hierarchy/skin/attachment/capsule。',
        'unsupported': '任何selected clip缺失包括1010/1110抛UnsupportedAnimation且资源缺失时保留两轨；不伪造0长度。此fail-closed runner边界不是原游戏null-bind运行后果的证明。',
        'caller_inputs': ['选择已满足profile的具体action.phase，读取其primary/blend_argument/start_frame_units或start；required_runtime_arguments非空时由owner状态输入提供，不猜None；不把blend_stored当原参数再除2',
                          '先FSM使用上一tick active/currentframe；具体phase/root-disable由normal/GS owner合同给出；不根据动作名猜',
                          'playback_step由现有producer给出raw animation units/call：默认2/sprint2.5/freeze0/slow float32(0x3e4ccccd)；无m/s或Hz转换',
                          'entity rotation/scale先更新；direction_transform复用world owner方向变换；把root_delta加到entity position一次，后续地面/物理修正由caller拥有',
                          'root_enabled显式对应原root-disable；yaw_delta/terrain/floor/collision/extra overlay及拔收刀attachment分支不由adapter推测'],
        'runner_example': 'state=AnimationState.from_contract(); state.set_animation(phase["primary"],phase["blend_argument"],phase.get("start_frame_units",phase.get("start",0))); frame=state.tick(playback_step,root_enabled=allowed,direction_transform=rotate_scale_direction); # frame["pose"] -> skin.hierarchy, frame["root_delta"] -> position once',
        'limits': ['时间字段/加减/比较及blend_delta/progress按原COP1顺序binary32；Hermite采样、root向量及blend basis仍为高精度数学模型，不保证完整PSP/VFPU逐步舍入；未验证真实运行',
                   '可替换root_sampler处理额外已解析root规则；当前node1 T模型不添加parent/entity/ground变换',
                   '首次blend前无旧clip时oldpose来自已知bind，旧root差为0（adapter初始化选择）；真实旧track未知时caller必须先绑定，不能宣称原初始化观察',
                   'root blend旧curve采用固定old_frame采样，held oldpose；不执行overlay/weapon visual branch或动态FSM']
    }
    result['reproduce']['self_test'] = 'python3 -B mh/tools/hunter_action_assets_probe.py --self-test'
    result['validation']['adapter_selftests'] = adapter_selftests(result, catalog, skin, mesh_data)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--write-report', action='store_true')
    group.add_argument('--check', action='store_true')
    group.add_argument('--self-test', action='store_true', help='read-only source verification and adapter selftests')
    args = parser.parse_args()
    result = build()
    if args.write_report:
        OUTPUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    elif args.check:
        require(json.loads(OUTPUT.read_text()) == result, 'generated contract differs')
    print(json.dumps({'output': str(OUTPUT), 'actions': len(result['actions']), 'clips': len(result['clips']),
                      'absent': [{'id': c['animation_id'], 'pack': c['selected_pack'], 'reason': c['lookup']['reason']}
                                 for c in result['clips'] if c['status'] == 'absent'],
                      'validation': result['validation']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
