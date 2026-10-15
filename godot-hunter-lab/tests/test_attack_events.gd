extends SceneTree

const Owner = preload("res://scripts/attack_events.gd")
const Animator = preload("res://scripts/hunter_animator.gd")
const Hunter = preload("res://scripts/hunter_controller.gd")
const Boar = preload("res://scripts/bulldrome_controller.gd")
var hunter_animator: HunterAnimator
var boar_animator: HunterAnimator
var checks: Array = []
var failures: Array = []
var calls: int = 0
var contacts_observed: Array = []

func check(label: String, condition: bool) -> void:
	if condition:
		checks.append(label)
	else:
		failures.append(label)
		print("ASSERT FAIL: ", label)

func _initialize() -> void:
	hunter_animator = Animator.new()
	boar_animator = Animator.new()
	check("加载真实猎人与猪王资源", hunter_animator.load_data() and boar_animator.load_data("res://assets/bulldrome_data.json"))
	if failures.is_empty():
		_boundaries()
		_geometry()
		_lifetime()
		_workflows()
	var result: Dictionary = {"engine":Engine.get_version_info().string, "passed":checks.size(), "failed":failures.size(), "checks":checks, "failures":failures, "simulation_calls":calls, "contacts":contacts_observed, "scope":"真实导出资产/真实controller与animator；几何golden为独立解析预期；未执行原游戏，非伤害/AI等价证明", "initialization":"hunter start>>1; shell24 start不除2; delay0不调整; short334余数绝对值,u8后s8负钳0", "ownership":"HP/资格窗口由caller拥有，history只随存活event保留；reset须与producer配对；shell24 selector0/2需caller显式shell24_active源资格，不猜mode", "visual_qa":"skipped: nonvisual owner task"}
	var output = FileAccess.open("res://tests/attack_events_test_results.json", FileAccess.WRITE)
	if output != null:
		output.store_string(JSON.stringify(result, "\t"))
	print("ATTACK EVENTS TESTS ", checks.size(), " passed / ", failures.size(), " failed; ", calls, " calls")
	quit(0 if failures.is_empty() else 1)

func actor(record: int = 3, id: int = 1, primary: int = 1428, start: int = 0, blend: int = 0) -> Dictionary:
	return {"primary":primary, "yaw":0, "position":Vector3.ZERO, "alive":true, "hard":0, "slow":0, "events":[{"event":"attack_spawn", "record":record, "primary":primary, "start":start, "blend_count":blend, "attack_scale":100, "attack_id":id}]}

func target(identity: String = "monster", generation: int = 0) -> Dictionary:
	# 显式巨大hurt-volume测试夹具，不冒充原physical-bodycircle。
	return {"identity":identity, "generation":generation, "eligible":true, "volumes":[{"kind":"sphere", "a":Vector3.ZERO, "radius":100.0}]}

func tick(owner: AttackEvents, state: Dictionary, targets: Array[Dictionary], animator: HunterAnimator = null) -> Array[Dictionary]:
	calls += 1
	return owner.tick(state, hunter_animator if animator == null else animator, 0, targets)

func _boundaries() -> void:
	var owner := Owner.new()
	var data: Dictionary = hunter_animator.data.combat.duplicate(true)
	data.erase("neutral_profile")
	for row in data.records.values():
		row.erase("power")
		row.erase("edge_delay_byte")
		row.erase("edge_duration_byte")
	check("common不要求中性profile/power/非几何edge字段", owner.configure(data))
	check("未知初始化kind显式拒绝且清旧配置", not owner.configure(data, "guessed") and owner.read_record(3).is_empty())
	check("猪王直接shape_lists配置无需adapter复制解析", owner.configure(boar_animator.data.combat, "shell24"))
	for id in range(7):
		var row: Dictionary = owner.read_record(id)
		check("猪王record%d保留source/raw byte2不叫power" % id, row.id == id and row.has("byte2_raw") and not row.has("power") and row.source is Dictionary)
	var state: Dictionary = actor(0, 1, 1015)
	check("unsupported0保留事实但不可spawn", tick(owner, state, [target()], boar_animator).is_empty() and owner.snapshot().attacks.is_empty() and owner.read_record(0).supported == false)
	state = actor(4, 2, 1015)
	tick(owner, state, [target()], boar_animator)
	var before: Dictionary = owner.snapshot()
	var copied: Dictionary = owner.read_record(4)
	copied.delay_byte = 254
	var inspection: Dictionary = owner.snapshot()
	inspection.attacks[0].delay = 127
	check("公开快照与记录不能反写owner", owner.snapshot() == before and owner.read_record(4).delay_byte == 20)
	for malformed in ["kind", "radius", "point", "source", "unterminated"]:
		data = hunter_animator.data.combat.duplicate(true)
		match malformed:
			"kind": data.shapes["0"][0].kind = 3
			"radius": data.shapes["0"][0].radius = INF
			"point": data.shapes["0"][0].point_a[2] = 1e100
			"source": data.records["3"].erase("source")
			"unterminated": data.shape_tables["0"].terminated = false
		check("边界fail closed %s" % malformed, not owner.configure(data) and owner.snapshot().attacks.is_empty() and owner.read_record(3).is_empty())
	check("恢复真实猎人配置", owner.configure(hunter_animator.data.combat))
	state = actor()
	tick(owner, state, [target()])
	state.events = []
	for invalid in [{"kind":"unknown"}, {"kind":"sphere", "a":Vector3.ZERO, "radius":-1}, {"kind":"sphere", "a":Vector3(NAN,0,0), "radius":1}, {"kind":"capsule", "a":Vector3.ZERO, "radius":1}, {"kind":"aabb", "low":Vector3.ONE, "high":Vector3.ZERO}]:
		check("非法target几何静态拒绝 %s" % str(invalid), Owner.read_volume(invalid).is_empty() and not Owner.volumes_intersect({"kind":"sphere", "a":Vector3.ZERO, "radius":1}, invalid))
	for i in range(18):
		var rejected: Dictionary = target()
		rejected.volumes = [{"kind":"unknown"}, {"kind":"sphere", "a":Vector3.ZERO, "radius":100}]
		tick(owner, state, [rejected])
	check("未知kind不得通过同target其他shape绕过/history不写", owner.snapshot().attacks[0].history.is_empty())
	check("合法target随后真实接触", tick(owner, state, [target()]).size() == 1)

func _geometry() -> void:
	var low := Vector3(-1,-1,-1)
	var high := Vector3(1,1,1)
	var box: Dictionary = {"kind":"aabb", "low":low, "high":high}
	var corner: Dictionary = {"kind":"capsule", "a":Vector3(1.4,1.4,-0.5), "b":Vector3(1.4,1.4,0.5), "radius":0.5}
	check("capsule-AABB角落不扩张", not Owner.volumes_intersect(corner, box) and is_equal_approx(Owner.segment_box_distance_squared(corner.a, corner.b, low, high), 0.32))
	check("capsule-AABB精确切线", Owner.volumes_intersect({"kind":"capsule", "a":Vector3(1.5,0,-2), "b":Vector3(1.5,0,2), "radius":0.5}, box))
	check("sphere-AABB退化角落golden3", is_equal_approx(Owner.segment_box_distance_squared(Vector3(2,2,2), Vector3(2,2,2), low, high), 3))
	check("sphere-AABB角落falsepositive拒绝", not Owner.volumes_intersect({"kind":"sphere", "a":Vector3(1.4,1.4,0), "radius":0.5}, box))
	check("AABB穿越线段零", Owner.segment_box_distance_squared(Vector3(-3,0,0), Vector3(3,0,0), low, high) == 0)
	var alternate_box: Dictionary = {"kind":"aabb", "a":low, "b":high, "radius":0.0}
	check("AABB a/b入口一次规范化同low/high", Owner.read_volume(alternate_box) == box and not Owner.volumes_intersect(corner, alternate_box))
	check("AABB任意正radius也不扩大角落", not Owner.volumes_intersect(corner, {"kind":"aabb", "a":low, "b":high, "radius":100.0}))
	var goldens: Array = [
		[Vector3.ZERO,Vector3(2,0,0),Vector3(0,1,0),Vector3(2,1,0),1.0,"平行"],
		[Vector3.ZERO,Vector3(2,0,0),Vector3(2,1,0),Vector3(0,1,0),1.0,"反向平行"],
		[Vector3.ZERO,Vector3(1,0,0),Vector3(2,1,0),Vector3(3,1,0),2.0,"端点限制"],
		[Vector3.ZERO,Vector3.ZERO,Vector3(0,1,-1),Vector3(0,1,1),1.0,"单退化"],
		[Vector3.ZERO,Vector3.ZERO,Vector3.ONE,Vector3.ONE,3.0,"双退化"],
		[Vector3(-1,0,0),Vector3(1,0,0),Vector3(0,-1,0),Vector3(0,1,0),0.0,"相交"],
		[Vector3(-1,0,0),Vector3(1,0,0),Vector3(0,-1,2),Vector3(0,1,2),4.0,"异面"]]
	for golden in goldens:
		check("segment-segment独立golden " + golden[5], is_equal_approx(Owner.segment_segment_distance_squared(golden[0], golden[1], golden[2], golden[3]), golden[4]))
	var sphere: Dictionary = {"kind":"sphere", "a":Vector3.ZERO, "radius":0.5}
	var capsule: Dictionary = {"kind":"capsule", "a":Vector3(1,-1,0), "b":Vector3(1,1,0), "radius":0.5}
	check("sphere-capsule切线对称", Owner.volumes_intersect(sphere, capsule) and Owner.volumes_intersect(capsule, sphere))
	check("sphere-sphere切线", Owner.volumes_intersect(sphere, {"kind":"sphere", "a":Vector3.RIGHT, "radius":0.5}))
	check("sphere-sphere分离", not Owner.volumes_intersect(sphere, {"kind":"sphere", "a":Vector3(1.01,0,0), "radius":0.5}))
	check("capsule-capsule平行切线", Owner.volumes_intersect(capsule, {"kind":"capsule", "a":Vector3(2,-1,0), "b":Vector3(2,1,0), "radius":0.5}))
	var bone := Transform3D(Basis(Vector3(2,0,0),Vector3(0,3,0),Vector3(0,0,4)),Vector3(10,20,30))
	check("完整boneworld局部/一次.01/lift/entity yaw position", Owner.world_point(bone * Vector3(1,2,3), {"yaw":16384,"position":Vector3(100,200,300)}, 0.5).is_equal_approx(Vector3(1.42,2.76,2.88)))

func _lifetime() -> void:
	for kind in ["hunter", "shell24"]:
		var owner := Owner.new()
		check("显式sourcekind配置 " + kind, owner.configure(boar_animator.data.combat, kind))
		for start in [0,8,32]:
			owner.reset()
			var expected: int = (9 - (start >> 1)) if kind == "hunter" else 9 - start
			expected = maxi(0, expected)
			var state: Dictionary = actor(4,1,1015,start)
			check("%s start%d S0不可碰撞" % [kind,start], tick(owner,state,[target()],boar_animator).is_empty())
			check("%s start%d源delay=%d" % [kind,start,expected], owner.snapshot().attacks[0].delay == expected)
			var blend25_expected: int = 34 - ((start >> 1) if kind == "hunter" else start)
			check("%s start%d blend25显式不被负钳掩盖差异" % [kind,start], owner.initial_delay(4,25,start) == blend25_expected)
			state.events = []
			for i in range(expected):
				check("%s start%d olddelay%d不可碰撞" % [kind,start,expected-i], tick(owner,state,[target()],boar_animator).is_empty())
			check("%s start%d olddelay0进入active" % [kind,start], tick(owner,state,[target()],boar_animator).size() == 1)
		check("%s D0不调整" % kind, owner.initial_delay(2,99,300) == 0)
		check("%s u8回绕后signed负钳0" % kind, owner.initial_delay(4,0,256 if kind == "shell24" else 512) == 9 and owner.initial_delay(4,0,100) == 0)
	var owner := Owner.new()
	owner.configure(hunter_animator.data.combat)
	var state: Dictionary = actor()
	tick(owner,state,[target()])
	state.events = []
	state.hard = 1
	tick(owner,state,[])
	check("hunter hard等待消耗delay且duration补偿", owner.snapshot().attacks[0].delay == 16 and owner.snapshot().attacks[0].duration == 6)
	state.hard = 0
	state.slow = 1
	tick(owner,state,[])
	check("hunter slow消费后非零补偿", owner.snapshot().attacks[0].duration == 7)
	state.slow = 0
	tick(owner,state,[])
	check("hunter slow已消费零不补偿", owner.snapshot().attacks[0].duration == 7)
	owner.reset()
	state = actor()
	tick(owner,state,[])
	state.events = []
	for i in range(21):
		tick(owner,state,[])
	check("lastactive旧1消费到0仍接触", tick(owner,state,[target()]).size() == 1 and owner.snapshot().attacks[0].duration == 0)
	state.hard = 1
	check("旧duration0不被hard复活/退休history清理", tick(owner,state,[target("next")]).is_empty() and owner.snapshot().attacks.is_empty())
	state = actor(3,1)
	check("退休后重放ID不能生成event", tick(owner,state,[target()]).is_empty() and owner.snapshot().attacks.is_empty())
	state = actor(3,2)
	tick(owner,state,[])
	state.events = []
	state.primary = 1406
	check("animation ID变化取消旧event", tick(owner,state,[target()]).is_empty() and owner.snapshot().attacks.is_empty())
	state = actor(3,3)
	tick(owner,state,[])
	state.alive = false
	check("actor死亡取消包括新通知", tick(owner,state,[target()]).is_empty() and owner.snapshot().attacks.is_empty())
	owner.configure(boar_animator.data.combat,"shell24")
	state = actor(4,1,1015)
	tick(owner,state,[],boar_animator)
	state.events = []
	tick(owner,state,[],boar_animator)
	check("shell24 selector3等待维护refresh99", owner.snapshot().attacks[0].delay == 8 and owner.snapshot().attacks[0].duration == 99)
	owner.reset()
	state = actor(2,1,1018)
	tick(owner,state,[],boar_animator)
	state.events = []
	state.hard = 1
	state.slow = 1
	tick(owner,state,[],boar_animator)
	check("shell24 selector1无猜测人类hard/slow补偿", owner.snapshot().attacks[0].duration == 121)
	for i in range(120):
		tick(owner,state,[],boar_animator)
	check("shell24 selector1 last1到0当次可接触", tick(owner,state,[target()],boar_animator).size() == 1 and owner.snapshot().attacks[0].duration == 0)
	check("shell24 selector1 old0退休不复活", tick(owner,state,[],boar_animator).is_empty() and owner.snapshot().attacks.is_empty())
	for record_id in [1,3]:
		owner.reset()
		state = actor(record_id,1,1015)
		tick(owner,state,[],boar_animator)
		state.events = []
		check("shell24 selector0/2未解析源活动资格fail closed %d" % record_id, tick(owner,state,[target()],boar_animator).is_empty() and owner.snapshot().attacks.is_empty())
		owner.reset()
		state = actor(record_id,1,1015)
		state.shell24_active = true
		tick(owner,state,[],boar_animator)
		state.events = []
		check("shell24 selector0/2显式源活动资格允许接触 %d" % record_id, tick(owner,state,[target()],boar_animator).size() == 1 and owner.snapshot().attacks[0].duration == 99)
		state.shell24_active = false
		check("shell24 selector0/2源活动资格消失退休 %d" % record_id, tick(owner,state,[],boar_animator).is_empty() and owner.snapshot().attacks.is_empty())

func _workflows() -> void:
	var hunter := Hunter.new()
	hunter.configure(hunter_animator)
	var owner := Owner.new()
	owner.configure(hunter_animator.data.combat)
	hunter.state.flags410 |= 8
	hunter.force_action(1,26)
	var observed: Array = []
	# 怪物形target是caller显式hurt夹具，不拿physical移动body圈当攻击几何。
	var monster: Dictionary = {"identity":"bulldrome_hurt_fixture", "generation":0, "eligible":true, "volumes":[{"kind":"capsule","a":Vector3(0,0.4,1.9),"b":Vector3(0,1.2,2.5),"radius":0.65}]}
	for i in range(60):
		var state: Dictionary = hunter.tick(0,0,0)
		observed.append_array(tick(owner,state,[monster]))
	check("真实hunter producer/pose向monster-shaped hurt target一次接触", observed.size() == 1)
	if not observed.is_empty():
		var contact: Dictionary = observed[0]
		check("contact实际接口无damage/HP保留source", contact.event == "contact" and contact.position is Vector3 and contact.record == 3 and contact.attack_scale == 100 and contact.target_identity == monster.identity and contact.target_generation == 0 and contact.source is Dictionary and contact.shape_source is Dictionary and not contact.has("damage") and not contact.has("hp"))
		contacts_observed.append(contact)
	# 真实猪王决策链采样产生shell24通知；无需改controller。
	var boar := Boar.new()
	check("真实猪王controller配置", boar.configure(boar_animator))
	boar.reset(Vector3(0,0,-100))
	var shell_actor: Dictionary = {}
	for i in range(80):
		var result: Dictionary = boar.tick({"position":Vector3(0,0,400),"hp":100,"alive":true})
		if not result.events.is_empty():
			for event in result.events:
				if event.event == "attack_spawn":
					shell_actor = result.state.duplicate(true)
					shell_actor.events = [event]
			if not shell_actor.is_empty():
				break
	check("真实猪王产生record4/5完整创建快照", not shell_actor.is_empty() and shell_actor.events[0].record in [4,5])
	if shell_actor.is_empty():
		return
	owner.configure(boar_animator.data.combat,"shell24")
	hunter.reset()
	hunter.force_action(0,28)
	hunter.tick(0,0,0)
	check("真实滚动owner生产资格窗口6", hunter.state.internal_window == 6 and not hunter.attack_collision_allowed())
	var shell_shape: Dictionary = boar_animator.data.combat.shapes["2"][0]
	var a: Vector3 = Owner.world_point(boar_animator.world_pose[2] * Vector3(shell_shape.point_a[0],shell_shape.point_a[1],shell_shape.point_a[2]),shell_actor,0)
	var player: Dictionary = {"identity":"player", "generation":0, "eligible":false, "volumes":[{"kind":"capsule","a":a,"b":a+Vector3(0,0.8,0),"radius":0.3}]}
	tick(owner,shell_actor,[player],boar_animator)
	shell_actor.events = []
	# 仅owner source delay推进，hunter controller不调用所以窗口仍6。
	var startup_calls: int = int(owner.snapshot().attacks[0].delay) + 2
	for i in range(startup_calls):
		check("回避eligiblefalse拒绝shell geometry/history %d" % i, tick(owner,shell_actor,[player],boar_animator).is_empty() and owner.snapshot().attacks[0].history.is_empty())
	var queued: Dictionary = owner.snapshot()
	for i in range(100):
		owner.snapshot()
	check("排队render读取不tick不推进window/event", owner.snapshot() == queued and hunter.state.internal_window == 6)
	for i in range(6):
		hunter.tick(0,0,0)
		player.eligible = hunter.attack_collision_allowed()
		var contacts: Array[Dictionary] = tick(owner,shell_actor,[player],boar_animator)
		check("资格窗口唯一controller消费至零 %d" % i, hunter.state.internal_window == 5-i and contacts.size() == (1 if i == 5 else 0))
		if not contacts.is_empty():
			check("shell contact保留byte2原字段不叫power/不改playerHP", contacts[0].byte2_raw in [30,40] and not contacts[0].has("power") and hunter.state.hp == 100)
			contacts_observed.append(contacts[0])
	check("同event同identity/generation一次", tick(owner,shell_actor,[player],boar_animator).is_empty())
	player.generation = 1
	check("新generation允许仍存活event再接触", tick(owner,shell_actor,[player],boar_animator).size() == 1)
	player.identity = "second_player"
	check("不同identity相同generation独立接触", tick(owner,shell_actor,[player],boar_animator).size() == 1)
	owner.configure(hunter_animator.data.combat)
	var state: Dictionary = actor()
	tick(owner,state,[target("a"),target("b")])
	state.events = []
	for i in range(17):
		tick(owner,state,[target("a"),target("b")])
	var multi: Array[Dictionary] = tick(owner,state,[target("a"),target("b"),target("a")])
	check("三真实source shape/重复target只产生每identity一contact", multi.size() == 2 and owner.snapshot().attacks[0].history.size() == 2)
	hunter_animator.set_animation(1428,0,0)
	check("同animation reset不造event/history保留", tick(owner,state,[target("a"),target("b")]).is_empty() and owner.snapshot().attacks.size() == 1)
	state.events = actor().events
	tick(owner,state,[target("a"),target("b")])
	check("同animation重放旧ID不能造event", owner.snapshot().attacks.size() == 1)
	state.events = actor(3,2).events
	tick(owner,state,[])
	check("新单调ID可创建下一event", owner.snapshot().attacks.size() == 2 and owner.snapshot().last_attack_id == 2)
	var short_fixture: Dictionary = hunter_animator.data.combat.duplicate(true)
	short_fixture.records["3"].delay_byte = 0
	short_fixture.records["3"].duration_byte = 2
	owner.configure(short_fixture)
	var bounded: bool = true
	for id in range(1,51):
		state = actor(3,id)
		tick(owner,state,[])
		state.events = []
		bounded = bounded and tick(owner,state,[target("a",id)]).size() == 1 and owner.snapshot().attacks[0].history.size() == 1
		tick(owner,state,[])
		bounded = bounded and owner.snapshot().attacks.is_empty()
	check("短寿命显式fixture50event退休无全局history日志", bounded and owner.snapshot().last_attack_id == 50)
