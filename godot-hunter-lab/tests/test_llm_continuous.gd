extends SceneTree

const Output = preload("res://tests/result_output.gd")
const Tactics = preload("res://scripts/llm_tactics.gd")
var lab: Node3D
var checks: int = 0
var failures: Array[String] = []
var rows: Array[Dictionary] = []
var capture_mode: bool = false
var server := TCPServer.new()
var port: int = 0
var actual_expected: int = 0
var unknown_expected: int = 0
var screenshots: Array[String] = []

func _initialize() -> void:
	capture_mode = "--capture" in OS.get_cmdline_user_args()
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error("ASSERT FAIL: "+label)

func respond(move: String, tactic: String, incomplete: bool = false) -> int:
	var llm = lab.llm
	# Accelerated offline clock only; never remove the production interval.
	llm._next_request = 0
	var count: int = llm.requests
	llm.start_request(llm.observe(lab.hunt),"http://127.0.0.1:%d/v1/chat/completions" % port,[])
	check(llm.pending and llm.requests == count+1,"HTTP request continues past old cumulative caps")
	var id: int = llm.decision_id
	llm.start_request({},"http://127.0.0.1:%d/v1/chat/completions" % port,[])
	check(llm.requests == count+1,"single in flight")
	var deadline: int = Time.get_ticks_msec()+3000
	while not server.is_connection_available() and Time.get_ticks_msec() < deadline:
		await process_frame
	check(server.is_connection_available(),"loopback connected")
	if not server.is_connection_available():
		return id
	var peer := server.take_connection()
	var received := PackedByteArray()
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_available_bytes() > 0:
			received.append_array(peer.get_data(peer.get_available_bytes())[1])
			var text: String = received.get_string_from_utf8()
			var split: int = text.find("\r\n\r\n")
			if split >= 0:
				var length: int = 0
				for header in text.substr(0,split).split("\r\n"):
					if header.to_lower().begins_with("content-length:"):
						length = int(header.split(":")[1])
				if received.size() >= split+4+length:
					var payload: Dictionary = JSON.parse_string(text.substr(split+4))
					check(payload.max_tokens == Tactics.MAX_OUTPUT_TOKENS and not text.to_lower().contains("authorization:"),"configured single-response output limit; unauthenticated mock")
					break
		await process_frame
	var body: Dictionary = {"choices":[{"message":{"content":"" if incomplete else JSON.stringify({"plan":[{"move":move,"tactic":tactic}]})},"finish_reason":"length" if incomplete else "stop"}]}
	if llm.requests%10 == 0:
		unknown_expected += 1
	else:
		body.usage = {"prompt_tokens":230,"completion_tokens":70,"total_tokens":300}
		actual_expected += 300
	var bytes: PackedByteArray = JSON.stringify(body).to_utf8_buffer()
	peer.put_data(("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % bytes.size()).to_utf8_buffer())
	peer.put_data(bytes)
	while llm.pending and Time.get_ticks_msec() < deadline:
		peer.poll()
		await process_frame
	peer.disconnect_from_host()
	check(not llm.pending and not lab.monster.llm_pending,"terminal clears both pending owners")
	check(llm.usage == actual_expected and llm.unknown_usage_requests == unknown_expected,"actual cumulative usage exact; absent fields unknown, no estimates")
	llm.start_request({},"http://127.0.0.1:%d/v1/chat/completions" % port,[])
	check(llm.requests == count+1,"minimum interval after completion")
	return id

func execute(move: String, tactic: String, scenario: String, number: int, new_round: bool = true) -> void:
	if new_round:
		lab.reset_hunt()
		lab.monster.state.position = Vector3(900,0,0) if scenario == "wall" else Vector3.ZERO
		lab.controller.state.position = Vector3(700,0,0) if scenario == "wall" else Vector3(0,0,125 if scenario == "contact" else 400)
		lab.controller.state.hp = 100000
		lab.llm.bind_round(lab.hunt)
	var id: int = await respond(move,tactic)
	check(lab.monster._plan_decision_id == id and not lab.monster.llm_plan.is_empty(),"actual HTTP plan accepted "+str(number))
	var commits: Array = []
	var finished: bool = false
	var states: Dictionary = {}
	var last_progress: String = ""
	var transitions: Array = []
	var prepare_ticks: int = 0
	var movement_valid: bool = true
	var preparation_valid: bool = true
	for tick in range(650):
		if scenario == "moving":
			lab.controller.state.position = Vector3(sin(tick*0.018)*220,0,400+cos(tick*0.018)*80)
		var input: Dictionary = {"held":0,"mag":0,"direction":0,"bits":0}
		if scenario == "input_moving":
			var destination := Vector3(sin(lab.hunt.ticks*0.018)*220,0,400+cos(lab.hunt.ticks*0.018)*80)
			input.mag = 64 if lab.controller.state.position.distance_to(destination) > 10.0 else 0
			input.direction = HuntSession._yaw(lab.controller.state.position,destination)
		if lab.monster.state.mode == "prepare":
			prepare_ticks += 1
		var cooling: bool = lab.monster.state.cooldown_ticks > 0
		var report: Dictionary = lab.hunt.tick(input)
		lab.llm.record(lab.hunt)
		var m: Dictionary = lab.monster.state
		if m.mode == "reacquire" and lab.monster._walk_requested and m.approach_delta.length() > 0.001:
			movement_valid = movement_valid and m.primary == BulldromeController.WALK_CLIP and m.approach_delta.length() <= BulldromeController.APPROACH_SPEED+0.001 and m.applied_root_delta == Vector3.ZERO
		states[m.mode] = int(states.get(m.mode,0))+1
		if m.progress_reason != last_progress:
			transitions.append({"tick":tick,"mode":m.mode,"progress":m.progress_reason,"distance":m.position.distance_to(lab.controller.state.position),"yaw":m.yaw})
			last_progress = m.progress_reason
		for event in report.events:
			if event.event == "move_commit":
				preparation_valid = preparation_valid and prepare_ticks >= 18 and not cooling
				commits.append({"move":event.move,"source":event.decision_source,"decision_id":event.decision_id,"tick":tick})
				if capture_mode and number in [97,98,99,100,101,102]:
					lab.update_visuals()
					lab.llm_banner_detail.text = "LOOPBACK MOCK request %d · %s/%s 执行中 · 非真实模型" % [lab.llm.requests,tactic,move]
					await process_frame
					RenderingServer.force_draw(false)
					var image := root.get_texture().get_image()
					var path: String = Output.path("user://continuous_%d_%s.png" % [number,move])
					check(image.save_png(path) == OK,"GPU mock execution capture")
					screenshots.append(ProjectSettings.globalize_path(path))
			if event.event == "move_release" and capture_mode and number in [97,98,99,100,101,102]:
				lab.update_visuals()
				lab.llm_banner_detail.text = "LOOPBACK MOCK request %d · %s 已出招 · 非真实模型" % [lab.llm.requests,move]
				await process_frame
				RenderingServer.force_draw(false)
				var image := root.get_texture().get_image()
				var path: String = Output.path("user://continuous_%d_%s_release.png" % [number,move])
				check(image.save_png(path) == OK,"GPU actual release capture")
				screenshots.append(ProjectSettings.globalize_path(path))
			if event.event == "move_finished" and event.decision_id == id:
				finished = true
		if finished:
			break
	check(movement_valid and preparation_valid,"ground1003 single root owner, original bounded speed and full18 preparation after cooldown")
	check(commits.size() == 1 and commits[0].move == move and commits[0].source == "llm" and commits[0].decision_id == id and finished,"selected completes "+scenario+" "+tactic+"/"+move)
	rows.append({"request_id":lab.llm.requests,"decision_id":id,"round_generation":lab.hunt.round_generation,"scenario":scenario,"move":move,"tactic":tactic,"commits":commits,"finished":finished,"states":states,"transitions":transitions})

func run() -> void:
	lab = load("res://main.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.panel.visible = false
	lab.llm.set_memory_key("")
	lab.llm.set_mode(true)
	for candidate in range(19400,19410):
		if server.listen(candidate,"127.0.0.1") == OK:
			port = candidate
			break
	check(port != 0,"explicit loopback listener")
	if port == 0:
		quit(1)
		return
	var id: int = 0
	for scenario in ["stationary","moving","contact","wall"]:
		for tactic in ["observe","approach","circle_left","circle_right"]:
			for move in BulldromeController.MOVE_MENU:
				id += 1
				await execute(move,tactic,scenario,id)
	for scenario in ["stationary","moving","input_moving"]:
		for index in range(30 if scenario == "stationary" else 50):
			id += 1
			await execute(BulldromeController.MOVE_MENU.keys()[index%6],["observe","approach","circle_left","circle_right"][index%4],scenario,id,index == 0)
	check(lab.llm.requests == 226 and actual_expected > 12000,"226 real loopback requests; reported tokens exceed old12000; no stop")
	for attempt in range(3):
		lab.reset_hunt()
		lab.controller.state.hp = 100000
		lab.llm.bind_round(lab.hunt)
		await respond("laser","observe",true)
		check(lab.llm._retry_after_fallback and lab.llm.status.contains("单次输出未完成"),"length/empty content explicitly enters fallback, not cumulative budget pause")
		var count: int = lab.llm.requests
		var completed: bool = false
		for tick in range(650):
			if lab.llm._retry_after_fallback:
				lab.llm.advance(lab.hunt,true)
			var report: Dictionary = lab.hunt.tick({"held":0,"mag":0,"direction":0,"bits":0})
			lab.llm.record(lab.hunt)
			if report.events.any(func(event): return event.event == "move_finished" and event.decision_source == "fallback"):
				completed = true
				break
		check(completed and not lab.llm._retry_after_fallback and lab.llm.requests == count and not lab.monster.llm_pending,"failed request grants completed fallback attack before any next request; no pending spin")
		await execute("laser","approach","after_fallback",id+attempt+1,false)
		check(lab.llm.requests == count+1 and not lab.llm._retry_after_fallback,"next actual HTTP plan executes after completed fallback, no reset or re-spin")
	server.stop()
	var file := FileAccess.open(Output.path("user://llm_continuous_results.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks":checks,"failures":failures,"rows":rows,"requests":lab.llm.requests,"actual_tokens":lab.llm.usage,"unknown_usage_requests":lab.llm.unknown_usage_requests,"log_path":ProjectSettings.globalize_path(lab.llm.log_path),"network":"explicit_loopback_test; no key read, no relay","screenshots":screenshots,"adapter":RenderingServer.get_video_adapter_name()},"\t"))
	file.close()
	print("CONTINUOUS: ",checks," checks / ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
