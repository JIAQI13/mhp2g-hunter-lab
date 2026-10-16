class_name AttackEvents
extends RefCounted

# 只拥有源记录、攻击寿命与接触几何；资格窗口及HP由caller拥有。
var _records: Dictionary = {}
var _shapes: Dictionary = {}
var _attacks: Array[Dictionary] = []
var _last_attack_id: int = 0
var _initialization_kind: String = "hunter"

func configure(data: Dictionary, initialization_kind: String = "hunter") -> bool:
	_records.clear()
	_shapes.clear()
	reset()
	if not initialization_kind in ["hunter", "shell24"] or data.get("schema_version") != 1 or not data.get("records") is Dictionary or not data.get("shapes") is Dictionary or data.records.is_empty():
		return false
	var tables: Dictionary = {}
	if data.get("shape_tables") is Dictionary:
		tables = data.shape_tables
	elif data.get("shape_lists") is Array:
		for table in data.shape_lists:
			if not table is Dictionary or not _integer(table.get("index")) or tables.has(str(int(table.index))):
				return false
			tables[str(int(table.index))] = table
	else:
		return false
	var records: Dictionary = {}
	var shapes: Dictionary = {}
	for key in data.records:
		var row = data.records[key]
		if not key is String or not key.is_valid_int() or not row is Dictionary or not row.get("source") is Dictionary:
			return false
		for field in ["id", "delay_byte", "duration_byte"]:
			if not _byte(row.get(field)):
				return false
		if str(int(row.id)) != key or (row.has("supported") and not row.supported is bool):
			return false
		var record: Dictionary = row.duplicate(true)
		for field in ["id", "delay_byte", "duration_byte"]:
			record[field] = int(row[field])
		for field in ["byte2_raw", "edge_delay_byte", "edge_duration_byte"]:
			if row.has(field):
				if not _byte(row[field]):
					return false
				record[field] = int(row[field])
		record.supported = row.get("supported", true)
		records[record.id] = record
		if not record.supported:
			continue # 保留unsupported事实，但绝不为它猜selector或生成事件。
		if not _byte(row.get("shape_selector")):
			return false
		record.shape_selector = int(row.shape_selector)
		if initialization_kind == "shell24" and (not _integer(row.get("selector")) or not int(row.selector) in range(6)):
			return false
		if row.has("selector"):
			if not _integer(row.selector):
				return false
			record.selector = int(row.selector)
		if shapes.has(record.shape_selector):
			continue
		var table = tables.get(str(record.shape_selector))
		var entries = data.shapes.get(str(record.shape_selector))
		if not table is Dictionary or table.get("terminated") != true or table.get("supported_geometry") != true or not entries is Array or entries.is_empty():
			return false
		var normalized: Array[Dictionary] = []
		for shape in entries:
			if not shape is Dictionary or not shape.get("source") is Dictionary:
				return false
			for field in ["bone", "kind", "part", "group"]:
				if not _integer(shape.get(field)) or shape[field] < -32768 or shape[field] > 32767:
					return false
			if shape.bone < 0 or int(shape.bone) in [125,126,127] or not int(shape.kind) in [0,1] or not _number(shape.get("radius")) or shape.radius < 0 or shape.radius > 3.4028234663852886e38:
				return false
			for field in ["point_a", "point_b"]:
				if not shape.get(field) is Array or shape[field].size() != 3:
					return false
				for component in shape[field]:
					if not _number(component) or absf(float(component)) > 3.4028234663852886e38:
						return false
			var parsed: Dictionary = shape.duplicate(true)
			for field in ["bone", "kind", "part", "group"]:
				parsed[field] = int(shape[field])
			parsed.radius = float(shape.radius) * 0.01
			for field in ["point_a", "point_b"]:
				parsed[field] = Vector3(shape[field][0], shape[field][1], shape[field][2])
			normalized.append(parsed)
		shapes[record.shape_selector] = normalized
	_records = records
	_shapes = shapes
	_initialization_kind = initialization_kind
	return true

static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

static func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floor(float(value))

static func _byte(value: Variant) -> bool:
	return _integer(value) and value >= 0 and value <= 255

static func _vector(value: Variant) -> bool:
	return value is Vector3 and value.is_finite()

func reset() -> void:
	_attacks.clear()
	_last_attack_id = 0 # caller同时重置producer；单独动画重置不可调用本方法。

func terminate(attack_id: int) -> void:
	_attacks = _attacks.filter(func(attack): return int(attack.attack_id) != attack_id)

func read_record(record_id: int) -> Dictionary:
	return _records.get(record_id, {}).duplicate(true)

func snapshot() -> Dictionary:
	# 深拷贝只读观察：外部写入不能改变寿命/接触history。
	return {"initialization_kind":_initialization_kind, "last_attack_id":_last_attack_id, "attacks":_attacks.duplicate(true)}

func initial_delay(record_id: int, blend_count: int, start: int) -> int:
	if not _records.has(record_id):
		return 0
	var delay: int = _records[record_id].delay_byte >> 1
	if delay == 0:
		return 0
	var blend: int = ((blend_count + 32768) & 65535) - 32768
	var source_start: int = start & 65535
	# 09b635c0人类start/2；09b96c20 shell24 start不/2。m已解析short334。
	if _initialization_kind == "hunter":
		source_start >>= 1
	var narrowed: int = (delay + absi(blend % 100) - source_start - 1) & 255
	return 0 if narrowed >= 128 else narrowed

func tick(actor_snapshot: Dictionary, animator: HunterAnimator, lift: float, targets: Array[Dictionary]) -> Array[Dictionary]:
	var contacts: Array[Dictionary] = []
	if actor_snapshot.get("alive", true) == false:
		_attacks.clear()
		return contacts
	if _records.is_empty() or animator == null or not is_finite(lift) or not _integer(actor_snapshot.get("primary")) or not _integer(actor_snapshot.get("yaw")) or not _vector(actor_snapshot.get("position")):
		return contacts
	# 生产者退出通知先于寿命/碰撞消费，不能靠目标资格隐藏仍然存活的旧攻击。
	for notification in actor_snapshot.get("events", []):
		if notification is Dictionary and notification.get("event") == "attack_end" and _integer(notification.get("attack_id")):
			terminate(int(notification.attack_id))
	var candidates: Array[Dictionary] = []
	for target in targets:
		# 先检查controller资格，拒绝时不碰几何，更不提交history。
		if target.get("eligible") != true or not target.get("identity") is String or not _integer(target.get("generation")) or not target.get("volumes") is Array:
			continue
		var volumes: Array[Dictionary] = []
		for volume in target.volumes:
			var parsed: Dictionary = read_volume(volume)
			if parsed.is_empty():
				volumes.clear()
				break
			volumes.append(parsed)
		if not volumes.is_empty():
			candidates.append({"identity":target.identity, "generation":int(target.generation), "volumes":volumes})
	var surviving: Array[Dictionary] = []
	for attack in _attacks:
		if int(actor_snapshot.primary) != attack.primary:
			continue
		if attack.state == 1:
			if attack.delay != 0:
				attack.delay -= 1
			else:
				attack.state = 2
		if attack.state == 2:
			if attack.duration == 0:
				continue # old0停用；last1消费到0当次仍可接触。
			attack.duration -= 1
		if _initialization_kind == "hunter":
			# 09b63fd8按消费后的33c/558补偿；等待期也会加。
			if int(actor_snapshot.get("hard", 0)) != 0 or int(actor_snapshot.get("slow", 0)) != 0:
				attack.duration = (attack.duration + 1) & 255
		else:
			# 09b96df0 selector0/2另需源298==3与09b4baa0资格。
			# caller解析为shell24_active；缺失未知不能当满足，不猜怪物mode。
			var selector: int = _records[attack.record].selector
			if selector in [0,2] and actor_snapshot.get("shell24_active") != true:
				continue
			# selector0/2/3/4/5刷新99；selector1用原duration。
			if selector != 1:
				attack.duration = 99
		if attack.state == 2:
			for target in candidates:
				var identity: Array = [target.identity, int(target.generation)]
				if attack.history.has(identity):
					continue
				for shape in _shapes[_records[attack.record].shape_selector]:
					if shape.bone >= animator.world_pose.size():
						continue
					var bone: Transform3D = animator.world_pose[shape.bone]
					var a: Vector3 = world_point(bone * shape.point_a, actor_snapshot, lift)
					var b: Vector3 = world_point(bone * shape.point_b, actor_snapshot, lift) if shape.kind == 1 else a
					var volume: Dictionary = {"kind":"capsule" if shape.kind == 1 else "sphere", "a":a, "b":b, "radius":shape.radius}
					var hit: bool = false
					for target_volume in target.volumes:
						if volumes_intersect(volume, target_volume):
							hit = true
							break
					if not hit:
						continue
					attack.history[identity] = true
					var record: Dictionary = _records[attack.record]
					var contact: Dictionary = {"event":"contact", "attack_id":attack.attack_id, "record":attack.record, "attack_scale":attack.attack_scale, "part":shape.part, "position":a, "target_identity":target.identity, "target_generation":int(target.generation), "source":record.source.duplicate(true), "shape_source":shape.source.duplicate(true), "initialization_kind":_initialization_kind, "delay_byte":record.delay_byte, "duration_byte":record.duration_byte, "shape_selector":record.shape_selector}
					if record.has("byte2_raw"):
						contact.byte2_raw = record.byte2_raw
					contacts.append(contact)
					break # 同event多个shape首次命中即结束此target。
		surviving.append(attack)
	_attacks = surviving
	# 新S0当次只初始化，不碰撞；producer单调ID阻止通知重放。
	for notification in actor_snapshot.get("events", []):
		if not notification is Dictionary or notification.get("event") != "attack_spawn":
			continue
		var valid: bool = true
		for field in ["record", "primary", "start", "blend_count", "attack_scale", "attack_id"]:
			valid = valid and _integer(notification.get(field))
		if not valid or not _records.has(int(notification.record)) or not _records[int(notification.record)].supported or notification.attack_id <= _last_attack_id or not _byte(notification.attack_scale) or int(notification.primary) != int(actor_snapshot.primary):
			continue
		_last_attack_id = int(notification.attack_id)
		var record: Dictionary = _records[int(notification.record)]
		_attacks.append({"attack_id":_last_attack_id, "record":record.id, "primary":int(notification.primary), "attack_scale":int(notification.attack_scale), "state":1, "delay":initial_delay(record.id, int(notification.blend_count), int(notification.start)), "duration":record.duration_byte >> 1, "history":{}})
	return contacts

static func world_point(point: Vector3, actor: Dictionary, lift: float) -> Vector3:
	# 完整骨矩阵先乘局部点，再只作一次源单位转换；不用drawn sword scale。
	var local: Vector3 = point * 0.01 + Vector3(0, lift, 0)
	return local.rotated(Vector3.UP, int(actor.yaw) * TAU / 65536.0) + Vector3(actor.position) * 0.01

static func read_volume(volume: Variant) -> Dictionary:
	if not volume is Dictionary:
		return {}
	if volume.get("kind") == "aabb":
		# AABB两种入口统一成low/high；a/b是两角点，不作radius扩张。
		var low = volume.get("low", volume.get("a"))
		var high = volume.get("high", volume.get("b"))
		if not _vector(low) or not _vector(high) or low.x > high.x or low.y > high.y or low.z > high.z or (volume.has("radius") and (not _number(volume.radius) or volume.radius < 0)):
			return {}
		return {"kind":"aabb", "low":low, "high":high}
	if not volume.get("kind") in ["sphere", "capsule"] or not _vector(volume.get("a")) or not _number(volume.get("radius")) or volume.radius < 0 or (volume.has("b") and not _vector(volume.b)):
		return {}
	if volume.kind == "capsule" and not _vector(volume.get("b")):
		return {}
	return {"kind":volume.kind, "a":volume.a, "b":volume.b if volume.kind == "capsule" else volume.a, "radius":float(volume.radius)}

static func volumes_intersect(first: Dictionary, second: Dictionary) -> bool:
	first = read_volume(first)
	second = read_volume(second)
	if first.is_empty() or second.is_empty():
		return false
	if first.kind == "aabb":
		if second.kind == "aabb":
			return first.low.x <= second.high.x and first.high.x >= second.low.x and first.low.y <= second.high.y and first.high.y >= second.low.y and first.low.z <= second.high.z and first.high.z >= second.low.z
		return volumes_intersect(second, first)
	var a: Vector3 = first.a
	var b: Vector3 = first.b if first.kind == "capsule" else a
	if second.kind == "aabb":
		return segment_box_distance_squared(a, b, second.low, second.high) <= first.radius * first.radius
	var c: Vector3 = second.a
	var d: Vector3 = second.b if second.kind == "capsule" else c
	var radius: float = first.radius + second.radius
	return segment_segment_distance_squared(a, b, c, d) <= radius * radius

static func segment_segment_distance_squared(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> float:
	# 两条有限线段的最近点；显式处理平行与退化，不能当无限直线。
	var u: Vector3 = b - a
	var v: Vector3 = d - c
	var w: Vector3 = a - c
	var uu: float = u.dot(u)
	var vv: float = v.dot(v)
	var uv: float = u.dot(v)
	var uw: float = u.dot(w)
	var vw: float = v.dot(w)
	var s: float = 0.0
	var t: float = 0.0
	if uu == 0.0 and vv == 0.0:
		return a.distance_squared_to(c)
	if uu == 0.0:
		t = clampf(vw / vv, 0.0, 1.0)
	elif vv == 0.0:
		s = clampf(-uw / uu, 0.0, 1.0)
	else:
		var denominator: float = uu * vv - uv * uv
		if denominator > 0.0:
			s = clampf((uv * vw - uw * vv) / denominator, 0.0, 1.0)
		t = (uv * s + vw) / vv
		if t < 0.0:
			t = 0.0
			s = clampf(-uw / uu, 0.0, 1.0)
		elif t > 1.0:
			t = 1.0
			s = clampf((uv - uw) / uu, 0.0, 1.0)
	return (w + u * s - v * t).length_squared()

static func point_box_distance_squared(point: Vector3, low: Vector3, high: Vector3) -> float:
	return point.distance_squared_to(point.clamp(low, high))

static func segment_box_distance_squared(a: Vector3, b: Vector3, low: Vector3, high: Vector3) -> float:
	# 沿线段分段二次，各box面分割t，检查端点与区间极小点；不扩大角落。
	var direction: Vector3 = b - a
	var cuts: Array[float] = [0.0, 1.0]
	for axis in range(3):
		if direction[axis] != 0:
			for face in [low[axis], high[axis]]:
				var t: float = (face - a[axis]) / direction[axis]
				if t > 0 and t < 1:
					cuts.append(t)
	cuts.sort()
	var best: float = minf(point_box_distance_squared(a, low, high), point_box_distance_squared(b, low, high))
	for index in range(cuts.size() - 1):
		var left: float = cuts[index]
		var right: float = cuts[index + 1]
		var middle: Vector3 = a + direction * ((left + right) * 0.5)
		var quadratic: float = 0.0
		var linear: float = 0.0
		for axis in range(3):
			if middle[axis] >= low[axis] and middle[axis] <= high[axis]:
				continue
			var face: float = low[axis] if middle[axis] < low[axis] else high[axis]
			quadratic += direction[axis] * direction[axis]
			linear += direction[axis] * (a[axis] - face)
		var t: float = clampf(-linear / quadratic, left, right) if quadratic != 0 else left
		best = minf(best, point_box_distance_squared(a + direction * t, low, high))
	return best
