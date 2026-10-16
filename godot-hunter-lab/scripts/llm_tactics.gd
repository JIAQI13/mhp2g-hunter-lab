class_name LlmTactics
extends Node

const ENDPOINT = "https://super-relay.byted.org/v1/chat/completions"
const MODEL = "model_api/experimental_0630"
const LOCAL_KEY_PATH = "user://llm_api_key.txt"
const MAX_LOCAL_KEY_BYTES = 512
var config_source: String = "none"
var config_status: String = "本地key未加载"
const TACTICS = ["observe","approach","circle_left","circle_right"]
const MAX_BODY = 65536
# Longest compact two-step JSON is 104 ASCII bytes; allow 152 whitespace bytes.
const MAX_CONTENT = 256
const INTERVAL_MS = 5000
const REQUEST_TIMEOUT_SECONDS = 30.0
const MAX_OUTPUT_TOKENS = 4096
const MAX_LOG_CONTENT_CHARS = 2048
var request_timeout_seconds: float = REQUEST_TIMEOUT_SECONDS
const PROMPT = "Decide directly from observed facts; do not explain or expand analysis. Output only JSON: {\"plan\":[{\"move\":\"charge\",\"tactic\":\"approach\"}]}. Root: plan only, 1-2 steps in order; step: move/tactic only. Move enum: charge, turn_attack, laser, stink, tusk, slam; choose currently legal moves. Tactic enum: observe, approach, circle_left, circle_right (short reposition, close distance, left/right arc). No other fields, reason, prose, markdown, code, coordinates, timing or HP changes. One slam at most, only if ready; avoid consecutive ranged spam. Unknown is not miss. Local executor handles pursuit, telegraphs and fixed committed geometry; damage remains fair. All ranges/distances are meters; hp is fraction of maximum."
var enabled: bool = false
var pending: bool = false
var status: String = "规则模式 · 不联网"
var reason: String = ""
var choice: String = "规则"
var usage: int = 0
var usage_known: bool = false
var requests: int = 0
var latency_ms: int = 0
var decision_id: int = 0
var accepted_decision_id: int = -1
var accepted_transport_source: String = ""
var session_id: String = ""
const LOG_DIR = "user://llm_logs"
const MAX_LOG_BYTES = 4*1024*1024
var log_path: String = ""
var log_status: String = ""
var _log: FileAccess
var _log_bytes: int = 0
var _request: Dictionary = {}
var _request_key: String = ""
var _key: String = ""
var _http := HTTPRequest.new()
var _callback: Callable
var _hunt: HuntSession
var _generation: int = -1
var _hp: int = -1
var _started: int = 0
var _next_request: int = 0
var unknown_usage_requests: int = 0
var _retry_after_fallback: bool = false
var _facts: Array[Dictionary] = []
var _last_position := Vector3.ZERO
var _last_tick: int = -1
var _last_attack: String = ""
var _last_hit: bool = false
var _last_attack_id: int = -1
var _last_attack_special: String = ""
var _last_interrupted: bool = false

func _ready() -> void:
	session_id = "mhp-"+Crypto.new().generate_random_bytes(16).hex_encode()
	log_path = LOG_DIR+"/"+session_id+".jsonl"
	_open_log()
	_http.set_tls_options(TLSOptions.client())
	_http.timeout = request_timeout_seconds
	_http.body_size_limit = MAX_BODY
	_http.accept_gzip = false
	_http.max_redirects = 0
	add_child(_http)
	if is_test_entry():
		config_status = "测试入口 · 不读取默认本地key；不自动开启LLM"
	else:
		load_local_key(LOCAL_KEY_PATH)

static func is_test_entry() -> bool:
	for arg in OS.get_cmdline_args():
		if arg in ["--script","-s","--check-only","--editor","-e","--import"] or arg.begins_with("--script="):
			return true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--test-frames="):
			return true
	return false

func has_key() -> bool:
	return not _key.is_empty()

func load_local_key(path: String) -> bool:
	cancel("本地key加载")
	_key = ""
	config_source = "none"
	var file := FileAccess.open(path,FileAccess.READ)
	if file == null:
		var error: int = FileAccess.get_open_error()
		config_status = "本地key文件不存在 · 可手动输入（仅内存）" if error == ERR_FILE_NOT_FOUND else "本地key读取失败 (%d) · 未加载" % error
		return false
	var length: int = file.get_length()
	if length > MAX_LOCAL_KEY_BYTES:
		file.close()
		config_status = "本地key超过512B · 未加载"
		return false
	var bytes: PackedByteArray = file.get_buffer(length)
	var error: int = file.get_error()
	file.close()
	if bytes.size() != length or bytes.size() > MAX_LOCAL_KEY_BYTES or error not in [OK,ERR_FILE_EOF]:
		config_status = "本地key读取失败 · 未加载"
		return false
	var value: String = bytes.get_string_from_utf8().strip_edges()
	if value.is_empty():
		config_status = "本地key为空 · 未加载"
		return false
	if value.contains("\n") or value.contains("\r"):
		config_status = "本地key须为一行 · 未加载"
		return false
	_key = value
	config_source = "local_file"
	config_status = "本地key已加载"
	status = "本地key仅内存 · 请求未验证"
	return true

func set_mode(value: bool) -> void:
	if enabled == value:
		return
	cancel("模式切换")
	enabled = value
	status = "fallback · 缺少内存key；规则AI继续" if enabled and _key.is_empty() else ("LLM沙盒 · 等待请求，未验证模型接管" if enabled else "规则模式 · 不联网")
	_write_log({"event":"mode_enabled" if enabled else "mode_disabled","session_id":session_id,"wall_unix_ms":Time.get_unix_time_from_system()*1000.0,"enabled":enabled})

func mode_brief(hunt: HuntSession, active: bool) -> String:
	var m = hunt.monster
	var committed: bool = m.sandbox_special.stage != "landing" and m.state.mode in ["charge","turn_attack","special","special_commit"] and m.state.committed_source == "llm" and m.state.committed_decision_id == accepted_decision_id and accepted_decision_id >= 0
	var selected: bool = m.decision_source == "llm" and m._plan_decision_id == accepted_decision_id and accepted_decision_id >= 0
	var execution: String = ""
	if active and (committed or selected):
		if accepted_transport_source == "explicit_loopback_test":
			execution = "MOCK计划执行中 · 非真实模型" if committed else "MOCK计划已采纳 · 非真实模型"
		elif accepted_transport_source == "production_relay":
			execution = "模型计划执行中 · decision_source llm" if committed else "模型计划已采纳 · decision_source llm"
	if not enabled:
		return "规则AI · 不发LLM请求"+("\n已承诺招式继续："+execution if not execution.is_empty() else "")
	if not active:
		return "训练模式 · 不请求/不接管"
	if hunt.round_state != "running" or not m.state.alive or hunt.player.state.hp <= 0:
		return "终局 · 本地安全收尾 · 不请求/不接管"
	if m.sandbox_special.stage == "landing":
		return "取消后连续安全降落 · 本地收尾 · 未接管"
	if not execution.is_empty():
		return execution
	if pending:
		return "MOCK请求等待中 · 非真实模型 · 未接管" if _request.get("transport_source","") == "explicit_loopback_test" else "请求等待中 · 本地无伤追踪 · HTTP上限%.1f秒 · 未接管" % request_timeout_seconds
	if not has_key():
		return "缺少key · fallback规则AI · 未接管"
	if status.contains("已接受"):
		return "本地规则AI · 已采纳计划不在执行 · 未接管"
	return status+" · 未接管"

func set_memory_key(value: String) -> void:
	cancel("密钥变更")
	_key = value.strip_edges()
	config_source = "memory" if has_key() else "none"
	config_status = "手动key仅内存" if has_key() else "内存key已移除"
	status = "fallback · 缺少key；规则AI继续" if _key.is_empty() else "key仅内存 · 未验证；切换LLM后才请求"

func cancel(label: String, outcome: String = "cancel") -> void:
	_finish(outcome,{"detail":label})
	_http.cancel_request()
	if _callback.is_valid() and _http.request_completed.is_connected(_callback):
		_http.request_completed.disconnect(_callback)
	pending = false
	if _hunt != null:
		_hunt.monster.llm_pending = false
	decision_id += 1
	if _hunt != null:
		_hunt.monster.cancel_llm_plan()
	status = "fallback · "+label if enabled else "规则模式 · 不联网"
	choice = "规则"
	reason = ""

func _exit_tree() -> void:
	cancel("退出")
	_key = ""
	if _log != null:
		_log.close()
		_log = null

func _redact(value: Variant) -> Variant:
	if value is String:
		var text: String = value
		for secret in [_key,_request_key]:
			if not secret.is_empty():
				text = text.replace(secret,"[REDACTED]")
				var encoded: String = JSON.stringify(secret)
				text = text.replace(encoded.substr(1,encoded.length()-2),"[REDACTED]")
		return text
	if value is Dictionary:
		var clean: Dictionary = {}
		for field in value:
			clean[_redact(field)] = _redact(value[field])
		return clean
	if value is Array:
		var clean: Array = []
		for item in value:
			clean.append(_redact(item))
		return clean
	return value

func _open_log() -> void:
	var error: int = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOG_DIR))
	if error == OK:
		_log = FileAccess.open(log_path,FileAccess.WRITE)
		if _log == null:
			error = FileAccess.get_open_error()
	log_status = "会话JSONL · 本地记录" if _log != null else "日志写入失败 (%d) · AI继续；本运行无法持久记录" % error

func _write_log(event: Dictionary) -> void:
	if _log == null:
		if not log_status.contains("失败") and not log_status.contains("上限"):
			log_status = "日志写入失败/停止 · AI继续；本运行记录不完整"
		return
	var line: String = JSON.stringify(_redact(event))+"\n"
	var size: int = line.to_utf8_buffer().size()
	if _log_bytes+size > MAX_LOG_BYTES:
		log_status = "本地log容量4MiB上限 · 非token限制；AI继续，后续记录未保存"
		_log.close()
		_log = null
		return
	_log.store_string(line)
	_log.flush()
	if _log.get_error() != OK:
		log_status = "日志写入失败 (%d) · AI继续；记录不完整" % _log.get_error()
		_log.close()
		_log = null
		return
	_log_bytes += size

func _finish(outcome: String, facts: Dictionary = {}) -> void:
	if _request.is_empty():
		return
	var event: Dictionary = _request.duplicate(true)
	event.merge(facts,true)
	event.event = "request_terminal"
	event.outcome = outcome
	if not event.has("failure_code"):
		event.failure_code = null if outcome == "accepted" else "request_"+outcome
	if not event.has("finish_reason"):
		event.finish_reason = null
	event.completed_wall_unix_ms = event.get("completed_wall_unix_ms",Time.get_unix_time_from_system()*1000.0)
	event.duration_ms = event.get("duration_ms",maxi(0,Time.get_ticks_msec()-_started))
	if not event.has("detail"):
		event.detail = status
	latency_ms = event.duration_ms
	var reported: Variant = event.get("usage")
	var tokens: Variant = reported.get("total_tokens") if reported is Dictionary else null
	var known: bool = (tokens is int or tokens is float) and is_finite(float(tokens)) and tokens >= 0 and float(tokens) < 9223372036854775808.0 and float(tokens) == floorf(float(tokens))
	if known:
		usage += int(tokens)
		usage_known = true
	elif not event.has("request_start_error"):
		unknown_usage_requests += 1
	event.usage_known = known
	event.accounting = "reported_total_tokens" if known else ("not_started" if event.has("request_start_error") else "unknown_usage")
	event.lifetime_actual_tokens = usage
	event.lifetime_unknown_usage_requests = unknown_usage_requests
	_write_log(event)
	_request.clear()
	_request_key = ""

func open_logs() -> void:
	var error: int = OS.shell_open(ProjectSettings.globalize_path(LOG_DIR))
	if error != OK:
		log_status = "打开日志目录失败 (%d)" % error

func bind_round(hunt: HuntSession) -> void:
	cancel("重开")
	_hunt = hunt
	_generation = hunt.round_generation
	_retry_after_fallback = false
	_facts.clear()
	_last_tick = -1
	_last_attack = ""
	_last_interrupted = false
	_hp = int(hunt.monster.state.hp)

func advance(hunt: HuntSession, active: bool) -> void:
	if _generation != hunt.round_generation:
		bind_round(hunt)
	_hunt = hunt
	var m: Dictionary = hunt.monster.state
	if int(m.hp) < _hp or not active or hunt.round_state != "running" or not m.alive or int(hunt.player.state.hp) <= 0 or m.mode in ["hit","down","dying","dead"]:
		cancel("受击/终局/非狩猎")
	_hp = int(m.hp)
	if not enabled or not active or hunt.round_state != "running" or not m.alive or int(hunt.player.state.hp) <= 0 or m.mode in ["hit","down","dying","dead"]:
		return
	if pending or _retry_after_fallback:
		return
	if not hunt.monster.llm_plan.is_empty() or (hunt.monster.llm_selection != "规则" and m.mode in ["special","charge","turn_attack","prepare","special_commit"]):
		return
	if _key.is_empty():
		status = "fallback · 缺少内存key；规则AI继续"
		choice = "规则"
		reason = ""
		return
	if not hunt.monster.can_accept_plan() or int(m.cooldown_ticks) > 0 or Time.get_ticks_msec() < _next_request:
		return
	var observation := observe(hunt)
	start_request(observation, ENDPOINT, ["Content-Type: application/json","Authorization: Bearer "+_key,"x-session-id: "+session_id])

func start_request(observation: Dictionary, endpoint: String, headers: PackedStringArray) -> void:
	# Only the production relay or explicitly invoked unauthenticated loopback tests.
	if endpoint == ENDPOINT:
		if _key.is_empty() or not enabled:
			return
	else:
		var loopback := RegEx.new()
		loopback.compile("^http://127\\.0\\.0\\.1:[0-9]{1,5}/v1/chat/completions$")
		if loopback.search(endpoint) == null:
			return
		headers = PackedStringArray(["Content-Type: application/json"])
	if pending or not enabled or Time.get_ticks_msec() < _next_request:
		return
	var observation_text: String = JSON.stringify(observation)
	var payload := {"model":MODEL,"messages":[{"role":"system","content":PROMPT},{"role":"user","content":observation_text}],"max_tokens":MAX_OUTPUT_TOKENS}
	_http.timeout = request_timeout_seconds
	decision_id += 1
	_started = Time.get_ticks_msec()
	_next_request = _started+INTERVAL_MS
	requests += 1
	_request_key = _key
	_request = {"endpoint":endpoint,"transport_source":"production_relay" if endpoint == ENDPOINT else "explicit_loopback_test","session_id":session_id,"request_id":requests,"decision_id":decision_id,"round_generation":_generation,"started_wall_unix_ms":Time.get_unix_time_from_system()*1000.0,"http_status":null,"http_response_code_raw":null,"http_request_result":null,"response_content":null,"parsed_plan":null,"parsed_reason":null,"usage":null,"usage_known":false,"response_duration_ms":null,"accepted_wall_unix_ms":null,"execution_latency_ms":null,"execution_coverage":"not instrumented; no step execution timing inferred","timing":"nonstreaming; duration is request start to response completion or local termination; TTFT and inference time unknown"}
	var start_event: Dictionary = _request.duplicate(true)
	start_event.event = "request_start"
	start_event.model = payload.model
	start_event.messages = payload.messages
	start_event.max_tokens = MAX_OUTPUT_TOKENS
	start_event.timeout_seconds = request_timeout_seconds
	_write_log(start_event)
	_hunt.monster.cancel_llm_plan()
	pending = true
	_hunt.monster.llm_pending = true
	status = "pending · 本地无伤追踪，HTTP最多%.1f秒后规则fallback" % request_timeout_seconds
	_callback = _completed.bind(decision_id, _generation)
	_http.request_completed.connect(_callback, CONNECT_ONE_SHOT)
	var error: int = _http.request(endpoint,headers,HTTPClient.METHOD_POST,JSON.stringify(payload))
	if error != OK:
		_finish("error",{"detail":"request start failed","request_start_error":error})
		cancel("请求启动失败")
		_retry_after_fallback = true

func _completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, id: int = -1, generation: int = -1) -> void:
	if not pending or id != decision_id or generation != _generation:
		return
	var completed_ms: float = Time.get_unix_time_from_system()*1000.0
	var duration: int = maxi(0,Time.get_ticks_msec()-_started)
	latency_ms = duration
	var response: Variant = null
	var json := JSON.new()
	if body.size() <= MAX_BODY and json.parse(body.get_string_from_utf8()) == OK:
		response = json.data
	var content: Variant = null
	var parsed: Dictionary = {"ok":false,"failure_code":"invalid_envelope"}
	var finish_reason: Variant = null
	if response is Dictionary:
		var choices: Variant = response.get("choices")
		if choices is Array and choices.size() == 1 and choices[0] is Dictionary and choices[0].get("message") is Dictionary and choices[0].message.get("content") is String:
			content = choices[0].message.content
			finish_reason = choices[0].get("finish_reason")
			parsed = parse_plan(content)
			if finish_reason != null and finish_reason != "stop":
				parsed = {"ok":false,"failure_code":"incomplete_completion","finish_reason":finish_reason}
	if not _request.is_empty():
		_request.http_status = code if code > 0 else null
		_request.http_response_code_raw = code
		_request.http_request_result = result
		_request.completed_wall_unix_ms = completed_ms
		_request.duration_ms = duration
		_request.response_duration_ms = duration if result == HTTPRequest.RESULT_SUCCESS else null
		_request.response_envelope = response
		_request.invalid_response_text = body.get_string_from_utf8() if response == null and body.size() <= MAX_BODY else null
		_request.response_bytes = body.size()
		if response is Dictionary:
			_request.usage = response.get("usage")
			_request.usage_known = response.has("usage") and response.usage != null
		_request.response_content = str(_redact(content)).left(MAX_LOG_CONTENT_CHARS) if content is String else null
		_request.response_content_truncated = content is String and content.length() > MAX_LOG_CONTENT_CHARS
		_request.finish_reason = finish_reason
		_request.relay_error = response.get("error") if response is Dictionary else null
		_request.parsed_plan = parsed.get("plan")
		_request.parsed_reason = parsed.get("reason")
	var outcome: Dictionary = _apply_response(result,code,body,generation,response,content,parsed)
	_retry_after_fallback = outcome.outcome != "accepted"
	if _retry_after_fallback:
		status += " · 先完成规则fallback招式再请求"
	_finish(outcome.outcome,{"failure_code":outcome.failure_code})

func _apply_response(result: int, code: int, body: PackedByteArray, generation: int, envelope: Variant, content: Variant, parsed: Dictionary) -> Dictionary:
	var applicable: bool = _hunt.monster.llm_pending and _hunt.monster.can_accept_plan()
	pending = false
	_hunt.monster.llm_pending = false
	choice = "规则"
	reason = ""
	if result == HTTPRequest.RESULT_TIMEOUT:
		status = "fallback · HTTP timeout（%.1f秒）" % request_timeout_seconds
		return {"outcome":"timeout","failure_code":"http_timeout"}
	if not applicable or _hunt.round_generation != generation or _hunt.round_state != "running" or not _hunt.monster.state.alive or int(_hunt.monster.state.hp) != _hp or int(_hunt.player.state.hp) <= 0:
		status = "fallback · 过期状态"
		return {"outcome":"cancel","failure_code":"stale_world_or_unsafe_boundary"}
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or body.size() > MAX_BODY:
		var failure: String = "response_body_limit" if body.size() > MAX_BODY or result == HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED else ("http_transport_failure" if result != HTTPRequest.RESULT_SUCCESS else "http_status_failure")
		status = "fallback · HTTP失败（不显示响应原文）"
		return {"outcome":"error","failure_code":failure}
	if not envelope is Dictionary or content == null:
		status = "fallback · 响应JSON/结构无效"
		return {"outcome":"error","failure_code":"invalid_envelope"}
	if not parsed.get("ok",false):
		if parsed.get("failure_code") == "incomplete_completion":
			status = "fallback · 单次输出未完成（非累计token耗尽）"
			if parsed.get("finish_reason") == "length":
				status += " · finish_reason=length：reasoning与正文共享单次%d token输出上限，可能在JSON计划前耗尽" % MAX_OUTPUT_TOKENS
		else:
			status = "fallback · 非法JSON/计划"
		return {"outcome":"error","failure_code":parsed.get("failure_code","invalid_plan_shape")}
	if not _hunt.monster.accept_llm_plan(parsed.plan,decision_id):
		status = "fallback · 执行器拒绝当前不可用计划"
		return {"outcome":"cancel","failure_code":"executor_unavailable_plan"}
	accepted_decision_id = decision_id
	accepted_transport_source = _request.get("transport_source","")
	if not _request.is_empty():
		_request.accepted_wall_unix_ms = Time.get_unix_time_from_system()*1000.0
	reason = parsed.reason
	var selections: PackedStringArray = []
	for step in parsed.plan:
		selections.append(step.tactic+"/"+step.move)
	choice = " → ".join(selections)
	status = "loopback mock选择已接受 · 未验证真实模型" if _request.get("transport_source","") == "explicit_loopback_test" else "LLM选择已接受 · 本地有限执行"
	return {"outcome":"accepted","failure_code":null}

static func parse_plan(text: String) -> Dictionary:
	if text.to_utf8_buffer().size() > MAX_CONTENT:
		return {"ok":false,"failure_code":"content_limit"}
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"ok":false,"failure_code":"invalid_json"}
	var value: Variant = json.data
	if not value is Dictionary or value.size() != 1 or not value.get("plan") is Array:
		return {"ok":false,"failure_code":"invalid_plan_shape"}
	if value.plan.size() < 1 or value.plan.size() > 2:
		return {"ok":false,"failure_code":"invalid_step_count"}
	for step in value.plan:
		if not step is Dictionary or step.size() != 2 or not step.get("move") is String or not step.get("tactic") is String or not BulldromeController.MOVE_MENU.has(step.move) or not TACTICS.has(step.tactic):
			return {"ok":false,"failure_code":"invalid_step_allowlist"}
	return {"ok":true,"plan":value.plan,"reason":""}

func observe(hunt: HuntSession) -> Dictionary:
	var p: Dictionary = hunt.player.state
	var m: Dictionary = hunt.monster.state
	var delta: Vector3 = p.position-m.position
	var relative: int = ((HuntSession._yaw(m.position,p.position)-int(m.yaw)+32768)&65535)-32768
	var trend: String = "unknown"
	if _last_tick >= 0 and hunt.ticks > _last_tick:
		var motion: Vector3 = p.position-_last_position
		trend = "stationary" if motion.length() < 10 else ("closing" if motion.dot(delta) < 0 else "retreating_or_lateral")
	_last_position = p.position
	_last_tick = hunt.ticks
	var menu: Dictionary = hunt.monster.decision_moves()
	for move in menu:
		var fact: Dictionary = menu[move]
		fact.range_m = snappedf(float(fact.range)*0.01,0.01)
		fact.erase("range")
		if fact.has("min_range"):
			fact.min_range_m = snappedf(float(fact.min_range)*0.01,0.01)
			fact.erase("min_range")
	var recent: Array = []
	for fact in _facts.slice(maxi(0,_facts.size()-3)):
		recent.append({"move":fact.move,"contact":fact.contact})
	if recent.is_empty():
		recent.append({"move":"unknown","contact":"unknown"})
	var wall: float = HuntSession.ARENA_HALF-HuntSession.MONSTER_RADIUS-maxf(absf(m.position.x),absf(m.position.z))
	return {"distance_m":snappedf(delta.length()*0.01,0.01),"bearing_deg":snappedf(relative*360.0/65536,15),"hunter":{"action":hunt.player.observable_action(),"trend":trend},"relative_hp":{"hunter":snappedf(float(p.hp)/p.hp_max,0.01),"boar":snappedf(float(m.hp)/m.hp_max,0.01)},"wall_clearance_m":snappedf(wall*0.01,0.01),"recent":recent,"slam_ready":hunt.monster.slam_available(),"legal_moves":menu,"range_semantics":"acquisition limits, not guaranteed hits; source hit reach unknown"}

func record(hunt: HuntSession) -> void:
	if enabled and (not hunt.monster.state.alive or hunt.player.state.hp <= 0 or hunt.monster.state.hp < _hp):
		cancel("受击/终局")
	for event in hunt.events:
		if event.event == "move_finished" and event.get("decision_source") == "fallback":
			_retry_after_fallback = false
		if event.event in ["move_commit","slam_lock","move_release","move_finished","move_cancelled"]:
			var execution: Dictionary = event.duplicate(true)
			execution.session_id = session_id
			execution.round_generation = hunt.round_generation
			execution.decision_id = event.get("decision_id")
			execution.binding = "accepted response" if execution.decision_id != null else "local selection; no model request inferred"
			_write_log(execution)
		if event.event == "decision_selected":
			_facts.append({"move":event.move,"contact":"unknown","source":event.decision_source})
			if _facts.size() > 3:
				_facts.pop_front()
			_write_log({"event":"decision_selected","session_id":session_id,"decision_id":event.get("decision_id"),"tick":hunt.ticks,"round_generation":hunt.round_generation,"move":event.move,"tactic":event.tactic,"decision_source":event.decision_source,"inference":"not established by executor; see request transport_source (loopback is mock)"})
		if event.get("actor","") == "bulldrome" and event.event in ["attack_spawn","sandbox_special_begin"]:
			_last_attack = str(event.get("special",hunt.monster.state.mode))
			_last_hit = false
			_last_attack_id = int(event.attack_id)
			_last_attack_special = str(event.get("special",""))
			_last_interrupted = false
		if event.event in ["monster_reaction","move_cancelled","round_end","incoming_not_ready"]:
			_last_interrupted = true
		if event.event == "incoming_contact" and event.status in ["pending","guarded"] and int(event.get("attack_id",-2)) == _last_attack_id and str(event.get("special","")) == _last_attack_special:
			_last_hit = true
	if _last_attack != "" and hunt.events.any(func(event): return event.event == "move_finished"):
		var fact: Dictionary = {"move":_last_attack,"contact":"hit" if _last_hit else ("unknown" if _last_interrupted else "miss"),"coverage":"interrupted/unknown eligibility" if _last_interrupted else "session observed complete move"}
		if not _facts.is_empty() and _facts[-1].move == _last_attack:
			_facts[-1].merge(fact,true)
		else:
			_facts.append(fact)
		if _facts.size() > 3:
			_facts.pop_front()
		_last_attack = ""
