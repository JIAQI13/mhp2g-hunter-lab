extends SceneTree

const Tactics = preload("res://scripts/llm_tactics.gd")
const Output = preload("res://tests/result_output.gd")
class StartupProbe:
	extends "res://scripts/llm_tactics.gd"
	var load_attempted: bool = false
	func load_local_key(_path: String) -> bool:
		load_attempted = true
		return false

var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error("ASSERT FAIL: "+label)

func write_fixture(path: String, value: String) -> void:
	var file := FileAccess.open(path,FileAccess.WRITE)
	check(file != null,"fixture writable")
	if file != null:
		file.store_string(value)
		file.close()

func run() -> void:
	var probe := StartupProbe.new()
	root.add_child(probe)
	check(Tactics.is_test_entry() and not probe.load_attempted,"script startup bypasses loader entirely; default secret never opened")
	check(not probe.has_key() and not probe.enabled and probe.config_status.contains("测试入口"),"test startup unconfigured and offline")
	probe.free()
	var lab = load("res://main.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	check(not lab.llm.has_key() and not lab.llm_mode.button_pressed and not lab.llm.enabled and lab.llm.requests == 0,"main script startup does not auto-enable or request")
	var directory: String = "user://local_key_fixture_"+str(OS.get_process_id())+"_"+str(Time.get_ticks_usec())
	check(DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory)) == OK,"dedicated user fixture directory")
	var path: String = directory.path_join("fixture.txt")
	var key: String = "FIXTURE-ONLY-not-a-credential"
	write_fixture(path,"  "+key+"\r\n")
	check(lab.llm.load_local_key(path) and lab.llm.has_key() and lab.llm.config_source == "local_file","one-line stripped fixture loaded into memory")
	check(lab.llm._redact(key) == "[REDACTED]","loaded key registered at log redaction boundary")
	lab.configure_llm_from_local()
	lab.update_visuals()
	check(lab.llm.enabled and lab.llm_mode.button_pressed and lab.llm.requests == 0 and not lab.llm.pending,"auto configuration does not itself request")
	check(lab.llm_status.text.contains("本地key已加载 / LLM自动开启，仅指定relay外传游戏摘要") and lab.llm_status.text.contains("未验证") and not lab.llm_status.text.contains(key),"UI distinguishes configuration from verified model without secret")
	lab.llm._write_log({"event":"fixture_redaction","value":key})
	var log_file := FileAccess.open(lab.llm.log_path,FileAccess.READ)
	check(log_file != null and not log_file.get_as_text().contains(key),"loaded key never appears in persisted session log")
	if log_file != null:
		log_file.close()
	lab.llm_mode.button_pressed = false
	lab.update_visuals()
	check(not lab.llm.enabled and lab.llm_status.text.contains("LLM已关闭"),"UI toggle can disable automatic mode")
	lab.llm.set_memory_key("MANUAL-FIXTURE-ONLY")
	var file := FileAccess.open(path,FileAccess.READ)
	check(file != null and file.get_as_text() == "  "+key+"\r\n" and lab.llm.config_source == "memory","manual input stays in memory; never rewrites local txt")
	if file != null:
		file.close()
	check(not lab.llm.load_local_key(directory.path_join("missing.txt")) and not lab.llm.has_key() and lab.llm.config_status.contains("不存在"),"missing file accurately reported")
	write_fixture(path," \r\n\t")
	check(not lab.llm.load_local_key(path) and not lab.llm.has_key() and lab.llm.config_status.contains("为空"),"empty file not configured")
	write_fixture(path,"x".repeat(513))
	check(not lab.llm.load_local_key(path) and not lab.llm.has_key() and lab.llm.config_status.contains("超过512B"),"oversized file rejected before content read")
	write_fixture(path,"first\nsecond")
	check(not lab.llm.load_local_key(path) and lab.llm.config_status.contains("一行"),"multiple lines rejected")
	write_fixture(path,key)
	check(FileAccess.set_unix_permissions(path,0) == OK,"fixture permissions removed")
	check(not lab.llm.load_local_key(path) and not lab.llm.has_key() and lab.llm.config_status.contains("读取失败"),"actual unreadable file fails without success status")
	check(FileAccess.set_unix_permissions(path,384) == OK,"fixture permissions restored to 0600 for cleanup")
	check(DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK and DirAccess.remove_absolute(ProjectSettings.globalize_path(directory)) == OK,"only owned fixture removed")
	check(lab.llm.requests == 0,"fixture tests never invoke production network")
	var output: String = Output.path("user://local_llm_key_results.json")
	var result := FileAccess.open(output,FileAccess.WRITE)
	check(result != null,"results writable in selected directory")
	if result != null:
		result.store_string(JSON.stringify({"checks":checks,"failures":failures,"real_key_read":false,"real_network_verified":false},"\t"))
		result.close()
	print("LOCAL LLM KEY: ",checks," checks / ",failures.size()," failed; fixtures only; results=",output)
	lab.free()
	quit(0 if failures.is_empty() else 1)
