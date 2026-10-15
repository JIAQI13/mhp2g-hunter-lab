extends SceneTree

var lab: Node3D
var checks: int = 0
var failures: Array[String] = []
var captures: Array[String] = []
var trace: Array[Dictionary] = []
var capture_mode: bool = false
var started: int = 0
var simulation_ticks: int = 0
var previous_state: String = ""
var fair_loop: Dictionary = {}

func _initialize() -> void:
	started = Time.get_ticks_usec()
	capture_mode = "--capture" in OS.get_cmdline_user_args()
	call_deferred("run")

func check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
		push_error("ASSERT FAIL: "+description)

func button(index: int, pressed: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.device = 0
	event.button_index = index
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
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

func step() -> Dictionary:
	var p: int = lab.controller.state.ticks
	var m: int = lab.monster.state.ticks
	var s: int = lab.skin_updates
	var result: Dictionary = lab.simulation_tick()
	simulation_ticks += 1
	check(lab.controller.state.ticks == p+1 and lab.monster.state.ticks == m+1 and lab.hunt.ticks == lab.controller.state.ticks,"paired once per source tick %d" % simulation_ticks)
	check(lab.skin_updates == s+1 and result.ready,"skin updated in simulation only %d" % simulation_ticks)
	check(result.space.distance >= 124.999 or not result.space.grounded_body,"body separation source owner %d" % simulation_ticks)
	lab.update_visuals()
	check(lab.hunter_hp.value == lab.controller.state.hp and lab.monster_label.text.contains(str(lab.monster.state.hp)+" / 1000") and lab.hud.text.contains("猎人 HP %d / 100" % lab.controller.state.hp),"HP HUD matches owners %d" % simulation_ticks)
	var identity: String = "%s/%s/%s" % [lab.hunt.round_state,lab.controller.state.recovery,lab.monster.state.mode]
	if identity != previous_state or result.events.any(func(e): return e.event in ["monster_damage","incoming_contact","player_damage","player_guard","round_end"]):
		trace.append({"tick":simulation_ticks,"round_tick":lab.hunt.ticks,"state":identity,"hp":[lab.controller.state.hp,lab.monster.state.hp],"events":result.events.duplicate(true)})
		previous_state = identity
	return result

func ticks(count: int) -> void:
	for i in range(count):
		step()

func release_all() -> void:
	for index in [JOY_BUTTON_Y,JOY_BUTTON_B,JOY_BUTTON_A,JOY_BUTTON_X,JOY_BUTTON_RIGHT_SHOULDER]:
		button(index,false)
	motion(JOY_AXIS_LEFT_X,0)
	motion(JOY_AXIS_LEFT_Y,0)

func fixture(ai: bool, player_at: Vector3, monster_at: Vector3) -> void:
	release_all()
	lab.reset_hunt()
	lab.monster.ai_enabled = ai
	lab.controller.state.position = player_at
	lab.monster.state.position = monster_at
	step()

func draw_weapon() -> void:
	button(JOY_BUTTON_Y,true)
	ticks(3)
	button(JOY_BUTTON_Y,false)
	ticks(100)
	check(lab.controller.is_drawn(),"real virtual Y draw")

func wait_event(name: String, limit: int = 500) -> Dictionary:
	for i in range(limit):
		var result := step()
		for event in result.events:
			if event.event == name:
				return event
	return {}

func capture(name: String) -> void:
	if not capture_mode:
		return
	lab.update_visuals()
	await process_frame
	RenderingServer.force_draw(false)
	var image := root.get_texture().get_image()
	var path: String = "res://screenshots/hunt/"+name+".png"
	check(not image.is_empty() and image.save_png(path) == OK,"GPU capture "+name)
	captures.append(path)

func mode_checks() -> void:
	lab.mode_button.emit_signal("pressed")
	check(not lab.hunt_mode and lab.target_mesh.visible and lab.danger_marker.visible and not lab.boar_view.visible,"mode button reveals original training")
	key(KEY_M,true)
	key(KEY_M,false)
	check(lab.hunt_mode and not lab.target_mesh.visible and lab.boar_view.visible,"M returns to hunt")
	button(JOY_BUTTON_DPAD_DOWN,true)
	button(JOY_BUTTON_DPAD_DOWN,false)
	check(not lab.hunt_mode,"virtual DpadDown selects training")
	var actor: Dictionary = lab.controller.state.duplicate(true)
	button(JOY_BUTTON_DPAD_UP,true)
	button(JOY_BUTTON_DPAD_UP,false)
	check(lab.controller.state == actor,"training reset preserves actor")
	button(JOY_BUTTON_DPAD_DOWN,true)
	button(JOY_BUTTON_DPAD_DOWN,false)
	check(lab.hunt_mode and lab.hunt.ticks == 0,"DpadDown paired reset into hunt")
	step()
	button(JOY_BUTTON_Y,true)
	button(JOY_BUTTON_Y,false)
	check(lab.snapshots.size() >= 2,"short press queued before restart")
	key(KEY_R,true)
	key(KEY_R,false)
	check(lab.snapshots.is_empty() and lab.last_snapshot.get("held",0) == 0 and lab.damage_labels.is_empty() and lab.hunt.ticks == 0 and lab.controller.state.hp == 100 and lab.monster.state.hp == 1000,"R clears whole round queued input floats counters")
	step()
	check(lab.controller.state.held == 0 and lab.hunt.hunter_hits == 0,"restart does not replay short attack")
	button(JOY_BUTTON_Y,true)
	key(KEY_R,true)
	key(KEY_R,false)
	ticks(3)
	check(lab.controller.state.held == 0 and lab.input_blocked_until_release,"held pre-reset attack blocked until release")
	button(JOY_BUTTON_Y,false)
	step()
	check(not lab.input_blocked_until_release,"release re-arms live input")
	lab.play_button.emit_signal("pressed")
	check(not lab.hunt_mode and lab.preview_ticks == 0,"gallery playback explicitly switches training")
	lab.set_hunt_mode(true)
	step()

func outgoing_checks() -> void:
	fixture(false,Vector3.ZERO,Vector3(0,0,-180))
	draw_weapon()
	button(JOY_BUTTON_Y,true)
	for i in range(200):
		step()
		if lab.controller.state.charge >= 82:
			break
	check(lab.controller.state.charge >= 82,"virtual Y charge3")
	button(JOY_BUTTON_Y,false)
	var hit := wait_event("monster_damage",180)
	check(hit.get("damage",0) == 143 and hit.get("record",0) == 93,"real charge original143 contact: "+str(hit))
	check(lab.monster.state.hp == 857 and lab.hunt.hunter_hits == 1 and lab.combat.hits == 0,"hunt damage never also ticks training cube")
	check(lab.damage_labels.size() == 1 and lab.damage_labels[0].label.text == "143","source damage float with shared TTL owner")
	await capture("hunt_charge_hit")
	var state: Dictionary = lab.hunt_snapshot.duplicate(true)
	var skin: int = lab.skin_updates
	var vertices: Array = lab.boar_view.vertices.duplicate(true)
	var ttl: int = lab.damage_labels[0].ttl if not lab.damage_labels.is_empty() else -1
	for i in range(60):
		lab._process(0)
	check(lab.skin_updates == skin and lab.boar_view.vertices == vertices and lab.hunt_snapshot == state,"60 renders do not skin/tick/damage")
	check(lab.damage_labels.is_empty() or lab.damage_labels[0].ttl == ttl,"render never owns label TTL")
	var before: int = lab.hunt.ticks
	lab._physics_process(1.0/30.0)
	check(lab.hunt.ticks == before+1 and lab.monster.state.ticks == lab.controller.state.ticks,"physics loop routes exactly one paired source tick")
	ticks(40)
	check(lab.damage_labels.is_empty(),"shared finite feedback lifetime")
	lab.target_reset_button.emit_signal("pressed")
	check(lab.hunt.ticks == 0 and lab.hunt.hunter_hits == 0 and lab.monster.state.hp == 1000,"current reset button restarts hunt")

func incoming_checks() -> void:
	fixture(true,Vector3(0,0,350),Vector3.ZERO)
	var initial: Vector3 = lab.monster.state.position
	var contact := wait_event("incoming_contact")
	check(not contact.is_empty() and contact.get("status","") == "pending" and lab.monster.state.position != initial,"AI moves and real attack geometry queues contact")
	check(lab.controller.state.hp == 100,"contact queue not premature damage")
	var result := step()
	check(lab.controller.state.hp == 80 and result.events.filter(func(e): return e.event == "player_damage").size() == 1,"incoming actual HP-20 once next tick")
	check(lab.damage_labels.any(func(f): return f.label.text == "-20") and lab.player_flash > 0,"incoming actual damage float red HP feedback")
	await capture("hunt_incoming")
	lab.monster.ai_enabled = false
	ticks(250)
	check(not lab.controller.is_recovering(),"real hurt and rise clips recover")
	fixture(false,Vector3(0,0,400),Vector3.ZERO)
	draw_weapon()
	button(JOY_BUTTON_RIGHT_SHOULDER,true)
	button(JOY_BUTTON_Y,true)
	ticks(3)
	button(JOY_BUTTON_Y,false)
	ticks(10)
	check(lab.controller.state.cate == 2,"actual R1+Y source guard")
	lab.monster.ai_enabled = true
	contact = wait_event("incoming_contact",200)
	check(contact.get("status","") == "guarded","actual spatial AI contact guard qualified")
	result = step()
	check(lab.controller.state.hp == 95 and result.events.filter(func(e): return e.event == "player_damage").size() == 1 and result.events.filter(func(e): return e.event == "player_guard").size() == 1,"guard chip5 and guard event no double damage")
	check(lab.damage_labels.any(func(f): return f.label.text == "防御 -5"),"guard actual numeric label")
	await capture("hunt_guard")
	button(JOY_BUTTON_RIGHT_SHOULDER,false)
	key(KEY_R,true)
	key(KEY_R,false)
	step()
	check(lab.controller.state.hp == 100 and lab.hunt.monster_hits == 0 and lab.hunt.monster_attack_events.snapshot().attacks.is_empty(),"reset removes incoming and attack lifetime remnants")

func terminal_checks() -> void:
	fixture(false,Vector3.ZERO,Vector3(0,0,-180))
	draw_weapon()
	lab.monster.state.hp = 1
	button(JOY_BUTTON_B,true)
	ticks(3)
	button(JOY_BUTTON_B,false)
	var hit := wait_event("monster_damage",180)
	check(hit.get("applied_damage",0) == 1 and hit.get("damage",0) == 36 and lab.hunt.round_state == "victory","low initial HP fixture still wins by real source slash")
	ticks(150)
	check(lab.round_panel.visible and lab.round_label.text.contains("狩猎成功") and not lab.monster.state.alive and lab.boar_view.visible and lab.monster.state.mode in ["dying","dead"],"victory original death corpse and panel")
	await capture("hunt_victory")
	var old_hits: int = lab.hunt.hunter_hits+lab.hunt.monster_hits
	button(JOY_BUTTON_B,true)
	ticks(100)
	button(JOY_BUTTON_B,false)
	check(lab.hunt.round_state == "victory" and lab.hunt.hunter_hits+lab.hunt.monster_hits == old_hits,"true dead corpse no new outgoing or incoming damage")
	fixture(true,Vector3(0,0,350),Vector3.ZERO)
	lab.controller.state.hp = 20
	var contact := wait_event("incoming_contact")
	check(not contact.is_empty(),"defeat still uses real incoming geometry")
	step()
	check(lab.hunt.round_state == "defeat" and lab.controller.is_dead() and lab.controller.state.hp == 0 and lab.round_panel.visible and lab.round_label.text.contains("猎人倒下"),"HP0 actual hit death panel")
	ticks(100)
	await capture("hunt_defeat")
	old_hits = lab.hunt.hunter_hits+lab.hunt.monster_hits
	button(JOY_BUTTON_Y,true)
	ticks(80)
	button(JOY_BUTTON_Y,false)
	check(lab.hunt.round_state == "defeat" and lab.controller.state.hp == 0 and lab.hunt.hunter_hits+lab.hunt.monster_hits == old_hits,"hunter death original corpse rejects new attacks")
	button(JOY_BUTTON_DPAD_UP,true)
	button(JOY_BUTTON_DPAD_UP,false)
	check(lab.hunt.round_state == "running" and lab.controller.state.hp == 100 and lab.monster.state.hp == 1000 and not lab.round_panel.visible,"DpadUp restarts actual defeat")
	step()

func boundary_and_fair_loop() -> void:
	fixture(false,Vector3(1400,0,1400),Vector3(-1400,0,-1400))
	check(absf(lab.controller.state.position.x) <= 960 and absf(lab.monster.state.position.x) <= 915,"session radius-aware boundary no scene physics mutation")
	check(lab.actor.position.is_equal_approx(lab.controller.state.position*0.01) and lab.boar_view.position.is_equal_approx(lab.monster.state.position*0.01) and lab.boar_view.scale == Vector3.ONE,"render source transform one scale no repeated lift")
	fixture(true,Vector3(0,0,350),Vector3.ZERO)
	var incoming: int = 0
	var outgoing: int = 0
	var hurt: bool = false
	var recovered: bool = false
	for i in range(1600):
		button(JOY_BUTTON_Y,i < 3)
		button(JOY_BUTTON_B,i >= 3 and i % 130 < 3)
		var result := step()
		for event in result.events:
			incoming += int(event.event == "incoming_contact")
			outgoing += int(event.event == "monster_damage")
		hurt = hurt or lab.controller.is_recovering()
		recovered = recovered or (hurt and not lab.controller.is_recovering())
		if lab.hunt.round_state != "running":
			break
	check(incoming > 0 and outgoing > 0 and recovered,"normal AI virtual input fair loop incoming outgoing recovery")
	fair_loop = {"ticks":lab.hunt.ticks,"incoming":incoming,"outgoing":outgoing,"recovered":recovered,"hp":[lab.controller.state.hp,lab.monster.state.hp],"round":lab.hunt.round_state,"fixture":"initial positions only; normal AI, real virtual Y/B events; no ongoing teleports/HP changes/forced action"}
	release_all()
	lab.reset_hunt()
	step()
	check(lab.controller.state.hp == 100 and lab.hunt.hunter_hits == 0 and lab.hunt.monster_hits == 0 and lab.damage_labels.is_empty(),"fair loop restart no old contact or feedback")

func run() -> void:
	lab = load("res://main.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	await process_frame
	check(lab.hunt_mode and lab.controller.state.ready and lab.monster.state.ready,"default playable hunt paired actors ready")
	check(lab.boar_view.visible and not lab.target_mesh.visible and not lab.danger_marker.visible,"original monster visible training fixtures hidden")
	check(lab.monster_animator.data.bones.size() == 19 and lab.monster_animator.data.clips.size() == 31 and not lab.boar_view.vertices.is_empty(),"original19 bones31 clips actual skinned mesh")
	check(lab.controller.state.position.distance_to(lab.monster.state.position) == 500,"initial5 display unit spacing")
	var viewport: Vector2 = root.get_visible_rect().size
	check(lab.panel.get_global_rect().end.x <= viewport.x and lab.panel.get_global_rect().end.y <= viewport.y and lab.help.get_global_rect().end.y <= viewport.y and lab.help.get_global_rect().end.x <= lab.panel.position.x,"1280x800 panel help fit")
	var max_x: float = 0
	for surface in lab.boar_view.vertices:
		for point in surface:
			max_x = maxf(max_x,lab.camera.unproject_position(lab.boar_view.global_transform*(point+Vector3.UP*lab.boar_view.lift)).x)
	check(max_x < lab.panel.position.x-12,"initial full pig mesh unobscured by panel")
	var old_orbit: float = lab.orbit
	var old_distance: float = lab.distance
	motion(JOY_AXIS_RIGHT_X,0.8)
	lab._process(0.1)
	check(lab.orbit != old_orbit and lab.hunt.ticks == 0,"hunt right stick free orbit without forced lock")
	motion(JOY_AXIS_RIGHT_X,0)
	lab.orbit = old_orbit
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	lab._unhandled_input(wheel)
	check(lab.distance < old_distance,"hunt camera zoom preserved")
	lab.distance = old_distance
	lab.update_visuals()
	await capture("hunt_start")
	mode_checks()
	await outgoing_checks()
	await incoming_checks()
	await terminal_checks()
	boundary_and_fair_loop()
	var report := {"engine":Engine.get_version_info().string,"passed":failures.is_empty(),"checks":checks,"failures":failures,"simulation_ticks":simulation_ticks,"captures":captures,"gpu_capture":capture_mode,"virtual_controller_events_only":true,"physical_controller_verified":false,"fair_loop":fair_loop,"trace":trace,"limits":lab.hunt.limits,"cost":{"elapsed_seconds":float(Time.get_ticks_usec()-started)/1000000.0,"static_memory_bytes":OS.get_static_memory_usage(),"static_memory_peak_bytes":OS.get_static_memory_peak_usage(),"cache":"warm imported assets, no controlled cold/warm comparison","agent_tokens":"unmeasured","cpu_seconds":"external /usr/bin/time -l","process_family_peak_memory":"single Godot process external /usr/bin/time -l; no before-equivalent benchmark"},"fixtures":"explicit stage initial positions / terminal threshold HP; all final damage from real source attack events and spatial contact; no take_damage/queue_incoming/force_action in harness"}
	var file := FileAccess.open("res://tests/hunt_lab_results.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	print("HUNT LAB: %d checks / %d failures; %d source ticks; capture=%s; fair=%s" % [checks,failures.size(),simulation_ticks,capture_mode,fair_loop])
	lab.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
