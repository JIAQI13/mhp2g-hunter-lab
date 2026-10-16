class_name HunterController
extends RefCounted

# 依据 ULJM05500 的 Python 参考逻辑及普通/大剑契约手工移植。
# 本地平地、选定kind0受击/防御/死亡入口沙盒，不代表原游戏完整等价。
# 转向、地面和余弦采用明确的 Godot 适配，保留原内部单位。
const R = 0x200
const TRIANGLE = 0x1000
const CIRCLE = 0x2000
const CROSS = 0x4000
const SQUARE = 0x8000
const SELECT = 1
const MOVE = {1: 0, 3: 2, 73: 7, 36: 6}
const DRAW = {4: 0, 5: 1, 10: 2, 15: 3}
const ROLL = {28: 0, 37: 3, 45: 1}
const SIDE = {49: 0, 50: 1}
const SWEEP = {0: 0, 5: 1, 6: 2, 7: 3, 8: 4}
const UPS = {1: 0, 9: 1, 10: 2, 11: 3, 12: 4}
const VERTICAL = {2: 0, 14: 2, 15: 3, 16: 4, 17: 5, 18: 6}
const CHARGE = {19: 0, 20: 1, 21: 2, 22: 3, 24: 5, 25: 6}
const RELEASE = {26: 0, 27: 1, 28: 2, 29: 3}
const GUARD = [3, 12, 38, 11, 1, 10, 8]
const NORMAL = [0, 1, 3, 73, 36, 4, 5, 10, 15, 28, 37, 45, 49, 50, 8, 29, 57, 59, 60, 61, 44, 63, 31, 70, 32, 68, 69]
const DISPATCH_ONLY = [2, 14, 15, 17, 18]
# 每组依次为主动画、原混合参数、原起始时间单位。
const PLANS = {
	0: [[1406,4,0]], 1: [[1407,4,0]], 2: [[1401,4,0],[1428,2,0]],
	3: [[1404,0,0]], 4: [[1411,0,0]],
	5: [[1417,4,0],[1406,2,26]], 6: [[1421,4,0],[1406,2,44]],
	7: [[1423,0,0],[1406,2,26]], 8: [[1427,0,0],[1406,0,44]],
	9: [[1416,4,0],[1407,2,64]], 10: [[1419,4,0],[1407,0,66]],
	11: [[1422,0,0],[1407,0,66]], 12: [[1425,0,0],[1407,0,66]],
	14: [[1420,4,0],[1401,2,50],[1428,2,0]],
	15: [[1418,4,0],[1429,2,0],[1428,2,8]], 16: [[1405,4,0],[1428,2,14]],
	17: [[1424,0,0],[1430,2,0],[1428,0,10]],
	18: [[1426,0,0],[1401,0,52],[1428,2,0]],
	19: [[1401,4,0]], 20: [[1431,2,0],[1401,0,56]],
	21: [[1420,4,0],[1401,2,50]], 22: [[1418,4,0]],
	24: [[1424,0,0]], 25: [[1426,0,0],[1401,0,52]],
	26: [[1428,2,0]], 27: [[1429,0,0],[1428,2,8]],
	28: [[1430,0,0],[1428,0,10]], 29: [[1410,0,0],[1428,0,32]]}
const NORMAL_ANIMS = {1:[3,6,0],3:[1004,4,0],73:[49,6,0],36:[3,0,38],
	4:[1002,2,0],5:[1003,0,0],10:[1017,0,0],15:[1003,0,0],
	28:[28,2,0],37:[28,2,0],45:[22,0,0],49:[1013,2,0],50:[1012,2,0]}
var animator: HunterAnimator
var state: Dictionary = {}
var last_tick: Dictionary = {}
var focus_d7: bool = false
var focus_d8: bool = false
# 危险源上游未闭合，仅由调用方提供明确快照，不推断怪物。
var danger_enabled: bool = false
var danger_yaw: int = 0
# 0xa1/0xa2 是碰撞窗口技能，与耐力消耗技能独立。
var evasion_skill_a1: bool = false
var evasion_skill_a2: bool = false
var evade_rank: int = 0
var evade_extension: bool = false
var infinite_stamina: bool = false
var yaw_max_step: int = 2048 # Godot 适配，并非从原代码恢复的 M10 转向追随逻辑。
var _magnitude: int = 0
var _direction: int = 0
var _directional_bits: int = 0
var _events: Array = []
# 单调创建身份跨 controller.reset 保留；同动画重设不产生新身份。
var _attack_id: int = 0
# 接触快照由控制器持有，渲染不消费；每任务至多一项。
var _pending_incoming: Dictionary = {}
var _float32 = PackedFloat32Array([0.0])

func configure(value: HunterAnimator) -> void:
	animator = value
	reset()

func reset() -> void:
	_pending_incoming = {}
	state = {"cate":0,"sub":0,"phase":0,"aux":0,"delay":0,"flags410":0,
		"flags288":0,"flags28c":0,"flags614":4,"flags111c":0,"air280":0,
		"previous":[0,0],"idle_counter":0,"timer414":0,"internal_window":0,
		"sprint_release_counter":0,"stamina":750,"stamina_max":750,"rate":1.0,
		"playback_step":2.0,"primary":1,"blend":0,"start":0,"charge":0,"level":0,
		"attack_scale":100,"attack_accumulator":1.0,"hard":0,"slow":0,"pending_hard":0,
		"hit_tag":"none","command":0,"command_hold":0,"command_phase":0,
		"command_clock":0,"pressed_latch":0,"triangle_latch":0,"previous_held":0,
		"held":0,"pressed":0,"released":0,"yaw":0,"target":0,"position":Vector3.ZERO,
		"velocity":Vector3.ZERO,"acceleration":Vector3.ZERO,"floor_height":0.0,
		"ticks":0,"dispatches":0,"frames":[0.0,0.0],"ready":false,
		"hp_max":100,"hp":100,"recovery":"none","source_owner":"normal",
		"adaptation":"Godot smooth yaw / cached flat floor / cosine; not PSP equivalence"}
	_events = []
	if animator != null:
		state.ready = animator.set_animation(1, 0, 0)
	last_tick = state.duplicate(true)

func is_drawn() -> bool:
	return bool(int(state.get("flags410", 0)) & 8)

# 仅对应 09c3d640 已核实的攻击碰撞拒绝门，不适用于 HP 或周期伤害。
func attack_collision_allowed() -> bool:
	return state.internal_window == 0

func observable_action() -> String:
	if is_recovering():
		return "hurt_or_recovering"
	if int(state.cate) == 2:
		return "guard"
	if int(state.cate) == 1:
		return "charging_weapon" if CHARGE.has(int(state.sub)) else "weapon_action"
	if ROLL.has(int(state.sub)) or SIDE.has(int(state.sub)) or int(state.sub) in [32,68,69]:
		return "evading"
	return "locomotion_or_idle"

func is_dead() -> bool:
	return state.get("recovery", "none") == "dead"

func is_recovering() -> bool:
	return state.get("recovery", "none") != "none"

# 只接入已选kind0地面路径；power为原resolve后的byte，不是完整伤害公式。
func queue_incoming(damage: int, power: int, incoming_yaw: int) -> Dictionary:
	if damage < 0 or power < 0 or power > 255 or incoming_yaw < 0 or incoming_yaw > 65535 or not state.get("ready", false):
		return {"status":"invalid"}
	if is_dead():
		return {"status":"dead"}
	if not attack_collision_allowed():
		return {"status":"evaded"}
	if not _pending_incoming.is_empty():
		return {"status":_pending_incoming.status,"duplicate":true}
	# 空中incoming须由launch/落地几何owner恢复，不能冒充已证地面kind0。
	if state.air280 != 0:
		return {"status":"invalid","reason":"selected ground kind0 only"}
	var guarded: bool = _guard_qualified(power, incoming_yaw, true, true)
	var forward: bool = ((int(state.yaw)-incoming_yaw+0x4000) & 65535) < 0x8000
	_pending_incoming = {"damage":damage,"power":power,"guarded":guarded,
		"forward":forward,"reaction_yaw":incoming_yaw if forward else (incoming_yaw+0x8000) & 65535,
		"status":"guarded" if guarded else "pending"}
	return {"status":_pending_incoming.status}

func _consume_incoming() -> bool:
	if _pending_incoming.is_empty():
		return false
	var incoming: Dictionary = _pending_incoming
	_pending_incoming = {}
	var damage: int = incoming.damage
	var power: int = incoming.power
	var applied: int = damage
	if incoming.guarded:
		# 削血依赖原外部资格/3ce，尚未闭合；仅明示中性沙盒分档。
		applied = 0 if power < 15 else int(damage / 4) if power < 40 else int(damage / 2)
		_cost(-75 if power < 15 else -100 if power < 40 else -180)
		_set_action(2,11 if power < 15 else 1 if power < 40 else 10)
		_events.append({"event":"player_guard","damage":damage,"applied_damage":applied,
			"power":power,"stamina":state.stamina,"chip_rule":"sandbox"})
	state.hp = maxi(0,int(state.hp)-applied)
	_events.append({"event":"player_damage","damage":damage,"applied_damage":applied,
		"hp":state.hp,"guarded":incoming.guarded,"power":power})
	# 不统一清零charge数槽；改变category后旧攻击handler不再运行。
	state.command = 0
	state.command_hold = 0
	state.command_phase = 0
	state.pressed_latch = 0
	state.triangle_latch = 0
	state.hit_tag = "none"
	state.pending_hard = 0
	state.slow = 0
	state.target = state.yaw
	if state.hp == 0:
		_set_action(3,0)
		state.recovery = "dead"
		state.source_owner = "09a68138 -> 09a8cc70/09a8cd10 entry; sandbox terminal"
		_events.append({"event":"player_dead","hp":0})
	elif not incoming.guarded:
		state.yaw = incoming.reaction_yaw
		state.target = state.yaw
		_set_action(2,(13 if incoming.forward else 9) if power < 11 else (6 if incoming.forward else 0))
		state.recovery = "light" if power < 11 else "down"
		state.source_owner = "09a66330 kind0 -> 09a8a1d0" if power < 11 else "09a66330 kind0 -> 09a89730/09a88370"
	return true

func _danger_gate() -> bool:
	return bool(int(state.flags111c) & 0x100) and ((danger_yaw-int(state.yaw)+0x2000) & 65535) > 0x4000

func toggle_weapon() -> void:
	force_action(0, 5 if is_drawn() else 4)

func get_actions() -> Array:
	var actions: Array = []
	for sub in NORMAL:
		actions.append({"category":0,"subaction":sub,"name":_name(0,sub),"input_reachability":"selected source input"})
	for sub in PLANS:
		actions.append({"category":1,"subaction":sub,"name":_name(1,sub),
			"input_reachability":"unverified dispatch-only gallery" if sub in DISPATCH_ONLY else "observed static producer"})
	actions.append({"category":1,"subaction":99,"name":"收刀踢脚","input_reachability":"SELECT"})
	for sub in GUARD:
		actions.append({"category":2,"subaction":sub,"name":_name(2,sub),"input_reachability":"guard / explicit incoming feedback"})
	return actions

func _name(category: int, sub: int) -> String:
	if category == 0:
		return {0:"待机",1:"跑",3:"拔刀移动",73:"慢走",36:"跑步恢复",4:"拔刀",5:"收刀",10:"移动收刀",15:"蹲下收刀",28:"翻滚",37:"翻滚变体",45:"蹲滚",49:"侧步左",50:"侧步右",8:"蹲下",29:"蹲待机",57:"站起",59:"蹲走",60:"蹲停止",61:"蹲快走",44:"停止",63:"回身",31:"冲刺",70:"冲刺恢复",32:"危险跑",68:"飞扑",69:"危险跑恢复"}.get(sub,"normal")
	if category == 2:
		return {3:"防御进入",12:"防御恢复",38:"防御变体",11:"小反冲",1:"中反冲",10:"大反冲",8:"防御退出"}.get(sub,"guard")
	var family: String = "横斩" if SWEEP.has(sub) else "上捞斩" if UPS.has(sub) else "纵斩" if VERTICAL.has(sub) else "蓄力" if CHARGE.has(sub) else "蓄力释放" if RELEASE.has(sub) else "弹刀" if sub == 3 else "踢脚"
	return "%s %02d" % [family,sub]

func _f32(value: float) -> float:
	_float32[0] = value
	return _float32[0]

static func _s16(value: int) -> int:
	return ((value + 32768) & 65535) - 32768

func _count_start() -> void:
	state.idle_counter = _s16(int(state.start)) - _s16(absi(_s16(int(state.blend))))

func _anim(primary: int, blend: int, start: int, count: bool = false) -> void:
	if not animator.set_animation(primary, blend, start):
		state.ready = false
		_events.append({"event":"missing_animation","primary":primary})
		return
	state.primary = primary
	state.blend = _s16(int(blend / 2.0))
	state.start = start & 65535
	_events.append({"event":"animation","primary":primary,"blend_argument":blend,"start":start})
	if count:
		_count_start()

func _plan(sub: int, index: int, count: bool = false) -> void:
	var row: Array = PLANS[sub][index]
	_anim(int(row[0]),int(row[1]),int(row[2]),count)

func force_action(category: int, subaction: int) -> bool:
	if animator == null or not state.get("ready",false) or is_recovering():
		return false
	if not (category == 0 and subaction in NORMAL or category == 1 and (PLANS.has(subaction) or subaction == 99) or category == 2 and subaction in GUARD):
		return false
	_set_action(category,subaction)
	return true

func _set_action(category: int, sub: int, flags: int = 0) -> void:
	var old: Array = [state.cate,state.sub]
	state.cate = category
	state.sub = sub
	state.recovery = "none"
	state.source_owner = "guard" if category == 2 else "greatsword" if category == 1 else "normal"
	state.previous = old
	state.phase = 0
	state.aux = 0
	state.delay = 0
	state.flags410 &= ~4
	state.rate = 1.0
	state.attack_scale = 100
	if not flags & 1:
		state.hit_tag = "none"
		if category == 2:
			state.flags614 &= ~0x800
	_count_start()
	state.flags288 &= 0x80100
	state.flags28c = 0
	state.playback_step = 2.0
	_events.append({"event":"set","from":old,"cate":category,"sub":sub,"flags":flags})

func _request(category: int, sub: int, flags: int = 0) -> void:
	_set_action(category,sub,flags)
	state.flags410 |= 4
	_events.append({"event":"request","cate":category,"sub":sub})

func _idle(blend: int) -> void:
	if is_dead():
		return
	state.recovery = "none"
	state.source_owner = "normal"
	state.phase = 0
	state.aux = 0
	state.delay = 0
	state.idle_counter = 0
	state.timer414 = 0
	state.internal_window = 0
	state.flags614 = (int(state.flags614) & ~0x980) | 4
	state.flags288 &= 0x100
	state.flags28c = 0
	state.flags410 &= ~2
	state.charge = 0
	state.rate = 1.0
	state.playback_step = 2.0
	state.air280 = 0
	state.previous = [state.cate,state.sub]
	state.cate = 0
	state.sub = 0
	_anim(1001 if is_drawn() else 403 if state.stamina_max < 76 else 1,blend,0,true)

func _mode(mode: int = 0, a2: int = 0, a3: int = 0) -> void:
	state.air280 = 2 if mode & 255 == 2 else 1 if mode & 255 == 1 else 0
	state.flags288 = int(state.flags288) & ~8 if mode & 0x8000 else int(state.flags288) | 8
	state.flags288 = int(state.flags288) | 1 if a2 else int(state.flags288) & ~1
	state.flags288 = int(state.flags288) | 2 if a3 else int(state.flags288) & ~2

func _apply(delta: int) -> void:
	if delta < 0 and infinite_stamina:
		return
	state.stamina = clampi(_s16(int(state.stamina) + _s16(delta)),0,int(state.stamina_max))

func _cost(delta: int) -> void:
	delta = _s16(delta)
	if evade_rank >= 2:
		delta >>= 1
	elif evade_rank == 1:
		delta -= delta >> 2
	elif evade_rank < 0:
		delta = int(_f32(_f32(delta) * _f32(1.2 if evade_rank == -1 else 1.35)))
	_apply(_s16(delta))

func _count_begin() -> void:
	if state.hard:
		return
	state.idle_counter = ((int(state.idle_counter) + 2 + 2147483648) & 0xffffffff) - 2147483648
	if state.idle_counter > 99999:
		state.idle_counter = 10000
	if state.sprint_release_counter:
		state.sprint_release_counter = _s16(int(state.sprint_release_counter)-1)
	if state.internal_window:
		state.internal_window = _s16(int(state.internal_window)-1)
	var excluded: Array = [37,126,110,109,108,107,68,50,49,45,28,120,119]
	if not int(state.flags288) & 0x200 and not int(state.flags410) & 0x10 and (state.cate == 1 or state.cate == 0 and not state.sub in excluded):
		_apply(2)

# 原代码 09a63fb0 的按住状态/边沿识别逻辑；每个任务执行一次，而非每次分派执行一次。
func _decode() -> void:
	var held: int = state.held
	var pressed: int = state.pressed
	if state.command_phase == 2:
		state.command = 0
		if not held & TRIANGLE:
			state.command_phase = 0
		return
	if state.command_phase != 1:
		state.command = 3 if held & 0x3000 == 0x3000 and pressed & 0x3000 else 0
		if state.command == 3:
			return
		state.command_hold = 0
		if pressed & 0xb000:
			state.command_clock = 0
			state.command_phase = 1
			state.pressed_latch = pressed & 0xb000
			state.triangle_latch = held & TRIANGLE
		return
	state.command_clock += 1
	if not pressed & 0xb000 and state.command_clock < 2:
		if not held & 0xb000:
			state.command = 1 if int(state.pressed_latch) & CIRCLE else 2 if int(state.pressed_latch) & TRIANGLE else 4 if int(state.pressed_latch) & SQUARE else 0
			if state.command == 2:
				state.command_hold = 2
			state.command_phase = 0
		if not held & TRIANGLE:
			state.triangle_latch &= ~TRIANGLE
		return
	if held & 0x3000 == 0x3000:
		state.command = 3
	elif held & CIRCLE:
		state.command = 1
	elif held & TRIANGLE:
		state.command = 2
		if state.triangle_latch:
			state.command_hold = 2
	elif held & SQUARE:
		state.command = 4
	if not state.command:
		state.command = 1 if int(state.pressed_latch) & CIRCLE else 2 if int(state.pressed_latch) & TRIANGLE else 4 if int(state.pressed_latch) & SQUARE else 0
		if state.command == 2:
			state.command_hold = 2
	state.command_phase = 2 if state.command_hold else 0

func _motion() -> int:
	var motion: int = 0 if _magnitude < 40 else 1 if _magnitude < 120 else 3
	if not state.air280 and not is_drawn() and int(state.held) & R and motion and (state.cate != 0 or state.sub != 36 or not state.sprint_release_counter):
		return 5
	return motion

func _aim() -> void:
	state.target = _direction

func _guard_select() -> void:
	if not int(state.held) & R:
		return
	if not is_drawn():
		if state.command == 2 and int(state.flags288) & 0x2001600:
			return
		if not state.command in [2,3] and int(state.held) & 0x3000 != 0x3000:
			return
	_request(2,3)

func _input(p: int = 0) -> void:
	state.flags614 |= 4
	var locks: int = int(state.flags288) & 0x2001600
	var motion: int = _motion()
	if is_drawn():
		if motion in [1,2,3] and not state.sub in [36,3,116]:
			_set_action(0,3)
		if int(state.pressed) & SQUARE:
			_set_action(0,10 if locks & 0x1200 else 5)
		_guard_select()
		state.flags111c &= ~0x800
		if state.command in [1,2,3]:
			_set_action(1,{1:0,2:19,3:1}[state.command],4)
		elif int(state.pressed) & SELECT:
			_set_action(1,4,4)
		elif int(state.pressed) & CROSS and state.stamina > 74:
			_set_action(0,28,4)
		return
	if state.sub in [44,63]:
		motion = 0
	if motion == 5 and not locks & 0x200:
		_set_action(0,32 if _danger_gate() else 31)
	elif motion == 3 and not state.sub in [1,63,19,36,31]:
		_aim()
		var diff: int = (int(state.target)-int(state.yaw)) & 65535
		_set_action(0,63 if diff >= 0x6000 and diff <= 0xa000 else 1,0x40 if diff >= 0x6000 and diff <= 0xa000 else 0)
	elif motion == 1 and not state.sub in [73,36]:
		_aim()
		_set_action(0,73)
	if int(state.pressed) & CROSS:
		if p == 2 or (_magnitude < 85 or motion == 0) and not locks & 0x2000655:
			_set_action(0,8)
		elif state.stamina > 74:
			_set_action(0,28,4)
	if int(state.pressed) & SELECT:
		_set_action(1,99,4)
	# 有意省略道具/台沿/交互的动作触发逻辑，不虚构攻击。
	_guard_select()
	if state.command == 2:
		if not locks & 0x2000600:
			if not int(state.held) & R:
				_set_action(0,4)
		else:
			state.flags111c |= 0x800
			_set_action(1,20,4)

func _side_select() -> void:
	if not int(state.pressed) & CROSS or state.stamina < 75:
		return
	var sub: int = 28
	if _directional_bits:
		var direction: int = (_direction + 0x4000) & 65535
		sub = 49 if direction < 0x5c72 else 28 if direction < 0xa38e else 50
	_set_action(0,sub,4)

func _combo(current: int) -> void:
	_side_select()
	state.flags111c &= ~0x1800
	state.attack_accumulator = 1.0
	var command: int = 2 if state.command == 3 else 1 if state.command == 1 else 4 if state.command == 2 else 255
	var sub: int = -1
	var left: bool = bool(int(state.held) & 0x800000)
	var right: bool = bool(int(state.held) & 0x200000)
	if command != current and command != 0:
		if command == 4:
			if current == 2:
				sub = 25 if left else 21
			elif current == 1:
				sub = 24 if right else 22
		elif command == 2:
			if current == 1:
				sub = 12 if left else 10
			elif current in [3,4]:
				sub = 11 if left else 9
		elif command == 1:
			if current == 2:
				sub = 8 if right else 6
			elif current in [3,4]:
				sub = 7 if right else 5
	if sub >= 0:
		_set_action(1,sub,4)

func _normal() -> void:
	var sub: int = state.sub
	if sub == 0:
		_input()
	elif MOVE.has(sub):
		var p: int = MOVE[sub]
		if not state.phase:
			state.phase = 1
			state.aux = 0
			state.delay = 10
			state.timer414 = 10
			_mode()
			state.flags288 |= 0x1000
			if p == 6:
				state.sprint_release_counter = 30
				if state.primary != 3:
					_anim(3,0,38)
				state.flags288 |= 0x2000000
			else:
				var row: Array = NORMAL_ANIMS[sub]
				_anim(row[0],row[1],row[2])
				if p == 0:
					state.flags288 |= 0x2000000
			state.idle_counter = 0
		var motion: int = _motion()
		state.delay = maxi(0,int(state.delay)-1)
		state.timer414 = maxi(0,int(state.timer414)-1)
		if motion == 0 and not state.timer414:
			if state.primary == 3 and not state.delay:
				state.flags614 |= 4
				_set_action(0,44)
			else:
				_idle(4)
		elif state.primary == 3 and motion < 3:
			state.flags614 |= 4
			_set_action(0,44)
		if motion:
			_aim()
		_input()
	elif DRAW.has(sub):
		var p: int = DRAW[sub]
		if state.phase == 2:
			_idle(0)
		elif not state.phase:
			state.phase = 1
			_mode()
			state.flags410 = int(state.flags410) | 8 if p == 0 else int(state.flags410) & ~8
			if p == 2:
				state.flags288 |= 0x1000
			var row: Array = NORMAL_ANIMS[sub]
			_anim(row[0],row[1],0)
		elif animator.animation_ended():
			if p == 3:
				_request(0,8,2)
			else:
				_idle(6 if p == 0 else 8 if p == 1 else 4)
	elif ROLL.has(sub) or SIDE.has(sub):
		var p: int = ROLL.get(sub,-1)
		if not state.phase:
			state.idle_counter = 0
			# 前滚、蹲滚和侧回避均调用同一窗口生产器 09a86918。
			state.internal_window = (16 if p == 3 else 6) + (6 if evasion_skill_a2 else 4 if evasion_skill_a1 else 0)
			state.timer414 = 0
			state.aux = 0
			state.flags614 &= ~0x1000
			_mode()
			_cost(-75)
			state.phase = 1 if p == 1 or SIDE.has(sub) else 2
			var row: Array = NORMAL_ANIMS[sub]
			_anim(row[0],row[1],0)
		elif p == 1 and state.phase == 1:
			if animator.animation_ended():
				state.phase = 2
				_anim(28,0,6)
		elif animator.animation_ended():
			_idle(8)
		elif evade_extension and animator.ge(10) and not animator.ge(40):
			_add_local(Vector3(-8 if sub == 49 else 8,0,0) if SIDE.has(sub) else Vector3(0,0,10))
	elif sub in [32,69]:
		state.flags614 |= 4
		if not state.phase:
			state.phase = 1
			_mode()
			state.flags288 |= 0x600
			state.idle_counter = 0
			_anim(38,4 if sub == 69 else 0,0)
			state.target = state.yaw
			_input()
			return
		# 09a99890：无耐力技能 0x18 的已闭合基础消耗为每次 -2。
		_apply(-2)
		if state.stamina < 76:
			# 原请求 34（力竭跑）不在动作库；明确平地适配返回待机。
			_idle(4)
			return
		if not _danger_gate():
			_request(0,70)
			return
		if int(state.pressed) & CROSS and state.stamina > 74:
			state.target = state.yaw
			_set_action(0,68,4)
			return
		if _magnitude > 39:
			_aim()
		_add_local(Vector3(0,0,1.5))
		var motion: int = _motion()
		if motion == 5:
			_input()
		elif motion == 3:
			_request(0,36)
		else:
			_request(0,44)
	elif sub == 68:
		_dive()
	elif sub in [31,70]:
		state.flags614 |= 4
		if not state.phase:
			state.phase = 1
			_mode()
			state.flags288 |= 0x600
			state.idle_counter = 0
			state.sprint_release_counter = 30
			if sub == 70:
				_anim(3,4,30)
			elif state.primary != 3:
				_anim(3,0,0)
			state.playback_step = 2.5
			state.target = state.yaw
			_input()
			return
		state.playback_step = 2.5
		if int(state.ticks) & 1:
			_apply(-1)
		if state.stamina < 76:
			# 普通动作库未包含力竭状态；Godot 中返回普通待机。
			_idle(4)
			return
		if int(state.pressed) & CROSS and state.stamina > 74:
			state.target = state.yaw
			_set_action(0,28,4)
			return
		if _magnitude > 39:
			_aim()
		_add_local(Vector3(0,0,5))
		var motion: int = _motion()
		if motion == 5:
			_input()
		elif motion == 3:
			if not state.sprint_release_counter:
				_request(0,36)
			else:
				_input()
		else:
			_request(0,44)
	elif sub in [44,63]:
		state.flags614 |= 4
		var p: int = 0
		if not state.phase:
			state.phase = 1
			_mode()
			state.flags288 |= 0x2000000
			if sub == 63:
				state.idle_counter = 0
				state.yaw = state.target
			_anim(42 if sub == 63 else 30,0 if sub == 63 else 4,0)
		elif animator.animation_ended():
			if sub == 63:
				_set_action(0,36)
			else:
				_idle(10)
		elif animator.ge(10):
			p = 2
		_input(p if sub == 44 else 0)
	elif sub in [8,29]:
		state.flags614 |= 4
		if not state.phase:
			state.phase = 1 if sub == 8 else 2
			if sub == 8:
				state.idle_counter = 0
				_anim(7,2,0)
				_mode()
			else:
				_anim(8,8 if state.primary == 412 else 2,0,true)
				_mode(0x8001)
			state.flags410 &= ~8
		elif state.phase == 1:
			if animator.animation_ended():
				state.phase = 2
				_anim(8,6,0,true)
				_mode(0x8001)
		else:
			_crouch_input()
	elif sub == 57:
		if not state.phase:
			state.phase = 1
			state.aux = 0
			state.idle_counter = 0
			_mode(1)
			_anim(9,0,0)
		elif animator.animation_ended():
			_idle(4)
	elif sub in [59,61]:
		if not state.phase:
			state.phase = 1
			state.idle_counter = 0
			state.timer414 = 15
			_anim(10 if sub == 59 else 37,8 if sub == 59 else 6,0)
			_mode(1)
			state.flags288 |= 0x1000 if sub == 59 else 0x2000000
			state.flags614 |= 4
			if sub == 59:
				state.flags410 &= ~8
			return
		state.timer414 = maxi(0,int(state.timer414)-1)
		if int(state.pressed) & CROSS and state.stamina >= 75:
			_set_action(0,45,4)
		else:
			_crouch_input()
	elif sub == 60:
		state.timer414 += 1
		state.flags614 |= 4
		if not state.phase:
			state.phase = 1
			_mode(0x8001)
			_anim(8,12 if state.primary == 37 else 8,0)
			state.timer414 = 0
		elif state.timer414 > 11:
			_set_action(0,29)

func _dive() -> void:
	if not state.phase:
		state.phase = 1
		state.idle_counter = 0
		_anim(46,4,0)
		_mode(2)
		_cost(-75)
		state.internal_window = 3
	elif state.phase == 1:
		state.internal_window = 3
		if animator.animation_ended():
			state.phase = 2
			_anim(47,0,0)
			var position: Vector3 = state.position
			position.y = _f32(position.y+100.0)
			state.position = position
			var direction: Vector3 = _world_direction(Vector3(0,0,16))
			state.velocity = Vector3(direction.x,3.0,direction.z)
			state.acceleration = Vector3(0,-0.75,0)
	elif state.phase == 2:
		state.internal_window = 3
		# 08865e8c：先速度加加速度，再位置加新速度；不是按秒的 Godot 重力。
		var velocity: Vector3 = state.velocity
		var acceleration: Vector3 = state.acceleration
		velocity = Vector3(_f32(velocity.x+acceleration.x),_f32(velocity.y+acceleration.y),_f32(velocity.z+acceleration.z))
		state.velocity = velocity
		var position: Vector3 = state.position
		position = Vector3(_f32(position.x+velocity.x),_f32(position.y+velocity.y),_f32(position.z+velocity.z))
		state.position = position
		if velocity.y <= 0 and position.y <= state.floor_height:
			state.phase = 3
			state.air280 = 0
			position.y = state.floor_height
			state.position = position
			_anim(48,0,0)
	else:
		# 落地后保留速度但不再积分；GE 包含原混合完成资格，不只比较帧号。
		if animator.animation_ended():
			state.internal_window = 0
			if not is_drawn() and int(state.held) & R:
				_request(0,69)
			else:
				state.flags614 |= 4
				_request(0,44)
		elif not animator.ge(30):
			state.internal_window = 2

func _crouch_input() -> void:
	state.flags614 |= 4
	var motion: int = _motion()
	if motion == 3:
		_aim()
		if state.sub != 61:
			_request(0,61)
	elif motion == 1:
		_aim()
		if state.sub != 59:
			_request(0,60 if state.sub == 61 else 59)
	elif state.sub in [59,61] and not state.timer414:
		_request(0,60)
	if int(state.pressed) & CROSS:
		_request(0,57)
	if state.command == 2:
		_set_action(0,4)
	_guard_select()

func _spawn(record: int) -> void:
	_attack_id += 1
	_events.append({"event":"attack_spawn","record":record,"primary":state.primary,
		"start":state.start,"blend_count":state.blend,"attack_scale":state.attack_scale,
		"attack_id":_attack_id,"combat":"HunterCombat"})

func _release_spawn() -> void:
	state.attack_scale = [100,110,120,130][int(state.level)]
	_spawn([3,91,92,93][int(state.level)])
	state.flags111c &= ~0x800

func _hit(mode: int) -> bool:
	if state.hit_tag == "none" or state.delay:
		return false
	var tag: String = state.hit_tag
	state.hit_tag = "none"
	state.delay = 1
	if tag == "bounce":
		state.pending_hard = 0
		if mode == 0:
			state.flags614 &= ~0x800
		_set_action(1,3)
	elif tag in ["normalhit2","normalhit3"]:
		_anim(int(state.primary),0,_s16(int(float(animator.tracks[0].currentframe)-2)))
		state.phase += 1
	return true

func charge_level(count: int) -> int:
	count = _s16(count)
	if focus_d7:
		count = _s16(int(_f32(_f32(count)*_f32(1.25))))
	elif focus_d8:
		count = _s16(int(_f32(_f32(count)*_f32(0.8333333134651184))))
	return 0 if count < 30 else 1 if count < 60 else 2 if count < 80 else 3

func _attack() -> void:
	var sub: int = state.sub
	if SWEEP.has(sub) or UPS.has(sub):
		var sweep: bool = SWEEP.has(sub)
		var p: int = SWEEP[sub] if sweep else UPS[sub]
		if not state.phase:
			state.flags614 |= 0x800
			state.delay = 0
			if p == 0:
				state.phase = 1
				_plan(sub,0,sweep)
				if not sweep:
					state.idle_counter = 0
				_spawn(2 if sweep else 1)
				_mode(0,1)
			elif not state.aux:
				state.aux = 1
				_count_start()
				if p in [3,4]:
					state.yaw = (int(state.yaw)+(0x2000 if sweep else -0x2000)) & 65535
					state.target = state.yaw
				_plan(sub,0)
			elif animator.animation_ended():
				state.phase = 1
				_plan(sub,1,true)
				_spawn(2 if sweep else 1)
			return
		if state.phase == 2:
			if not state.slow:
				state.phase = 3
			return
		if animator.animation_ended():
			_idle(4 if state.phase == 1 else 6)
			return
		if state.phase == 1 and _hit(0):
			return
		var low: int = 72 if sweep and state.phase == 1 else 78 if sweep else 116
		var high: int = 98 if sweep and state.phase == 1 else 104 if sweep else 192
		if animator.ge(low) and not animator.ge(high):
			_combo(1 if sweep else 2)
	elif VERTICAL.has(sub):
		var p: int = VERTICAL[sub]
		if not state.phase:
			state.phase = 2 if p in [0,4] else 1
			_mode(0,1)
			state.flags410 |= 8
			state.flags614 |= 0x800
			if p in [5,6]:
				state.yaw = (int(state.yaw)+(0x2000 if p == 5 else -0x2000)) & 65535
				state.target = state.yaw
			_plan(sub,0,p == 0)
		elif state.phase == 1:
			if p == 3 and animator.ge(24) or p == 5 and animator.ge(26) or not p in [3,5] and animator.animation_ended():
				state.phase = 2
				_plan(sub,1)
		elif state.phase == 2:
			if p in [0,2,6] and animator.ge(58) or p in [3,4,5] and animator.animation_ended():
				state.phase = 3
				_plan(sub,PLANS[sub].size()-1,true)
				_spawn(3)
				if p == 4:
					state.flags111c |= 0x1000
		elif state.phase in [4,6]:
			if not state.slow:
				state.phase += 1
		else:
			if animator.animation_ended():
				_idle(8 if state.phase in [3,5] else 6)
			elif not _hit(1) and animator.ge(48) and not animator.ge(102):
				_combo(3)
	elif CHARGE.has(sub):
		var p: int = CHARGE[sub]
		if not state.phase:
			state.phase = 1 if p in [1,2,6] else 2
			state.aux = 0
			state.delay = 0
			state.charge = 0
			state.level = 0
			_mode(0,1)
			state.flags410 |= 8
			state.flags614 |= 0x800
			state.timer414 = _s16(int(_f32(_f32(90)*_f32(0.8 if focus_d7 else 1.2 if focus_d8 else 1.0))))
			if p in [5,6]:
				state.yaw = (int(state.yaw)+(0x2000 if p == 5 else -0x2000)) & 65535
				state.target = state.yaw
			_plan(sub,0,p == 0)
			return
		if state.phase == 1:
			if animator.animation_ended():
				state.phase = 2
				_plan(sub,1)
				return
			if p in [2,6]:
				return
			if not state.aux and not animator.ge(10) and state.command_hold != 2:
				state.aux = 2
			if state.aux == 2 and animator.ge(10):
				state.level = 0
				state.rate = 1.0
				_request(1,29,4)
			return
		var count_gate: int = 0 if p == 3 else 2 if p == 5 else 34
		var release_gate: int = 24 if p == 3 else 26 if p == 5 else 58
		if animator.ge(count_gate):
			if state.command_hold != 2:
				state.aux = 1
			if not state.delay and not state.aux:
				state.delay = 1
				_events.append({"event":"charge_effect","selector":8})
			if not state.aux:
				state.rate = 0.5
				state.charge = _s16(int(state.charge)+1)
				state.timer414 -= 1
				if state.timer414 < 1:
					state.aux = 1
			else:
				state.rate = 1.0
		if animator.ge(release_gate) and state.aux == 1:
			state.level = charge_level(int(state.charge))
			state.rate = 1.0
			_request(1,28 if p == 5 else 27 if p == 3 else 26,4)
	elif RELEASE.has(sub):
		var p: int = RELEASE[sub]
		if not state.phase:
			state.phase = 2 if p == 0 else 1
			state.delay = 0
			_mode(0,1)
			state.flags614 |= 0x800
			_plan(sub,0,true)
			if p == 0:
				_release_spawn()
			if state.level:
				if int(state.held) & 0x200000:
					state.target = (int(state.yaw)+0x1000) & 65535
				elif int(state.held) & 0x800000:
					state.target = (int(state.yaw)-0x1000) & 65535
			return
		if state.phase == 1:
			if animator.animation_ended():
				state.phase = 2
				_count_start()
				_plan(sub,1)
				_release_spawn()
			return
		if state.phase in [3,5]:
			if not state.slow:
				state.phase += 1
			return
		if animator.animation_ended():
			_idle(8 if state.phase in [2,4] else 6)
			return
		if _hit(1):
			state.charge = 0
			state.level = 0
			return
		if animator.ge(48) and not animator.ge(102):
			_combo(4)
			state.charge = 0
			state.level = 0
	elif sub == 3:
		if not state.phase:
			state.phase = 1
			state.aux = 0
			state.delay = 0
			_mode()
			_anim(1404,0,0)
			return
		if not state.aux:
			if animator.ge(2) and not animator.ge(60) and not int(state.flags614) & 1 and state.command >= 1 and state.command <= 3:
				state.aux = 1
				state.delay = 0
		elif animator.ge(18):
			_set_action(1,16,12)
		if animator.animation_ended():
			_idle(10)
	elif sub in [4,99]:
		if not state.phase:
			state.phase = 1
			_mode(0,1)
			_anim(1411 if sub == 4 else 50,0 if sub == 4 else 4,0)
			_spawn(4 if sub == 4 else 5)
		elif animator.animation_ended():
			_idle(4 if sub == 4 else 6)

# 供测试/动作库使用的显式来袭输入边界；不推断怪物/命中资格。
func _guard_qualified(power: int, incoming_yaw: int, qualified: bool, permission: bool) -> bool:
	var angle: int = (_s16(int(state.yaw))-_s16(incoming_yaw)+0x4000) & 65535
	return power >= 0 and power <= 255 and not is_recovering() and state.cate == 2 and state.sub in [3,12,38] and state.stamina >= 75 and qualified and permission and (angle < 0xe3a or angle >= 0x71c7)

func guard_incoming(power: int, incoming_yaw: int, qualified: bool, permission: bool) -> bool:
	if not _guard_qualified(power, incoming_yaw, qualified, permission):
		return false
	_cost(-75 if power < 15 else -100 if power < 40 else -180)
	_set_action(2,11 if power < 15 else 1 if power < 40 else 10)
	return true

func _guard() -> void:
	var sub: int = state.sub
	if sub in [3,12,38]:
		if not state.phase:
			state.phase = 1
			_anim(1412,3 if sub == 3 else 6,0 if sub == 3 else 40)
			_mode()
			state.flags288 |= 0x8000
			state.flags410 |= 8
		elif state.idle_counter > 18 and not int(state.held) & R:
			_request(2,8)
		elif state.idle_counter > 18 and int(state.pressed) & CROSS and state.stamina > 74:
			_set_action(0,28,4)
	elif sub in [11,8]:
		if not state.phase:
			state.phase = 1
			_anim(1413 if sub == 11 else 1414,0 if sub == 11 else 2,0,sub == 11)
			_mode(0,0,1 if sub == 11 else 0)
			state.flags288 |= 0x8000
		elif animator.animation_ended():
			if sub == 11:
				_request(2,12)
			else:
				_idle(2)
	elif sub in [1,10]:
		if not state.phase:
			state.phase = 1
			_anim(1414 if sub == 1 else 1415,2 if sub == 1 else 0,0,true)
			_mode(0,0,1)
			state.flags288 |= 0x8002
			state.flags614 |= 8
			return
		var limit: int = 30 if sub == 1 else 104
		var amount: float = 0.0
		if not animator.ge(limit):
			var divisor: float = 32.0 if sub == 1 else 104.0
			var frame: float = animator.tracks[0].currentframe
			var angle: float = _f32(_f32(_f32(_f32(frame/divisor)*90.0)/360.0)*_f32(6.2831855))
			amount = _f32(_f32(cos(angle))*(-20 if sub == 1 else -22))
		_add_local(Vector3(0,0,amount))
		if animator.animation_ended():
			_idle(10)

# recovery是明确incoming上下文：不把类别2重叠sub送进guard消费者。
func _recovery() -> void:
	state.flags614 &= ~0x1202 # 09a87fc0/09a8cd10选定消费者的每分派清理。
	if is_dead():
		if not state.phase:
			state.phase = 1
			_anim(210,0,0)
			_mode()
			state.flags410 &= ~8
		elif animator.animation_ended():
			state.phase = 2
		return
	if state.recovery == "light":
		if not state.phase:
			state.phase = 1
			_anim(1211 if is_drawn() else 201,0,0)
			_mode(0,0,1)
			# 源轻反应没有35e写入；只做平地local-z速度适配，不模拟VFPU。
			state.velocity = _world_direction(Vector3(0,0,4 if state.sub == 13 else -4))
		elif animator.animation_ended():
			_idle(6)
		elif not animator.ge(16):
			var position: Vector3 = state.position
			state.position = position + Vector3(state.velocity.x,0,state.velocity.z)
		return
	# 09a88370/09a89730每次handler写35e=2；唯一计时owner仍是_count_begin。
	state.internal_window = 2
	if not state.phase:
		state.phase = 1
		_anim(204 if state.sub == 6 else 202,0,0)
		_mode(0,0,1)
	elif animator.animation_ended():
		if state.phase == 1:
			state.phase = 2
			state.recovery = "rise"
			_anim(207 if state.sub == 6 else 216,6,58 if state.sub == 6 else 34)
		else:
			_idle(4)
			state.internal_window = 6 # 09a8c180普通恢复分支，非永久无敌。

func _dispatch() -> void:
	state.flags614 &= ~4
	state.flags410 |= 1
	state.dispatches += 1
	if is_recovering():
		_recovery()
	elif state.cate == 0:
		_normal()
	elif state.cate == 1:
		_attack()
	else:
		_guard()

func _world_direction(local: Vector3) -> Vector3:
	var angle: float = int(state.yaw)*TAU/65536.0
	return Vector3(_f32(local.x*cos(angle)+local.z*sin(angle)),local.y,_f32(local.z*cos(angle)-local.x*sin(angle)))

func _add_local(local: Vector3) -> void:
	var delta: Vector3 = _world_direction(local)
	var position: Vector3 = state.position
	state.position = Vector3(_f32(position.x+delta.x),_f32(position.y+delta.y),_f32(position.z+delta.z))

func tick(held: int, magnitude: int, direction: int, directional_bits: int = 0) -> Dictionary:
	if animator == null or not state.get("ready",false):
		last_tick = state.duplicate(true)
		return last_tick.duplicate(true)
	if held < 0 or held > 0xffffffff or magnitude < 0 or magnitude > 127 or direction < 0 or direction > 65535 or directional_bits & ~0xf00000:
		last_tick = state.duplicate(true)
		last_tick.error = "input width/range"
		return last_tick.duplicate(true)
	_magnitude = magnitude
	_direction = direction
	_directional_bits = directional_bits
	_events = []
	state.dispatches = 0
	state.flags111c = (int(state.flags111c) & ~0x100) | (0x100 if danger_enabled else 0)
	state.flags614 &= ~8
	state.held = held | directional_bits
	state.pressed = (~int(state.previous_held) & int(state.held)) & 0xffffffff
	state.released = (~int(state.held) & int(state.previous_held)) & 0xffffffff
	state.previous_held = state.held
	_count_begin()
	var incoming_consumed: bool = _consume_incoming()
	if not is_recovering():
		_decode()
	# hard保持计时/播放冻结，但已接触incoming必须初始化新动画以失效旧attack。
	if not state.hard or incoming_consumed:
		_dispatch()
		if int(state.flags410) & 4 and state.ready:
			_dispatch()
		state.flags410 &= ~4
	if not state.ready:
		last_tick = state.duplicate(true)
		last_tick.events = _events.duplicate(true)
		return last_tick.duplicate(true)
	if state.pending_hard:
		state.hard = (int(state.hard)+int(state.pending_hard)) & 255
		state.pending_hard = 0
	elif state.hard:
		state.hard = (int(state.hard)-1) & 255
	if state.hard:
		state.playback_step = 0.0
	elif state.slow:
		state.slow -= 1
		state.playback_step = _f32(0.2)
	elif not state.primary in [34,35,1841,3]:
		state.playback_step = _f32(float(state.rate)*_f32(2))
	if is_dead() and state.phase == 2:
		state.playback_step = 0.0
	var diff: int = _s16(int(state.target)-int(state.yaw))
	state.yaw = (int(state.yaw)+clampi(diff,-yaw_max_step,yaw_max_step)) & 65535
	var result: Dictionary = animator.tick(float(state.playback_step))
	if result.is_empty():
		state.ready = false
		last_tick = state.duplicate(true)
		return last_tick.duplicate(true)
	var root_delta: Vector3 = result.root_delta
	if not int(state.flags288) & 0x20000:
		_add_local(root_delta)
	if not state.air280:
		# 仅非空中吸附明确平地缓存；地图坡面/高度采样尚未恢复。
		var position: Vector3 = state.position
		state.position = Vector3(position.x,state.floor_height,position.z)
	state.ticks += 1
	state.frames = result.frames.duplicate()
	state.frame = result.frames[0]
	state.blend_remaining = animator.tracks[0].blend_remaining
	state.name = _name(int(state.cate),int(state.sub))
	last_tick = state.duplicate(true)
	last_tick.root_delta = _world_direction(root_delta)
	last_tick.events = _events.duplicate(true)
	return last_tick.duplicate(true)
