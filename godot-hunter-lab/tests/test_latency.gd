extends SceneTree

var lab: Node3D

func _initialize() -> void:
	call_deferred("run")

func key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func run() -> void:
	lab = load("res://main.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.monster.ai_enabled = false
	lab.simulation_tick()
	key(KEY_J,true)
	key(KEY_J,false)
	key(KEY_K,true)
	key(KEY_K,false)
	key(KEY_W,true)
	var magnitudes: Array = []
	for i in range(5):
		lab.simulation_tick()
		magnitudes.append(lab.controller._magnitude)
	key(KEY_W,false)
	key(KEY_J,true)
	key(KEY_J,false)
	key(KEY_K,true)
	key(KEY_K,false)
	key(KEY_W,true)
	lab.simulation_tick()
	key(KEY_W,false)
	lab.simulation_tick()
	var release_magnitude: int = lab.controller._magnitude
	var release_bits: int = lab.controller._directional_bits
	lab.reset_hunt()
	lab.monster.ai_enabled = false
	lab.simulation_tick()
	for i in range(30):
		lab.simulation_tick()
		lab.update_visuals()
	var simulation_us: Array = []
	var render_us: Array = []
	var skin_us: Array = []
	for i in range(180):
		var begin: int = Time.get_ticks_usec()
		lab.simulation_tick()
		simulation_us.append(Time.get_ticks_usec()-begin)
		begin = Time.get_ticks_usec()
		lab.update_visuals()
		render_us.append(Time.get_ticks_usec()-begin)
		begin = Time.get_ticks_usec()
		lab.boar_view.update_pose(lab.monster_animator)
		skin_us.append(Time.get_ticks_usec()-begin)
	print("LATENCY ",JSON.stringify({"engine":Engine.get_version_info().string,"hz":lab.hz,"motion_magnitudes_after_edges":magnitudes,"release_magnitude":release_magnitude,"release_bits":release_bits,"warm_samples":180,"simulation_us":summary(simulation_us),"render_submission_us":summary(render_us),"skin_us":summary(skin_us),"gpu":RenderingServer.get_video_adapter_name()}))
	if "--verify" in OS.get_cmdline_user_args() and (magnitudes[0] != 127 or release_magnitude != 0 or release_bits != 0):
		push_error("ASSERT FAIL: movement must use current analog sample despite button queue")
		quit(1)
	else:
		quit()

func summary(values: Array) -> Dictionary:
	values.sort()
	var total: int = 0
	for value in values:
		total += value
	return {"mean":float(total)/values.size(),"p95":values[int(values.size()*0.95)],"max":values[-1]}
