extends SceneTree

const ControllerScript = preload("res://scripts/bulldrome_controller.gd")

# 经过真实动画边界计数，不用模拟provider替代原31clips。
class CountingAnimator extends HunterAnimator:
	var calls: int = 0
	var sampled: Dictionary = {}
	func tick(step: float) -> Dictionary:
		calls += 1
		sampled = super.tick(step)
		return sampled

var animator: CountingAnimator
var controller: ControllerScript
var checks: Array = []
var failures: Array = []
var simulation_ticks: int = 0
var spawns: Array = []
var trace: Array = []
var charge_distance: float = 0.0
var _last_trace: String = ""

func _initialize() -> void:
	var started: int = Time.get_ticks_usec()
	animator = CountingAnimator.new()
	_check("真实包6127加载", animator.load_data("res://assets/bulldrome_data.json"))
	controller = ControllerScript.new()
	if failures.is_empty():
		_check("configure验证单track/stride200/root1", controller.configure(animator))
		controller.sandbox_motion_enabled = false
		_run_checks()
	var results: Dictionary = {"engine":Engine.get_version_info().string,
		"passed":checks.size(), "failed":failures.size(), "checks":checks, "failures":failures,
		"simulation_ticks":simulation_ticks, "elapsed_seconds":float(Time.get_ticks_usec() - started) / 1000000.0,
		"charge_integrated_distance_source_units":charge_distance, "trace":trace,
		"source_labels":ControllerScript.SOURCE_LABELS, "limits":ControllerScript.LIMITS,
		"original_game_equivalence":false, "simulation_hz_policy":30,
		"visual_qa":"skipped; 非视觉actor逻辑测试，不改view/main",
		"measurement_scope":"真实Godot headless单进程；cache状态未知，无before/after，token和CPU/peak RSS由外部测量"}
	if not "--check" in OS.get_cmdline_user_args():
		var output = FileAccess.open(preload("res://tests/result_output.gd").path("res://tests/bulldrome_controller_results.json"), FileAccess.WRITE)
		if output != null:
			output.store_string(JSON.stringify(results, "\t"))
		else:
			failures.append("结果文件不可写")
	print("BULLDROME CONTROLLER: ", checks.size(), " passed / ", failures.size(), " failed; ", simulation_ticks, " ticks; charge distance ", charge_distance)
	for failure in failures:
		print("ASSERT FAIL: ", failure)
	quit(0 if failures.is_empty() else 1)

func _check(label: String, value: bool) -> void:
	if value:
		checks.append(label)
	else:
		failures.append(label)

func _player(position: Vector3 = Vector3.ZERO, hp: int = 100) -> Dictionary:
	return {"position":position, "hp":hp, "alive":hp > 0}

func _tick(player: Dictionary = {}) -> Dictionary:
	var before_calls: int = animator.calls
	var before_position: Vector3 = controller.state.position
	var result: Dictionary = controller.tick(_player() if player.is_empty() else player)
	simulation_ticks += 1
	if animator.calls != before_calls + 1 or result.animator_ticks != 1:
		failures.append("每tick唯一次动画调用 @%d" % simulation_ticks)
	if not controller.state.ready:
		failures.append("缺失动画 @%d" % simulation_ticks)
	var delta: Vector3 = animator.sampled.root_delta
	var rotated: Vector3 = Basis(Vector3.UP, float(controller.state.yaw) * TAU / 65536.0) * delta
	var applied: Vector3 = rotated if not controller.sandbox_motion_enabled or controller.state.mode in ["charge","hit","down","dying"] else Vector3.ZERO
	var expected: Vector3 = before_position + controller.state.approach_delta + applied
	if not controller.state.position.is_equal_approx(expected) or result.root_delta != delta:
		failures.append("root必须entity唯一次且不缩放 @%d" % simulation_ticks)
	if controller.state.frames != animator.sampled.frames:
		failures.append("frame必须与唯一sample一致 @%d" % simulation_ticks)
	for event in result.events:
		if event.event == "attack_spawn":
			spawns.append(event)
	var label: String = "%s/%d/%d" % [controller.state.mode, controller.state.phase, controller.state.primary]
	if label != _last_trace:
		trace.append({"tick":simulation_ticks, "state":label, "frame":controller.state.frames[0]})
		_last_trace = label
	return result

func _run(count: int, player: Dictionary = {}) -> void:
	for index in range(count):
		_tick(player)

func _until(mode: String, limit: int = 600, player: Dictionary = {}) -> bool:
	for index in range(limit):
		_tick(player)
		if controller.state.mode == mode:
			return true
	return false

func _reset(position: Vector3 = Vector3(0, 0, -500)) -> void:
	controller.ai_enabled = true
	controller.reset(position)
	spawns.clear()

func _run_checks() -> void:
	_check("原31clips资源覆盖", animator.data.clips.size() == 31)
	for key in animator.data.clips:
		var primary: int = int(key.split(":")[0])
		_check("原clip %d 可选可采样" % primary, animator.set_animation(primary, 0, 0) and not animator.tick(2.0).is_empty())
	var invalid = ControllerScript.new()
	_check("拒绝空animator", not invalid.configure(null))
	invalid.reset()
	_check("无效configure后reset不恢复ready", not invalid.state.ready)
	_reset()
	_check("初始化HP/原idle/来源限制", controller.state.hp == 1000 and controller.state.primary == 1001 and controller.state.limits.size() > 0)
	_run(1)
	_check("可读沙盒预备18tick", controller.state.mode == "prepare" and controller.state.prepare_ticks == 18)
	_run(17)
	_check("预备不spawn", spawns.is_empty() and controller.state.mode == "prepare")
	_tick()
	_check("phase0原1015 B10→phase1尚未spawn", controller.state.mode == "charge" and controller.state.phase == 1 and controller.state.primary == 1015 and controller.state.blend == 10 and spawns.is_empty())
	_tick()
	_check("phase1单spawn record4预算89", spawns.size() == 1 and spawns[0].record == 4 and controller.state.phase == 2 and controller.state.attack_budget == 89)
	var event: Dictionary = spawns[0]
	_check("hunter通知字段契约", event.primary == 1015 and event.start == 0 and event.blend_count == 10 and event.attack_scale == 100 and event.attack_id > 0)
	var charge_start: Vector3 = controller.state.position
	var limit: int = 120
	while controller.state.phase != 3 and limit > 0:
		_tick()
		limit -= 1
	charge_distance = controller.state.position.distance_to(charge_start)
	_check("真实root冲撞有位移无速度补偿", charge_distance > 0.0)
	_check("冲撞预算/距离结束原1016 B10", limit > 0 and controller.state.primary == 1016 and controller.state.blend == 10 and spawns.size() == 1)
	_check("原1016 END→0/1及30tick冷却", _until("idle") and controller.state.main == 0 and controller.state.sub == 1 and controller.state.cooldown_ticks == 30)
	_run(30)
	_check("冷却不新增攻击", controller.state.mode == "idle" and spawns.size() == 1)
	# 正前方固定测试两种source record，不向通用RNG伪造概率。
	var ahead: Vector3 = controller.state.position + Vector3(0, 0, 500)
	_check("下轮charge启动", _until("charge", 60, _player(ahead)))
	_tick(_player(ahead))
	_check("第二轮原record5且attack_id递增", spawns.size() == 2 and spawns[1].record == 5 and spawns[1].attack_id > event.attack_id)
	var pose: Array = animator.world_pose.duplicate()
	var frame: float = animator.tracks[0].currentframe
	var position: Vector3 = controller.state.position
	controller.stop_charge()
	_check("墙停止不改当次pose/frame/位置", pose == animator.world_pose and frame == animator.tracks[0].currentframe and position == controller.state.position)
	_tick()
	_check("墙停止下一tick原1016收招且无spawn", controller.state.phase == 3 and controller.state.primary == 1016 and spawns.size() == 2)
	_reset()
	_until("charge", 60)
	# 保留真实动画执行，注入远目标只隔离90tick source预算分支。
	controller.state.remaining_distance = 100000.0
	_run(89)
	_check("90tick预算未提前结束", controller.state.phase == 2 and controller.state.attack_budget == 1 and spawns.size() == 1)
	_tick()
	_check("原90tick预算结束收招", controller.state.phase == 3 and controller.state.attack_budget == 0 and controller.state.primary == 1016 and spawns.size() == 1)
	_reset()
	_until("charge", 60)
	controller.stop_charge()
	_tick()
	_check("spawn之前墙停止直接收招不造攻击", controller.state.primary == 1016 and controller.state.phase == 3 and spawns.is_empty())
	controller.sandbox_motion_enabled = true
	_reset(Vector3(0, 0, -1500))
	_run(2)
	_check("普通approach地面1003 + 沙盒加速3/最高18", controller.state.mode == "reacquire" and controller.state.primary == ControllerScript.WALK_CLIP and is_equal_approx(controller.state.approach_delta.length(), 6.0) and controller.state.position.z > -1500)
	_check("接近后进入预备", _until("prepare", 100))
	# 默认沙盒快速转向；显式来源轨迹的phase/window/END覆盖在test_turn_pacing。
	for angle in [0x3000, 0x6000, 0x8000, 0xa000, 0xd000]:
		_reset(Vector3.ZERO)
		var target: Vector3 = Basis(Vector3.UP, angle * TAU / 65536.0) * Vector3(0, 0, 190)
		var player: Dictionary = _player(target)
		controller._begin_attack(target,"turn_attack")
		_check("角%d显式选招进入单次转向" % angle, controller.state.mode == "turn_attack")
		_check("角%d最短方向clip" % angle, controller.state.primary == (1019 if angle >= 0x8000 else 1018))
		_run(ControllerScript.TURN_TICKS-1, player)
		_check("角%d保留激活期/单record2" % angle, controller.state.mode == "turn_attack" and spawns.size() == 1 and spawns[0].record == 2)
		_tick(player)
		_check("角%d准确对准/15tick结束/可移动恢复/显式终止" % angle, controller.state.yaw == angle and controller.state.mode == "move_recovery" and controller.state.cooldown_ticks == ControllerScript.MOVE_RECOVERY_TICKS.turn_attack and controller.state.events.any(func(e): return e.event == "attack_end"))
		_check("角%d下一招仍有18tick前摇" % angle, _until("prepare",120,player) and controller.state.prepare_ticks == 18)
	_damage_checks()
	_death_checks()
	_reset()
	controller.ai_enabled = false
	position = controller.state.position
	_run(100)
	_check("ai关闭稳定idle/无移动无攻击", controller.state.position == position and controller.state.primary == 1001 and spawns.is_empty())
	controller.ai_enabled = true
	_check("AI恢复charge", _until("charge", 60))
	_tick()
	controller.ai_enabled = false
	var disabled_count: int = spawns.size()
	_tick()
	position = controller.state.position
	_run(30)
	_check("攻击中ai关闭取消执行并稳定idle", controller.state.mode == "idle" and controller.state.position == position and spawns.size() == disabled_count)
	controller.ai_enabled = true
	_until("charge", 60)
	_tick()
	var count: int = spawns.size()
	_tick(_player(Vector3.ZERO, 0))
	position = controller.state.position
	_run(100, _player(Vector3.ZERO, 0))
	_check("玩家hp0主动idle停攻不追打", controller.state.mode == "idle" and controller.state.primary == 1001 and position == controller.state.position and spawns.size() == count)
	# 公共返回快照不能反向改actor内部。
	var result: Dictionary = _tick(_player(Vector3.ZERO, 0))
	result.state.hp = -1
	_check("返回state独立快照", controller.state.hp == 1000)

func _damage_checks() -> void:
	_reset()
	_tick()
	controller.take_damage(120, 0)
	_tick()
	_check("预备受击取消未来spawn", controller.state.mode == "hit" and controller.state.primary == 1060 and spawns.is_empty())
	_reset()
	_until("charge", 60)
	_tick()
	var pose: Array = animator.world_pose.duplicate()
	var old_primary: int = controller.state.primary
	controller.take_damage(60, int(controller.state.yaw))
	_check("damage即时HP但不改sample", controller.state.hp == 940 and pose == animator.world_pose and controller.state.primary == old_primary)
	_tick()
	_check("不足120不每hit硬直", controller.state.mode == "charge")
	controller.take_damage(60, int(controller.state.yaw))
	_tick()
	_check("累计120中断原1060受击/不spawn", controller.state.mode == "hit" and controller.state.primary == 1060 and controller.state.events.all(func(e): return e.event != "attack_spawn"))
	_check("怒阈值100/1800/f32rate", controller.state.rage_ticks > 1790 and controller.state.rate == 1.100000023841858)
	_check("受击END恢复", _until("idle"))
	for source in [0x5000, 0xb000, 0x8000]:
		_reset()
		controller.take_damage(120, source)
		_tick()
		var expected: int = 1060 if source == 0x5000 else 1061 if source == 0xb000 else 1020
		_check("原方向受击%d" % expected, controller.state.primary == expected)
	_reset()
	controller.take_damage(250, 0)
	_tick()
	_check("累计250原1062倒地", controller.state.mode == "down" and controller.state.primary == 1062)
	var observed: Array = []
	for index in range(500):
		_tick()
		if controller.state.primary not in observed:
			observed.append(controller.state.primary)
		if controller.state.primary == 1063 and controller.state.recovery_ticks == 150:
			controller.take_damage(120, 0xb000)
			var frame: float = animator.tracks[0].currentframe
			_tick()
			_check("倒地追加伤害不重启动画stunlock", controller.state.primary == 1063 and animator.tracks[0].currentframe >= frame and controller.state.recovery_ticks == 149)
		if controller.state.mode == "idle":
			break
	_check("倒地1063→150计数→1066 END恢复/不攻击", 1063 in observed and 1066 in observed and controller.state.mode == "idle" and spawns.is_empty())
	_reset()
	controller.take_damage(250, 0xb000)
	_tick()
	_check("反向倒地原1067", controller.state.primary == 1067)

func _death_checks() -> void:
	_reset()
	_until("charge", 60)
	_tick()
	var last_id: int = controller.state.attack_id
	var primary: int = controller.state.primary
	controller.take_damage(1000, int(controller.state.yaw))
	_check("接触死亡即时HP0/alivefalse不改当次动画", controller.state.hp == 0 and not controller.state.alive and controller.state.primary == primary)
	_tick()
	_check("下tick死亡原倒地中断攻击", controller.state.mode == "dying" and controller.state.primary == 1062)
	var count: int = spawns.size()
	var observed: Array = []
	for index in range(600):
		_tick()
		if controller.state.primary not in observed:
			observed.append(controller.state.primary)
		if controller.state.mode == "dead":
			break
	_check("死亡1063 END→1064 END尸体", 1063 in observed and 1064 in observed and controller.state.mode == "dead")
	var corpse: Vector3 = controller.state.position
	var pose: Array = animator.world_pose.duplicate()
	_run(1900)
	controller.take_damage(100, 0)
	_check("超过原1800不复活/不攻击/尸体不漂移", controller.state.mode == "dead" and not controller.state.alive and controller.state.hp == 0 and controller.state.position == corpse and animator.world_pose == pose and spawns.size() == count)
	_reset(Vector3(30, 0, -500))
	_check("reset清生命/行为/原单位位置保留单调ID", controller.state.hp == 1000 and controller.state.alive and controller.state.ticks == 0 and controller.state.mode == "idle" and controller.state.position == Vector3(30, 0, -500) and controller.state.attack_id == last_id)
	_until("charge", 60, _player(Vector3(30, 0, 0)))
	_tick(_player(Vector3(30, 0, 0)))
	_check("reset后新attack_id严格递增", spawns.size() == 1 and spawns[0].attack_id > last_id)
