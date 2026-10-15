class_name BulldromeController
extends RefCounted

# type68 / 包6127；原执行链与沙盒决策分开，不复刻未闭合的37行通用AI。
const REQUIRED_CLIPS = [1001, 1015, 1016, 1018, 1019, 1020, 1024, 1060, 1061, 1062, 1063, 1064, 1066, 1067]
const PREPARE_TICKS = 18
const COOLDOWN_TICKS = 30
const APPROACH_SPEED = 18.0
const DECISION_DISTANCE = 650.0
const SOURCE_LABELS = {
	"identity": "原type68 / runtime包6127，非Em07",
	"decision": "显式沙盒：单目标距离/方位，预备18tick、收招后冷却30tick、普通接近18原单位/tick",
	"charge": "09b58328 + 09b59d88 + 09ad4cd8：1015 B10，selector3/4→record4/5，root Z距离预算+300、90tick、追向0x40，1016 B10 END→0/1",
	"turn_attack": "09b59ed8：相对yaw象限选择1018/1019，record2，±230；phase>=60；142<=phase<164时±860/2350；END→0/1",
	"reaction": "09b5a180 / 09b58840 / 09b5a278：方向选1060/61/1020、1062/67→1063→150tick→1066 END",
	"death": "09b5a8e0：倒地→1063 END→1064；沙盒保留尸体，取消原消失/销毁",
	"rage": "原阈值100、计数1800、float32 0x3f8ccccd；damage累计入口为沙盒",
	"movement": "1024原09b59a30 local80生产仅作来源对照；普通接近采用沙盒18，不把80挪用到冲撞",
}
const LIMITS = [
	"通用选招/RNG、目标仲裁、特殊mod分支未闭合，不实现、不宣称原AI等价。",
	"30 simulation Hz、基础动画step2、普通接近角速0x400与距离650为项目沙盒选择；原计数不是秒。",
	"接触damage累计120轻硬直/250倒地，恢复中不重复排反应，HP1000为抗stunlock沙盒，不是原伤害仲裁。",
	"倒地phase>=10后等待倒地clip END作为平地落稳资格，未复刻09b58678动力/VFPU及09acfe98地形helper。",
	"root由HunterAnimator唯一采样，entity旋转加一次；单位不缩放；未添加冲撞速度补偿，不声明PSP数值等价。",
	"冲撞目标按攻击入口快照保留；root距离预算复用当tick唯一样本，达到距离后的收招在下一tick，无额外helper重采样。",
	"攻击通知仅保留source record身份；不解读byte2_raw为power，不计算猎人HP；原攻击寿命/接触由session中的AttackEvents拥有。",
	"主场景显式开启原创沙盒特殊招式：两次原招后激光/臭屁；特殊招式独占SandboxSpecial，以待机pose显示，不声明原特殊动画/规则。臭屁选招接近距离260。",
]

const Special = preload("res://scripts/sandbox_special.gd")
var sandbox_special = Special.new()
var sandbox_specials_enabled: bool = false
var _sandbox_decision: int = 0
var animator: HunterAnimator
var state: Dictionary = {}
var ai_enabled: bool = true
var _attack_id: int = 0
var _charge_variant: int = 0
var _pending_reaction: String = ""
var _source_yaw: int = 0
var _light_damage: int = 0
var _down_damage: int = 0
var _rage_damage: int = 0
var _stop_requested: bool = false
var _spawned: bool = false
var _events: Array = []
var _configured: bool = false

func configure(value: HunterAnimator) -> bool:
	animator = value
	var valid: bool = animator != null and int(animator.data.get("body_pack", -1)) == 6127
	if valid:
		valid = int(animator.data.get("track_count", 0)) == 1 and int(animator.data.get("clip_id_stride", 0)) == 200 and int(animator.data.get("root_bone", -1)) == 1
	if valid:
		for primary in REQUIRED_CLIPS:
			if not animator.data.clips.has("%d:0" % primary):
				valid = false
	_configured = valid
	reset()
	return state.ready

func reset(position: Vector3 = Vector3(0, 0, -500)) -> void:
	sandbox_special.reset()
	_sandbox_decision = 0
	_pending_reaction = ""
	_source_yaw = 0
	_light_damage = 0
	_down_damage = 0
	_rage_damage = 0
	_stop_requested = false
	_spawned = false
	_charge_variant = 0
	_events = []
	state = {"position":position, "yaw":0, "primary":1001, "frames":[0.0],
		"hp":1000, "hp_max":1000, "alive":true, "mode":"idle", "phase":0,
		"ticks":0, "ready":false, "rate":1.0, "playback_step":2.0,
		"attack_budget":0, "remaining_distance":0.0, "attack_id":_attack_id,
		"main":0, "sub":1, "blend":0, "start":0, "prepare_ticks":0,
		"cooldown_ticks":0, "recovery_ticks":0, "rage_ticks":0, "quadrant":0,
		"target_position":Vector3.ZERO, "events":[], "source_labels":SOURCE_LABELS.duplicate(true),
		"limits":LIMITS.duplicate(), "policy":"explicit_sandbox", "root_delta":Vector3.ZERO,
		"world_root_delta":Vector3.ZERO, "approach_delta":Vector3.ZERO, "special":sandbox_special.snapshot()}
	if _configured:
		state.ready = animator.set_animation(1001, 0, 0)

# 接触阶段只提交HP/排队；不改当次动画、pose或位置。
func take_damage(damage: int, source_yaw: int) -> void:
	if state.is_empty() or not state.ready or not state.alive or damage <= 0:
		return
	state.hp = maxi(0, int(state.hp) - damage)
	_source_yaw = source_yaw & 65535
	_light_damage += damage
	_down_damage += damage
	_rage_damage += damage
	if state.hp == 0:
		state.alive = false
		_pending_reaction = "death"
	elif state.mode not in ["hit", "down", "dying", "dead"]:
		if _down_damage >= 250:
			_pending_reaction = "down"
		elif _light_damage >= 120 and _pending_reaction != "down":
			_pending_reaction = "hit"

# 空间owner在采样后通知；下一tick才改收招动画。
func stop_charge() -> void:
	if state.get("mode", "") == "charge" and int(state.phase) < 3:
		state.attack_budget = 0
		_stop_requested = true

func tick(player_snapshot: Dictionary) -> Dictionary:
	_events = []
	if state.is_empty() or not state.ready:
		return {"state":state.duplicate(true), "events":[], "animator_ticks":0}
	state.ticks += 1
	state.root_delta = Vector3.ZERO
	state.world_root_delta = Vector3.ZERO
	state.approach_delta = Vector3.ZERO
	_update_rage()
	if _pending_reaction != "":
		_begin_reaction()
	else:
		var recovering: bool = state.mode in ["hit", "down", "dying", "dead"]
		var player_alive: bool = int(player_snapshot.get("hp", 0)) > 0 and bool(player_snapshot.get("alive", true))
		if not recovering and (not ai_enabled or not player_alive):
			if state.mode != "idle" or state.primary != 1001:
				_idle(0, 0)
		elif recovering:
			_recovery_tick()
		elif state.mode == "special":
			sandbox_special.tick()
			if sandbox_special.kind == "":
				_idle()
		elif state.mode == "charge":
			_charge_tick()
		elif state.mode == "turn_attack":
			_turn_attack_tick()
		else:
			_decide(player_snapshot)
	var frozen: bool = state.mode in ["dead", "special"] or (state.mode == "idle" and (not ai_enabled or int(player_snapshot.get("hp", 0)) <= 0 or not bool(player_snapshot.get("alive", true))))
	state.playback_step = 0.0 if frozen else 2.0 * float(state.rate)
	# 每simulation调用唯一次tick；root已从world_pose清除，不在view再积分。
	var sample: Dictionary = animator.tick(float(state.playback_step))
	var local: Vector3 = sample.get("root_delta", Vector3.ZERO)
	var world: Vector3 = _rotate(local)
	state.position += world
	state.root_delta = local
	state.world_root_delta = world
	state.frames = sample.get("frames", []).duplicate()
	if state.mode == "charge" and int(state.phase) == 2:
		# 原helper在更新路径读local root Z；这里复用唯一采样结果，不再次抽样。
		state.remaining_distance -= local.z
	state.special = sandbox_special.snapshot()
	state.events = _events.duplicate(true)
	return {"state":state.duplicate(true), "events":_events.duplicate(true),
		"root_delta":local, "world_root_delta":world, "frames":state.frames.duplicate(), "animator_ticks":1}

func _animation(primary: int, blend: int = 0, start: int = 0) -> void:
	state.primary = primary
	state.blend = blend
	state.start = start
	state.ready = animator.set_animation(primary, blend, start)

func _rotate(local: Vector3) -> Vector3:
	return Basis(Vector3.UP, float(state.yaw) * TAU / 65536.0) * local

func _target_yaw(point: Vector3) -> int:
	var delta: Vector3 = point - state.position
	return int(round(atan2(delta.x, delta.z) * 65536.0 / TAU)) & 65535

func _yaw_towards(target: int, limit: int) -> void:
	var delta: int = ((target - int(state.yaw) + 32768) & 65535) - 32768
	state.yaw = (int(state.yaw) + clampi(delta, -limit, limit)) & 65535

func _idle(cooldown: int = COOLDOWN_TICKS, blend: int = 10) -> void:
	sandbox_special.reset()
	state.mode = "idle"
	state.main = 0
	state.sub = 1
	state.phase = 0
	state.cooldown_ticks = cooldown
	state.attack_budget = 0
	state.prepare_ticks = 0
	_stop_requested = false
	_spawned = false
	_animation(1001, blend)

func _decide(player: Dictionary) -> void:
	if state.cooldown_ticks > 0:
		state.cooldown_ticks -= 1
		return
	if not player.get("position") is Vector3:
		if state.mode != "idle":
			_idle(0, 0)
		return
	var target: Vector3 = player.position
	var offset: Vector3 = target - state.position
	offset.y = 0
	if state.mode == "prepare":
		state.prepare_ticks -= 1
		if state.prepare_ticks <= 0:
			if sandbox_specials_enabled and _sandbox_decision % 4 >= 2:
				begin_special("laser" if _sandbox_decision % 4 == 2 else "stink", target)
			else:
				_begin_attack(target)
			_sandbox_decision += 1
		return
	var decision_distance: float = 260.0 if sandbox_specials_enabled and _sandbox_decision % 4 == 3 else DECISION_DISTANCE
	if offset.length() > decision_distance:
		if state.mode != "approach":
			state.mode = "approach"
			state.main = 2
			state.sub = 2
			state.phase = 1
			_animation(1024)
		_yaw_towards(_target_yaw(target), 0x400)
		state.approach_delta = _rotate(Vector3(0, 0, minf(APPROACH_SPEED, offset.length() - decision_distance)))
		state.position += state.approach_delta
	else:
		state.mode = "prepare"
		state.main = 0
		state.sub = 1
		state.phase = 0
		state.prepare_ticks = PREPARE_TICKS
		_animation(1001, 10)

# 原创沙盒招式：只复用待机pose，不冒称原攻击动画或来源record。
func begin_special(move: String, target: Vector3) -> bool:
	if not state.get("ready",false) or not state.alive or state.mode in ["hit","down","dying","dead"] or not Special.MOVES.has(move):
		return false
	var facing: int = (_target_yaw(target)+(32768 if move == "stink" else 0)) & 65535
	if not sandbox_special.begin(move,state.position,facing):
		return false
	state.mode = "special"
	state.yaw = facing
	state.attack_budget = 0
	state.prepare_ticks = 0
	_spawned = false
	_animation(1001)
	state.special = sandbox_special.snapshot()
	_events.append({"event":"sandbox_special_begin","special":move,"attack_id":sandbox_special.attack_id,"policy":"original_sandbox_move"})
	return true

func _begin_attack(target: Vector3) -> void:
	state.target_position = target
	var relative: int = (_target_yaw(target) - int(state.yaw)) & 65535
	_spawned = false
	_stop_requested = false
	state.main = 3
	state.phase = 1
	if relative >= 0x2000 and relative < 0xe000:
		state.mode = "turn_attack"
		state.sub = 6
		state.quadrant = [0, 2, 3, 1][relative >> 14]
		_animation(1018 + (int(state.quadrant) & 1))
	else:
		state.mode = "charge"
		state.sub = _charge_variant
		_charge_variant = 1 - _charge_variant
		state.attack_budget = 90
		var offset: Vector3 = target - state.position
		offset.y = 0
		state.remaining_distance = offset.length() + 300.0
		_animation(1015, 10)

func _spawn(record: int) -> void:
	if _spawned or not state.alive:
		return
	_spawned = true
	_attack_id += 1
	state.attack_id = _attack_id
	_events.append({"event":"attack_spawn", "record":record, "primary":int(state.primary),
		"start":int(state.start), "blend_count":int(state.blend), "attack_scale":100, "attack_id":_attack_id})

func _charge_tick() -> void:
	if state.phase == 3:
		if animator.animation_ended():
			_idle()
		return
	if _stop_requested or state.attack_budget <= 0:
		state.phase = 3
		_stop_requested = false
		_animation(1016, 10)
		return
	if state.phase == 1:
		_spawn(4 + int(state.sub))
		state.phase = 2
	_yaw_towards(_target_yaw(state.target_position), 0x40)
	if state.remaining_distance <= 0.0:
		state.attack_budget = 1
	state.attack_budget -= 1
	if state.attack_budget <= 0:
		state.phase = 3
		_animation(1016, 10)

func _turn_attack_tick() -> void:
	var direction: int = -1 if int(state.quadrant) & 1 else 1
	if state.phase == 1:
		_spawn(2)
		state.phase = 2
	if state.phase == 2:
		state.yaw = (int(state.yaw) + direction * 230) & 65535
		if animator.ge(60):
			state.phase = 3
	elif state.phase == 3:
		if animator.ge(142) and not animator.ge(164):
			state.yaw = (int(state.yaw) + direction * (2350 if int(state.quadrant) & 2 else 860)) & 65535
		if animator.animation_ended():
			_idle()

func _begin_reaction() -> void:
	sandbox_special.reset()
	var reaction: String = _pending_reaction
	_pending_reaction = ""
	state.attack_budget = 0
	state.prepare_ticks = 0
	_stop_requested = false
	_spawned = false
	state.phase = 1
	_light_damage = 0
	var relative: int = (_source_yaw - int(state.yaw)) & 65535
	if reaction == "hit":
		state.mode = "hit"
		state.main = 4
		state.sub = 0
		var primary: int = 1060 if relative < 0x8000 else 1061
		if relative > 0x6000 and relative <= 0x9fff:
			primary = 1020
		_animation(primary)
	else:
		_down_damage = 0
		state.mode = "dying" if reaction == "death" else "down"
		state.main = 5 if reaction == "death" else 4
		state.sub = 0 if reaction == "death" else 1
		_animation(1062 if relative < 0x8000 else 1067)
	_events.append({"event":"monster_reaction", "reaction":reaction, "primary":int(state.primary), "hp":int(state.hp)})

func _recovery_tick() -> void:
	if state.mode == "dead":
		return
	if state.mode == "hit":
		if animator.animation_ended():
			_idle()
		return
	if state.phase == 1:
		if animator.ge(10):
			state.phase = 2
	elif state.phase == 2:
		# 明示平地适配：动画落稳代替未闭合动力/地形资格；非原END门。
		if animator.animation_ended():
			state.phase = 3
			state.recovery_ticks = 150
			_animation(1063, 6)
	elif state.phase == 3:
		if state.mode == "dying":
			if animator.animation_ended():
				state.phase = 4
				_animation(1064)
		else:
			state.recovery_ticks -= 1
			if state.recovery_ticks <= 0:
				state.phase = 4
				_animation(1066, 6)
	elif state.phase == 4 and animator.animation_ended():
		if state.mode == "dying":
			state.mode = "dead"
			_events.append({"event":"monster_dead", "hp":0})
		else:
			_idle()

func _update_rage() -> void:
	if not state.alive:
		state.rage_ticks = 0
		state.rate = 1.0
		return
	if state.rage_ticks > 0:
		state.rage_ticks -= 1
	if state.rage_ticks == 0 and _rage_damage >= 100:
		_rage_damage = 0
		state.rage_ticks = 1800
		_events.append({"event":"monster_rage", "policy":"sandbox_damage_accumulation"})
	state.rate = 1.100000023841858 if state.rage_ticks > 0 else 1.0
