class_name HunterAnimator
extends RefCounted

var data: Dictionary = {}
var tracks: Array[Dictionary] = [_empty_track(), _empty_track()]
var pose: Array[Transform3D] = []
var world_pose: Array[Transform3D] = []
var _node_pose: Array[Dictionary] = []
var _previous_frames: Array[float] = [0.0, 0.0]
var _clock := PackedFloat32Array([0.0])

static func _empty_track() -> Dictionary:
	return {"clip": "", "currentframe": 0.0, "end": 0.0, "loop": false,
		"loop_start": 0.0, "step": 0.0, "blend_remaining": 0, "blendphase": 0.0,
		"active": false, "blend_delta": 0.0, "blend_sign": 0,
		"old_clip": "", "old_frame": 0.0, "old_pose": {}, "captured_this_tick": false}

func _f32(value: float) -> float:
	_clock[0] = value
	return _clock[0]

func load_data(path: String = "res://assets/hunter_data.json") -> bool:
	if not FileAccess.file_exists(path):
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not _valid_data(parsed):
		return false
	# Godot 的 JSON 数值为浮点数；由负责数据的模块统一转换标识索引。
	for bone in parsed.bones:
		bone.parent = int(bone.parent)
	for clip in parsed.clips.values():
		for i in range(clip.bindings.size()):
			clip.bindings[i] = int(clip.bindings[i])
		for node in clip.nodes:
			for channel in node.channels:
				channel.component = int(channel.component)
	data = parsed
	tracks.clear()
	_previous_frames.clear()
	for group in range(int(data.get("track_count", 2))):
		tracks.append(_empty_track())
		_previous_frames.append(0.0)
	_node_pose.clear()
	for bone in data.bones:
		_node_pose.append(_make_node(bone.defaults))
	_build_world()
	if data.has("initial_animation"):
		set_animation(int(data.initial_animation), 0, 0)
		tick(0.0)
	return true

func _valid_data(value: Variant) -> bool:
	if not value is Dictionary or value.get("schema_version") != 1:
		return false
	if not value.get("bones") is Array or not value.get("clips") is Dictionary:
		return false
	if value.bones.is_empty() or value.clips.is_empty():
		return false
	var count = value.get("track_count", 2)
	var stride = value.get("clip_id_stride", 100)
	var root = value.get("root_bone", 1)
	if not _integer(count) or count < 1 or count > value.bones.size():
		return false
	if not _integer(stride) or stride < 1 or stride > 32767:
		return false
	if not _integer(root) or root < -1 or root >= value.bones.size():
		return false
	if value.has("initial_animation"):
		if not _integer(value.initial_animation) or value.initial_animation < -32768 or value.initial_animation > 32767:
			return false
		for group in range(int(count)):
			var runtime_id: int = ((int(value.initial_animation) + group * int(stride) + 32768) & 65535) - 32768
			if not value.clips.has("%d:%d" % [runtime_id, group]):
				return false
	for i in range(value.bones.size()):
		var bone = value.bones[i]
		if not bone is Dictionary or not bone.get("defaults") is Array or bone.defaults.size() != 9:
			return false
		if not _integer(bone.get("parent")) or bone.parent < -1 or bone.parent >= i:
			return false
		if bone.has("group") and (not _integer(bone.group) or bone.group < 0 or bone.group >= count):
			return false
		for component in bone.defaults:
			if not _number(component):
				return false
	var binding_groups: Dictionary = {}
	for key in value.clips:
		var clip = value.clips[key]
		if not key is String or not clip is Dictionary:
			return false
		var parts: PackedStringArray = key.split(":")
		if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
			return false
		var group: int = int(parts[1])
		if group < 0 or group >= count or int(parts[0]) < -32768 or int(parts[0]) > 32767 or key != "%d:%d" % [int(parts[0]), group]:
			return false
		if not _number(clip.get("end")) or clip.end < 0 or not clip.get("loop") is bool:
			return false
		if not _number(clip.get("loop_start")) or clip.loop_start < 0 or clip.loop_start > clip.end:
			return false
		if not clip.get("bindings") is Array or not clip.get("nodes") is Array or clip.bindings.size() != clip.nodes.size():
			return false
		if group == 0 and root >= 0:
			var root_bound: bool = false
			for binding in clip.bindings:
				if _integer(binding) and int(binding) == int(root):
					root_bound = true
			if not root_bound:
				return false
		var seen: Dictionary = {}
		for i in range(clip.nodes.size()):
			var binding = clip.bindings[i]
			if not _integer(binding) or binding < 0 or binding >= value.bones.size() or seen.has(binding):
				return false
			if value.bones[int(binding)].has("group") and value.bones[int(binding)].group != group:
				return false
			if binding_groups.has(binding) and binding_groups[binding] != group:
				return false
			binding_groups[binding] = group
			seen[binding] = true
			var node = clip.nodes[i]
			if not node is Dictionary or not node.get("channels") is Array:
				return false
			var components: Dictionary = {}
			for channel in node.channels:
				if not channel is Dictionary or not _integer(channel.get("component")) or channel.component < 0 or channel.component > 8:
					return false
				if components.has(channel.component) or not channel.get("keys") is Array or channel.keys.is_empty():
					return false
				components[channel.component] = true
				var previous: float = -1.0
				for sample in channel.keys:
					if not sample is Array or sample.size() != 4:
						return false
					for scalar in sample:
						if not _number(scalar):
							return false
					if sample[1] <= previous or sample[1] < 0 or sample[1] > clip.end:
						return false
					previous = sample[1]
	return true

static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

static func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floor(float(value))

func set_animation(primary: int, blend: int, start: int) -> bool:
	primary = ((primary + 32768) & 65535) - 32768
	if data.is_empty():
		return false
	var keys: Array[String] = []
	for group in range(tracks.size()):
		var runtime_id: int = ((primary + group * int(data.get("clip_id_stride", 100)) + 32768) & 65535) - 32768
		var key: String = "%d:%d" % [runtime_id, group]
		if not data.clips.has(key):
			return false
		keys.append(key)
	var count: int = ((int(float(blend) / 2.0) + 32768) & 65535) - 32768
	var pending: Array[Dictionary] = tracks.duplicate(true)
	for group in range(tracks.size()):
		var track: Dictionary = pending[group]
		var clip: Dictionary = data.clips[keys[group]]
		if count != 0 and not track.captured_this_tick:
			track.old_clip = track.clip
			track.old_frame = track.currentframe
			if track.clip != "" and track.blend_remaining == 0:
				track.old_pose = _sample(data.clips[track.clip], track.currentframe)
			else:
				track.old_pose = {}
				for bone in clip.bindings:
					track.old_pose[int(bone)] = _node_pose[int(bone)].duplicate()
			for bone in clip.bindings:
				if not track.old_pose.has(int(bone)):
					return false
			track.captured_this_tick = true
		track.clip = keys[group]
		track.currentframe = _f32(start & 65535)
		track.end = clip.end
		track.loop = clip.loop
		track.loop_start = clip.loop_start
		track.active = true
		track.blend_remaining = absi(count) + 1 if count != 0 else 0
		track.blend_delta = _f32(1.0 / _f32(track.blend_remaining)) if count != 0 else 0.0
		track.blendphase = track.blend_delta
		track.blend_sign = signi(count)
	tracks = pending
	for group in range(tracks.size()):
		_previous_frames[group] = tracks[group].currentframe
	return true

func animation_ended(group: int = 0) -> bool:
	return group >= 0 and group < tracks.size() and tracks[group].clip != "" and not tracks[group].active

func ge(threshold: float, group: int = 0) -> bool:
	return group >= 0 and group < tracks.size() and tracks[group].clip != "" and tracks[group].blend_remaining == 0 and tracks[group].currentframe >= _f32(threshold)

func crossed(threshold: float, group: int = 0) -> bool:
	return ge(threshold, group) and _previous_frames[group] < _f32(threshold)

func tick(playback_step: float) -> Dictionary:
	if data.is_empty() or not is_finite(playback_step) or playback_step < 0:
		return {}
	for track in tracks:
		if track.clip == "":
			return {}
	var step: float = _f32(playback_step)
	if not is_finite(step):
		return {}
	var primary: Dictionary = tracks[0]
	var delta := Vector3.ZERO
	if primary.blend_sign >= 0:
		if primary.blend_remaining != 0:
			var weight: float = _blend_weight(primary.blendphase)
			var current: Vector3 = _root_delta(primary.clip, primary.currentframe, _f32(primary.currentframe + step))
			var old := Vector3.ZERO
			if primary.old_clip != "":
				old = _root_delta(primary.old_clip, primary.old_frame, _f32(primary.old_frame + step))
			delta = old.lerp(current, weight)
		else:
			delta = _root_delta(primary.clip, _f32(primary.currentframe - step), primary.currentframe)
	var events: Array[String] = []
	for group in range(tracks.size()):
		var track: Dictionary = tracks[group]
		track.step = step
		track.captured_this_tick = false
		_previous_frames[group] = track.currentframe
		var next_frame: float = _f32(track.currentframe + step)
		var sampled: Dictionary
		var event: String
		if track.blend_remaining != 0:
			sampled = _blend_pose(track.old_pose, _sample(data.clips[track.clip], track.currentframe), _blend_weight(track.blendphase))
			track.blendphase = _f32(track.blendphase + track.blend_delta)
			track.blend_remaining -= 1
			if track.blend_remaining == 0:
				track.blend_sign = 0
				track.currentframe = next_frame
			event = "blend"
		elif next_frame <= track.end:
			sampled = _sample(data.clips[track.clip], track.currentframe)
			track.currentframe = next_frame
			track.active = true
			event = "sample_then_advance"
		elif track.loop:
			sampled = _sample(data.clips[track.clip], track.end)
			track.currentframe = track.loop_start
			track.active = false
			event = "loop_reset_no_overshoot"
		else:
			track.currentframe = track.end
			sampled = _sample(data.clips[track.clip], track.end)
			track.active = false
			event = "end"
		var root: int = int(data.get("root_bone", 1))
		if group == 0 and root >= 0:
			sampled[root].origin = Vector3.ZERO
		for bone in sampled:
			_node_pose[bone] = sampled[bone]
		events.append(event)
	_build_world()
	var frames: Array[float] = []
	var active: Array[bool] = []
	for track in tracks:
		frames.append(float(track.currentframe))
		active.append(bool(track.active))
	return {"root_delta": delta, "frames": frames,
		"active": active,
		"pose": pose.duplicate(), "world_pose": world_pose.duplicate(), "events": events}

static func _rotation(euler: Vector3) -> Basis:
	return Basis(Vector3(0, 0, 1), euler.z) * Basis(Vector3(0, 1, 0), euler.y) * Basis(Vector3(1, 0, 0), euler.x)

static func _make_node(values: Array) -> Dictionary:
	return {"rotation": _rotation(Vector3(values[3], values[4], values[5])),
		"scale": Vector3(values[0], values[1], values[2]), "origin": Vector3(values[6], values[7], values[8])}

func _sample(clip: Dictionary, time: float, floating: bool = false) -> Dictionary:
	var result: Dictionary = {}
	if not floating:
		time = floor(time)
	for i in range(clip.bindings.size()):
		var bone: int = int(clip.bindings[i])
		var values: Array = data.bones[bone].defaults.duplicate()
		for channel in clip.nodes[i].channels:
			values[int(channel.component)] = _curve(channel.keys, time)
		result[bone] = _make_node(values)
	return result

static func _curve(keys: Array, time: float) -> float:
	if time <= keys[0][1]:
		return keys[0][0]
	if time >= keys[-1][1]:
		return keys[-1][0]
	var low: int = 0
	var high: int = keys.size() - 1
	while high - low > 1:
		var middle: int = (low + high) / 2
		if time < keys[middle][1]:
			high = middle
		else:
			low = middle
	var left: Array = keys[low]
	var right: Array = keys[high]
	var dt: float = right[1] - left[1]
	var u: float = (time - left[1]) / dt
	var square: float = u * u
	var cube: float = square * u
	return (2 * cube - 3 * square + 1) * left[0] + (cube - 2 * square + u) * dt * left[3] + (-2 * cube + 3 * square) * right[0] + (cube - square) * dt * right[2]

static func _blend_weight(phase: float) -> float:
	return phase * phase * (3.0 - 2.0 * phase)

static func _blend_pose(old: Dictionary, current: Dictionary, weight: float) -> Dictionary:
	var result: Dictionary = {}
	for bone in current:
		var before: Dictionary = old[bone]
		var after: Dictionary = current[bone]
		var x: Vector3 = before.rotation.x.lerp(after.rotation.x, weight).normalized()
		var y: Vector3 = before.rotation.y.lerp(after.rotation.y, weight).normalized()
		var z: Vector3 = x.cross(y).normalized()
		y = z.cross(x)
		result[bone] = {"rotation": Basis(x, y, z), "scale": before.scale.lerp(after.scale, weight),
			"origin": before.origin.lerp(after.origin, weight)}
	return result

func _root(clip_key: String, time: float) -> Vector3:
	var root: int = int(data.get("root_bone", 1))
	if root < 0:
		return Vector3.ZERO
	var clip: Dictionary = data.clips[clip_key]
	var index: int = clip.bindings.find(root)
	var values: Array = data.bones[root].defaults.duplicate()
	for channel in clip.nodes[index].channels:
		var component: int = int(channel.component)
		if component >= 6:
			values[component] = _curve(channel.keys, time)
	return Vector3(values[6], values[7], values[8])

func _root_delta(clip_key: String, previous: float, current: float) -> Vector3:
	if previous < 0:
		current = _f32(current - previous)
		previous = 0.0
	return _root(clip_key, current) - _root(clip_key, previous)

func _build_world() -> void:
	pose.clear()
	world_pose.clear()
	for i in range(_node_pose.size()):
		var node: Dictionary = _node_pose[i]
		var local := Transform3D(node.rotation.scaled_local(node.scale), node.origin)
		pose.append(local)
		var parent: int = int(data.bones[i].parent)
		world_pose.append(world_pose[parent] * local if parent >= 0 else local)
