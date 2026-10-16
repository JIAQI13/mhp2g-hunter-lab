extends SceneTree

const Output = preload("res://tests/result_output.gd")
var animator: HunterAnimator
var boar: BulldromeController
var checks: int = 0
var failures: Array[String] = []
var metrics: Dictionary = {}
var trace: Array = []
var lab: Node3D
var screenshots: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error("ASSERT FAIL: "+label)

func step(point: Vector3) -> Dictionary:
	boar.tick({"position":point,"hp":100,"alive":true,"observable_action":"moving"})
	if boar.state.mode == "special_commit":
		boar.commit_special()
	return boar.state.duplicate(true)

func pending_measure() -> void:
	boar.reset(Vector3.ZERO)
	boar.llm_pending = true
	var stationary: int = 0
	var distance: float = 0
	var yaw: int = 0
	for i in range(100):
		var before: Vector3 = boar.state.position
		var old_yaw: int = boar.state.yaw
		step(Vector3(400,0,-350)+Vector3(i*2,0,0))
		var moved: float = before.distance_to(boar.state.position)
		var turned: int = absi(((int(boar.state.yaw)-old_yaw+32768)&65535)-32768)
		distance += moved
		yaw += turned
		stationary += 1 if moved < 0.001 and turned == 0 else 0
	metrics.pending = {"ticks":100,"stationary_ticks":stationary,"distance":distance,"yaw_travel":yaw}

func charge_measure() -> void:
	boar.reset(Vector3.ZERO)
	boar._begin_attack(Vector3(0,0,600),"charge")
	var still: int = 0
	var peak: int = 0
	var modes: Array = []
	for i in range(250):
		var before: Vector3 = boar.state.position
		var frame: float = animator.tracks[0].currentframe
		step(Vector3(400,0,600))
		if boar.state.mode == "charge" and boar.state.position.is_equal_approx(before) and frame == animator.tracks[0].currentframe:
			still += 1
		else:
			still = 0
		peak = maxi(peak,still)
		var mode: String = boar.state.mode+"/"+str(boar.state.phase)
		if modes.is_empty() or modes[-1] != mode:
			modes.append(mode)
		if boar.state.mode != "charge":
			break
	metrics.charge = {"max_no_pose_or_position_progress_ticks":peak,"chain":modes,"clip1015_end":animator.data.clips["1015:0"].end,"clip1015_loop":animator.data.clips["1015:0"].loop,"clip1016_end":animator.data.clips["1016:0"].end}

func pending_checks() -> void:
	boar.reset(Vector3.ZERO)
	boar.llm_pending = true
	var stationary: int = 0
	var pending_ticks: int = int(LlmTactics.REQUEST_TIMEOUT_SECONDS*30)+60
	for i in range(pending_ticks):
		var before: Vector3 = boar.state.position
		var yaw: int = boar.state.yaw
		var state := step(Vector3(0,0,500))
		stationary += 1 if before.is_equal_approx(state.position) and yaw == state.yaw else 0
		check(state.mode == "reacquire" and not state.events.any(func(e): return e.event in ["attack_spawn","sandbox_special_begin","move_commit"]),"pending non-damage tracking, no fallback competition")
		check(state.observed_target == Vector3(0,0,500),"current observed target from caller snapshot only")
	check(stationary == 0,"stationary hunter does not cause pending empty waits")
	check(boar.llm_pending,"simulation cannot expire HTTP owner's pending even beyond wall-time equivalent")
	boar.llm_pending = false
	step(Vector3(0,0,500))
	check(boar.decision_source == "fallback","HTTP owner release permits legal fallback")
	var committed: bool = false
	for i in range(100):
		step(Vector3(0,0,500))
		committed = committed or boar.state.events.any(func(e): return e.event == "move_commit")
		if committed:
			break
	check(committed,"fallback makes bounded attack progress after timeout")
	metrics.pending_stationary_hunter = {"ticks":pending_ticks,"empty_wait_ticks":stationary}

func move_checks() -> void:
	for move in ["charge","turn_attack","laser","stink"]:
		boar.reset(Vector3.ZERO)
		var point: Vector3 = Vector3(190,0,0) if move == "turn_attack" else Vector3(0,0,190 if move == "stink" else 600)
		boar.accept_llm_plan([{"move":move,"tactic":"observe"},{"move":"charge","tactic":"approach"}])
		var commits: int = 0
		var first_target: Vector3
		var released: bool = false
		var ended: bool = false
		var cooling_distance: float = 0
		var fixed: Dictionary = {}
		var chain: Array = []
		var prep_ticks: int = 0
		for i in range(500):
			if released:
				point = Vector3(480+i*0.1,0,-300)
			var before: Vector3 = boar.state.position
			var old_yaw: int = boar.state.yaw
			var cooling: bool = boar.state.cooldown_ticks > 0
			var state := step(point)
			if chain.is_empty() or chain[-1] != state.mode:
				chain.append(state.mode)
			if state.mode == "prepare":
				prep_ticks += 1
			if state.mode in ["reacquire","move_recovery","prepare"]:
				check(absi(((int(state.yaw)-old_yaw+32768)&65535)-32768) <= boar.WALK_TURN_STEP,"shared tracker limited yaw across0")
				check(before.distance_to(state.position) <= 18.001 and state.applied_root_delta == Vector3.ZERO,"grounded walk single owner, not charge root plus walk")
			check(state.observed_target == point,"release current target updates every caller observation")
			for event in state.events:
				if event.event == "move_commit":
					commits += 1
					check(event.decision_source == "llm" and event.target == point,"commit uses selected plan and current target, not prep snapshot")
					check(prep_ticks >= 18,"each attack keeps full prepare18")
					prep_ticks = 0
					if commits == 1:
						first_target = state.committed_target
						if move == "turn_attack":
							var side: int = ((int(state.turn_target_yaw)-int(state.yaw)+32768)&65535)-32768
							check(absi(side) >= 0x1000,"turn retains meaningful close-side angle at commit")
				if event.event == "move_release" and not released:
					released = true
					check(state.tracking_stage == "release_intent_locked","release creates immediate pursuit intent without rotating hazard")
				if event.event == "move_finished":
					ended = true
			if released and not ended:
				check(state.committed_target == first_target,"released attack committed target remains immutable")
				if move in ["laser","stink"]:
					if fixed.is_empty():
						fixed = boar.sandbox_special.volume()
					check(fixed == boar.sandbox_special.volume(),"beam/cloud never follows target at release or during active/recovery")
					check(state.position == before and state.yaw == old_yaw,"special valid window preserves actor geometry")
			if cooling:
				cooling_distance += before.distance_to(state.position)
				check(not state.events.any(func(e): return e.event == "move_commit"),"cooldown can walk but cannot attack early")
			trace.append({"move":move,"tick":i,"mode":state.mode,"tracking_stage":state.tracking_stage,"observed_target":str(state.observed_target),"committed_target":str(state.committed_target),"yaw":state.yaw,"position":str(state.position),"decision_source":boar.decision_source})
			if commits == 2:
				break
		check(released and ended and commits == 2,"moving hunter reacquired after "+move+" and next attack commits")
		check(cooling_distance > 0,"post-attack cooldown repositions after "+move)
		metrics[move+"_chain"] = {"states":chain,"commits":commits,"cooldown_distance":cooling_distance}
	boar.reset(Vector3.ZERO)
	boar.accept_llm_plan([{"move":"charge","tactic":"approach"}],17)
	for i in range(100):
		step(Vector3(0,0,500))
		if boar.state.mode == "charge":
			break
	boar.take_damage(1,0)
	step(Vector3(350,0,500))
	check(boar.state.events.any(func(event): return event.event == "move_release" and event.decision_source == "llm" and event.decision_id == 17),"committed execution binding survives future-plan cancellation from subthreshold hurt")
	for reaction in [120,1000]:
		boar.reset(Vector3.ZERO)
		boar.llm_pending = true
		step(Vector3(0,0,500))
		boar.take_damage(reaction,0)
		step(Vector3(0,0,500))
		check(boar.state.tracking_stage == "cancelled" and boar.state.observed_target == null and boar.llm_plan.is_empty() and not boar.llm_pending,"hurt/death cancels pursuit/plan")
		boar.reset()
		check(boar.state.committed_target == null and boar.state.observed_target == null and boar._walk_speed == 0,"restart resets tracking identity and speed")

func boundary_checks() -> void:
	lab = load("res://main.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.panel.visible = false
	lab.llm.set_mode(false)
	for mode in ["reacquire","move_recovery","prepare","charge"]:
		lab.reset_hunt()
		lab.llm.advance(lab.hunt,true)
		lab.monster.state.mode = mode
		lab.monster.llm_pending = true
		lab.llm.pending = true
		var text: String = '{"plan":[{"tactic":"observe","move":"laser"}]}'
		var parsed: Dictionary = LlmTactics.parse_plan(text)
		var outcome: Dictionary = lab.llm._apply_response(HTTPRequest.RESULT_SUCCESS,200,text.to_utf8_buffer(),lab.hunt.round_generation,{"choices":[]},text,parsed)
		check(outcome.outcome == ("accepted" if mode in ["reacquire","move_recovery"] else "cancel"),"response only applies at owned decision boundary: "+mode)
	lab.reset_hunt()
	lab.llm.advance(lab.hunt,true)
	lab.monster.llm_pending = false
	lab.llm.pending = true
	var reply: String = '{"plan":[{"tactic":"observe","move":"laser"}]}'
	check(lab.llm._apply_response(HTTPRequest.RESULT_SUCCESS,200,reply.to_utf8_buffer(),lab.hunt.round_generation,{},reply,LlmTactics.parse_plan(reply)).outcome == "cancel","late reply after pending owner release cannot resurrect plan")
	for pair in [[Vector3(880,0,880),Vector3(960,0,960)],[Vector3(915,0,0),Vector3(960,0,0)],[Vector3(900,0,0),Vector3(700,0,0)]]:
		lab.reset_hunt()
		lab.monster.state.position = pair[0]
		lab.controller.state.position = pair[1]
		lab.monster.state.yaw = 0x4000
		lab.monster.accept_llm_plan([{"tactic":"circle_right","move":"stink"}])
		var progress: bool = false
		var moved: float = 0
		for i in range(220):
			var old: Vector3 = lab.monster.state.position
			var report: Dictionary = lab.tick_hunt({"held":0,"mag":0,"direction":0,"bits":0})
			moved += old.distance_to(lab.monster.state.position)
			check(report.space.distance >= 124.999 and absf(lab.monster.state.position.x) <= 915.001 and absf(lab.monster.state.position.z) <= 915.001,"wall/body constrained local progress")
			progress = report.events.any(func(e): return e.event == "move_commit" and e.decision_source == "llm" and e.move == "stink")
			if progress:
				break
		check(progress and moved > 1,"bounded progress behind/near wall/body, no perpetual walk")
	if "--capture" in OS.get_cmdline_user_args():
		lab.reset_hunt()
		lab.monster.state.position = Vector3.ZERO
		lab.controller.state.position = Vector3(0,0,600)
		lab.monster.llm_pending = true
		await capture("pending_start")
		for i in range(30):
			lab.tick_hunt({"held":0,"mag":0,"direction":0,"bits":0})
		await capture("pending_reposition30")
		lab.monster.accept_llm_plan([{"tactic":"observe","move":"laser"},{"tactic":"approach","move":"stink"}])
		var taken: Dictionary = {}
		for i in range(400):
			if lab.monster.state.released:
				lab.controller.state.position = Vector3(350,0,300) if lab.monster.sandbox_special.kind == "stink" else Vector3(-350,0,-250)
			lab.tick_hunt({"held":0,"mag":0,"direction":0,"bits":0})
			var key: String = lab.monster.state.tracking_stage+"_"+lab.monster.sandbox_special.kind
			if key not in taken and lab.monster.state.tracking_stage in ["release_intent_locked","cooldown_reposition","prepare_current_target","committed_locked"] and (lab.monster.state.tracking_stage != "release_intent_locked" or lab.monster.state.observed_target != lab.monster.state.committed_target):
				taken[key] = true
				await capture(key)
			if taken.has("release_intent_locked_stink"):
				break
	metrics.boundary = {"network":"none; local completed-response fixture, no HTTP start or keys","adapter":RenderingServer.get_video_adapter_name(),"screenshots":screenshots}

func capture(name: String) -> void:
	lab.update_visuals()
	lab.camera.position = Vector3(12,14,16)
	lab.camera.look_at(Vector3(0,0.8,0))
	lab.llm_status.text = "离线回归 / "+name+"\n"+lab.llm_status.text
	await process_frame
	RenderingServer.force_draw(false)
	var image := root.get_texture().get_image()
	var path: String = Output.path("user://release_tracking/capture.json").get_base_dir().path_join(name+".png")
	check(not image.is_empty() and image.save_png(path) == OK,"GPU capture "+name)
	screenshots.append(ProjectSettings.globalize_path(path))

func run() -> void:
	animator = HunterAnimator.new()
	check(animator.load_data("res://assets/bulldrome_data.json"),"real animation data")
	boar = BulldromeController.new()
	check(boar.configure(animator),"real controller configured")
	boar.sandbox_specials_enabled = true
	pending_measure()
	charge_measure()
	if not "--baseline" in OS.get_cmdline_user_args():
		pending_checks()
		move_checks()
		await boundary_checks()
	var output := FileAccess.open(Output.path("user://release_tracking/baseline.json" if "--baseline" in OS.get_cmdline_user_args() else "user://release_tracking/tracking_results.json"),FileAccess.WRITE)
	output.store_string(JSON.stringify({"checks":checks,"failures":failures,"metrics":metrics,"trace":trace},"\t"))
	output.close()
	print("RELEASE TRACKING ",metrics," checks=",checks," failures=",failures.size())
	quit(0 if failures.is_empty() else 1)
