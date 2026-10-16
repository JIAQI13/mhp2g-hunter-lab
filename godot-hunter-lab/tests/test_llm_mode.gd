extends SceneTree

const Output = preload("res://tests/result_output.gd")
var lab: Node3D
var checks: int = 0
var failures: Array[String] = []
var captures: Array[String] = []
var server := TCPServer.new()

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error("ASSERT FAIL: "+label)

func key(pressed: bool = true, echo: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_L
	event.physical_keycode = KEY_L
	event.unicode = 108
	event.pressed = pressed
	event.echo = echo
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func toggle() -> void:
	key()
	key(false)

func events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var file := FileAccess.open(lab.llm.log_path,FileAccess.READ)
	check(file != null,"actual session log readable")
	if file != null:
		while not file.eof_reached():
			var line := file.get_line()
			if not line.is_empty():
				var event: Variant = JSON.parse_string(line)
				check(event is Dictionary,"mode/conversation JSONL valid")
				if event is Dictionary:
					result.append(event)
		file.close()
	return result

func capture(name: String) -> void:
	lab.update_visuals()
	await process_frame
	await process_frame
	var rect: Rect2 = lab.llm_banner.get_global_rect()
	check(absf(rect.get_center().x-lab.llm_banner.get_parent().size.x*0.5) < 2 and rect.position.y == 18 and rect.size.x <= 364 and rect.end.y < 220,"banner top centered and bounded "+name)
	check(not rect.intersects(lab.hud.get_global_rect()) and not rect.intersects(lab.hunter_hp.get_global_rect()) and not rect.intersects(lab.panel.get_global_rect()),"banner does not overlap HUD/HP/actions "+name)
	if "--capture" in OS.get_cmdline_user_args():
		RenderingServer.force_draw(false)
		var image := root.get_texture().get_image()
		var path: String = Output.path("user://"+name+".png")
		check(not image.is_empty() and image.save_png(path) == OK,"GPU screenshot "+name)
		captures.append(ProjectSettings.globalize_path(path))

func response_body() -> PackedByteArray:
	return JSON.stringify({"choices":[{"message":{"content":JSON.stringify({"plan":[{"tactic":"observe","move":"laser"}]})}}]}).to_utf8_buffer()

func loopback() -> void:
	lab.reset_hunt()
	lab.controller.state.position = Vector3(0,0,190)
	lab.monster.state.position = Vector3.ZERO
	lab.llm.set_memory_key("FAKEKEY-MODE-FIXTURE-ONLY")
	var port: int = 0
	for candidate in range(19480,19490):
		if server.listen(candidate,"127.0.0.1") == OK:
			port = candidate
			break
	check(port != 0,"loopback listener available")
	if port == 0:
		return
	lab.llm.start_request(lab.llm.observe(lab.hunt),"http://127.0.0.1:%d/v1/chat/completions" % port,[])
	check(lab.llm.pending,"actual HTTP pending")
	check(lab.llm.mode_brief(lab.hunt,true).contains("未接管") and lab.llm.mode_brief(lab.hunt,true).contains("MOCK"),"pending mock is explicit and not accepted")
	await capture("mode_pending")
	var deadline: int = Time.get_ticks_msec()+5000
	while not server.is_connection_available() and Time.get_ticks_msec() < deadline:
		await process_frame
	check(server.is_connection_available(),"actual loopback connection")
	if not server.is_connection_available():
		server.stop()
		return
	var peer := server.take_connection()
	var request := PackedByteArray()
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_available_bytes() > 0:
			request.append_array(peer.get_data(peer.get_available_bytes())[1])
		var text: String = request.get_string_from_utf8()
		var split: int = text.find("\r\n\r\n")
		if split >= 0:
			var length: int = 0
			for header in text.substr(0,split).split("\r\n"):
				if header.to_lower().begins_with("content-length:"):
					length = int(header.split(":")[1])
			if request.size() >= split+4+length:
				break
		await process_frame
	check(request.get_string_from_utf8().begins_with("POST /v1/chat/completions") and not request.get_string_from_utf8().to_lower().contains("authorization:"),"actual POST no transport key")
	var body := response_body()
	peer.put_data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % body.size()).to_utf8_buffer())
	peer.put_data(body)
	while lab.llm.pending and Time.get_ticks_msec() < deadline:
		peer.poll()
		await process_frame
	peer.disconnect_from_host()
	server.stop()
	check(not lab.llm.pending and lab.monster.llm_plan.size() == 1,"actual HTTP plan accepted")
	check(lab.llm.mode_brief(lab.hunt,true).contains("MOCK计划已采纳") and lab.llm.mode_brief(lab.hunt,true).contains("非真实模型"),"mock accepted never claims model")
	await capture("mode_mock_accepted")
	for i in range(100):
		lab.tick_hunt({"held":0,"mag":0,"direction":0,"bits":0})
		if lab.monster.sandbox_special.stage == "active":
			break
	check(lab.monster.sandbox_special.stage == "active" and lab.llm.mode_brief(lab.hunt,true).contains("MOCK计划执行中"),"accepted decision provenance follows execution")
	await capture("mode_mock_executing")
	var volume: Dictionary = lab.monster.sandbox_special.volume().duplicate(true)
	toggle()
	check(not lab.llm.enabled and lab.monster.llm_plan.is_empty() and lab.monster.sandbox_special.volume() == volume,"L cancels plan but preserves committed active geometry")
	check(lab.llm.mode_brief(lab.hunt,true).contains("已承诺招式继续") and lab.llm.mode_brief(lab.hunt,true).contains("MOCK"),"disabled distinguishes continuing mock committed move")
	await capture("mode_disabled_committed")
	var logged := events()
	var terminal: Array[Dictionary] = logged.filter(func(event): return event.event == "request_terminal")
	check(terminal.size() == 1 and terminal[0].outcome == "accepted" and terminal[0].transport_source == "explicit_loopback_test" and terminal[0].usage == null and not terminal[0].usage_known,"actual conversation accepted with unknown usage")
	var file := FileAccess.open(lab.llm.log_path,FileAccess.READ)
	check(file != null and not file.get_as_text().contains("FAKEKEY-MODE-FIXTURE-ONLY"),"fixture credential not persisted")
	if file != null:
		file.close()

func run() -> void:
	lab = load("res://main.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	check(not lab.llm.has_key() and not lab.llm.enabled and lab.llm.requests == 0,"test entry offline without default key read")
	check(lab.llm_mode.text.contains("L 开/关"),"button shortcut visible")
	await capture("mode_rule_ai")
	key()
	check(lab.llm.enabled and lab.llm_mode.button_pressed,"physical L enables shared owner/button")
	var count: int = events().size()
	key(true,true)
	key(false)
	check(lab.llm.enabled and events().size() == count,"echo and release do not toggle/log")
	lab.set_llm_mode(true)
	check(events().size() == count,"idempotent mode setter no duplicate log")
	check(lab.llm_banner_detail.text.contains("缺少key") and lab.llm_banner_detail.text.contains("未接管"),"enabled missing key accurate")
	await capture("mode_missing_key")
	for editor in [lab.llm_key,LineEdit.new(),TextEdit.new()]:
		if editor != lab.llm_key:
			lab.llm_key.get_parent().add_child(editor)
		editor.grab_focus()
		await process_frame
		toggle()
		check(lab.llm.enabled and events().size() == count and editor.text == "l","typing L in LineEdit/TextEdit never toggles")
		editor.release_focus()
		if editor != lab.llm_key:
			editor.free()
		else:
			editor.clear()
	lab.llm_mode.button_pressed = false
	check(not lab.llm.enabled,"button shares mode setter")
	toggle()
	check(lab.llm.enabled and lab.llm_mode.button_pressed,"keyboard re-enables after button")
	var modes := events().filter(func(event): return event.event in ["mode_enabled","mode_disabled"])
	check(modes.size() == 3 and modes[0].event == "mode_enabled" and modes[1].event == "mode_disabled" and modes[2].event == "mode_enabled","exactly one mode log per effective transition")
	for event in modes:
		check(event.session_id == lab.llm.session_id and event.wall_unix_ms > 0 and not event.has("messages") and not event.has("usage"),"timestamp/session mode events no fake conversation/usage")
	check(lab.llm.requests == 0 and not lab.llm.usage_known,"no-key toggles no network or usage")
	lab.set_hunt_mode(false)
	check(lab.llm.enabled and lab.llm.mode_brief(lab.hunt,false).contains("训练模式"),"training preserves enabled intent, cancels request/plan")
	lab.set_hunt_mode(true)
	lab.reset_hunt()
	check(lab.llm.enabled and lab.monster.llm_plan.is_empty(),"round reset preserves mode intent")
	var motion: CheckButton = lab.mode_button.get_parent().get_child(1)
	motion.button_pressed = false
	toggle()
	check(not lab.llm.enabled and lab.llm_mode.disabled and not lab.llm_mode.button_pressed and lab.llm_banner_detail.text.contains("禁用"),"source motion mode disables both L and button")
	await capture("mode_source_disabled")
	motion.button_pressed = true
	var writer: FileAccess = lab.llm._log
	lab.llm._log = null
	lab.llm.log_status = ""
	toggle()
	check(lab.llm_banner_detail.text.contains("日志写入失败"),"mode log write failure visible in banner")
	await capture("mode_log_failure")
	lab.llm._log = writer
	lab.llm.log_status = "会话JSONL · 本地记录"
	await loopback()
	# Offline producer-boundary fixture only: no request sent to the production relay.
	lab.reset_hunt()
	lab.set_llm_mode(true)
	lab.llm.pending = true
	lab.monster.llm_pending = true
	lab.llm._started = Time.get_ticks_msec()
	lab.llm._request = {"transport_source":"production_relay"}
	var envelope: Dictionary = JSON.parse_string(response_body().get_string_from_utf8())
	var content: String = envelope.choices[0].message.content
	lab.llm._apply_response(HTTPRequest.RESULT_SUCCESS,200,response_body(),lab.hunt.round_generation,envelope,content,lab.Tactics.parse_plan(content))
	lab.llm._request.clear()
	check(lab.llm.mode_brief(lab.hunt,true).contains("模型计划已采纳") and not lab.llm.mode_brief(lab.hunt,true).contains("MOCK"),"production provenance status unit fixture distinct from loopback")
	for i in range(100):
		lab.hunt.tick({"held":0,"mag":0,"direction":0,"bits":0})
		if lab.monster.sandbox_special.stage == "active":
			break
	check(lab.monster.sandbox_special.stage == "active" and lab.llm.mode_brief(lab.hunt,true).contains("模型计划执行中"),"production execution status offline fixture only; no log inference")
	lab.llm.accepted_decision_id = -1
	check(lab.llm.mode_brief(lab.hunt,true).contains("未接管"),"unmatched accepted identity cannot claim model execution")
	lab.controller.state.hp = 0
	check(lab.llm.mode_brief(lab.hunt,true).contains("安全收尾") and lab.llm.mode_brief(lab.hunt,true).contains("不请求/不接管"),"terminal state does not claim model control")
	var output: String = Output.path("user://llm_mode_results.json")
	var file := FileAccess.open(output,FileAccess.WRITE)
	check(file != null,"dedicated results writable")
	if file != null:
		file.store_string(JSON.stringify({"checks":checks,"failures":failures,"screenshots":captures,"log_path":ProjectSettings.globalize_path(lab.llm.log_path),"real_relay_verified":false,"production_status_verification":"offline producer fixture only"},"\t"))
		file.close()
	print("LLM MODE: ",checks," checks / ",failures.size()," failed; results=",output)
	lab.free()
	quit(0 if failures.is_empty() else 1)
