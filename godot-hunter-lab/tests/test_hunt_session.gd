extends SceneTree

const Session = preload("res://scripts/hunt_session.gd")

class CountingAnimator extends HunterAnimator:
	var calls: int = 0
	var sample: Dictionary = {}
	func tick(step: float) -> Dictionary:
		calls += 1
		sample = super.tick(step)
		return sample

var pa: CountingAnimator
var ma: CountingAnimator
var player: HunterController
var monster: BulldromeController
var session: Session
var checks: Array = []
var failures: Array = []
var trace: Array = []
var simulation_ticks: int = 0
var incoming: Array = []
var outgoing: Array = []
var damage_events: Array = []
var recovery_seen: Dictionary = {}
var profiles: Dictionary = {}
var _last_mode: String = ""

func _initialize() -> void:
	var started: int = Time.get_ticks_usec()
	pa = CountingAnimator.new()
	ma = CountingAnimator.new()
	check("真实猎人/猪王资产加载", pa.load_data() and ma.load_data("res://assets/bulldrome_data.json"))
	player = HunterController.new()
	monster = BulldromeController.new()
	player.configure(pa)
	check("真实猪王configure", monster.configure(ma))
	# Same standing lift calculation as main; sample at rest is setup, not a simulation tick.
	pa.tick(0.0)
	var pl: float = -minf(pa.world_pose[5].origin.y, pa.world_pose[8].origin.y) * 0.01 + 0.055
	var ml: float = -float(ma.data.mesh.standing_min_y) * 0.01
	session = Session.new()
	check("session双源schema配置", session.configure(player, monster, pa, ma, pl, ml))
	print("LIFTS ", pl, " / ", ml)
	profiles["source_records"] = {}
	for id in [2, 4, 5]:
		var record: Dictionary = session.monster_attack_events.read_record(id)
		profiles.source_records[str(id)] = {"selector":record.selector, "delay_byte":record.delay_byte, "duration_byte":record.duration_byte, "impact_byte2_raw":record.byte2_raw, "source":record.source}
	if failures.is_empty():
		_outgoing_checks()
		_incoming_checks()
		_space_checks()
		_round_checks()
		_render_checks()
		_danger_checks()
		_spawn_checks()
		_fair_loop()
	profiles["completed_suite"] = {"elapsed_seconds":float(Time.get_ticks_usec()-started)/1000000.0, "simulation_ticks":simulation_ticks, "godot_static_memory_bytes":OS.get_static_memory_usage(), "godot_static_memory_peak_bytes":OS.get_static_memory_peak_usage(), "cache":"warm imported assets; cold/warm classification not controlled", "cpu_seconds":"external /usr/bin/time -l", "peak_process_family_rss":"external /usr/bin/time -l; single headless process", "agent_tokens":"unmeasured; no equivalent before workflow"}
	var results: Dictionary = {"engine":Engine.get_version_info().string, "passed":checks.size(), "failed":failures.size(), "checks":checks, "failures":failures, "profiles":profiles, "coverage":{"real_assets":true, "real_controllers":true, "normal_actual_ai":profiles.get("fair_loop", {}), "fixtures":"explicit ai_enabled=false positions/HP/window state for isolated boundaries; not original game recording", "visual_qa":"skipped nonvisual simulation; no scene changes", "original_game_equivalence":false}, "limits":session.limits, "events_interface":{"outgoing":"monster_damage", "contact_queue":"incoming_contact status pending/guarded, damage20/impact/source", "submitted_next_tick":["player_damage", "player_guard", "player_dead"], "terminal":"round_end outcome victory/defeat", "unknown_air":"incoming_not_ready", "raw_producer":"animation/set/request/attack_spawn/monster_reaction/monster_rage/dead with actor"}, "trace":trace, "incoming_contacts":incoming, "outgoing_hits":outgoing, "player_damage_events":damage_events}
	var file = FileAccess.open("res://tests/hunt_session_results.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(results, "\t"))
	else:
		failures.append("结果不可写")
	print("HUNT SESSION: ", checks.size(), " passed / ", failures.size(), " failed; ", simulation_ticks, " ticks")
	for failure in failures:
		print("ASSERT FAIL: ", failure)
	quit(0 if failures.is_empty() else 1)

func check(label: String, condition: bool) -> void:
	if condition:
		checks.append(label)
	else:
		failures.append(label)
		print("ASSERT FAIL: ", label)

func step(held: int = 0, mag: int = 0, direction: int = 0, bits: int = 0) -> Dictionary:
	var pc: int = pa.calls
	var mc: int = ma.calls
	var result: Dictionary = session.tick({"held":held, "mag":mag, "direction":direction, "bits":bits})
	simulation_ticks += 1
	if pa.calls != pc + 1 or ma.calls != mc + 1:
		failures.append("每simulation actor animator唯一次 @%d" % simulation_ticks)
	if not player.state.ready or not monster.state.ready:
		failures.append("真实动画缺失 @%d" % simulation_ticks)
	if result.space.grounded_body and result.space.distance < 124.999:
		failures.append("推挡不收敛 @%d: %f" % [simulation_ticks, result.space.distance])
	for event in result.events:
		var copy: Dictionary = event.duplicate(true)
		copy.tick = session.ticks
		if event.event == "incoming_contact":
			incoming.append(copy)
		elif event.event == "monster_damage":
			outgoing.append(copy)
		elif event.event == "player_damage":
			damage_events.append(copy)
	var mode: String = "%s/%s/%d" % [player.state.recovery, monster.state.mode, player.state.primary]
	recovery_seen[player.state.recovery] = true
	if mode != _last_mode:
		trace.append({"tick":simulation_ticks, "state":mode, "hp":[player.state.hp, monster.state.hp]})
		_last_mode = mode
	return result

func run_ticks(count: int, held: int = 0) -> void:
	for i in range(count):
		step(held)

func reset_fixture(ai: bool = false, p: Vector3 = Vector3.ZERO, m: Vector3 = Vector3(0,0,-180)) -> void:
	session.reset()
	monster.ai_enabled = ai
	player.danger_enabled = false
	player.state.position = p
	monster.state.position = m
	player.state.yaw = 32768
	player.state.target = 32768

func draw_weapon() -> void:
	run_ticks(3, HunterController.TRIANGLE)
	run_ticks(100)

func slash() -> void:
	run_ticks(3, HunterController.CIRCLE)
	run_ticks(110)

func _spawn_checks() -> void:
	var old_player: Vector3 = session.player_spawn
	var old_monster: Vector3 = session.monster_spawn
	session.player_spawn = Vector3(100,0,250)
	session.monster_spawn = Vector3(-100,0,-250)
	session.reset()
	check("整局owner应用场景出生配置",player.state.position == session.player_spawn and monster.state.position == session.monster_spawn)
	player.state.position += Vector3(90,0,0)
	monster.state.position += Vector3(90,0,0)
	session.reset()
	check("重开再次应用同一出生配置",player.state.position == session.player_spawn and monster.state.position == session.monster_spawn)
	session.player_spawn = old_player
	session.monster_spawn = old_monster
	session.reset()

func _danger_checks() -> void:
	reset_fixture(true, Vector3.ZERO, Vector3(0,0,-500))
	player.state.yaw = 0
	player.state.target = 0
	step(HunterController.R,127,0)
	check("真实猪王自动提供危险方位",player.danger_enabled and player.danger_yaw == 32768 and player.state.sub == 32)
	step(HunterController.R,127,0)
	step(HunterController.R | HunterController.CROSS,127,0)
	step(HunterController.R,127,0)
	check("背离真实猪王冲刺按键进入飞扑",player.state.sub == 68 and player.state.air280 == 2 and not player.attack_collision_allowed())
	reset_fixture(false)
	step()
	check("停用AI不残留危险夹具",not player.danger_enabled)

func _outgoing_checks() -> void:
	reset_fixture()
	draw_weapon()
	check("完整source输入拔刀", player.is_drawn())
	slash()
	print("NEAR HITS ", session.hunter_hits, " damage ", session.total_monster_damage)
	check("大剑当前骨近距离有效命中", session.hunter_hits > 0 and session.total_monster_damage > 0)
	var unique: Dictionary = {}
	for event in outgoing:
		unique[[event.attack_id, event.target_generation]] = true
	check("同event同generation只命中一次", unique.size() == outgoing.size())
	check("伤害复用raw100源power/scale", session._damage.damage_for(1) == 46 and session._damage.damage_for(2) == 36 and session._damage.damage_for(3) == 48 and session._damage.damage_for(91,110) == 71 and session._damage.damage_for(92,120) == 96 and session._damage.damage_for(93,130) == 143)
	reset_fixture(false, Vector3.ZERO, Vector3(0,0,-850))
	draw_weapon()
	slash()
	check("远离空挥不按按钮扣HP", session.hunter_hits == 0 and monster.state.hp == 1000)
	reset_fixture(false, Vector3.ZERO, Vector3(0,0,180))
	draw_weapon()
	slash()
	check("背向空挥有几何而非距离直扣", session.hunter_hits == 0)

func wait_incoming(limit: int = 500, held: int = 0) -> bool:
	for i in range(limit):
		var result: Dictionary = step(held)
		for event in result.events:
			if event.event == "incoming_contact" and event.status in ["pending", "guarded"]:
				return true
	return false

func _incoming_checks() -> void:
	reset_fixture(true, Vector3(0,0,350), Vector3.ZERO)
	check("真实猪王record空间攻击产生pending", wait_incoming())
	check("原record初始化/delay寿命不是按钮伤害", not incoming.is_empty() and incoming.back().tick >= 39 and incoming.back().delay_byte == 20 and incoming.back().duration_byte == 90)
	check("contact当tick不立即扣HP", player.state.hp == 100)
	var before: int = damage_events.size()
	step()
	check("下一tick唯一player_damage HP-20", player.state.hp == 80 and damage_events.size() == before + 1 and damage_events.back().applied_damage == 20)
	check("queued源证据跟随下一turn且UI不丢出处", damage_events.back().incoming_source.attack_id == incoming.back().attack_id and damage_events.back().incoming_source.source == incoming.back().source and damage_events.back().tick == damage_events.back().incoming_source.contact_tick + 1)
	monster.ai_enabled = false
	var submitted: int = damage_events.size()
	run_ticks(300)
	check("player_damage只给UI一次且guard不额外扣血", damage_events.size() == submitted and player.state.hp == 80)
	check("重度倒地/rise原END恢复观测", recovery_seen.has("down") and recovery_seen.has("rise"))
	reset_fixture()
	draw_weapon()
	check("roll前窗口允许", player.attack_collision_allowed())
	step(HunterController.CROSS)
	step()
	check("source CROSS滚动窗口生产", player.state.internal_window > 0 and not player.attack_collision_allowed())
	check("roll中拒绝且不扣HP", player.queue_incoming(20,20,0).status == "evaded" and player.state.hp == 100)
	run_ticks(7)
	check("roll后仍动作但窗口结束可受击", player.attack_collision_allowed())
	check("roll后pending", player.queue_incoming(20,20,0).status == "pending")
	step()
	check("roll后伤害提交", player.state.hp == 80)
	reset_fixture()
	draw_weapon()
	run_ticks(3, HunterController.TRIANGLE)
	run_ticks(30, HunterController.TRIANGLE)
	check("source蓄力开始", player.state.cate == 1 and player.state.charge > 0)
	check("蓄力接触pending", player.queue_incoming(20,20,0).status == "pending")
	step(HunterController.TRIANGLE)
	check("hurt中断蓄力且不重放旧release", player.is_recovering() and player.state.cate == 2 and player.state.hp == 80)
	var old_hits: int = session.hunter_hits
	run_ticks(200)
	check("重度rise END回普通且旧攻击不伤人", not player.is_recovering() and session.hunter_hits == old_hits)
	for guard_yaw in [32768, 0]:
		reset_fixture()
		draw_weapon()
		step(HunterController.R)
		# Source drawn guard entry requires command selection; explicit held R+TRIANGLE.
		run_ticks(3, HunterController.R | HunterController.TRIANGLE)
		run_ticks(10, HunterController.R)
		check("source防御进入方向%d" % guard_yaw, player.state.cate == 2)
		var stamina: int = player.state.stamina
		var queued: Dictionary = player.queue_incoming(20,20,guard_yaw)
		check("防御方向资格%d" % guard_yaw, queued.status == ("guarded" if guard_yaw == 0 else "pending"))
		step(HunterController.R)
		check("防御chip/耐力仅由controller提交%d" % guard_yaw, player.state.hp == (95 if guard_yaw == 0 else 80) and (player.state.stamina < stamina if guard_yaw == 0 else true))
	reset_fixture(false, Vector3(0,0,400), Vector3.ZERO)
	draw_weapon()
	run_ticks(3, HunterController.R | HunterController.TRIANGLE)
	run_ticks(10, HunterController.R)
	monster.ai_enabled = true
	var got_guard_contact: bool = wait_incoming(200, HunterController.R)
	profiles["guard_fixture_initial_distance"] = 400
	check("真实猪王空间attack可防御queued", got_guard_contact and session.events.any(func(e): return e.event == "incoming_contact" and e.status == "guarded"))
	var guard_stamina: int = player.state.stamina
	step(HunterController.R)
	check("真实防御次tick guard与damage各一次/无双扣HP", player.state.hp == 95 and player.state.stamina < guard_stamina and session.events.filter(func(e): return e.event == "player_damage").size() == 1 and session.events.filter(func(e): return e.event == "player_guard").size() == 1)
	reset_fixture()
	draw_weapon()
	run_ticks(3, HunterController.R | HunterController.TRIANGLE)
	run_ticks(10, HunterController.R)
	player.state.stamina = 74
	check("耐力不足不伪造防御资格", player.queue_incoming(20,20,0).status == "pending")
	step(HunterController.R)
	check("耐力不足正常受伤不套chip", player.state.hp == 80)
	reset_fixture()
	player.state.air280 = 1
	player.state.internal_window = 0
	var unsupported: Dictionary = step()
	check("未知空中路径not_ready不谎称笼统无敌", player.attack_collision_allowed() and unsupported.events.any(func(e): return e.event == "incoming_not_ready"))

func _space_checks() -> void:
	reset_fixture(true, Vector3(0,0,350), Vector3.ZERO)
	for i in range(30):
		step()
		if monster.state.mode == "charge":
			break
	check("原AI进入charge供墙碰撞fixture", monster.state.mode == "charge")
	monster.state.position = Vector3(0,0,1200) # Explicit wall fixture after real charge entry.
	var charge_wall: Dictionary = session._resolve_space(player.state.position, monster.state.position)
	check("撞radius墙边stop_charge预算清零", charge_wall.monster_wall and monster.state.attack_budget == 0)
	step()
	check("撞墙下一tick尽快原1016收招", monster.state.primary == 1016 and monster.state.phase == 3)
	reset_fixture(false, Vector3(0,0,-300), Vector3(0,0,300))
	player.state.position = Vector3(0,0,300)
	monster.state.position = Vector3(0,0,-300)
	var sweep: Dictionary = session._resolve_space(Vector3(0,0,-300), Vector3(0,0,300))
	check("高速相对segment TOI防对穿", sweep.swept and sweep.toi < 1 and player.state.position.z < monster.state.position.z and sweep.distance >= 124.999)
	reset_fixture(false, Vector3(960,0,960), Vector3(915,0,915))
	var wall: Dictionary = session._resolve_space(player.state.position, monster.state.position)
	check("墙角circle迭代收敛且各自radius边界", wall.distance >= 124.999 and absf(player.state.position.x) <= 960 and absf(player.state.position.z) <= 960 and absf(monster.state.position.x) <= 915 and absf(monster.state.position.z) <= 915)
	reset_fixture(false, Vector3(0,0,0), Vector3(0,0,0))
	var overlap: Dictionary = session._resolve_space(player.state.position, monster.state.position)
	check("零距离overlap有限法向分离", overlap.distance >= 124.999 and player.state.position.is_finite())
	player.state.position = Vector3(0,150,0)
	monster.state.position = Vector3.ZERO
	var elevated: Dictionary = session._resolve_space(player.state.position, monster.state.position)
	check("真实高度跳过地面推挡", not elevated.grounded_body and elevated.distance == 0)
	player.state.position = Vector3.ZERO
	player.state.air280 = 1
	var crouch: Dictionary = session._resolve_space(player.state.position, monster.state.position)
	check("ground高度不因air flag误判always-air", crouch.grounded_body and crouch.distance >= 124.999)
	# 狩猎危险快照由真实猪王位置提供，不再手动覆盖夹具。
	reset_fixture(true, Vector3.ZERO, Vector3(800,0,700))
	for i in range(5):
		step(HunterController.R,127,32768,0x100000)
	step(HunterController.R | HunterController.CROSS,127,32768,0x100000)
	var dive_air: bool = false
	var dive_landed: bool = false
	var dive_window: bool = false
	for i in range(180):
		var dive: Dictionary = step()
		if player.state.position.y > 85:
			dive_air = dive_air or not dive.space.grounded_body
			dive_window = dive_window or not player.attack_collision_allowed()
		if dive_air and player.state.air280 == 0 and player.state.position.y == 0:
			dive_landed = dive.space.grounded_body
	check("source危险跑飞扑高度真升高并跳过地面circle", dive_air and dive_window)
	check("source飞扑落地恢复平地资格非always-air", dive_landed)
	reset_fixture(false, Vector3.ZERO, Vector3(800,0,-700))
	var previous: Vector3 = player.state.position
	var result: Dictionary = step(0,127,32768,0x100000)
	var expected: Vector3 = previous + pa.sample.root_delta.rotated(Vector3.UP, player.state.yaw * TAU / 65536.0)
	check("平地root只积分一次且scene无参与", player.state.position.is_equal_approx(expected) and result.player.frames == pa.sample.frames)

func _round_checks() -> void:
	reset_fixture()
	draw_weapon()
	monster.state.hp = 1 # terminal threshold fixture, kill still comes from source slash/contact.
	slash()
	check("实际大剑最后一击victory", session.round_state == "victory" and not monster.state.alive)
	var hits: int = session.monster_hits
	run_ticks(100, HunterController.CIRCLE)
	check("终局不翻转/不产生新incoming，尸体可动画", session.round_state == "victory" and session.monster_hits == hits and monster.state.mode in ["dying", "dead"])
	reset_fixture(true, Vector3(0,0,350), Vector3.ZERO)
	player.state.hp = 20
	check("致死几何incoming queued", wait_incoming())
	step()
	check("HP0明确defeat/player_dead", session.round_state == "defeat" and player.is_dead() and session.events.any(func(e): return e.event == "player_dead"))
	run_ticks(200)
	check("败局锁定且猪王停止AI", session.round_state == "defeat" and monster.state.mode == "idle")
	reset_fixture()
	player.queue_incoming(20,20,0)
	monster.state.hp = 0
	monster.state.alive = false
	step()
	check("已queued仍次tick提交且败优先前的存活胜利", player.state.hp == 80 and session.round_state == "victory")
	reset_fixture()
	player.state.hp = 20
	player.queue_incoming(20,20,0)
	monster.state.hp = 0
	monster.state.alive = false
	step()
	check("同tick双死固定败优先", session.round_state == "defeat")
	var generation: int = session.round_generation
	session.reset()
	check("paired reset HP/stats/round/world/queue全部清理", session.round_generation == generation+1 and session.round_state == "running" and session.ticks == 0 and player.state.hp == 100 and monster.state.hp == 1000 and session.hunter_hits == 0 and session.monster_hits == 0 and session.events.is_empty() and player.state.position == Vector3(0,0,250) and monster.state.position == Vector3(0,0,-350) and session.hunter_attack_events.snapshot().attacks.is_empty() and session.monster_attack_events.snapshot().attacks.is_empty())
	step()
	check("reset不泄露上轮queued伤害", player.state.hp == 100 and damage_events.back().hp == 0)

func _render_checks() -> void:
	reset_fixture(false, Vector3.ZERO, Vector3(0,0,-850))
	var first: Array = []
	for i in range(100):
		var state: Dictionary = step(HunterController.TRIANGLE if i < 3 else 0)
		first.append([state.player.position, state.player.frames, state.player.hp, state.monster.position, state.monster.frames])
	reset_fixture(false, Vector3.ZERO, Vector3(0,0,-850))
	var same: bool = true
	for i in range(100):
		# Different display transforms/read frequencies must never drive sampling/root or queues.
		for render_pass in range(i % 5):
			var display: Transform3D = Transform3D(Basis(Vector3.UP, render_pass), Vector3(render_pass,0,0))
			var display_point: Vector3 = display * pa.world_pose[10].origin * 0.01
			if not display_point.is_finite():
				same = false
		var state: Dictionary = step(HunterController.TRIANGLE if i < 3 else 0)
		same = same and first[i] == [state.player.position, state.player.frames, state.player.hp, state.monster.position, state.monster.frames]
	check("多个sim相异render频率/transform结果一致", same)

func _fair_loop() -> void:
	reset_fixture(true, Vector3(0,0,350), Vector3.ZERO)
	var start: int = Time.get_ticks_usec()
	var observed_in: int = 0
	var observed_out: int = 0
	var recovered: bool = false
	var hurt: bool = false
	# Fixed source buttons, no teleports/HP edits/take_damage/force_action during this run.
	for i in range(1600):
		var held: int = 0
		if i < 3:
			held = HunterController.TRIANGLE
		elif i % 130 < 3:
			held = HunterController.CIRCLE
		var result: Dictionary = step(held)
		for event in result.events:
			if event.event == "incoming_contact":
				observed_in += 1
			elif event.event == "monster_damage":
				observed_out += 1
		hurt = hurt or player.is_recovering()
		recovered = recovered or (hurt and not player.is_recovering())
		if session.round_state != "running":
			break
	profiles["fair_loop"] = {"incoming":observed_in, "outgoing":observed_out, "recovered":recovered, "ticks":session.ticks, "round":session.round_state, "hp":[player.state.hp,monster.state.hp], "elapsed_seconds":float(Time.get_ticks_usec()-start)/1000000.0, "fixture":"initial positions only; actual AI enabled; no state mutation during loop; fixed source draw/slash buttons"}
	print("FAIR LOOP ", profiles.fair_loop)
	check("公平实际AI loop incoming/outgoing/recover observed", observed_in > 0 and observed_out > 0 and recovered)
