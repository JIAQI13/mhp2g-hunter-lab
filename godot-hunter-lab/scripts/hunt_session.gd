class_name HuntSession
extends RefCounted

const Events = preload("res://scripts/attack_events.gd")
const Combat = preload("res://scripts/hunter_combat.gd")
const ARENA_HALF: float = 1000.0
const HUNTER_RADIUS: float = 40.0
const MONSTER_RADIUS: float = 85.0
const BODY_DISTANCE: float = HUNTER_RADIUS + MONSTER_RADIUS
const LIMITS = [
	"平地30Hz沙盒：猎人HP100、猪王HP1000、猪王每次有效攻击20；不是原HP/猎人防御公式。",
	"猎人大剑沿用HunterCombat中性raw100与源power/attack_scale，不复制伤害公式。",
	"猪王byte2_raw仅明确适配为反冲impact；不称原power解析或完整原猎人防御公式；防御chip分档由HunterController拥有。",
	"猪王hurtbox是当前bone2身体胶囊近似：局部(0,0,-50)至(0,0,70)，radius65源单位，未恢复完整原hurt table。",
	"猎人hurtbox是当前bone10/bone20粗球，radius0.4/0.25显示单位；骨矩阵后只转换一次.01与lift，不用render transform。",
	"推挡独立采用猎人40/猪王85源单位XZ圆，arena中心边界±(1000-radius)；不是原hurt/attack形状。",
	"相对直线swept-circle TOI、等分法向冲量/切向滑动及迭代墙边推挡是平地空间适配，不是原物理。",
	"身体高度资格按猎人高于floor85源单位跳过地面推挡（明确平地clearance沙盒）；不把air280或地面flags当永久空中。",
	"只支持选定地面kind0 incoming；非零原碰撞窗口先拒绝，窗口为零的未知空中路径报告not_ready，不造新无敌计时。",
	"按tick先提交上次incoming，再两actor唯一次采样，空间修正后hunter伤害先提交；死猪本tick不再伤人。已queued incoming下tick提交，败优先、终局锁定。",
	"原攻击record寿命/timegate由两个AttackEvents拥有；当前pose接触，未实现武器/攻击胶囊连续扫掠。",
]

var player: HunterController
var monster: BulldromeController
var player_animator: HunterAnimator
var monster_animator: HunterAnimator
var player_lift: float = 0.0
var monster_lift: float = 0.0
var hunter_attack_events: AttackEvents = Events.new()
var monster_attack_events: AttackEvents = Events.new()
var _damage: HunterCombat = Combat.new()
var round_state: String = "running"
var ticks: int = 0
var events: Array[Dictionary] = []
var hunter_hits: int = 0
var monster_hits: int = 0
var total_monster_damage: int = 0
var last_monster_damage: int = 0
var round_generation: int = 0
var player_spawn := Vector3(0, 0, 250)
var monster_spawn := Vector3(0, 0, -350)
var limits: Array = LIMITS.duplicate()
var _ready: bool = false
var _incoming_queued: bool = false
var _queued_source: Dictionary = {}

func configure(p: HunterController, m: BulldromeController, pa: HunterAnimator, ma: HunterAnimator, pl: float, ml: float) -> bool:
	_ready = false
	if p == null or m == null or pa == null or ma == null or p.animator != pa or m.animator != ma or not is_finite(pl) or not is_finite(ml):
		return false
	if not p.state.get("ready", false) or not m.state.get("ready", false) or pa.world_pose.size() <= 20 or ma.world_pose.size() <= 2:
		return false
	if not pa.data.get("combat") is Dictionary or not ma.data.get("combat") is Dictionary:
		return false
	if not hunter_attack_events.configure(pa.data.combat, "hunter") or not monster_attack_events.configure(ma.data.combat, "shell24") or not _damage.configure(pa.data.combat):
		return false
	for record_id in [2, 4, 5]:
		if not monster_attack_events.read_record(record_id).has("byte2_raw"):
			return false
	player = p
	monster = m
	player_animator = pa
	monster_animator = ma
	player_lift = pl
	monster_lift = ml
	_ready = true
	reset()
	return player.state.ready and monster.state.ready

func reset() -> void:
	if not _ready:
		return
	player.reset()
	monster.reset(monster_spawn)
	player.state.position = player_spawn
	player.state.yaw = 32768
	player.state.target = 32768
	hunter_attack_events.reset()
	monster_attack_events.reset()
	_damage.reset()
	round_generation += 1
	round_state = "running"
	ticks = 0
	events.clear()
	hunter_hits = 0
	monster_hits = 0
	total_monster_damage = 0
	last_monster_damage = 0
	_incoming_queued = false
	_queued_source.clear()

func tick(input_snapshot: Dictionary) -> Dictionary:
	events.clear()
	if not _ready:
		return {"ready":false, "round_state":round_state, "events":[], "limits":limits.duplicate()}
	var old_player: Vector3 = player.state.position
	var old_monster: Vector3 = monster.state.position
	var active: bool = round_state == "running"
	# 单目标狩猎的危险来源适配；原多怪物筛选未闭合，不再依赖手动夹具。
	player.danger_enabled = active and monster.state.alive and monster.ai_enabled
	player.danger_yaw = _yaw(player.state.position, monster.state.position)
	var p: Dictionary = player.tick(int(input_snapshot.get("held", 0)) if active else 0, int(input_snapshot.get("mag", 0)) if active else 0, int(input_snapshot.get("direction", 0)), int(input_snapshot.get("bits", 0)) if active else 0)
	# Invalid input does not advance either paired producer/engine or discard pending incoming.
	if p.has("error"):
		return {"ready":true, "error":p.error, "round_state":round_state, "ticks":ticks, "events":[], "limits":limits.duplicate()}
	_incoming_queued = false
	_append_actor_events(p.get("events", []), "hunter")
	_queued_source.clear()
	var target: Dictionary = p.duplicate(true)
	target.alive = active and int(p.hp) > 0
	var notification: Dictionary = monster.tick(target)
	var m: Dictionary = notification.state
	m.events = notification.events
	_append_actor_events(notification.events, "bulldrome")
	var space: Dictionary = _resolve_space(old_player, old_monster)
	p.position = player.state.position
	m.position = monster.state.position
	p.alive = active and int(p.hp) > 0
	m.alive = active and bool(monster.state.alive)
	# Selected records 2/4/5 have source selectors 1/3/4. Unknown selector0/2
	# applicability is deliberately omitted: AttackEvents must not treat it as aligned.
	var monster_targets: Array[Dictionary] = [{"identity":"bulldrome", "generation":round_generation, "eligible":m.alive, "volumes":_monster_volumes(m)}]
	for contact in hunter_attack_events.tick(p, player_animator, player_lift, monster_targets):
		if not monster.state.alive:
			break
		last_monster_damage = _damage.damage_for(int(contact.record), int(contact.attack_scale))
		var applied: int = mini(int(monster.state.hp), last_monster_damage)
		monster.take_damage(last_monster_damage, _yaw(monster.state.position, player.state.position))
		hunter_hits += 1
		total_monster_damage += applied
		var hit: Dictionary = contact.duplicate(true)
		hit.merge({"event":"monster_damage", "damage":last_monster_damage, "applied_damage":applied, "hp":monster.state.hp}, true)
		events.append(hit)
	m.alive = active and bool(monster.state.alive)
	var eligible: bool = p.alive and player.attack_collision_allowed()
	var unsupported_air: bool = eligible and int(player.state.air280) != 0
	if unsupported_air:
		events.append({"event":"incoming_not_ready", "reason":"selected ground kind0 only; unknown airborne incoming", "air280":player.state.air280})
	var player_targets: Array[Dictionary] = [{"identity":"hunter", "generation":round_generation, "eligible":eligible and not unsupported_air, "volumes":_player_volumes(p)}]
	for contact in monster_attack_events.tick(m, monster_animator, monster_lift, player_targets):
		var impact: int = int(contact.byte2_raw)
		var queued: Dictionary = player.queue_incoming(20, impact, _yaw(monster.state.position, player.state.position))
		var hit: Dictionary = contact.duplicate(true)
		hit.merge({"event":"incoming_contact", "damage":20, "impact":impact, "status":queued.status, "impact_policy":"byte2_raw sandbox adaptation, not full defense formula"}, true)
		events.append(hit)
		if queued.status in ["pending", "guarded"] and not queued.get("duplicate", false):
			monster_hits += 1
			_incoming_queued = true
			_queued_source = contact.duplicate(true)
			_queued_source.contact_tick = ticks + 1
	ticks += 1
	if round_state == "running":
		if int(player.state.hp) <= 0:
			_finish("defeat")
		elif not monster.state.alive and not _incoming_queued:
			_finish("victory")
	return {"ready":true, "player":player.state.duplicate(true), "monster":monster.state.duplicate(true), "events":events.duplicate(true), "ticks":ticks, "round_state":round_state, "round_generation":round_generation, "hunter_hits":hunter_hits, "monster_hits":monster_hits, "last_monster_damage":last_monster_damage, "total_monster_damage":total_monster_damage, "space":space, "limits":limits.duplicate()}

func _append_actor_events(source: Array, actor: String) -> void:
	for value in source:
		var event: Dictionary = value.duplicate(true)
		event.actor = actor
		if actor == "hunter" and event.event in ["player_damage", "player_guard", "player_dead"] and not _queued_source.is_empty():
			event.incoming_source = _queued_source.duplicate(true)
		events.append(event)

func _finish(outcome: String) -> void:
	round_state = outcome
	events.append({"event":"round_end", "outcome":outcome, "priority":"defeat before victory; terminal latched"})

static func _yaw(from: Vector3, to: Vector3) -> int:
	var delta: Vector3 = to - from
	return int(round(atan2(delta.x, delta.z) * 65536.0 / TAU)) & 65535

func _monster_volumes(actor: Dictionary) -> Array[Dictionary]:
	var bone: Transform3D = monster_animator.world_pose[2]
	return [{"kind":"capsule", "a":Events.world_point(bone * Vector3(0, 0, -50), actor, monster_lift), "b":Events.world_point(bone * Vector3(0, 0, 70), actor, monster_lift), "radius":0.65}]

func _player_volumes(actor: Dictionary) -> Array[Dictionary]:
	return [{"kind":"sphere", "a":Events.world_point(player_animator.world_pose[10].origin, actor, player_lift), "radius":0.4}, {"kind":"sphere", "a":Events.world_point(player_animator.world_pose[20].origin, actor, player_lift), "radius":0.25}]

static func _xz(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)

static func _bounded(point: Vector2, radius: float) -> Vector2:
	var bound: float = ARENA_HALF - radius
	return point.clamp(Vector2(-bound, -bound), Vector2(bound, bound))

func _resolve_space(previous_player: Vector3, previous_monster: Vector3) -> Dictionary:
	var p: Vector2 = _bounded(_xz(player.state.position), HUNTER_RADIUS)
	var m: Vector2 = _bounded(_xz(monster.state.position), MONSTER_RADIUS)
	var wall: bool = not m.is_equal_approx(_xz(monster.state.position))
	var grounded: bool = float(player.state.position.y) - float(player.state.floor_height) <= MONSTER_RADIUS
	var swept: bool = false
	var blocked: bool = false
	var toi: float = 1.0
	if grounded:
		var p0: Vector2 = _bounded(_xz(previous_player), HUNTER_RADIUS)
		var m0: Vector2 = _bounded(_xz(previous_monster), MONSTER_RADIUS)
		var offset: Vector2 = p0 - m0
		var dp: Vector2 = p - p0
		var dm: Vector2 = m - m0
		var relative: Vector2 = dp - dm
		var a: float = relative.length_squared()
		var b: float = 2.0 * offset.dot(relative)
		var c: float = offset.length_squared() - BODY_DISTANCE * BODY_DISTANCE
		var discriminant: float = b * b - 4.0 * a * c
		if a > 0.000001 and c >= -0.001 and b < 0.0 and discriminant >= 0.0:
			toi = (-b - sqrt(discriminant)) / (2.0 * a)
			if toi >= 0.0 and toi < 1.0:
				var normal: Vector2 = (offset + relative * toi).normalized()
				var remaining_p: Vector2 = dp * (1.0 - toi)
				var remaining_m: Vector2 = dm * (1.0 - toi)
				var inward: float = minf(0.0, (remaining_p - remaining_m).dot(normal))
				p = p0 + dp * toi + remaining_p - normal * inward * 0.5
				m = m0 + dm * toi + remaining_m + normal * inward * 0.5
				swept = true
				blocked = true
		# Alternating circle/wall projections converge even against a wall/corner.
		for iteration in range(64):
			p = _bounded(p, HUNTER_RADIUS)
			m = _bounded(m, MONSTER_RADIUS)
			var delta: Vector2 = p - m
			var distance: float = delta.length()
			if distance >= BODY_DISTANCE - 0.00001:
				break
			var normal: Vector2 = delta / distance if distance > 0.00001 else Vector2.RIGHT
			var correction: Vector2 = normal * (BODY_DISTANCE - distance + 0.00001) * 0.5
			p += correction
			m -= correction
			blocked = true
	p = _bounded(p, HUNTER_RADIUS)
	m = _bounded(m, MONSTER_RADIUS)
	player.state.position = Vector3(p.x, player.state.position.y, p.y)
	monster.state.position = Vector3(m.x, monster.state.position.y, m.y)
	if wall or blocked:
		monster.stop_charge()
	return {"grounded_body":grounded, "swept":swept, "toi":toi, "blocked":blocked, "monster_wall":wall, "distance":p.distance_to(m), "minimum_distance":BODY_DISTANCE, "player_center_bound":ARENA_HALF-HUNTER_RADIUS, "monster_center_bound":ARENA_HALF-MONSTER_RADIUS}
