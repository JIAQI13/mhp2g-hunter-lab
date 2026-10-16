extends SceneTree

const AnimatorScript = preload("res://scripts/hunter_animator.gd")
const ControllerScript = preload("res://scripts/hunter_controller.gd")
var animator: HunterAnimator
var controller: HunterController
var checks: Array = []
var failures: Array = []
var ticks: int = 0

func _initialize() -> void:
	animator = AnimatorScript.new()
	_check("真实双轨资源加载",animator.load_data() and animator.tracks.size() == 2)
	controller = ControllerScript.new()
	controller.configure(animator)
	if failures.is_empty():
		_run_checks()
	var output = FileAccess.open(preload("res://tests/result_output.gd").path("res://tests/hunter_recovery_results.json"),FileAccess.WRITE)
	output.store_string(JSON.stringify({"engine":Engine.get_version_info().string,"passed":checks.size(),
		"failed":failures.size(),"ticks":ticks,"checks":checks,"failures":failures,
		"equivalence":false,"scope":"真实Animator+选定kind0地面轻/重/起身/死亡入口；guard削血沙盒；无原游戏执行",
		"visual_qa":"skipped; non-visual controller task"},"\t"))
	print("HUNTER RECOVERY TESTS ",checks.size()," passed / ",failures.size()," failed; ",ticks," ticks")
	for failure in failures:
		print("ASSERT FAIL: ",failure)
	quit(0 if failures.is_empty() else 1)

func _check(label: String, condition: bool) -> void:
	if condition:
		checks.append(label)
	else:
		failures.append(label)

func _tick(held: int = 0, magnitude: int = 0, direction: int = 0) -> Dictionary:
	ticks += 1
	var result: Dictionary = controller.tick(held,magnitude,direction)
	_check("任务%d资源有效/至多两次分派" % ticks,result.ready and result.dispatches <= 2)
	return result

func _events(result: Dictionary, name: String) -> Array:
	return result.events.filter(func(event: Dictionary) -> bool: return event.event == name)

func _finish() -> void:
	var limit: int = 400
	while controller.is_recovering() and not controller.is_dead() and limit > 0:
		var previous_primary: int = controller.state.primary
		var ended: bool = animator.animation_ended()
		var result: Dictionary = _tick(0x7000,127,32768)
		_check("恢复不得产生attack %d" % ticks,_events(result,"attack_spawn").is_empty())
		if result.primary != previous_primary:
			_check("恢复动画只能由真实END交接 %d" % ticks,ended)
		if controller.is_recovering():
			_check("恢复禁普通攻击移动handler %d" % ticks,result.cate == 2 and result.yaw == 0)
		limit -= 1
	_check("真实END完成恢复",not controller.is_recovering() and limit > 0)

func _guard_setup(stamina: int = 750) -> void:
	controller.reset()
	controller.force_action(2,3)
	_tick(0x200)
	controller.state.stamina = stamina

func _run_checks() -> void:
	_check("中性HP初始化",controller.state.hp == 100 and controller.state.hp_max == 100 and not controller.is_dead())
	for bad in [[-1,20,0],[20,-1,0],[20,256,0],[20,20,-1],[20,20,65536]]:
		_check("拒绝非法incoming %s" % str(bad),controller.queue_incoming(bad[0],bad[1],bad[2]).status == "invalid")
	# 原方向分支与power10/11边界，两种持刀状态都用真实受击clip。
	for drawn in [false,true]:
		for forward in [true,false]:
			controller.reset()
			controller.state.flags410 = 8 if drawn else 0
			var yaw: int = 0 if forward else 32768
			_check("轻受击排队",controller.queue_incoming(20,10,yaw).status == "pending" and controller.state.hp == 100)
			_check("同任务第二attack去重",controller.queue_incoming(99,255,yaw).get("duplicate",false))
			var hit: Dictionary = _tick(0x1000,127)
			_check("轻受击HP只扣一次",hit.hp == 80 and _events(hit,"player_damage").size() == 1)
			_check("轻受击dispatch上下文",hit.recovery == "light" and hit.sub == (13 if forward else 9) and hit.primary == (1211 if drawn else 201) and hit.source_owner.contains("09a8a1d0"))
			_check("轻受击不虚构保护窗",hit.internal_window == 0 and controller.attack_collision_allowed())
			_check("UI不能绕过恢复",not controller.force_action(1,19))
			controller.toggle_weapon()
			_check("toggle不改受击动作",controller.state.recovery == "light")
			_finish()
			_check("恢复后可正常选择攻击",controller.force_action(1,0))
	# 轻受击本身没有无敌，可被下一任务真实incoming打断。
	controller.reset()
	controller.queue_incoming(20,0,0)
	_tick()
	_check("轻受击允许再接触",controller.queue_incoming(20,11,0).status == "pending")
	var down: Dictionary = _tick()
	_check("power11重地面而非kind2 launch",down.hp == 60 and down.recovery == "down" and down.sub == 6 and down.primary == 204 and down.air280 == 0)
	_finish()
	for forward in [true,false]:
		controller.reset()
		controller.queue_incoming(20,20,0 if forward else 32768)
		down = _tick()
		_check("重地面前后真实clip",down.primary == (204 if forward else 202) and down.sub == (6 if forward else 0))
		_check("重地面源再受击窗口",down.internal_window == 2 and controller.queue_incoming(20,20,0).status == "evaded")
		controller.state.hard = 3
		var frozen_frame: float = animator.tracks[0].currentframe
		_tick()
		_check("hard保持窗口和动画冻结",controller.state.internal_window == 2 and animator.tracks[0].currentframe == frozen_frame)
		_finish()
		_check("恢复后源窗口6",controller.state.internal_window == 6)
		controller.state.hard = 0
		for i in range(6):
			var before: int = controller.state.internal_window
			_tick()
			_check("唯一计时每任务减一次",controller.state.internal_window == before-1)
		_check("恢复窗口非永久",controller.queue_incoming(20,20,0).status == "pending")
	controller.reset()
	controller.queue_incoming(20,20,12345)
	controller.state.yaw = 32768
	var aimed: Dictionary = _tick(0,127,60000)
	_check("hurt使用接触时方向快照而非当前转向",aimed.yaw == 12345 and aimed.target == 12345 and aimed.sub == 6)
	# 防御方向用既有guard owner的原resolved yaw门，不重解成世界front。
	for row in [[14,75,0,11],[15,100,5,1],[39,100,5,1],[40,180,10,10],[255,180,10,10]]:
		_guard_setup()
		_check("防御成功只排队 %d" % row[0],controller.queue_incoming(20,row[0],32768).status == "guarded" and controller.state.stamina == 750)
		controller.state.yaw = 0x4000
		controller.force_action(1,19)
		var guarded: Dictionary = _tick(0x1000,127,0)
		_check("queued防御资格方向不被后续输入改变",guarded.cate == 2 and guarded.sub == row[3] and guarded.recovery == "none")
		_check("guard成本削血仅提交一次",guarded.stamina == 750-row[1] and guarded.hp == 100-row[2] and _events(guarded,"player_guard").size() == 1 and _events(guarded,"player_damage").size() == 1 and _events(guarded,"player_damage")[0].guarded)
	_guard_setup()
	_check("方向不合格pending非guarded",controller.queue_incoming(20,10,0).status == "pending")
	var rejected: Dictionary = _tick(0x200)
	_check("方向拒绝接入真正hurt非guard反冲",rejected.recovery == "light" and rejected.primary == 1211 and rejected.hp == 80)
	_guard_setup(74)
	_check("74耐力不能防御",controller.queue_incoming(20,20,32768).status == "pending")
	_tick()
	_check("低耐力普通hit扣HP",controller.state.hp == 80)
	_guard_setup(75)
	controller.queue_incoming(20,40,32768)
	_tick()
	_check("75重防御耗尽",controller.state.stamina == 0 and controller.state.hp == 90)
	controller.force_action(2,3)
	_tick(0x200)
	_check("耗尽不能无限防御",controller.queue_incoming(20,10,32768).status == "pending")
	# 蓄力/挥剑中断，新源动画使Combat旧事件身份失效，之后不得release。
	for sub in [0,19,26]:
		controller.reset()
		controller.force_action(1,sub)
		var attack: Dictionary = _tick(0x1000)
		var old_primary: int = attack.primary
		controller.state.hard = 3
		controller.queue_incoming(20,20,0)
		var interrupted: Dictionary = _tick(0)
		_check("hard内incoming仍换源动画",interrupted.primary != old_primary and interrupted.recovery == "down" and _events(interrupted,"attack_spawn").is_empty())
		_finish()
	# 接触窗口必须在queue当时判断，不在下一任务递减后重新接收。
	controller.reset()
	controller.state.internal_window = 1
	_check("窗口末任务接触仍evaded",controller.queue_incoming(20,20,0).status == "evaded")
	var evaded: Dictionary = _tick()
	_check("evaded不扣HP不发事件",evaded.hp == 100 and evaded.internal_window == 0 and _events(evaded,"player_damage").is_empty())
	controller.reset()
	controller.queue_incoming(100,20,0)
	var dead: Dictionary = _tick(0x7000,127,32768)
	_check("死亡入口HP0与真实210",dead.hp == 0 and dead.cate == 3 and dead.primary == 210 and controller.is_dead() and controller.is_recovering() and _events(dead,"player_dead").size() == 1)
	_check("死亡拒绝incoming和直接UI",controller.queue_incoming(20,20,0).status == "dead" and not controller.force_action(0,1))
	var death_end_seen: bool = false
	for i in range(ceili(animator.tracks[0].end / 2.0) + 10):
		death_end_seen = death_end_seen or animator.animation_ended()
		var terminal: Dictionary = _tick(0x7000,127,32768)
		controller.toggle_weapon()
		_check("死亡永不idle/攻击 %d" % i,terminal.cate == 3 and terminal.recovery == "dead" and terminal.primary == 210 and _events(terminal,"attack_spawn").is_empty() and _events(terminal,"player_dead").is_empty())
	_check("死亡真实END后保持终态",death_end_seen and controller.state.phase == 2 and controller.state.playback_step == 0.0)
	controller.reset()
	controller.force_action(1,0)
	var first_id: int = _events(_tick(),"attack_spawn")[0].attack_id
	controller.queue_incoming(100,20,0)
	controller.reset()
	var clean: Dictionary = _tick()
	_check("reset清HP恢复pending",clean.hp == 100 and clean.recovery == "none" and not controller.is_dead() and _events(clean,"player_damage").is_empty())
	controller.force_action(1,0)
	_check("reset保留单调attack_id",_events(_tick(),"attack_spawn")[0].attack_id > first_id)
