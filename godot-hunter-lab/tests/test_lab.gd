extends SceneTree

var lab: Node3D
var failures: Array[String] = []
var checks: int = 0
var variants: Array[Dictionary] = []
var captures: Array[String] = []
var capture_mode: bool = false
var start_time: int = 0
var sword_extents: Array[Vector3] = []
var checking_dive: bool = false
var dive_ticks: int = 0
var dive_minimum_y: float = INF
var dive_phases: Dictionary = {}
var dive_geometry: Array[Dictionary] = []
var combat_coverage: Dictionary = {}
var combat_hits: Array[Dictionary] = []

func _initialize() -> void:
	start_time = Time.get_ticks_msec()
	capture_mode = "--capture" in OS.get_cmdline_user_args()
	call_deferred("run")

func check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error("ASSERT FAIL: " + description)

func button(index: int, pressed: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.device = 0
	event.button_index = index
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func motion(axis: int, value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.device = 0
	event.axis = axis
	event.axis_value = value
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func ticks(count: int) -> void:
	for i in range(count):
		lab.simulation_tick()
		if checking_dive:
			lab.update_visuals()
			check_dive_sword()
	lab.update_visuals()

func sword_minimum_y() -> float:
	var minimum: float = INF
	for point in sword_extents:
		minimum = minf(minimum,(lab.sword.global_transform*point).y)
	return minimum

func check_dive_sword() -> void:
	check_back_distance("dive tick %d" % (dive_ticks+1))
	dive_ticks += 1
	var identity: String = "%d/p%d" % [lab.controller.state.sub,lab.controller.state.phase]
	dive_phases[identity] = int(dive_phases.get(identity,0))+1
	var minimum := sword_minimum_y()
	dive_minimum_y = minf(dive_minimum_y,minimum)
	check(finite_pose(),"dive finite source/render pose tick %d %s" % [dive_ticks,identity])
	check(minimum >= lab.controller.state.floor_height*0.01-0.002,"all sword mesh extents clear floor tick %d %s: %.6f m" % [dive_ticks,identity,minimum])
	var spine: Transform3D = lab.animator.world_pose[10]
	var expected: Transform3D = Transform3D(spine.basis.orthonormalized(),spine.origin*0.01)*lab.back_mount
	check(lab.sword.transform.is_equal_approx(expected),"entire sword mount follows current spine tick %d" % dive_ticks)

func check_back_distance(context: String) -> void:
	var pelvis: Vector3 = lab.animator.world_pose[9].origin*0.01
	var neck: Vector3 = lab.animator.world_pose[19].origin*0.01
	var blade: Vector3 = lab.sword.transform*Vector3(0,0,0.8)
	var closest: Vector3 = Geometry3D.get_closest_point_to_segment(blade,pelvis,neck)
	check(blade.distance_to(closest) < 0.24,"blade body stays within 24cm of torso axis " + context + ": " + str(blade.distance_to(closest)))

func finite_pose() -> bool:
	if not lab.controller.state.ready or not lab.actor.transform.is_finite() or not lab.sword.transform.is_finite():
		return false
	for transform in lab.animator.world_pose:
		if not transform.is_finite():
			return false
	for rod in lab.rods:
		if not rod.transform.is_finite():
			return false
	return true

func capture(name: String, back_detail: bool = false) -> void:
	if not capture_mode:
		return
	lab.update_visuals()
	var original_camera: Transform3D = lab.camera.transform
	var original_offset: float = lab.camera.h_offset
	var original_panel: bool = lab.panel.visible
	var original_target: bool = lab.target_mesh.visible
	var original_target_label: bool = lab.target_label.visible
	if back_detail:
		lab.target_mesh.visible = false
		lab.target_label.visible = false
		var back: Vector3 = lab.sword.global_basis.y.normalized()
		var focus: Vector3 = lab.joints[10].global_position
		lab.camera.h_offset = 0.0
		lab.camera.position = focus+back*2.8+Vector3.UP*0.35
		lab.camera.look_at(focus)
		lab.panel.visible = false
	await process_frame
	# 截图主动刷新GPU，窗口后台节流不应无限等待frame_post_draw。
	RenderingServer.force_draw(false)
	var image := root.get_texture().get_image()
	var path: String = "res://screenshots/lab/"+name+".png"
	var error := image.save_png(path)
	check(error == OK and not image.is_empty(),"GPU capture " + name)
	captures.append(path)
	lab.camera.transform = original_camera
	lab.camera.h_offset = original_offset
	lab.panel.visible = original_panel
	lab.target_mesh.visible = original_target
	lab.target_label.visible = original_target_label

# 使用真实 Input 队列的虚拟手柄路径，不用 force_action 进入飞扑。
func dive_player_path(keep_r: bool) -> void:
	lab.reset_lab()
	motion(JOY_AXIS_LEFT_Y,1.0)
	button(JOY_BUTTON_RIGHT_SHOULDER,true)
	ticks(19)
	var delta: Vector3 = lab.danger_marker.position-lab.controller.state.position*0.01
	ticks(1)
	check(lab.controller.state.sub == 32,"player faces away from fixed marker and enters danger run")
	check(lab.controller.danger_yaw == (int(round(atan2(delta.x,delta.z)*65536.0/TAU))&65535),"fixture yaw derives from pre-tick horizontal marker direction")
	checking_dive = true
	dive_ticks = 0
	dive_minimum_y = INF
	dive_phases.clear()
	button(JOY_BUTTON_A,true)
	ticks(1)
	check(lab.controller.state.sub == 68 and lab.controller.state.phase == 0,"player CROSS SET68 deferred initialization")
	button(JOY_BUTTON_A,false)
	ticks(1)
	check(lab.controller.state.phase == 1 and lab.controller.state.air280 == 2 and lab.probe_result.status == "evaded","next tick initializes dive with attack-path rejection")
	if keep_r:
		ticks(4)
		await capture("dive_takeoff")
	if not keep_r:
		button(JOY_BUTTON_RIGHT_SHOULDER,false)
	motion(JOY_AXIS_LEFT_Y,0.0)
	for i in range(100):
		if lab.controller.state.phase == 2:
			break
		ticks(1)
	check(lab.controller.state.phase == 2 and lab.controller.state.position.y > 0,"air2 preserves nonzero simulated Y")
	var before: Vector3 = lab.controller.state.position
	var result: Dictionary = lab.simulation_tick()
	var expected_velocity: Vector3 = result.velocity
	check(is_equal_approx(result.position.y-before.y,expected_velocity.y+result.root_delta.y),"airborne integration plus root applied exactly once")
	lab.update_visuals()
	check_dive_sword()
	check(is_equal_approx(lab.actor.position.y,result.position.y*0.01),"actor renders airborne Y without forced grounding")
	if keep_r:
		await capture("dive_air")
	for i in range(100):
		if lab.controller.state.phase == 3:
			break
		ticks(1)
	check(lab.controller.state.sub == 68 and lab.controller.state.phase == 3 and lab.controller.state.position.y == lab.controller.state.floor_height,"discrete dive lands in phase3 on floor")
	ticks(1)
	if keep_r:
		await capture("dive_landing")
	for i in range(100):
		if lab.animator.ge(30):
			break
		ticks(1)
	check(lab.animator.ge(30) and lab.controller.state.internal_window == 2,"scene landing GE30 retains window2")
	var geometry: int = lab.probe_stats.geometry_checks
	var hits: int = lab.probe_stats.hits
	ticks(1)
	check(lab.controller.state.internal_window == 1 and lab.probe_result.status == "evaded" and lab.probe_stats.geometry_checks == geometry and lab.probe_stats.hits == hits,"GE30 first residual call rejects before geometry or hit registration")
	ticks(1)
	check(lab.controller.state.internal_window == 0 and lab.probe_result.status == "accepted" and lab.probe_stats.geometry_checks == geometry+1 and lab.probe_stats.hits == hits+1,"GE30 second call window0 genuinely overlaps, accepted not damage")
	for i in range(100):
		if lab.controller.state.sub != 68:
			break
		ticks(1)
	check(lab.controller.state.sub == (69 if keep_r else 44),"player dive ends via recovery69/44")
	button(JOY_BUTTON_RIGHT_SHOULDER,false)
	ticks(120)
	check(lab.controller.state.sub == 0 and lab.controller.state.position.y == lab.controller.state.floor_height,"dive recovery returns ground idle")
	checking_dive = false
	for phase in ["68/p0","68/p1","68/p2","68/p3",("69/p1" if keep_r else "44/p1"),"0/p0"]:
		check(dive_phases.has(phase),"sword geometry covers actual player " + phase)
	dive_geometry.append({"keep_shoulder":keep_r,"ticks":dive_ticks,"extent_points_per_tick":sword_extents.size(),"minimum_mesh_extent_y_m":dive_minimum_y,"phase_ticks":dive_phases.duplicate()})

func probe_checks() -> void:
	check(not lab.danger_toggle.button_pressed and not lab.probe_toggle.button_pressed,"fixture and probe default disabled")
	button(JOY_BUTTON_LEFT_SHOULDER,true)
	button(JOY_BUTTON_LEFT_SHOULDER,false)
	check(lab.danger_toggle.button_pressed and lab.controller.danger_enabled,"virtual L1 toggles danger fixture")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_H
	key.pressed = true
	Input.parse_input_event(key)
	Input.flush_buffered_events()
	key = key.duplicate()
	key.pressed = false
	Input.parse_input_event(key)
	Input.flush_buffered_events()
	check(lab.probe_enabled,"H toggles independent probe")
	await dive_player_path(true)
	await dive_player_path(false)
	button(JOY_BUTTON_LEFT_SHOULDER,true)
	button(JOY_BUTTON_LEFT_SHOULDER,false)
	check(not lab.controller.danger_enabled,"second virtual L1 disables fixture")
	for skill in range(3):
		lab.window_skill.select(skill)
		lab.window_skill.emit_signal("item_selected",skill)
		lab.controller.evade_rank = 2
		lab.reset_lab()
		check(lab.controller.evasion_skill_a1 == (skill == 1) and lab.controller.evasion_skill_a2 == (skill == 2) and lab.controller.evade_rank == 2,"UI sets window skills independently of stamina skill")
		motion(JOY_AXIS_LEFT_Y,1.0)
		button(JOY_BUTTON_A,true)
		for i in range(5):
			ticks(1)
			if lab.controller.state.sub == 28 and lab.controller.state.phase > 0:
				break
		check(lab.controller.state.internal_window == [6,10,12][skill],"roll window reflects UI skill priority")
		if skill == 2:
			ticks(4)
			await capture("roll_evade")
		button(JOY_BUTTON_A,false)
		motion(JOY_AXIS_LEFT_Y,0.0)
		for i in range(60):
			if lab.controller.state.internal_window == 0:
				break
			ticks(1)
		check(lab.probe_result.status == "accepted","roll expired window overlaps via actual geometry")
		if skill == 2:
			await capture("window_expired")
	lab.window_skill.select(0)
	lab.window_skill.emit_signal("item_selected",0)
	lab.controller.evade_rank = 0
	lab.reset_lab()
	lab.controller.state.position = Vector3(140,80,-90)
	lab.controller.state.yaw = 16384
	var centers: Array[Vector3] = lab.body_probe_centers()
	var expected: Vector3 = lab.controller.state.position*0.01+(lab.animator.world_pose[10].origin*0.01+Vector3(0,lab.lift,0)).rotated(Vector3.UP,PI/2)
	check(centers[0].is_equal_approx(expected),"body probe uses latest position/yaw/lift before render")
	lab.update_visuals()
	check(centers[0].is_equal_approx(lab.joints[10].global_position) and centers[1].is_equal_approx(lab.joints[20].global_position),"both body spheres agree with rendered world bones")
	check(lab.probe_attack(centers[0],0.24).status == "accepted","window0 overlapping fixed sphere accepted")
	check(lab.probe_attack(Vector3(100,100,100),0.1).status == "miss","window0 non-overlapping fixed sphere misses")
	var geometry: int = lab.probe_stats.geometry_checks
	var hits: int = lab.probe_stats.hits
	for window in [3,-1]:
		lab.controller.state.internal_window = window
		check(lab.probe_attack(centers[0],0.24).status == "evaded" and lab.probe_stats.geometry_checks == geometry and lab.probe_stats.hits == hits,"any nonzero window rejects without geometry/hit")
	check(lab.probe_attack(Vector3(INF,0,0),0.2).status == "invalid" and lab.probe_attack(centers[0],-1).status == "invalid","probe validates finite center and radius")
	lab.reset_lab()
	lab._physics_process(1.0/30.0)
	check(lab.probe_stats.hits == 1 and lab.probe_stats.geometry_checks == 1,"main loop probes once per live simulation tick")
	var stats: Dictionary = lab.probe_stats.duplicate()
	for i in range(20):
		lab._process(0.0)
	check(lab.probe_stats == stats,"multiple renders do not issue attacks")
	for sub in [32,68,69]:
		lab.preview_action(0,sub)
		geometry = lab.probe_stats.geometry_checks
		var fixture_preserved: bool = true
		for i in range(300):
			ticks(1)
			fixture_preserved = fixture_preserved and not lab.controller.danger_enabled
			if lab.preview_ticks < 0:
				break
		check(fixture_preserved,"preview does not persist fixture override")
		check(lab.controller.state.sub == 0 and lab.preview_ticks == -1,"danger/dive previews complete")
		check(lab.probe_stats.geometry_checks == geometry,"gallery preview does not issue live probes")
	lab.preview_action(0,68)
	button(JOY_BUTTON_B,true)
	check(lab.preview_ticks == -1 and not lab.controller.danger_enabled,"player input exits dive preview with live fixture unchanged")
	button(JOY_BUTTON_B,false)
	lab.probe_toggle.button_pressed = false
	lab.reset_lab()
	check(lab.probe_stats == {"evaded":0,"hits":0,"misses":0,"geometry_checks":0} and lab.probe_result.is_empty(),"reset clears counters and synchronizes UI settings")

func key_press(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func draw_for_combat() -> void:
	lab.reset_lab()
	key_press(KEY_Q,true)
	key_press(KEY_Q,false)
	ticks(100)
	check(lab.controller.is_drawn(),"combat uses actual Q draw input")
	lab.reset_target()

func wait_for_hit(limit: int = 180) -> Dictionary:
	for i in range(limit):
		ticks(1)
		for event in lab.combat_events:
			if event.event == "hit":
				combat_hits.append(event.duplicate(true))
				return event
	return {}

# 原攻击通知 -> 真正模拟胶囊/球 -> 默认方块，不改HP或伪造attack_spawn。
func charge_cube(level: int) -> Dictionary:
	draw_for_combat()
	button(JOY_BUTTON_Y,true)
	var reached: bool = false
	for i in range(200):
		ticks(1)
		check(lab.combat.target_hp == 500 and lab.combat_events.is_empty(),"charge windup has no damaging record level %d tick %d" % [level,i])
		if lab.controller.state.charge >= [0,32,62,82][level]:
			reached = true
			break
	check(reached,"virtual Y reaches requested charge level %d" % level)
	button(JOY_BUTTON_Y,false)
	var hit := wait_for_hit()
	var expected: int = [48,71,96,143][level]
	check(hit.get("damage",0) == expected and hit.get("record",0) == [3,91,92,93][level] and hit.get("attack_scale",0) == [100,110,120,130][level],"real charge release %d damage %d with original record and scale: %s" % [level,expected,hit])
	check(lab.combat.target_hp == 500-expected and lab.combat.hits == 1,"charge release HP owner applies once level %d" % level)
	combat_coverage["charge"+str(level)] = hit
	return hit

func combat_checks() -> void:
	draw_for_combat()
	check(lab.combat.target_center == Vector3(0,0.9,2.3) and lab.combat.target_half_size == Vector3(0.75,0.9,0.75),"scene retains combat owner's default AABB")
	check(lab.target_mesh.position == lab.combat.target_center and lab.target_mesh.mesh.size == lab.combat.target_half_size*2,"visible cube maps owner center and full dimensions")
	ticks(60)
	check(lab.combat.target_hp == 500 and lab.damage_labels.is_empty(),"idle/no spawn does not damage")
	button(JOY_BUTTON_B,true)
	ticks(1)
	check(lab.combat.target_hp == 500,"button and deferred spawn cannot directly damage")
	button(JOY_BUTTON_B,false)
	var hit := wait_for_hit()
	check(hit.get("damage",0) == 36 and hit.get("applied_damage",0) == 36 and hit.get("record",0) == 2 and hit.get("hp",0) == 464,"default virtual B sweep genuinely hits cube for36: " + str(hit))
	check(lab.damage_labels.size() == 1 and lab.damage_labels[0].label.text == "36","exactly one concrete 36 damage float")
	check(lab.target_flash > 0 and lab.target_mesh.material_override.emission_enabled,"actual hit flashes target")
	await capture("cube_hit")
	combat_coverage.sweep = hit
	if not lab.damage_labels.is_empty():
		var floating: Dictionary = lab.damage_labels[0]
		var ttl: int = floating.ttl
		var position: Vector3 = floating.label.position
		var damage: int = lab.combat.total_damage
		var sim_ticks: int = lab.controller.state.ticks
		for i in range(60):
			lab._process(0.0)
		check(lab.combat.total_damage == damage and lab.combat.hits == 1 and lab.combat.target_hp == 464 and lab.controller.state.ticks == sim_ticks,"60 renders cannot repeat damage or simulation")
		check(floating.ttl == ttl and floating.label.position == position,"60 renders cannot advance float TTL or drift")
		ticks(10)
		check(lab.combat.target_hp == 464 and lab.combat.hits == 1,"same event multi-shape/multi-tick overlaps do not duplicate")
		lab.reset_button.emit_signal("pressed")
		check(not is_instance_valid(floating.label) and lab.damage_labels.is_empty() and lab.combat.target_hp == 500,"lab reset frees all floats and resets owner")
	draw_for_combat()
	button(JOY_BUTTON_Y,true)
	button(JOY_BUTTON_B,true)
	ticks(1)
	button(JOY_BUTTON_Y,false)
	button(JOY_BUTTON_B,false)
	hit = wait_for_hit()
	check(hit.get("damage",0) == 46 and hit.get("record",0) == 1,"virtual Y+B upslash real record damage46: " + str(hit))
	combat_coverage.upslash = hit
	for level in range(1,4):
		hit = charge_cube(level)
		if level == 3:
			check(lab.damage_labels.size() == 1 and lab.damage_labels[0].label.text == "143","third charge visible float143")
			await capture("cube_charge3")
		ticks(180)
		check(lab.combat.hits == 1 and lab.damage_labels.is_empty(),"charge event dedup and finite float lifetime level %d" % level)
	draw_for_combat()
	lab.controller.state.position = Vector3(0,0,-1000)
	button(JOY_BUTTON_B,true)
	ticks(1)
	button(JOY_BUTTON_B,false)
	ticks(180)
	check(lab.combat.target_hp == 500 and lab.combat.hits == 0 and lab.damage_labels.is_empty(),"far away real sweep is empty swing")
	lab.probe_attack(lab.body_probe_centers()[0],0.24)
	check(lab.combat.target_hp == 500,"body homing probe never damages cube")
	combat_coverage.empty_swing = {"hp":lab.combat.target_hp,"hits":lab.combat.hits,"actor_position":lab.controller.state.position}
	draw_for_combat()
	button(JOY_BUTTON_B,true)
	var saw_spawn: bool = false
	for i in range(20):
		var snapshot: Dictionary = lab.simulation_tick()
		for event in snapshot.events:
			if event.event == "attack_spawn":
				saw_spawn = true
		if saw_spawn:
			break
	button(JOY_BUTTON_B,false)
	check(saw_spawn and lab.combat.target_hp == 500,"capture pending source attack before collision")
	var actor_state: Dictionary = lab.controller.state.duplicate(true)
	key_press(KEY_R,true)
	key_press(KEY_R,false)
	check(lab.controller.state == actor_state and lab.combat.target_hp == 500 and lab.combat.hits == 0,"manual R clears target/stats but leaves active actor unchanged")
	ticks(30)
	check(lab.combat.hits == 0 and lab.combat.target_hp == 500,"manual reset does not replay prior snapshot spawn on following ticks")
	lab.reset_lab()
	draw_for_combat()
	# 横斩带真实根位移；用摇杆退回并转身再斩，不改目标HP或强造必中。
	var original_orbit: float = lab.orbit
	lab.orbit = 0.0
	var approach_z: float = lab.controller.state.position.z
	var final_hit: Dictionary = {}
	for attack in range(14):
		if attack > 0:
			motion(JOY_AXIS_LEFT_Y,-1.0)
			for step in range(200):
				ticks(1)
				if lab.controller.state.position.z < approach_z-100:
					break
			motion(JOY_AXIS_LEFT_Y,1.0)
			for step in range(200):
				ticks(1)
				if lab.controller.state.position.z >= approach_z and lab.controller.state.yaw == 0:
					break
			motion(JOY_AXIS_LEFT_Y,0.0)
			ticks(20)
		button(JOY_BUTTON_B,true)
		ticks(1)
		button(JOY_BUTTON_B,false)
		final_hit = wait_for_hit()
		check(not final_hit.is_empty(),"repeat sweep %d hits; actor=%s yaw=%d action=%d/%d phase=%d HP=%d" % [attack,lab.controller.state.position,lab.controller.state.yaw,lab.controller.state.cate,lab.controller.state.sub,lab.controller.state.phase,lab.combat.target_hp])
		if not lab.combat.target_alive:
			break
		ticks(140)
	lab.orbit = original_orbit
	check(not lab.combat.target_alive and lab.combat.target_hp == 0 and lab.combat.hits == 14 and lab.combat.total_damage == 500,"14 real sweeps break500HP; total uses applied damage")
	check(final_hit.get("damage",0) == 36 and final_hit.get("applied_damage",0) == 32,"final hit float36 distinguishes remaining applied32")
	check(not lab.target_mesh.visible and lab.combat.respawn_remaining == 90,"broken hides cube and starts90 simtick countdown")
	await capture("cube_broken")
	combat_coverage.broken = {"hits":lab.combat.hits,"total_damage":lab.combat.total_damage,"final_hit":final_hit,"respawn_remaining":lab.combat.respawn_remaining}
	var generation: int = lab.combat.target_generation
	for i in range(60):
		lab._process(0.0)
	check(lab.combat.respawn_remaining == 90,"render cannot advance respawn countdown")
	ticks(89)
	check(not lab.combat.target_alive and lab.combat.respawn_remaining == 1,"89 following simulation calls remain broken")
	ticks(1)
	check(lab.combat.target_alive and lab.combat.target_hp == 500 and lab.target_mesh.visible and lab.combat.target_generation == generation+1,"90th simulation call respawns new owner generation500HP")
	check(lab.combat_events.size() == 1 and lab.combat_events[0].event == "respawned","respawn owner notification consumed once")
	combat_coverage.respawn = {"hp":lab.combat.target_hp,"generation":lab.combat.target_generation,"calls":90}
	await capture("cube_respawned")
	actor_state = lab.controller.state.duplicate(true)
	lab.target_reset_button.emit_signal("pressed")
	check(lab.controller.state == actor_state and lab.combat.hits == 0 and lab.combat.total_damage == 0 and lab.combat.last_damage == 0,"target button clears statistics without actor reset")
	button(JOY_BUTTON_DPAD_UP,true)
	button(JOY_BUTTON_DPAD_UP,false)
	check(lab.controller.state == actor_state and lab.damage_labels.is_empty() and lab.target_flash == 0,"DPAD UP target callback nonconflicting and clean")
	lab.preview_action(1,0)
	hit = wait_for_hit()
	check(hit.get("damage",0) == 36 and lab.combat.hits == 1,"gallery preview also ticks real combat once per simulation call")
	combat_coverage.preview_sweep = hit
	lab.reset_lab()
	button(JOY_BUTTON_A,true)
	ticks(1)
	button(JOY_BUTTON_A,false)
	ticks(90)
	check(lab.combat.target_hp == 500 and lab.combat.hits == 0,"evasion without attack_spawn never damages target")
	lab.reset_lab()
	combat_coverage.guarantees = ["current snapshot consumed once per live/preview simulation call","no input-based or probe damage","no windup/no-spawn damage","same event shapes/ticks deduplicated","render independent floatTTL/damage/respawn","reset frees floats and clears statistics without actor reset","real player14 sweeps break and90 calls respawn","28GS finite/clip tests retained; not every variant forced to hit small cube"]

func run() -> void:
	var packed: PackedScene = load("res://main.tscn")
	check(packed != null,"main scene loads")
	lab = packed.instantiate()
	root.add_child(lab)
	lab.set_physics_process(false)
	lab.set_process(false)
	await process_frame
	lab.set_hunt_mode(false)
	check(lab.controller.state.ready,"controller ready")
	var viewport_size: Vector2 = root.get_visible_rect().size
	check(lab.panel.get_global_rect().end.y <= viewport_size.y and lab.panel.get_global_rect().end.x <= viewport_size.x,"gallery controls fit viewport")
	for control in lab.panel.get_parent().get_children():
		if control is Label:
			check(control.get_global_rect().end.y <= viewport_size.y and control.get_global_rect().end.x <= lab.panel.position.x,"HUD and help fit viewport without panel overlap")
	check(lab.joints.size() == 21,"21 real bone nodes")
	check(lab.get_node("Ground") is StaticBody3D,"actual static ground")
	check(lab.get_node("Ground").get_child(1) is CollisionShape3D,"ground collision shape")
	check(lab.joints[20].position.y+lab.lift > 1.0,"head above ground")
	check(absf(minf(lab.joints[5].position.y,lab.joints[8].position.y)+lab.lift-0.055) < 0.002,"one-time standing foot lift")
	for child in lab.sword.get_children():
		if child is MeshInstance3D:
			var bounds: AABB = child.mesh.get_aabb()
			for corner in range(8):
				sword_extents.append(child.transform*bounds.get_endpoint(corner))
	check(sword_extents.size() == 72,"all nine sword meshes contribute eight conservative geometry extents")
	var standing_spine: Transform3D = lab.animator.world_pose[10]
	var shoulders: Vector3 = (lab.animator.world_pose[12].origin+lab.animator.world_pose[16].origin)*0.005
	var up: Vector3 = (shoulders-lab.animator.world_pose[9].origin*0.01).normalized()
	var shoulder_line: Vector3 = lab.animator.world_pose[12].origin-lab.animator.world_pose[16].origin
	var right: Vector3 = (shoulder_line-up*shoulder_line.dot(up)).normalized()
	var back: Vector3 = up.cross(right).normalized()
	check(lab.sword.position.is_equal_approx(shoulders+up*0.16+right*0.15+back*0.14),"grip binds above right shoulder and 14cm behind shoulder plane")
	check(lab.sword.basis.z.normalized().dot(up) < -0.9 and lab.sword.basis.z.normalized().dot(right) < -0.3 and lab.sword.basis.y.normalized().is_equal_approx(back),"blade slopes from right shoulder to left hip within back plane")
	check(lab.sword.scale.is_equal_approx(Vector3.ONE*0.55),"sheathed approximate dimensions: 1.27m long / 22cm wide, drawn layout unchanged")
	check_back_distance("standing")
	for axis in [Vector3.RIGHT,Vector3.UP,Vector3.FORWARD]:
		var rotation := Basis(axis,1.1)
		lab.animator.world_pose[10] = Transform3D(rotation*standing_spine.basis,standing_spine.origin+Vector3(17,-9,23))
		lab.update_visuals()
		var rotated_spine: Transform3D = lab.animator.world_pose[10]
		var expected: Transform3D = Transform3D(rotated_spine.basis.orthonormalized(),rotated_spine.origin*0.01)*lab.back_mount
		check(lab.sword.transform.is_equal_approx(expected),"complete local mount including offset/orientation/scale follows rotation " + str(axis))
	lab.animator.world_pose[10] = standing_spine
	lab.update_visuals()
	check(sword_minimum_y() >= -0.002 and finite_pose(),"standing whole sword extents and finite source pose clear floor")
	var categories: Array[int] = [0,0,0]
	for action in lab.actions:
		if action.category == 1 and action.subaction == 99:
			continue
		categories[int(action.category)] += 1
	check(categories == [27,28,7],"complete normal27 / GS28 / guard7 gallery")
	var count_before: int = InputMap.action_get_events("lab_triangle").size()
	lab.configure_inputs()
	check(InputMap.action_get_events("lab_triangle").size() == count_before,"idempotent InputMap")
	check(JOY_BUTTON_X == 2 and JOY_BUTTON_Y == 3,"Godot standard X/Y enum mapping")
	await capture("startup")
	await capture("sheathed_back",true)
	var before_ticks: int = lab.controller.state.ticks
	for i in range(60):
		lab._physics_process(1.0/60.0)
	check(int(lab.controller.state.ticks)-before_ticks == 30,"60 physics ticks produce 30 simulation ticks")
	before_ticks = lab.controller.state.ticks
	lab._physics_process(5.0)
	check(int(lab.controller.state.ticks)-before_ticks <= 8,"fixed accumulator catchup bounded")
	lab.reset_lab()
	for i in range(100):
		motion(JOY_AXIS_LEFT_X,float(i)/100.0)
	check(lab.snapshots.size() <= 1,"analog updates coalesced without transition backlog")
	motion(JOY_AXIS_LEFT_X,0.0)
	motion(JOY_AXIS_RIGHT_X,0.8)
	var old_orbit: float = lab.orbit
	lab._process(0.1)
	check(lab.orbit != old_orbit,"virtual right stick orbit")
	motion(JOY_AXIS_RIGHT_X,0.0)
	lab.orbit = old_orbit
	lab.reset_lab()

	motion(JOY_AXIS_LEFT_X,0.1)
	check(lab.input_snapshot().mag == 0,"circular deadzone rejects 0.1")
	motion(JOY_AXIS_LEFT_X,0.7)
	motion(JOY_AXIS_LEFT_Y,-0.7)
	check(lab.input_snapshot().mag <= 127 and lab.input_snapshot().mag > 100,"diagonal magnitude bounded")
	motion(JOY_AXIS_LEFT_X,0.0)
	motion(JOY_AXIS_LEFT_Y,-1.0)
	button(JOY_BUTTON_RIGHT_SHOULDER,true)
	ticks(30)
	check(lab.controller.state.position.length() > 50,"virtual left stick moves hunter")
	check(lab.controller.state.sub == 31,"virtual shoulder + stick sprint")
	check_back_distance("sheathed sprint")
	await capture("sheathedrun")
	button(JOY_BUTTON_RIGHT_SHOULDER,false)
	motion(JOY_AXIS_LEFT_Y,0.0)
	ticks(120)
	lab.reset_lab()
	var key := InputEventKey.new()
	key.physical_keycode = KEY_Q
	key.pressed = true
	Input.parse_input_event(key)
	Input.flush_buffered_events()
	ticks(100)
	check(lab.controller.is_drawn(),"Q event draws weapon")
	key = key.duplicate()
	key.pressed = false
	Input.parse_input_event(key)
	Input.flush_buffered_events()
	button(JOY_BUTTON_X,true)
	ticks(100)
	button(JOY_BUTTON_X,false)
	ticks(10)
	check(not lab.controller.is_drawn(),"virtual X square sheath")

	lab.reset_lab()
	lab.controller.state.flags410 |= 8
	button(JOY_BUTTON_B,true)
	ticks(8)
	check(lab.controller.state.cate == 1 and lab.controller.state.sub == 0,"virtual B circle sweep")
	button(JOY_BUTTON_B,false)
	ticks(9)
	await capture("sweep")
	ticks(200)
	check(lab.controller.state.cate == 0,"sweep returns idle")

	lab.reset_lab()
	lab.controller.state.flags410 |= 8
	button(JOY_BUTTON_Y,true)
	var saw_charge: bool = false
	var max_charge: int = 0
	for i in range(200):
		ticks(1)
		max_charge = maxi(max_charge,int(lab.controller.state.charge))
		if lab.controller.state.charge >= 82:
			saw_charge = true
			break
	check(saw_charge,"virtual Y held reaches third charge level")
	await capture("charge")
	button(JOY_BUTTON_Y,false)
	var saw_release: bool = false
	var release_level: int = 0
	for i in range(100):
		ticks(1)
		if lab.controller.state.cate == 1 and lab.controller.state.sub == 26:
			saw_release = true
			release_level = int(lab.controller.state.level)
			if lab.controller.state.frames[0] > 38:
				break
	check(saw_release and release_level == 3,"virtual Y release level3")
	await capture("release")
	ticks(200)
	check(lab.controller.state.cate == 0,"charge/release terminates")

	lab.reset_lab()
	lab.controller.state.flags410 |= 8
	button(JOY_BUTTON_RIGHT_SHOULDER,true)
	ticks(20)
	check(lab.controller.state.cate == 2,"virtual shoulder drawn guard")
	await capture("guard")
	button(JOY_BUTTON_RIGHT_SHOULDER,false)
	ticks(160)
	check(lab.controller.state.cate == 0,"guard release returns idle")
	lab.reset_lab()
	button(JOY_BUTTON_Y,true)
	button(JOY_BUTTON_Y,false)
	lab.simulation_tick()
	check(int(lab.controller.state.pressed) & 0x1000 != 0,"short virtual press retained at simulation tick")
	lab.simulation_tick()
	check(int(lab.controller.state.released) & 0x1000 != 0,"short virtual release retained separately")

	for action in lab.actions:
		if action.category != 1 or action.subaction == 99:
			continue
		check(lab.preview_action(1,int(action.subaction)),"gallery starts " + action.name)
		var trace: Array = []
		var events: Array = []
		var complete: bool = false
		var valid: bool = true
		var previous: String = ""
		var duration: int = 0
		var min_tip_y: float = INF
		for i in range(700):
			var result: Dictionary = lab.simulation_tick()
			lab.update_visuals()
			valid = valid and finite_pose() and not result.has("error")
			min_tip_y = minf(min_tip_y,(lab.sword.global_transform * Vector3(0,0,2.3)).y)
			var identity: String = "%d/%d/p%d/a%d" % [result.cate,result.sub,result.phase,result.primary]
			if identity != previous:
				trace.append(identity)
				previous = identity
			for event in result.events:
				if event.event in ["attack_spawn","charge_effect","missing_animation"]:
					events.append(event)
			if result.cate == 0 and result.sub == 0 and i > 1:
				complete = true
				duration = i+1
				break
		check(min_tip_y >= 0.024,"rough sword tip clears floor " + action.name)
		check(valid,"finite complete transforms " + action.name)
		check(complete,"GS variant finishes without end-loop " + action.name)
		variants.append({"subaction":action.subaction,"name":action.name,"input_reachability":action.input_reachability,"ticks":duration,"phase_trace":trace,"events":events,"finite":valid,"completed":complete,"minimum_visual_tip_y_m":min_tip_y})

	for action in lab.actions:
		if action.category == 1 and action.subaction != 99:
			continue
		lab.preview_action(int(action.category),int(action.subaction))
		ticks(200)
		check(finite_pose(),"normal/guard playback finite " + action.name)
	lab.preview_action(2,3)
	ticks(20)
	check(lab.controller.guard_incoming(20,(int(lab.controller.state.yaw)+32768)&65535,true,true),"explicit qualified guard feedback callback")
	ticks(150)
	check(finite_pose(),"guard feedback finite")
	lab.speed.value = 45
	check(lab.hz == 45,"speed slider callback")
	lab.speed.value = 30
	lab.play_button.emit_signal("pressed")
	check(lab.preview_ticks == 0,"play button callback")
	lab.reset_button.emit_signal("pressed")
	check(lab.preview_ticks == -1 and not lab.controller.is_drawn(),"reset button callback")
	lab._joy_changed(0,true)
	lab._joy_changed(0,false)
	check(lab.hotplug_count >= 2,"hotplug callback exercised (synthetic notification)")

	await probe_checks()
	await combat_checks()
	var neutral_damage: Array[Dictionary] = []
	for row in [["横斩",2,100,36],["上捞",1,100,46],["普通纵斩",3,100,48],["蓄力1",91,110,71],["蓄力2",92,120,96],["蓄力3",93,130,143],["短攻击",4,100,2],["收刀踢",5,100,2]]:
		var actual: int = lab.combat.damage_for(row[1],row[2])
		check(actual == row[3],"neutral owner damage table " + row[0])
		neutral_damage.append({"name":row[0],"record":row[1],"attack_scale":row[2],"damage":actual})
	var report := {"engine":Engine.get_version_info().string,"passed":failures.is_empty(),"checks":checks,"failures":failures,"virtual_controller_events_only":true,"physical_controller_verified":false,"connected_devices":Input.get_connected_joypads(),"simulation_hz":30,"original_tick_hz_verified":false,"categories":categories,"variants":variants,"dive_sword_geometry":dive_geometry,"neutral_profile":lab.animator.data.combat.neutral_profile,"neutral_damage_table":neutral_damage,"combat_coverage":combat_coverage,"combat_hits":combat_hits,"captures":captures,"gpu_capture":capture_mode,"elapsed_ms":Time.get_ticks_msec()-start_time,"approximations":["procedural body geometry over 21 source bones","bone14 +Z rough drawn sword unchanged (.87); bone10 full local Transform3D from standing shoulder/spine back plane; sheathed display .55 (~1.27m length / .22m width), not original asset dimensions or full weapon attachment","flat floor, yaw pursuit and selected controller adaptation","independent incoming body probe only models attack_collision_allowed; outgoing original record capsules/spheres intersect neutral500HP AABB via HunterCombat, not full monster/element/critical/skill/bounce/hitstop system;90 simulation calls sandbox respawn not original value"]}
	var path: String = "res://tests/lab_test_results.json"
	var existing: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if not capture_mode and existing is Dictionary and existing.get("gpu_capture",false):
		report["previous_gpu_run"] = {"captures":existing.captures,"passed":existing.passed,"engine":existing.engine}
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	print("LAB TEST: %d checks, %d failures; %d GS variants; capture=%s" % [checks,failures.size(),variants.size(),capture_mode])
	lab.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
