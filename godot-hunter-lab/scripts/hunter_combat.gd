class_name HunterCombat
extends RefCounted

const Events = preload("res://scripts/attack_events.gd")
# 中性方块沙盒：raw100不是UI攻击；只提交HP，不生产反馈/hitstop。
const RESPAWN_TICKS: int = 90
var target_center: Vector3 = Vector3(0, 0.9, 2.3)
var target_half_size: Vector3 = Vector3(0.75, 0.9, 0.75)
var target_hp: int = 500
var target_max_hp: int = 500
var target_alive: bool = true
var respawn_remaining: int = 0
var target_generation: int = 0
var last_damage: int = 0
var hits: int = 0
var total_damage: int = 0
var attack_events: AttackEvents = Events.new()
var _configured: bool = false
var _powers: Dictionary = {}
var _float32 := PackedFloat32Array([0.0])

func configure(data: Dictionary) -> bool:
	_configured = false
	_powers.clear()
	reset()
	# 几何解析只有AttackEvents拥有；中性伤害profile仅在本HP消费者验证。
	if not attack_events.configure(data, "hunter"):
		return false
	var neutral: Dictionary = {"raw_attack":100,"hitzone":100,"physical_sharpness":1,"hit_phase":1,"target_multiplier":1,"element":0,"critical_multiplier":1}
	if not data.get("neutral_profile") is Dictionary:
		return false
	for key in neutral:
		if data.neutral_profile.get(key) != neutral[key]:
			return false
	var powers: Dictionary = {}
	for key in data.records:
		var record: Dictionary = attack_events.read_record(int(key))
		if not record.get("power") is int and not record.get("power") is float:
			return false
		if not is_finite(float(record.power)) or record.power < 0 or record.power > 255 or float(record.power) != floor(float(record.power)):
			return false
		powers[int(key)] = int(record.power)
	_powers = powers
	_configured = true
	return true

func reset() -> void:
	attack_events.reset()
	target_hp = target_max_hp
	target_alive = true
	respawn_remaining = 0
	target_generation = 0
	last_damage = 0
	hits = 0
	total_damage = 0

func _f32(value: float) -> float:
	_float32[0] = value
	return _float32[0]

func damage_for(record_id: int, attack_scale: int = 100) -> int:
	if not _configured or not _powers.has(record_id) or attack_scale < 0 or attack_scale > 255:
		return 0
	var power: int = _powers[record_id]
	# 09c3e448各步binary32，中性owner * power * q；trunc.w.s。
	var owner: float = _f32(_f32(100.0) / _f32(100.0))
	var candidate: float = _f32(_f32(_f32(attack_scale) / _f32(100.0)) * _f32(_f32(100.0) / _f32(100.0)))
	var q: float = _f32(_f32(_f32(1.0) * _f32(1.0)) * candidate)
	var physical: int = int(_f32(_f32(owner * _f32(power)) * q))
	return 1 if physical == 0 and power != 0 else physical

func tick(actor_snapshot: Dictionary, animator: HunterAnimator, lift: float) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if not _configured:
		return events
	if not target_alive:
		respawn_remaining -= 1
		if respawn_remaining == 0:
			target_generation += 1
			target_hp = target_max_hp
			target_alive = true
			events.append({"event":"respawned","hp":target_hp,"target_generation":target_generation})
	var targets: Array[Dictionary] = [{"identity":"training_cube", "generation":target_generation, "eligible":target_alive, "volumes":[{"kind":"aabb", "low":target_center-target_half_size, "high":target_center+target_half_size}]}]
	for contact in attack_events.tick(actor_snapshot, animator, lift, targets):
		# 同tick多个event可接触；第一笔致死后不可继续向尸体提交伤害。
		if not target_alive:
			break
		last_damage = damage_for(contact.record, contact.attack_scale)
		var applied: int = mini(target_hp, last_damage)
		target_hp -= applied
		hits += 1
		total_damage += applied
		var hit: Dictionary = contact.duplicate(true)
		hit.merge({"event":"hit", "damage":last_damage, "applied_damage":applied, "hp":target_hp}, true)
		events.append(hit)
		if target_hp == 0:
			target_alive = false
			respawn_remaining = RESPAWN_TICKS
			events.append({"event":"broken","hp":0,"attack_id":contact.attack_id,"target_generation":target_generation})
	return events
