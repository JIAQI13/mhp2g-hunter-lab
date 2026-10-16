class_name BulldromeController
extends RefCounted

# type68 / 包6127；原执行链与沙盒决策分开，不复刻未闭合的37行通用AI。
const WALK_CLIP = 1003
const REQUIRED_CLIPS = [1001, WALK_CLIP, 1015, 1016, 1018, 1019, 1020, 1024, 1060, 1061, 1062, 1063, 1064, 1066, 1067]
const PREPARE_TICKS = 18
const COOLDOWN_TICKS = 30
const TURN_TICKS = 15
const MOVE_RECOVERY_TICKS = {"charge":30, "turn_attack":6, "laser":30, "stink":30, "tusk":24, "slam":30}
const SEEK_DEADLINE = 180
const ALIGN_TOLERANCE = 0x400
const APPROACH_SPEED = 18.0
const WALK_ACCELERATION = 3.0
const WALK_TURN_STEP = 0x800
var sandbox_motion_enabled: bool = true
var _walk_speed: float = 0.0
var _walk_requested: bool = false
var _special_move: String = ""
var _source_quadrant: int = 0
const DECISION_DISTANCE = 650.0
const LLM_RANGES = {"charge":DECISION_DISTANCE,"turn_attack":260.0,"laser":1100.0,"stink":260.0,"tusk":750.0,"slam":450.0}
const TUSK_MIN_RANGE = 300.0
const TUSK_REPOSITION_RANGE = 400.0
var _retreating: bool = false
var _slam_ready_tick: int = 0
var _slam_cancel_reported: bool = false
var _plan_ttl: int = 360

# The executor owns the advertised/approved move menu, shared by policy and LLM.
const MOVE_MENU = {
	"charge":{"use":"medium-range closing and space pressure","avoid":"lateral target can sidestep; miss leaves recovery","telegraph":"prepare18 then source charge and END","range":LLM_RANGES.charge,"prepare_ticks":PREPARE_TICKS,"recovery":"source 1016 END","gap_ticks":MOVE_RECOVERY_TICKS.charge},
	"turn_attack":{"use":"close side/rear target: correct facing and damage together","avoid":"not long-range closing or harmless facing","telegraph":"prepare18 then locked shortest arc15; record2 damage","range":LLM_RANGES.turn_attack,"prepare_ticks":PREPARE_TICKS,"turn_ticks":TURN_TICKS,"gap_ticks":MOVE_RECOVERY_TICKS.turn_attack},
	"laser":{"use":"medium/far straight line; stationary weapon action or guard","avoid":"lateral/evading target; avoid repeated ranged spam","telegraph":"prepare18, windup36 then instant fixed line length1000 radius35","range":LLM_RANGES.laser,"prepare_turn_ticks":PREPARE_TICKS,"windup_ticks":Special.MOVES.laser.windup,"recovery_ticks":Special.MOVES.laser.recovery,"gap_ticks":MOVE_RECOVERY_TICKS.laser},
	"stink":{"use":"close exclusion, especially hugging rear","avoid":"far target: walk closer before turning rear; never teleport","telegraph":"prepare18, windup30 then fixed rear100 radius220","range":LLM_RANGES.stink,"prepare_turn_ticks":PREPARE_TICKS,"windup_ticks":Special.MOVES.stink.windup,"recovery_ticks":Special.MOVES.stink.recovery,"gap_ticks":MOVE_RECOVERY_TICKS.stink},
	"tusk":{"use":"front medium range; finite traveling pressure while hunter keeps moving, unlike instant beam","avoid":"point blank, lateral/evading target; do not spam consecutive ranged moves","telegraph":"prepare18 then mouth charge30; one visible nonhoming tusk with locked launch yaw","range":LLM_RANGES.tusk,"min_range":TUSK_MIN_RANGE,"prepare_turn_ticks":PREPARE_TICKS,"windup_ticks":Special.MOVES.tusk.windup,"speed_per_tick":Special.MOVES.tusk.speed*100,"projectile_range":Special.MOVES.tusk.range*100,"ttl_ticks":Special.MOVES.tusk.ttl,"damage":Special.MOVES.tusk.damage,"recovery_ticks":Special.MOVES.tusk.recovery,"gap_ticks":MOVE_RECOVERY_TICKS.tusk},
	"slam":{"use":"helicopter_slam: close/medium area pressure against stationary weapon actions","avoid":"long telegraph; hunter can leave locked ring; only when ready, not every move","telegraph":"prepare18, spin charge30, rise45 to height500, hover24; track <=8/tick and total200, lock ring24, vertical drop10, impact6, punish recovery60","range":LLM_RANGES.slam,"prepare_ticks":PREPARE_TICKS,"parameters":Special.SLAM,"gap_ticks":MOVE_RECOVERY_TICKS.slam},
}
const SOURCE_LABELS = {
	"identity": "原type68 / runtime包6127，非Em07",
	"decision": "显式沙盒：共享当前观测→reacquire/reposition→ready→前摇18→commit；release刷新追踪意图不改已承诺几何；必要收招后冷却可走（转向6/牙弹24/其余30tick），无observe空等；前进最高18原单位/tick",
	"charge": "09b58328 + 09b59d88 + 09ad4cd8：1015 B10，selector3/4→record4/5，root Z距离预算+300、90tick、追向0x40，1016 B10 END→0/1",
	"turn_attack": "来源09b59ed8的1018/1019与record2；沙盒改为15tick最短角对准入口yaw并显式终止攻击，无原±230/晚段860/2350/END后摇，不声明原作等价",
	"reaction": "09b5a180 / 09b58840 / 09b5a278：方向选1060/61/1020、1062/67→1063→150tick→1066 END",
	"death": "09b5a8e0：倒地→1063 END→1064；沙盒保留尸体，取消原消失/销毁",
	"rage": "原阈值100、计数1800、float32 0x3f8ccccd；damage累计入口为沙盒",
	"movement": "1024原09b59a30 local80生产仅作来源对照；默认沙盒用地面循环1003（1024是bone2地下固定pose，不当步行）前进最高18、加减速3/tick、角速0x800，无侧滑；非冲撞/反应不积分clip残留root；source模式保持旧root积分，冲撞root预算不改",
	"special_preparation": "共享reacquire当前目标、臭屁尾向/转向攻击保留近侧方；limited yaw后ready才前摇18tick；空间修正后begin固定几何或牙弹方向，release追踪意图不改激光云/牙弹轨迹",
	"source_mode": "sandbox_motion_enabled=false仅保留已核实来源动作执行：turn phase2 ±230、142..164 ±860/2350、完整END；不执行原创激光/臭屁/猪牙/螺旋砸地，选招仍沙盒，非原通用AI",
	"helicopter_slam": "原创平地30Hz沙盒，enum slam；实体位置/yaw与hurtbox同一轨迹，无render_offset；prepare18→蓄力30→升空45/5m→高空24→锁圈24→垂直下降10→落地冲击6/25→恢复60；空中追踪8原单位/tick、总200，发招间隔360；正常反应/关闭先无伤连续下降25原单位/tick，落地后原反应，仅明确整局reset可重定位。低于120累计伤害不触发反应，仍可命中空中hurtbox。",
}
const LIMITS = [
	"通用选招/RNG、目标仲裁、特殊mod分支未闭合，不实现、不宣称原AI等价。",
	"30 simulation Hz、基础动画step2、沙盒普通步行角速0x800（source模式0x400）与距离650为项目沙盒选择；原计数不是秒。",
	"接触damage累计120轻硬直/250倒地，恢复中不重复排反应，HP1000为抗stunlock沙盒，不是原伤害仲裁。",
	"倒地phase>=10后等待倒地clip END作为平地落稳资格，未复刻09b58678动力/VFPU及09acfe98地形helper。",
	"root由HunterAnimator唯一采样，entity旋转加一次；单位不缩放；未添加冲撞速度补偿，不声明PSP数值等价。",
	"冲撞目标按攻击入口快照保留；root距离预算复用当tick唯一样本，达到距离后的收招在下一tick，无额外helper重采样。",
	"攻击通知仅保留source record身份；不解读byte2_raw为power，不计算猎人HP；原攻击寿命/接触由session中的AttackEvents拥有。",
	"主场景启用原创特殊；fallback独立按距离/方位/可观察当前动作与最近4招有界权重选招，非固定序列、非LLM。合法模型plan只按原顺序执行，特殊独占SandboxSpecial，臭屁远处先接近260。",
]

const Special = preload("res://scripts/sandbox_special.gd")
var sandbox_special = Special.new()
var sandbox_specials_enabled: bool = false
const Policy = preload("res://scripts/sandbox_tactics.gd")
var tactics = Policy.new()
var _next_step: Dictionary = {}
var _seek_age: int = 0
var _circle_age: int = 0
var _reposition_destination: Variant = null
var _blocked_ticks: int = 0
var _escape_side: int = 1
var _movement_bound: float = INF
var decision_source: String = "fallback"
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
var llm_pending: bool = false
var llm_plan: Array = []
var llm_selection: String = "规则"
var _llm_age: int = 0
var _plan_decision_id: int = -1


func cancel_llm_plan() -> void:
	llm_pending = false
	_retreating = false
	llm_plan.clear()
	_plan_decision_id = -1
	_circle_age = 0
	_reposition_destination = null
	llm_selection = "规则"
	decision_source = "fallback"
	_next_step.clear()
	if state.get("mode","") == "prepare" and sandbox_motion_enabled:
		state.mode = "reacquire"
		state.prepare_ticks = 0

func accept_llm_plan(plan: Array, decision_id: int = -1) -> bool:
	if not can_accept_plan() or plan.is_empty() or plan.size() > 2:
		return false
	for step in plan:
		if not step is Dictionary or not MOVE_MENU.has(step.get("move","")) or not step.get("tactic","") in ["observe","approach","circle_left","circle_right"] or (Special.MOVES.has(step.move) and not sandbox_specials_enabled):
			return false
	var slams: int = 0
	for step in plan:
		if step.move == "slam":
			slams += 1
	if slams > 1 or (slams == 1 and not slam_available()):
		return false
	cancel_llm_plan()
	_plan_ttl = 600 if slams == 1 else 360
	llm_plan = plan.duplicate(true)
	_plan_decision_id = decision_id
	_next_step.clear()
	decision_source = "llm"
	_llm_age = 0
	_reacquire()
	return true

func decision_moves() -> Dictionary:
	var menu: Dictionary = {}
	for move in MOVE_MENU:
		if (Special.MOVES.has(move) and not sandbox_specials_enabled) or (move == "slam" and not slam_available()):
			continue
		var source: Dictionary = MOVE_MENU[move]
		menu[move] = {"use":source.use,"avoid":source.avoid,"range":source.range}
		if source.has("min_range"):
			menu[move].min_range = source.min_range
	return menu

func slam_available() -> bool:
	return sandbox_motion_enabled and sandbox_specials_enabled and int(state.get("ticks",0)) >= _slam_ready_tick

func can_accept_plan() -> bool:
	return sandbox_motion_enabled and ai_enabled and bool(state.get("alive",false)) and bool(state.get("ready",false)) and state.get("mode","") in ["idle","approach","move_recovery","reacquire"]

func _observe_target(player: Dictionary) -> void:
	var valid: bool = player.get("position") is Vector3 and bool(player.get("alive",true)) and int(player.get("hp",0)) > 0 and ai_enabled and state.alive
	state.observed_target = player.position if valid else null
	if valid:
		state.observed_target_yaw = _target_yaw(player.position)
	state.tracking_stage = "reacquire_after_release" if state.released else "reacquire"
	if not valid or state.mode in ["hit","down","dying","dead"]:
		state.tracking_stage = "cancelled"
	elif sandbox_special.kind == "slam" and sandbox_special.stage in ["windup","ascent","hover"]:
		state.tracking_stage = "bounded_air_tracking_until_lock"
	elif state.mode in ["charge","turn_attack","special","special_commit"]:
		state.tracking_stage = "release_intent_locked" if state.released else "committed_locked"

func _lock_target(target: Vector3) -> void:
	state.committed_target = target
	state.committed_source = decision_source
	state.committed_decision_id = _plan_decision_id if decision_source == "llm" and _plan_decision_id >= 0 else null
	state.released = false
	state.tracking_stage = "committed_locked"

func _release(move: String) -> void:
	state.released = true
	state.tracking_stage = "release_intent_locked"
	_events.append({"event":"move_release","move":move,"tick":state.ticks,"decision_source":state.committed_source,"decision_id":state.committed_decision_id,"observed_target":state.observed_target,"committed_target":state.committed_target,"tracking_stage":state.tracking_stage})

func _progress(reason: String) -> void:
	if state.get("progress_reason","") == reason:
		return
	state.progress_reason = reason
	_events.append({"event":"move_progress","reason":reason,"mode":state.mode,"tick":state.ticks,"seek_age":_seek_age})

func _reacquire() -> void:
	state.mode = "reacquire"
	state.prepare_ticks = 0
	_seek_age = 0
	_circle_age = 0
	_reposition_destination = null
	_progress("reacquire")

func space_feedback(wall: bool, blocked: bool, previous: Vector3, movement_bound: float = INF) -> void:
	_movement_bound = movement_bound
	if wall or blocked:
		stop_charge()
	if state.mode in ["reacquire","move_recovery"]:
		_blocked_ticks = _blocked_ticks+1 if _walk_requested and state.position.distance_to(previous) < 1.0 else 0
		if wall:
			_escape_side = -1 if state.position.x+state.position.z > 0 else 1
		if _reposition_destination != null and (wall or _blocked_ticks >= 6):
			_reposition_destination = null

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
	cancel_llm_plan()
	sandbox_special.reset()
	_slam_ready_tick = 0
	_plan_ttl = 360
	_walk_speed = 0.0
	_seek_age = 0
	_blocked_ticks = 0
	_escape_side = 1
	_special_move = ""
	tactics.reset()
	_next_step.clear()
	decision_source = "fallback"
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
		"cooldown_ticks":0, "recovery_ticks":0, "rage_ticks":0,
		"turn_target_yaw":0, "turn_ticks":0, "turn_step":0,
		"committed_target":null, "committed_source":"fallback", "committed_decision_id":null, "observed_target":null,
		"observed_target_yaw":0, "tracking_stage":"unknown", "released":false, "decision_source":"fallback",
		"events":[], "source_labels":SOURCE_LABELS.duplicate(true),
		"limits":LIMITS.duplicate(), "policy":"explicit_sandbox", "root_delta":Vector3.ZERO,
		"world_root_delta":Vector3.ZERO, "approach_delta":Vector3.ZERO, "progress_reason":"idle", "special":sandbox_special.snapshot()}
	if _configured:
		state.ready = animator.set_animation(1001, 0, 0)

# 接触阶段只提交HP/排队；不改当次动画、pose或位置。
func take_damage(damage: int, source_yaw: int) -> void:
	if state.is_empty() or not state.ready or not state.alive or damage <= 0:
		return
	cancel_llm_plan()
	state.hp = maxi(0, int(state.hp) - damage)
	_source_yaw = source_yaw & 65535
	_light_damage += damage
	_down_damage += damage
	_rage_damage += damage
	if state.hp == 0:
		sandbox_special.cancel()
		state.special = sandbox_special.snapshot()
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
	state.motion_policy = "continuous_sandbox" if sandbox_motion_enabled else "verified_source_actions_sandbox_decision"
	if not sandbox_motion_enabled:
		cancel_llm_plan()
	if (not sandbox_motion_enabled or not sandbox_specials_enabled) and state.mode in ["special","special_commit"] and not sandbox_special.airborne():
		_idle(0)
	if not llm_plan.is_empty():
		_llm_age += 1
		if _llm_age > _plan_ttl:
			cancel_llm_plan()
	_observe_target(player_snapshot)
	state.root_delta = Vector3.ZERO
	state.world_root_delta = Vector3.ZERO
	state.approach_delta = Vector3.ZERO
	_walk_requested = false
	_update_rage()
	var player_valid: bool = int(player_snapshot.get("hp",0)) > 0 and bool(player_snapshot.get("alive",true))
	var safe_landing: bool = sandbox_special.airborne() and (_pending_reaction != "" or not ai_enabled or not player_valid or not sandbox_motion_enabled or not sandbox_specials_enabled or sandbox_special.cancelled)
	if safe_landing:
		if not _slam_cancel_reported:
			_events.append({"event":"move_cancelled","move":"slam","tick":state.ticks,"height":state.position.y,"reason":_pending_reaction if _pending_reaction != "" else "AI/target/mode disabled","policy":"continuous harmless landing before reaction","decision_source":state.committed_source,"decision_id":state.committed_decision_id})
			_slam_cancel_reported = true
		cancel_llm_plan()
		sandbox_special.cancel()
		_special_tick()
	elif _pending_reaction != "":
		_begin_reaction()
	else:
		var recovering: bool = state.mode in ["hit", "down", "dying", "dead"]
		var player_alive: bool = int(player_snapshot.get("hp", 0)) > 0 and bool(player_snapshot.get("alive", true))
		if not ai_enabled or not player_alive:
			cancel_llm_plan()
		if not recovering and (not ai_enabled or not player_alive):
			if state.mode != "idle" or state.primary != 1001:
				_idle(0, 0)
		elif recovering:
			_recovery_tick()
		elif state.mode == "special":
			_special_tick()
		elif state.mode == "charge":
			_charge_tick()
		elif state.mode == "turn_attack":
			_turn_attack_tick()
		else:
			_decide(player_snapshot)
	if sandbox_motion_enabled and not _walk_requested:
		if ai_enabled and bool(player_snapshot.get("alive",true)) and int(player_snapshot.get("hp",0)) > 0 and state.mode in ["idle","reacquire","prepare","move_recovery"]:
			_walk_speed = move_toward(_walk_speed,0.0,WALK_ACCELERATION)
			_apply_walk()
		else:
			_walk_speed = 0.0
	var frozen: bool = state.mode in ["dead", "special"] or (state.mode == "idle" and (not ai_enabled or int(player_snapshot.get("hp", 0)) <= 0 or not bool(player_snapshot.get("alive", true))))
	state.playback_step = 0.0 if frozen else 2.0 * float(state.rate)
	# 每simulation调用唯一次tick；root已从world_pose清除，不在view再积分。
	var sample: Dictionary = animator.tick(float(state.playback_step))
	var local: Vector3 = sample.get("root_delta", Vector3.ZERO)
	var world: Vector3 = _rotate(local)
	# 沙盒步行有自己的位移owner；待机/换clip残留root不能成为隐式传送。
	var applied: Vector3 = world if not safe_landing and state.mode != "special" and (not sandbox_motion_enabled or state.mode in ["charge","hit","down","dying"]) else Vector3.ZERO
	state.position += applied
	state.applied_root_delta = applied
	state.walk_speed = _walk_speed
	state.root_delta = local
	state.world_root_delta = world
	state.frames = sample.get("frames", []).duplicate()
	if state.mode == "charge":
		_progress("source_end" if state.phase == 3 else ("source_root" if local.length_squared() > 0.0001 else "source_windup"))
	elif state.mode == "special":
		_progress(str(sandbox_special.stage))
	elif state.mode == "turn_attack":
		_progress("committed_turn")
	if state.mode == "charge" and int(state.phase) == 2:
		# 原helper在更新路径读local root Z；这里复用唯一采样结果，不再次抽样。
		state.remaining_distance -= local.z
	state.special = sandbox_special.snapshot()
	state.decision_source = decision_source
	state.events = _events.duplicate(true)
	return {"state":state.duplicate(true), "events":_events.duplicate(true),
		"root_delta":local, "world_root_delta":world, "frames":state.frames.duplicate(), "animator_ticks":1}

func _special_tick() -> void:
	var move: String = sandbox_special.kind
	var stage: String = sandbox_special.stage
	var cancelled: bool = sandbox_special.cancelled
	sandbox_special.tick(state.observed_target)
	if move == "slam":
		state.position = sandbox_special.origin*100.0
		state.yaw = sandbox_special.yaw
		if sandbox_special.stage == "locked" and stage != "locked":
			_lock_target(sandbox_special.landing_point*100.0)
			_events.append({"event":"slam_lock","move":"slam","tick":state.ticks,"landing_point":state.committed_target,"warning_ticks":Special.SLAM.lock,"decision_source":state.committed_source,"decision_id":state.committed_decision_id})
		if sandbox_special.stage == "active" and stage != "active":
			_release(move)
	elif stage == "windup" and sandbox_special.stage == "active":
		_release(move)
	if sandbox_special.kind == "":
		if cancelled:
			state.position.y = 0.0
			_idle(0,0)
		else:
			_finish_move(move)

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

func _apply_walk() -> void:
	state.approach_delta = _rotate(Vector3(0,0,_walk_speed))
	state.position += state.approach_delta

func _walk_towards(point: Vector3, speed: float) -> void:
	_walk_requested = true
	var yaw: int = _target_yaw(point)
	_yaw_towards(yaw,WALK_TURN_STEP)
	var error: int = ((yaw-int(state.yaw)+32768)&65535)-32768
	var desired: float = minf(APPROACH_SPEED,speed)*maxf(0.0,cos(error*TAU/65536.0))
	_walk_speed = move_toward(_walk_speed,desired,WALK_ACCELERATION)
	# 1024 is a fixed two-frame underground pose (bone2 Y=-508.25), not grounded locomotion.
	if state.primary != WALK_CLIP:
		_animation(WALK_CLIP,6)
	_apply_walk()

func _end_turn_attack() -> void:
	if state.mode == "turn_attack" and _spawned:
		_events.append({"event":"attack_end", "attack_id":int(state.attack_id)})
	state.turn_ticks = 0

func _finish_move(move: String) -> void:
	_idle(int(MOVE_RECOVERY_TICKS[move]), 6 if move == "turn_attack" else 10)
	if sandbox_motion_enabled:
		state.mode = "move_recovery"
		state.tracking_stage = "reacquire_after_release"
		_progress("cooldown")
	_events.append({"event":"move_finished","move":move,"tick":state.ticks,"decision_source":state.committed_source,"decision_id":state.committed_decision_id,"observed_target":state.observed_target,"committed_target":state.committed_target,"recovery_ticks":state.cooldown_ticks})

func _idle(cooldown: int = COOLDOWN_TICKS, blend: int = 10) -> void:
	_end_turn_attack()
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

func _selected(step: Dictionary, source: String) -> void:
	decision_source = source
	llm_selection = step.tactic+" / "+step.move
	tactics.selected(step.move)
	_events.append({"event":"decision_selected","move":step.move,"tactic":step.tactic,"decision_source":source,"decision_id":_plan_decision_id if source == "llm" and _plan_decision_id >= 0 else null})

func _decide(player: Dictionary) -> void:
	if sandbox_motion_enabled:
		_seek_tick(player)
		return
	_source_decide(player)

func _source_decide(player: Dictionary) -> void:
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
			_begin_attack(target)
		return
	var decision_distance: float = DECISION_DISTANCE
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
		state.turn_target_yaw = _target_yaw(target)

		state.mode = "prepare"
		state.main = 0
		state.sub = 1
		state.phase = 0
		state.prepare_ticks = PREPARE_TICKS
		_animation(1001, 10)

func _move_facing(move: String, target_yaw: int) -> int:
	if move == "stink":
		return (target_yaw+32768)&65535
	if move == "turn_attack":
		var relative: int = ((target_yaw-int(state.yaw)+32768)&65535)-32768
		# Preserve a close side target for the damaging turn, not a redundant face command.
		return int(state.yaw) if absi(relative) <= 0x6000 else (target_yaw-signi(relative)*0x4000)&65535
	return target_yaw

func _reposition(target: Vector3, move: String, side: int) -> void:
	var offset: Vector3 = target-state.position
	offset.y = 0
	var radial: Vector3 = offset.normalized()
	if _reposition_destination == null:
		var radius: float = TUSK_REPOSITION_RANGE+50.0 if move == "tusk" else maxf(160.0,minf(400.0,float(LLM_RANGES[move])*0.7))
		var tangent: Vector3 = radial.cross(Vector3.UP)*side
		var destination: Vector3 = target-radial*radius+tangent*150.0
		destination.x = clampf(destination.x,-_movement_bound,_movement_bound)
		destination.z = clampf(destination.z,-_movement_bound,_movement_bound)
		if move == "tusk" and destination.distance_to(target) < TUSK_REPOSITION_RANGE:
			destination = target+tangent*radius
			destination.x = clampf(destination.x,-_movement_bound,_movement_bound)
			destination.z = clampf(destination.z,-_movement_bound,_movement_bound)
		_reposition_destination = destination
		if _blocked_ticks >= 6:
			_escape_side = -_escape_side
			_progress("blocked_reposition")
	_walk_towards(_reposition_destination,minf(12.0,state.position.distance_to(_reposition_destination)))

func _seek_tick(player: Dictionary) -> void:
	if state.observed_target == null:
		_progress("unknown_target")
		return
	var cooling: bool = state.cooldown_ticks > 0
	if cooling:
		state.cooldown_ticks -= 1
	if state.mode == "move_recovery" and not cooling:
		_reacquire()
	if state.mode not in ["reacquire","prepare","move_recovery"]:
		_reacquire()
	if not llm_pending:
		_seek_age += 1
	if _seek_age > SEEK_DEADLINE and not cooling and not llm_pending:
		cancel_llm_plan()
		_next_step = {"tactic":"approach","move":"laser" if sandbox_specials_enabled else "charge"}
		_selected(_next_step,"fallback")
		_seek_age = 0
		state.mode = "reacquire"
		_progress("unreachable_fallback_seek")
	var target: Vector3 = state.observed_target
	var offset: Vector3 = target-state.position
	offset.y = 0
	var target_yaw: int = state.observed_target_yaw
	var relative: int = ((target_yaw-int(state.yaw)+32768)&65535)-32768
	if llm_pending:
		state.tracking_stage = "pending_reposition"
		_progress("pending_reposition")
		if _reposition_destination != null and state.position.distance_to(_reposition_destination) < 12.0:
			_reposition_destination = null
		if offset.length() > DECISION_DISTANCE:
			_walk_towards(target,minf(APPROACH_SPEED,offset.length()-DECISION_DISTANCE))
		else:
			_reposition(target,"charge",_escape_side)
		return
	if _next_step.is_empty():
		_next_step = llm_plan[0].duplicate() if not llm_plan.is_empty() else tactics.choose(offset.length(),relative,str(player.get("observable_action","unknown")),sandbox_specials_enabled,LLM_RANGES,slam_available())
		_selected(_next_step,"llm" if not llm_plan.is_empty() else "fallback")
	var move: String = str(_next_step.get("move","charge"))
	var facing: int = _move_facing(move,target_yaw)
	if move == "tusk" and offset.length() < TUSK_MIN_RANGE:
		_retreating = true
	if _retreating and (move != "tusk" or offset.length() >= TUSK_REPOSITION_RANGE):
		_retreating = false
		_reposition_destination = null
	var too_close: bool = move == "tusk" and _retreating
	if too_close and _reposition_destination != null and state.position.distance_to(_reposition_destination) < 12.0:
		_reposition_destination = null
	var acquisition_range: float = float(LLM_RANGES[move])
	if move in ["turn_attack","stink"] and state.mode != "prepare":
		acquisition_range *= 0.7
	var distance_ok: bool = offset.length() <= acquisition_range and not too_close and (move != "slam" or slam_available())
	var error: int = ((facing-int(state.yaw)+32768)&65535)-32768
	state.tracking_stage = "cooldown_reposition" if cooling else "reacquire"
	if state.mode == "prepare":
		_yaw_towards(facing,WALK_TURN_STEP)
		if not distance_ok or absi(error) > WALK_TURN_STEP+ALIGN_TOLERANCE:
			state.mode = "reacquire"
			state.prepare_ticks = 0
			_progress("reacquire_target_moved")
			return
		state.prepare_ticks -= 1
		_progress("windup")
		state.tracking_stage = "prepare_current_target"
		if state.prepare_ticks <= 0 and _walk_speed == 0.0:
			_lock_target(target)
			if move == "slam":
				state.committed_target = null
				state.tracking_stage = "takeoff_ready_landing_uncommitted"
			_events.append({"event":"move_commit","move":move,"tick":state.ticks,"target":state.committed_target,"yaw":state.yaw,"decision_source":decision_source,"decision_id":state.committed_decision_id,"reason":"takeoff_ready_landing_uncommitted" if move == "slam" else "range_and_facing_ready","seek_age":_seek_age})
			if decision_source == "llm" and not llm_plan.is_empty():
				llm_plan.pop_front()
			_next_step.clear()
			_circle_age = 0
			_reposition_destination = null
			if Special.MOVES.has(move):
				_special_move = move
				state.mode = "special_commit"
			else:
				_begin_attack(target,move,target_yaw)
		return
	if not distance_ok:
		_progress("position")
		if too_close or _blocked_ticks >= 6:
			_reposition(target,move,_escape_side)
		else:
			_walk_towards(target,minf(APPROACH_SPEED,maxf(WALK_ACCELERATION,offset.length()-acquisition_range*0.7)))
		return
	var tactic: String = str(_next_step.get("tactic","observe"))
	var maneuver_ticks: int = 12 if tactic in ["circle_left","circle_right"] else 8
	if _circle_age < maneuver_ticks:
		_circle_age += 1
		_progress("cooldown_reposition" if cooling else "observe_reposition")
		_reposition(target,move,-1 if tactic == "circle_right" else 1)
		return
	_reposition_destination = null
	_yaw_towards(facing,WALK_TURN_STEP)
	if absi(error) > ALIGN_TOLERANCE or _walk_speed > 0:
		_progress("align")
		if state.primary != 1001:
			_animation(1001,6)
		return
	if cooling:
		_progress("cooldown_ready")
		return
	_progress("ready")
	state.mode = "prepare"
	state.prepare_ticks = PREPARE_TICKS
	_animation(1001,6)

# 原创沙盒招式：只复用待机pose，不冒称原攻击动画或来源record。
func begin_special(move: String, target: Vector3) -> bool:
	if not state.get("ready",false) or not state.alive or not can_accept_plan() or not sandbox_specials_enabled or not Special.MOVES.has(move) or (move == "slam" and not slam_available()):
		return false
	cancel_llm_plan()
	_next_step = {"move":move,"tactic":"approach"}
	_selected(_next_step,"explicit")
	_reacquire()
	state.observed_target = target
	state.observed_target_yaw = _target_yaw(target)
	return true

func commit_special() -> void:
	if state.mode != "special_commit":
		return
	if sandbox_special.begin(_special_move,state.position,int(state.yaw)):
		state.mode = "special"
		if _special_move == "slam":
			_slam_cancel_reported = false
			_slam_ready_tick = int(state.ticks)+Special.SLAM.interval
			_animation(1001,0)
		state.special = sandbox_special.snapshot()
		var event := {"event":"sandbox_special_begin","special":_special_move,"attack_id":sandbox_special.attack_id,"policy":"original_sandbox_move"}
		_events.append(event)
		state.events.append(event)

func _begin_attack(target: Vector3, selected: String = "", locked_target_yaw: int = -1) -> void:
	_end_turn_attack()
	_lock_target(target)
	var target_yaw: int = locked_target_yaw if locked_target_yaw >= 0 else _target_yaw(target)
	var relative: int = (target_yaw - int(state.yaw)) & 65535
	_spawned = false
	_stop_requested = false
	state.main = 3
	state.phase = 1
	if selected == "turn_attack" or (selected == "" and relative >= 0x2000 and relative < 0xe000):
		state.mode = "turn_attack"
		state.sub = 6
		var delta: int = ((relative + 32768) & 65535) - 32768
		state.turn_target_yaw = target_yaw
		state.turn_ticks = 0
		state.turn_step = ceili(float(absi(delta)) / TURN_TICKS)
		_source_quadrant = [0,2,3,1][relative >> 14]
		_animation(1019 if (delta < 0 if sandbox_motion_enabled else (_source_quadrant & 1) != 0) else 1018)
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
	_release(str(state.mode))

func _charge_tick() -> void:
	if state.phase == 3:
		if animator.animation_ended():
			_finish_move("charge")
		return
	if _stop_requested or state.attack_budget <= 0:
		state.phase = 3
		_stop_requested = false
		_animation(1016, 10)
		return
	if state.phase == 1:
		_spawn(4 + int(state.sub))
		state.phase = 2
	_yaw_towards(_target_yaw(state.committed_target), 0x40)
	if state.remaining_distance <= 0.0:
		state.attack_budget = 1
	state.attack_budget -= 1
	if state.attack_budget <= 0:
		state.phase = 3
		_animation(1016, 10)

func _turn_attack_tick() -> void:
	if not sandbox_motion_enabled:
		var direction: int = -1 if (_source_quadrant & 1) != 0 else 1
		if state.phase == 1:
			_spawn(2)
			state.phase = 2
		if state.phase == 2:
			state.yaw = (int(state.yaw)+direction*230)&65535
			if animator.ge(60):
				state.phase = 3
		else:
			if animator.ge(142) and not animator.ge(164):
				state.yaw = (int(state.yaw)+direction*(2350 if (_source_quadrant & 2) != 0 else 860))&65535
			if animator.animation_ended():
				_idle()
		return
	if state.phase == 1:
		_spawn(2)
		state.phase = 2
	state.turn_ticks += 1
	_yaw_towards(int(state.turn_target_yaw), int(state.turn_step))
	# record2 delay=0，下一tick激活；15tick保留激活机会，退出显式取消其122tick寿命。
	if state.turn_ticks >= TURN_TICKS:
		_finish_move("turn_attack")

func _begin_reaction() -> void:
	state.observed_target = null
	state.committed_target = null
	state.released = false
	state.tracking_stage = "cancelled"
	_walk_speed = 0.0
	_blocked_ticks = 0
	_end_turn_attack()
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
