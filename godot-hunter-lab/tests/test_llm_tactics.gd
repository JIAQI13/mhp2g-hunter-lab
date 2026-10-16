extends SceneTree

const Tactics = preload("res://scripts/llm_tactics.gd")
var lab: Node3D
var checks: int = 0
var failures: Array[String] = []
var server := TCPServer.new()
var port: int = 0
var capture_mode: bool = false
var plan := {"plan":[{"tactic":"observe","move":"laser"},{"tactic":"approach","move":"stink"}]}

func _initialize() -> void:
	capture_mode = "--capture" in OS.get_cmdline_user_args()
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error("ASSERT FAIL: "+label)

func step() -> Dictionary:
	var previous: int = lab.hunt.ticks
	var result: Dictionary = lab.tick_hunt({"held":0,"mag":0,"direction":0,"bits":0})
	check(lab.hunt.ticks == previous+1 and lab.controller.state.ticks == lab.monster.state.ticks,"single paired simulation owners")
	return result

func fixture() -> void:
	lab.reset_hunt()
	lab.controller.state.position = Vector3(0,0,190)
	lab.monster.state.position = Vector3.ZERO
	lab.llm.set_memory_key("")
	lab.llm.set_mode(true)
	lab.llm_mode.set_pressed_no_signal(true)
	lab.llm.advance(lab.hunt,true)

func envelope(content: String) -> PackedByteArray:
	return JSON.stringify({"choices":[{"message":{"content":content}}],"usage":{"prompt_tokens":230,"completion_tokens":70,"total_tokens":300}}).to_utf8_buffer()

func parser_checks() -> void:
	check(Tactics.parse_plan(JSON.stringify(plan)) == {"ok":true,"plan":plan.plan,"reason":""},"two-step network plan returns empty internal reason")
	for move in BulldromeController.MOVE_MENU:
		for tactic in Tactics.TACTICS:
			check(Tactics.parse_plan(JSON.stringify({"plan":[{"move":move,"tactic":tactic}]})).ok,"each single-step enum pair accepted")
	for bad in ["not json","[]","{}","prefix "+JSON.stringify(plan),JSON.stringify(plan)+" explanation",JSON.stringify(plan)+JSON.stringify(plan),"```json\n"+JSON.stringify(plan)+"\n```","```\n"+JSON.stringify(plan)+"\n```",JSON.stringify({"plan":[]}),JSON.stringify({"plan":plan.plan+[plan.plan[0]]}),JSON.stringify({"plan":null}),JSON.stringify({"plan":"charge"}),JSON.stringify({"plan":[null]}),JSON.stringify({"plan":[[]]}),JSON.stringify({"plan":[{"move":"execute","tactic":"observe"}]}),JSON.stringify({"plan":[{"move":"charge","tactic":"observe|approach"}]}),JSON.stringify({"plan":[{"move":"charge","tactic":"teleport"}]}),JSON.stringify({"plan":[{"move":1,"tactic":"observe"}]}),JSON.stringify({"plan":[{"move":"charge","tactic":false}]}),JSON.stringify({"plan":[{"move":"charge"}]}),JSON.stringify({"plan":[{"move":"charge","tactic":"observe","windup":0}]}),JSON.stringify({"plan":plan.plan,"reason":""}),JSON.stringify({"plan":plan.plan,"hp":0}),"x".repeat(Tactics.MAX_CONTENT+1)]:
		check(not Tactics.parse_plan(bad).ok,"strict malformed/extra/reason/fence/count/enum/type rejected: "+bad.left(70))
	var longest: String = JSON.stringify({"plan":[{"move":"turn_attack","tactic":"circle_right"},{"move":"turn_attack","tactic":"circle_right"}]})
	check(longest.length() == 104 and Tactics.parse_plan(longest).ok,"maximum compact enum structure derives 104 bytes")
	check(Tactics.parse_plan(" ".repeat(Tactics.MAX_CONTENT-longest.length())+longest).ok and Tactics.parse_plan(" ".repeat(Tactics.MAX_CONTENT-longest.length()+1)+longest).failure_code == "content_limit","bounded whitespace allowance remains exact")
	var facts: Dictionary = lab.llm.observe(lab.hunt)
	check(facts.hunter.trend == "unknown" and facts.recent == [{"move":"unknown","contact":"unknown"}],"initial unknowns preserved, not fabricated misses")
	check(is_equal_approx(facts.distance_m,1.9) and facts.bearing_deg == 0 and is_equal_approx(facts.wall_clearance_m,9.15) and facts.relative_hp == {"hunter":1.0,"boar":1.0},"initial compact observation golden")
	for move in facts.legal_moves:
		var source: Dictionary = BulldromeController.MOVE_MENU[move]
		check(facts.legal_moves[move].use == source.use and facts.legal_moves[move].avoid == source.avoid and is_equal_approx(facts.legal_moves[move].range_m,source.range*0.01),"shared menu owner facts projected once into meters")
	check(facts.legal_moves.tusk.min_range_m == 3 and BulldromeController.MOVE_MENU.tusk.range == 750 and lab.monster.decision_moves().tusk.range == 750,"conversion cannot mutate controller source-unit facts")
	print_sizes(facts,"initial")
	for units in [95,200,600]:
		lab.controller.state.position = Vector3(0,0,units)
		check(is_equal_approx(lab.llm.observe(lab.hunt).distance_m,units*0.01),"95/200/600 source distance converted once")
	lab.llm._facts.assign([{"move":"charge","contact":"hit"},{"move":"laser","contact":"unknown"},{"move":"stink","contact":"miss"},{"move":"tusk","contact":"unknown"}])
	check(lab.llm.observe(lab.hunt).recent == [{"move":"laser","contact":"unknown"},{"move":"stink","contact":"miss"},{"move":"tusk","contact":"unknown"}],"latest three preserve observed contact and unknowns")
	lab.monster._slam_ready_tick = 100
	check(not lab.llm.observe(lab.hunt).slam_ready and not lab.llm.observe(lab.hunt).legal_moves.has("slam"),"unready slam omitted from current legal menu")
	lab.monster.sandbox_specials_enabled = false
	check(lab.llm.observe(lab.hunt).legal_moves.keys() == ["charge","turn_attack"],"disabled specials are not advertised as legal")
	lab.monster.sandbox_specials_enabled = true
	fixture()
	lab.controller.state.hp = 100000
	for tick in range(600):
		lab.hunt.tick({"held":0,"mag":0,"direction":0,"bits":0})
		lab.llm.record(lab.hunt)
	var snapshot: Dictionary = lab.llm.observe(lab.hunt)
	check(lab.hunt.ticks == 600 and snapshot.recent.size() <= 3 and snapshot.hunter.action == lab.controller.observable_action(),"actual 600-tick game snapshot uses observed owner facts")
	check(is_equal_approx(snapshot.distance_m,snappedf(lab.controller.state.position.distance_to(lab.monster.state.position)*0.01,0.01)),"600-tick actual geometry converted at observation boundary")
	print_sizes(snapshot,"600 ticks")
	fixture()

func print_sizes(facts: Dictionary, label: String) -> void:
	var text: String = JSON.stringify(facts)
	var payload_text: String = JSON.stringify({"model":Tactics.MODEL,"messages":[{"role":"system","content":Tactics.PROMPT},{"role":"user","content":text}],"max_tokens":Tactics.MAX_OUTPUT_TOKENS})
	print("PAYLOAD SIZE ",label," (characters / UTF-8 bytes; NOT tokens): system=",Tactics.PROMPT.length(),"/",Tactics.PROMPT.to_utf8_buffer().size()," user=",text.length(),"/",text.to_utf8_buffer().size()," payload=",payload_text.length(),"/",payload_text.to_utf8_buffer().size())
	check(facts.size() == 9 and not text.contains("ticks") and not text.contains("projectile_shape") and not text.contains("held") and not text.contains("res://") and not text.contains("Authorization"),"compact input has only decision facts, no per-tick/bone/projectile parameters")
	check(text.length() < 2200,"representative compact observation character bound; not a token estimate")

func log_events() -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var file := FileAccess.open(lab.llm.log_path,FileAccess.READ)
	check(file != null,"session log readable at actual UI path")
	if file == null:
		return events
	while not file.eof_reached():
		var line: String = file.get_line()
		if line.is_empty():
			continue
		var event: Variant = JSON.parse_string(line)
		check(event is Dictionary,"persisted JSONL parses")
		if event is Dictionary:
			events.append(event)
	file.close()
	return events

func mock(body: PackedByteArray, timeout: bool = false, code: int = 200, restart: bool = false, synthetic_key: String = "", relocate: bool = false) -> void:
	fixture()
	var llm = lab.llm
	llm.request_timeout_seconds = 1.0 if timeout else Tactics.REQUEST_TIMEOUT_SECONDS
	# Explicit loopback clock fixture; production keeps its monotonic five-second interval.
	llm._next_request = 0
	if not synthetic_key.is_empty():
		llm.set_memory_key(synthetic_key)
	var observation: Dictionary = llm.observe(lab.hunt)
	if not synthetic_key.is_empty():
		observation.game_note = {"Authorization":"ordinary game content",synthetic_key:synthetic_key}
	llm.start_request(observation,"http://127.0.0.1:%d/v1/chat/completions" % port,[])
	check(llm.pending and lab.monster.llm_pending,"real HTTPRequest pending")
	var count: int = llm.requests
	llm.start_request({},"http://127.0.0.1:%d/v1/chat/completions" % port,[])
	check(llm.requests == count,"one in flight")
	var deadline: int = Time.get_ticks_msec()+6000
	while not server.is_connection_available() and Time.get_ticks_msec() < deadline:
		await process_frame
	check(server.is_connection_available(),"loopback accepted connection")
	if not server.is_connection_available():
		return
	var peer := server.take_connection()
	var received := PackedByteArray()
	var request_text: String = ""
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_available_bytes() > 0:
			received.append_array(peer.get_data(peer.get_available_bytes())[1])
			request_text = received.get_string_from_utf8()
			var split: int = request_text.find("\r\n\r\n")
			if split >= 0:
				var length: int = 0
				for header in request_text.substr(0,split).split("\r\n"):
					if header.to_lower().begins_with("content-length:"):
						length = int(header.split(":")[1])
				if received.size() >= split+4+length:
					break
		await process_frame
	check(request_text.begins_with("POST /v1/chat/completions HTTP/1.1") and not request_text.to_lower().contains("authorization:"),"actual POST, mock has no fake credential")
	var payload: Variant = JSON.parse_string(request_text.split("\r\n\r\n",true,1)[1])
	check(payload is Dictionary and payload.size() == 3 and payload.model == Tactics.MODEL and payload.max_tokens == Tactics.MAX_OUTPUT_TOKENS and payload.has("messages"),"compatible payload contains ONLY model/messages/max_tokens")
	check(payload.max_tokens == Tactics.MAX_OUTPUT_TOKENS,"single completion capacity, not a cumulative budget")
	if relocate:
		lab.controller.state.position = Vector3(-500,0,-300)
	if not timeout:
		peer.put_data(("HTTP/1.1 %d OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [code,body.size()]).to_utf8_buffer())
		peer.put_data(body)
	if restart:
		lab.reset_hunt()
		await process_frame
		check(lab.monster.llm_plan.is_empty() and llm._http.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED,"restart cancels real HTTP before late reply")
	while llm.pending and Time.get_ticks_msec() < deadline:
		peer.poll()
		await process_frame
	peer.disconnect_from_host()
	check(not llm.pending and not lab.monster.llm_pending,"completion/timeout releases pending")
	var events := log_events()
	var starts: Array[Dictionary] = []
	var terminals: Array[Dictionary] = []
	for event in events:
		if int(event.get("request_id",-1)) == count:
			if event.event == "request_start":
				starts.append(event)
			elif event.event == "request_terminal":
				terminals.append(event)
	check(starts.size() == 1 and terminals.size() == 1,"one start and exactly one terminal for actual request")
	if starts.size() == 1 and terminals.size() == 1:
		var start: Dictionary = starts[0]
		var terminal: Dictionary = terminals[0]
		check(start.endpoint == "http://127.0.0.1:%d/v1/chat/completions" % port and terminal.endpoint == start.endpoint and start.transport_source == "explicit_loopback_test" and terminal.transport_source == start.transport_source,"explicit transport provenance retained in start/terminal; no headers")
		check(not start.has("headers") and not terminal.has("headers"),"transport credentials never persisted")
		check(start.messages == llm._redact(payload.messages) and start.model == payload.model,"persist actual system/user messages and model")
		check(start.max_tokens == Tactics.MAX_OUTPUT_TOKENS and start.timeout_seconds == (1.0 if timeout else Tactics.REQUEST_TIMEOUT_SECONDS),"log actual single-output capacity and timeout; preserve one-second timeout fixture")
		check(start.session_id == terminal.session_id and start.decision_id == terminal.decision_id and start.round_generation == terminal.round_generation,"request / decision / round linkage")
		check(terminal.duration_ms >= 0 and terminal.completed_wall_unix_ms > 0 and start.started_wall_unix_ms > 0,"nonnegative monotonic latency and wall timestamps")
		check(terminal.execution_latency_ms == null and terminal.execution_coverage.contains("not instrumented"),"execution timing explicitly unknown, not HTTP duration")
		if restart:
			check(terminal.outcome == "cancel" and terminal.http_request_result == null,"cancel observed despite disconnected callback")
		elif timeout:
			check(terminal.outcome == "timeout" and terminal.duration_ms >= int(llm.request_timeout_seconds*1000)-200 and terminal.response_duration_ms == null,"actual timeout duration and no invented complete response")
		else:
			check(terminal.http_request_result != null,"actual HTTPRequest result persisted")
			if body.size() <= Tactics.MAX_BODY:
				check(terminal.http_status == code and terminal.response_duration_ms == terminal.duration_ms,"HTTP status and full-response duration")
				var json := JSON.new()
				var response: Variant = json.data if json.parse(body.get_string_from_utf8()) == OK else null
				if response is Dictionary:
					check(terminal.usage == llm._redact(response.get("usage")),"usage raw values preserved")
					check(terminal.relay_error == llm._redact(response.get("error")),"relay error code/type retained without transport credentials")
					if response.get("choices") is Array and not response.choices.is_empty():
						check(terminal.response_content == str(llm._redact(response.choices[0].message.content)).left(Tactics.MAX_LOG_CONTENT_CHARS),"actual model content persisted, precise key redacted")
						check(terminal.finish_reason == response.choices[0].get("finish_reason"),"actual finish_reason retained, absence remains unknown")
						var parsed: Dictionary = Tactics.parse_plan(response.choices[0].message.content) if response.choices[0].get("finish_reason") in [null,"stop"] else {"ok":false}
						check(terminal.parsed_plan == llm._redact(parsed.get("plan")) and terminal.parsed_reason == llm._redact(parsed.get("reason")),"parsed plan/reason preserved on success or rejection")
			if code != 200:
				check(terminal.outcome == "error","HTTP error terminal outcome")
		llm._completed(HTTPRequest.RESULT_SUCCESS,200,[],body,int(start.decision_id),int(start.round_generation))
		llm._finish("error")
		if not synthetic_key.is_empty():
			check(llm._redact(start) == start and llm._redact(terminal) == terminal,"all persisted values including envelope, messages and parsed reason redact exact synthetic key")
			check(start.messages[1].content.contains("ordinary game content") and start.messages[1].content.contains("Authorization"),"no name-pattern deletion of ordinary game content")
		check(log_events().size() == events.size(),"late callback and repeated termination cannot duplicate terminal")

func lifecycle_checks() -> void:
	fixture()
	var before: int = lab.llm.requests
	for i in range(40):
		step()
	check(lab.llm.requests == before and lab.llm.status.contains("缺少") and lab.hunt.ticks == 40,"missing key: no network, game continues")
	lab.llm.set_mode(false)
	check(lab.monster.ai_enabled,"mode does not disable game AI")
	for mode in ["restart","toggle","hurt","dead","stale_id","timeout","unsafe_commit","round_end"]:
		fixture()
		var llm = lab.llm
		llm.pending = true
		lab.monster.llm_pending = true
		llm._started = Time.get_ticks_msec()
		var id: int = llm.decision_id
		var generation: int = lab.hunt.round_generation
		if mode == "restart":
			lab.reset_hunt()
		elif mode == "toggle":
			llm.set_mode(false)
		elif mode == "hurt":
			lab.monster.take_damage(1,0)
		elif mode == "dead":
			lab.controller.state.hp = 0
		elif mode == "unsafe_commit":
			lab.monster.state.mode = "charge"
		elif mode == "round_end":
			lab.hunt.round_state = "victory"
		llm._completed(HTTPRequest.RESULT_TIMEOUT if mode == "timeout" else HTTPRequest.RESULT_SUCCESS,200,[],envelope(JSON.stringify(plan)),id-1 if mode == "stale_id" else id,generation)
		if mode == "unsafe_commit":
			check(lab.monster.state.mode == "charge","late plan does not cancel current committed move")
		check(lab.monster.llm_plan.is_empty(),"late response rejected: "+mode)
		llm.cancel("test cleanup")
	check(log_events().filter(func(event): return event.event in ["request_start","request_terminal"]).is_empty(),"producer-only lifecycle callbacks never invent request or terminal evidence")

func combo_checks() -> void:
	check(lab.monster.llm_plan.size() == 2,"combo consumes actual HTTP accepted plan, not a second injector")
	var begun: Array[String] = []
	var finished: Array[String] = []
	var captured: Dictionary = {}
	var prepare: int = 0
	var fixed: Dictionary = {}
	for i in range(500):
		if lab.monster.state.mode == "prepare":
			prepare += 1
		var cooling: bool = lab.monster.state.cooldown_ticks > 0
		var report := step()
		for event in report.events:
			if event.event == "move_commit":
				check(prepare >= 18 and event.target == lab.monster.state.observed_target and event.decision_source == "llm","full preparation commits current target in accepted plan")
				prepare = 0
				check(not cooling,"no attack during movable cooldown")
			if event.event == "sandbox_special_begin":
				begun.append(event.special)
				fixed = lab.monster.sandbox_special.volume()
			if event.event == "move_finished":
				finished.append(event.move)
				check(lab.llm._facts[-1].move == event.move and lab.llm._facts[-1].contact == "hit","history derives matching contact at move_finished boundary")
		if lab.monster.sandbox_special.kind != "":
			check(lab.monster.sandbox_special.volume() == fixed,"committed special geometry fixed through windup/active/recovery")
			var key: String = "plan_"+lab.monster.sandbox_special.kind+"_"+lab.monster.sandbox_special.stage
			if key not in captured:
				captured[key] = true
				await capture(key)
		if finished.size() == 2:
			break
	check(begun == ["laser","stink"] and finished == begun and lab.monster.llm_plan.is_empty(),"entire accepted combo completes once in model order")
	check(lab.controller.state.hp == 68 and lab.hunt.monster_hits == 2,"combo damage dedup per move")
	var executions: Array[Dictionary] = log_events().filter(func(event): return event.event == "move_commit" and event.decision_source == "llm")
	check(executions.size() >= 2 and executions[-1].decision_id == lab.monster.state.committed_decision_id,"execution commit binds accepted response, not current request counter")
	for label in ["damage","death","mode"]:
		fixture()
		lab.monster.accept_llm_plan(plan.plan)
		if label == "damage":
			lab.monster.take_damage(1,0)
		elif label == "death":
			lab.controller.state.hp = 0
			step()
		else:
			lab.llm.set_mode(false)
		check(lab.monster.llm_plan.is_empty(),"combo cancelled: "+label)
	fixture()
	lab.monster.accept_llm_plan(plan.plan)
	lab.monster._llm_age = 360
	step()
	check(lab.monster.llm_plan.is_empty(),"bounded plan TTL")

func log_fault_checks() -> void:
	fixture()
	var llm = lab.llm
	var file: FileAccess = llm._log
	var bytes: int = llm._log_bytes
	llm._next_request = 0
	var path: String = llm.log_path
	llm._log = null
	llm.log_path = Tactics.LOG_DIR
	llm._open_log()
	check(llm._log == null and llm.log_status.contains("失败"),"actual FileAccess writer open failure on directory")
	llm.log_path = path
	llm.start_request({},"http://127.0.0.1:%d/v1/chat/completions" % port,[])
	check(llm.pending and llm.log_status.contains("失败"),"unavailable writer warns but does not block HTTP/AI")
	llm.cancel("mock unavailable writer")
	step()
	check(lab.monster.ai_enabled and lab.hunt.ticks == 1 and llm._request.is_empty(),"write failure does not stop game or retain terminal ownership")
	await capture("log_write_failure")
	llm._log = file
	llm._log_bytes = Tactics.MAX_LOG_BYTES-1
	llm._write_log({"event":"cap probe"})
	check(llm._log == null and llm.log_status.contains("本地log容量") and llm.log_status.contains("非token限制"),"bounded local storage explicitly independent of tokens")
	llm._next_request = 0
	llm.start_request({},"http://127.0.0.1:%d/v1/chat/completions" % port,[])
	check(llm.pending and lab.monster.llm_pending,"log capacity cannot stop AI/HTTP")
	llm.cancel("log capacity mock cleanup")
	llm._log = FileAccess.open(llm.log_path,FileAccess.READ_WRITE)
	llm._log.seek_end()
	llm._log_bytes = bytes
	llm.log_status = "会话JSONL · 本地记录（mock故障测试已恢复）"

func capture(name: String) -> void:
	if not capture_mode:
		return
	lab.update_visuals()
	lab.llm_status.text = "LOOPBACK MOCK / 非真实relay · "+lab.llm_status.text
	await process_frame
	RenderingServer.force_draw(false)
	var image := root.get_texture().get_image()
	check(not image.is_empty() and image.save_png(preload("res://tests/result_output.gd").path("user://"+name+".png")) == OK,"GPU capture "+name)

func live_relay() -> void:
	var requested: int = 1
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--live-requests="):
			requested = int(arg.trim_prefix("--live-requests="))
	if requested not in [1,2,3]:
		push_error("live diagnostic requires 1, 2 or 3 explicitly bounded requests")
		quit(2)
		return
	var key: String = OS.read_string_from_stdin().strip_edges()
	if key.is_empty():
		print("live_relay: stdin 无key；未发请求")
		quit(2)
		return
	lab = load("res://main.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	fixture()
	lab.controller.state.hp = 100000
	var llm = lab.llm
	llm.set_memory_key(key)
	key = ""
	var responses: Array[Dictionary] = []
	for index in range(requested):
		# Exactly one advance per iteration. Next iteration requires a completed accepted plan.
		while Time.get_ticks_msec() < llm._next_request:
			await process_frame
		llm.advance(lab.hunt,true)
		var request_id: int = llm.requests
		var deadline: int = Time.get_ticks_msec()+int(llm.request_timeout_seconds*1000)+2000
		var next_tick: int = Time.get_ticks_msec()
		while llm.pending and Time.get_ticks_msec() < deadline:
			if Time.get_ticks_msec() >= next_tick:
				lab.hunt.tick({"held":0,"mag":0,"direction":0,"bits":0})
				llm.record(lab.hunt)
				next_tick = Time.get_ticks_msec()+33
			await process_frame
		if llm.pending:
			llm.cancel("live验收等待上限","timeout")
		var terminal: Dictionary = {}
		for event in log_events():
			if event.event == "request_terminal" and int(event.get("request_id",-1)) == request_id:
				terminal = event
		var accepted: bool = terminal.get("outcome","") == "accepted"
		var committed: Array[String] = []
		var finished: Array[String] = []
		var accepted_tick: int = lab.hunt.ticks
		var commit_ticks: Array[int] = []
		if accepted:
			for tick in range(1000):
				var report: Dictionary = lab.hunt.tick({"held":0,"mag":0,"direction":0,"bits":0})
				llm.record(lab.hunt)
				for event in report.events:
					if event.get("decision_id") != llm.accepted_decision_id or event.get("decision_source") != "llm":
						continue
					if event.event == "move_commit":
						committed.append(event.move)
						commit_ticks.append(lab.hunt.ticks-accepted_tick)
					if event.event == "move_finished":
						finished.append(event.move)
				if finished.size() == terminal.parsed_plan.size() and lab.monster.can_accept_plan() and lab.monster.state.cooldown_ticks == 0:
					break
		var expected: Array = terminal.get("parsed_plan",[]).map(func(item): return item.move) if terminal.get("parsed_plan") is Array else []
		var executed: bool = accepted and committed == expected and finished == expected and not expected.is_empty()
		var safe_usage: Dictionary = {}
		if terminal.get("usage") is Dictionary:
			for field in ["prompt_tokens","completion_tokens","total_tokens"]:
				if terminal.usage.get(field) is float or terminal.usage.get(field) is int:
					safe_usage[field] = terminal.usage[field]
		responses.append({"request_id":request_id,"decision_id":terminal.get("decision_id"),"transport_source":terminal.get("transport_source"),"outcome":terminal.get("outcome"),"http_code":terminal.get("http_status"),"duration_ms":terminal.get("duration_ms"),"finish_reason":terminal.get("finish_reason"),"failure_code":terminal.get("failure_code"),"usage":safe_usage if not safe_usage.is_empty() else null,"plan_accepted":accepted,"moves_committed":committed,"moves_executed":finished,"accepted_to_commit_ticks":commit_ticks,"executed":executed})
		if not executed:
			break
	var successful: bool = responses.size() == requested and responses.all(func(item): return item.executed) and llm.requests == requested
	var result: Dictionary = {"status":"live_relay completed" if successful else "live_relay incomplete; no further requests","requested":requested,"requests":llm.requests,"responses":responses,"actual_tokens":llm.usage if llm.usage_known else null,"unknown_usage_requests":llm.unknown_usage_requests,"log_path":ProjectSettings.globalize_path(llm.log_path),"timeout_seconds":llm.request_timeout_seconds,"fixture":"stationary hunter hp100000 for bounded diagnostic; no plan injection; accelerated post-response simulation; production cooldown/telegraph unchanged"}
	var summary: String = JSON.stringify(llm._redact(result))
	var file := FileAccess.open(preload("res://tests/result_output.gd").path("user://llm_live_relay_results.json"),FileAccess.WRITE)
	if file != null:
		file.store_string(summary)
		file.close()
	print(summary)
	llm.set_memory_key("")
	quit(0 if successful and failures.is_empty() and file != null else 1)

func run() -> void:
	if "--live-relay" in OS.get_cmdline_user_args():
		await live_relay()
		return
	lab = load("res://main.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.panel.visible = false
	lab.distance = 11
	lab.elevation = 0.55
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots/llm/logging"))
	fixture()
	var logs_button: Button = lab.llm_status.get_parent().get_parent().get_children()[-1]
	check(logs_button.tooltip_text.contains(ProjectSettings.globalize_path(lab.llm.log_path)) and logs_button.pressed.is_connected(lab.llm.open_logs),"UI exposes exact session file path and opens owned log directory")
	if capture_mode:
		logs_button.pressed.emit()
		check(not lab.llm.log_status.contains("打开日志目录失败"),"actual UI shell-open log directory succeeds")
	parser_checks()
	lifecycle_checks()
	for candidate in range(19380,19390):
		if server.listen(candidate,"127.0.0.1") == OK:
			port = candidate
			break
	check(port != 0,"loopback listener")
	if port != 0:
		await mock(envelope(JSON.stringify(plan)))
		check(lab.monster.llm_plan.size() == 2 and lab.llm.usage_known and lab.llm.usage == 300,"real HTTP path parses plan / mock usage")
		lab.update_visuals()
		check(lab.llm.reason.is_empty() and log_events()[-1].parsed_reason == "" and not JSON.parse_string(log_events()[-1].response_content).has("reason"),"UI safely renders empty internal reason; actual network JSON never includes reason")
		await capture("mock_selected")
		await combo_checks()
		await mock(envelope(JSON.stringify(plan)),false,200,false,"",true)
		check(lab.monster.state.mode == "reacquire" and not lab.monster.llm_plan.is_empty(),"HTTP plan reacquires, no stale preparation")
		step()
		check(lab.monster.state.observed_target == lab.controller.state.position and lab.monster.state.committed_target == null,"post-response next tick observes moved current player before damage")
		await mock(envelope("```json\n"+JSON.stringify(plan)+"\n```"))
		check(lab.monster.llm_plan.is_empty() and log_events()[-1].failure_code == "invalid_json","actual HTTP fenced JSON rejected, never stripped")
		await mock(JSON.stringify({"choices":[{"message":{"content":JSON.stringify(plan)},"finish_reason":"length"}]}).to_utf8_buffer())
		check(lab.monster.llm_plan.is_empty() and log_events()[-1].failure_code == "incomplete_completion","finish_reason length cannot execute even syntactically complete JSON")
		var reasoning_response: Dictionary = {"choices":[{"message":{"content":"","reasoning_content":"r".repeat(Tactics.MAX_BODY/2)},"finish_reason":"length"}],"usage":{"prompt_tokens":1623,"completion_tokens":Tactics.MAX_OUTPUT_TOKENS,"total_tokens":1623+Tactics.MAX_OUTPUT_TOKENS}}
		await mock(JSON.stringify(reasoning_response).to_utf8_buffer(),false,200,false,"MOCK-only-reasoning")
		var length_terminal: Dictionary = log_events()[-1]
		check(lab.monster.llm_plan.is_empty() and length_terminal.failure_code == "incomplete_completion" and length_terminal.response_envelope == JSON.parse_string(JSON.stringify(reasoning_response)),"expanded reasoning envelope retained; empty length completion never executes")
		check(lab.llm.status.contains("reasoning与正文共享单次%d token输出上限" % Tactics.MAX_OUTPUT_TOKENS) and length_terminal.detail == lab.llm.status and length_terminal.detail.contains("非累计token耗尽") and lab.llm.mode_brief(lab.hunt,true).contains("finish_reason=length"),"UI and terminal log explain shared reasoning/output length capacity, not cumulative budget")
		reasoning_response.choices[0].message.content = JSON.stringify(plan)
		reasoning_response.choices[0].finish_reason = "stop"
		await mock(JSON.stringify(reasoning_response).to_utf8_buffer(),false,200,false,"MOCK-only-reasoning")
		check(not lab.monster.llm_plan.is_empty() and log_events()[-1].response_envelope == JSON.parse_string(JSON.stringify(reasoning_response)),"expanded reasoning envelope with completed bounded JSON plan accepted")
		await mock(envelope("x".repeat(3000)))
		check(log_events()[-1].response_content_truncated and log_events()[-1].response_content.length() == Tactics.MAX_LOG_CONTENT_CHARS and log_events()[-1].failure_code == "content_limit","bounded raw content and meaningful content-limit failure")
		await mock(envelope("not json"))
		check(lab.monster.llm_plan.is_empty() and lab.llm.status.contains("非法"),"HTTP bad JSON fallback")
		await mock("x".repeat(Tactics.MAX_BODY+1).to_utf8_buffer())
		check(lab.monster.llm_plan.is_empty() and log_events()[-1].failure_code == "response_body_limit","HTTP response size cap")
		await mock(JSON.stringify({"error":{"code":"unsupported_parameter","type":"invalid_request_error","param":"response_format","message":"unsupported parameter"}}).to_utf8_buffer(),false,400)
		check(log_events()[-1].failure_code == "http_status_failure" and log_events()[-1].relay_error.code == "unsupported_parameter","invalid params diagnosed, never retry")
		await mock([],false,401)
		check(lab.llm.status.contains("HTTP失败"),"HTTP auth error fallback without body disclosure")
		await mock([],true)
		check(lab.llm.status.contains("HTTP失败") or lab.llm.status.contains("timeout"),"actual HTTP timeout")
		await mock(envelope(JSON.stringify(plan)),false,200,true)
		var synthetic_key: String = "MOCK-ONLY-echo-\"\\-value"
		var echo_plan: Dictionary = plan.duplicate(true)
		echo_plan.reason = "echo "+synthetic_key
		await mock(JSON.stringify({"choices":[{"message":{"content":JSON.stringify(echo_plan)}}],"usage":{"total_tokens":"unknown",synthetic_key:synthetic_key},"game_key":"ordinary game content"}).to_utf8_buffer(),false,200,false,synthetic_key)
		check(lab.monster.llm_plan.is_empty(),"exact key echo in reason rejected for gameplay as well as redacted on disk")
		await mock(JSON.stringify({"choices":[{"message":{"content":JSON.stringify(plan)}}]}).to_utf8_buffer())
		var terminal: Dictionary = log_events()[-1]
		check(terminal.outcome == "accepted" and terminal.accepted_wall_unix_ms != null and terminal.usage == null and not terminal.usage_known,"accepted identity timestamp and unknown usage retained")
		await log_fault_checks()
		var count: int = lab.llm.requests
		lab.llm.start_request({},"http://127.0.0.1:%d/v1/chat/completions" % port,[])
		check(not lab.llm.pending and lab.llm.requests == count,"minimum interval still rejects immediate reentry without stopping AI")
		server.stop()
	fixture()
	lab.llm_mode.set_pressed_no_signal(true)
	step()
	await capture("missing_key")
	var output: String = preload("res://tests/result_output.gd").path("user://llm_tactics_results.json")
	var results := FileAccess.open(output,FileAccess.WRITE)
	check(results != null,"mock results writable in selected directory")
	if results != null:
		results.store_string(JSON.stringify({"checks":checks,"failures":failures,"transport":"explicit_loopback_test","real_relay_verified":false},"\t"))
		results.close()
	print("MOCK session log: ",ProjectSettings.globalize_path(lab.llm.log_path))
	print("LLM TACTICS: ",checks," checks / ",failures.size()," failed; MOCK ONLY; actual relay/model unverified; adapter=",RenderingServer.get_video_adapter_name())
	quit(0 if failures.is_empty() else 1)
