extends SceneTree

const Animator = preload("res://scripts/hunter_animator.gd")
const View = preload("res://scripts/bulldrome_view.gd")
var checks: int = 0
var failures: int = 0
var max_vertex_error: float = 0.0
var max_pose_error: float = 0.0
var max_curve_error: float = 0.0

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		if failures <= 20:
			push_error("ASSERT FAIL: " + label)

func matrix(value: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(value[0][0], value[1][0], value[2][0]), Vector3(value[0][1], value[1][1], value[2][1]), Vector3(value[0][2], value[1][2], value[2][2])), Vector3(value[0][3], value[1][3], value[2][3]))

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var started: int = Time.get_ticks_usec()
	var animator = Animator.new()
	check(animator.load_data("res://assets/bulldrome_data.json"), "standalone original bulldrome data loads")
	if animator.data.is_empty():
		quit(1)
		return
	check(animator.tracks.size() == 1 and animator.tracks[0].clip == "1001:0", "single actual track, initial idle1")
	check(animator.pose[1].origin == Vector3.ZERO, "initial standing root cleared")
	check(animator.data.bones.size() == 19 and animator.data.clips.size() == 31, "all 19 bones / 31 original clips")
	check(animator.data.root_bone == 1 and animator.data.clip_id_stride == 200, "verified root and source stride")
	var selections: int = 0
	for selection in animator.data.animation_selection_records:
		if selection.supported:
			check(animator.data.clips.has(selection.clip_key), "verified behavior selection points to actual resource clip")
			selections += 1
		else:
			check(selection.clip_key == null, "empty behavior selection remains unsupported")
	check(selections == 31 and animator.data.animation_selection_records.size() == 74, "74 source selections retain 31 nonempty resources without invented action names")
	var view = View.new()
	root.add_child(view)
	check(view.configure(animator), "real PNG and original skin configure")
	check(view._mesh.get_surface_count() == 9, "79 groups merged into nine material surfaces")
	check(view._materials[0].albedo_texture.get_width() == 128, "original 128px TMH texture")
	var min_y: float = INF
	for surface in view.vertices:
		for point in surface:
			min_y = minf(min_y, point.y)
	check(absf(min_y + view.lift) < 0.00001, "idle1 foot lift is display-only")
	var data_before: Dictionary = animator.data.duplicate(true)
	var golden: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/bulldrome_goldens.json"))
	var curve_samples: int = 0
	for curve in golden.curves:
		var keys: Array = animator.data.clips[curve.key].nodes[int(curve.node)].channels[int(curve.channel)].keys
		for sample in curve.samples:
			var error: float = absf(Animator._curve(keys, sample[0]) - float(sample[1]))
			max_curve_error = maxf(max_curve_error, error)
			check(error < 0.00000001, "all original keys and interval midpoints against Python")
			curve_samples += 1
	var vertex_samples: int = 0
	var distinct: Dictionary = {}
	for sample in golden.samples:
		distinct[sample.key] = true
		check(animator.set_animation(int(sample.key.get_slice(":", 0)), 0, 0), "bind original runtime ID")
		animator.tracks[0].currentframe = animator._f32(sample.time)
		var result: Dictionary = animator.tick(0)
		check(result.frames.size() == 1 and result.active.size() == 1 and result.events.size() == 1, "one-track outputs")
		check(result.root_delta == Vector3.ZERO and result.pose[1].origin == Vector3.ZERO, "frozen root emitted/cleared once")
		for i in range(19):
			var actual: Transform3D = animator.world_pose[i]
			var expected: Transform3D = matrix(sample.world_pose[i])
			var error: float = maxf(actual.origin.distance_to(expected.origin), maxf(actual.basis.x.distance_to(expected.basis.x), maxf(actual.basis.y.distance_to(expected.basis.y), actual.basis.z.distance_to(expected.basis.z))))
			max_pose_error = maxf(max_pose_error, error)
			check(actual.origin.is_finite() and actual.basis.is_finite() and error < 0.002, "93 original parent-first poses vs Python")
		var root_value: Vector3 = animator._root(sample.key, sample.time)
		check(root_value.distance_to(View._vector(sample.root_float)) < 0.001, "floating root differs from integer pose only as source dictates")
		var before_tracks: Array = animator.tracks.duplicate(true)
		view.update_pose(animator)
		check(animator.tracks == before_tracks, "view never advances animator")
		for s in range(view.vertices.size()):
			for i in range(view.vertices[s].size()):
				var point: Vector3 = view.vertices[s][i]
				var expected: Vector3 = View._vector(sample.vertices[s][i]) * 0.01
				var error: float = point.distance_to(expected)
				max_vertex_error = maxf(max_vertex_error, error)
				check(point.is_finite() and error < 0.00003, "all 1578 vertices in 93 original mesh poses")
				vertex_samples += 1
			var arrays: Array = view._mesh.surface_get_arrays(s)
			for normal in arrays[Mesh.ARRAY_NORMAL]:
				check(normal.is_finite(), "recomputed skin normals finite")
	check(distinct.size() == 31 and golden.samples.size() == 93 and vertex_samples == 146754, "all original clips/mesh poses coverage")
	check(animator.data == data_before, "view/pose sampling never modifies source assets")
	animator.set_animation(1003, 0, 0)
	var moved: Dictionary = animator.tick(2)
	check(moved.root_delta.distance_to(animator._root("1003:0", 2) - animator._root("1003:0", 0)) < 0.00001, "single floating delta output")
	view.position = moved.root_delta * 0.01
	view.rotation.y = 0.37
	var before_position: Vector3 = view.position
	var before_rotation: Vector3 = view.rotation
	view.update_pose(animator)
	check(view.position == before_position and view.rotation == before_rotation, "view does not reapply entity translation/yaw")
	animator.set_animation(1001, 6, 0)
	var snapshot: Dictionary = animator.tracks[0].old_pose.duplicate(true)
	for i in range(4):
		check(animator.tick(0).frames.size() == 1, "single-track frozen blend")
	check(animator.tracks[0].blend_remaining == 0 and animator.tracks[0].old_pose == snapshot, "retain fixed old blend pose")
	animator.set_animation(1003, -6, 0)
	for i in range(4):
		check(animator.tick(2).root_delta == Vector3.ZERO, "single-track negative blend suppresses root")
	for key in animator.data.clips:
		var clip: Dictionary = animator.data.clips[key]
		animator.set_animation(int(key.get_slice(":", 0)), 0, int(clip.end))
		var result: Dictionary = animator.tick(7)
		check(result.frames[0] == (clip.loop_start if clip.loop else clip.end) and not result.active[0], "original loop clamp/no overshoot")
	animator.set_animation(1001, 0, 0)
	for i in range(90):
		animator.tick(0.2)
	check(animator.tracks[0].currentframe == 17.999996185302734, "single-track binary32 clock")
	check(not animator.ge(0, 1) and not animator.animation_ended(1), "nonexistent secondary is not a fake track")
	var before: Array = animator.tracks.duplicate(true)
	check(not animator.set_animation(1201, 6, 0) and animator.tracks == before, "empty actual group1 slot fails atomically")
	check(not animator.set_animation(1099, 0, 0) and animator.tracks == before, "unknown resource slot fails atomically")
	for field in ["track_count", "clip_id_stride", "root_bone", "initial_animation"]:
		var bad: Dictionary = animator.data.duplicate(true)
		bad[field] = null
		check(not animator._valid_data(bad), "unknown config fails closed " + field)
	var bad: Dictionary = animator.data.duplicate(true)
	bad.bones[2].group = 1
	check(not animator._valid_data(bad), "binding actual group mismatch fails closed")
	bad = animator.data.duplicate(true)
	bad.clips["1001:0"].bindings[1] = 2
	check(not animator._valid_data(bad), "missing root/duplicate binding fails closed")
	bad = animator.data.duplicate(true)
	bad.mesh.surfaces[0].vertices[0][0].bone = 999
	check(not View._valid_mesh(bad.mesh, 19), "unknown skin palette fails closed")
	bad = animator.data.duplicate(true)
	bad.mesh.surfaces[0].vertices[0][0].weight = 0.7
	check(not View._valid_mesh(bad.mesh, 19), "nonunit skin weight fails closed")
	check(animator.data.combat.schema_version == 1 and animator.data.combat.records.size() == 7 and animator.data.combat.shapes.size() == 3, "all original combat records and shapes")
	check(not animator.data.combat.records["0"].supported and animator.data.combat.records["0"].shape_selector == null, "empty record0 remains unsupported")
	for i in ["1", "2", "3", "4", "5", "6"]:
		var record: Dictionary = animator.data.combat.records[i]
		check(record.delay_byte == record.bytes_u8[0] and record.duration_byte == record.bytes_u8[1] and record.byte2_raw == record.bytes_u8[2] and not record.has("power"), "literal raw field semantics")
	check(animator.data.combat.shapes["0"][0].radius == 52 and animator.data.combat.shapes["1"][0].radius == 70 and animator.data.combat.shapes["2"][0].kind == 1 and animator.data.combat.shapes["2"][0].radius == 60, "real bone2 sphere/capsule geometry")
	if "--capture" in OS.get_cmdline_user_args():
		animator.set_animation(1001, 0, 0)
		animator.tick(0)
		view.position = Vector3.ZERO
		view.rotation = Vector3.ZERO
		view.update_pose(animator)
		await _capture_preview()
	var report: Dictionary = {"schema_version": 1, "checks": checks, "failures": failures, "clips": distinct.size(), "mesh_poses": golden.samples.size(), "vertex_samples": vertex_samples, "curve_samples": curve_samples, "max_vertex_error_display_units": max_vertex_error, "max_pose_error_source_units": max_pose_error, "max_curve_error": max_curve_error, "elapsed_seconds": float(Time.get_ticks_usec() - started) / 1000000.0, "engine": Engine.get_version_info(), "preview_path": "res://tests/bulldrome_preview.png" if "--capture" in OS.get_cmdline_user_args() else "", "limits": ["Original CPU geometry/PNG import verified; optional native idle preview only, no GE/VFPU/PSP runtime equivalence.", "CPU time/process-family peak memory and token baseline not measured in this harness."]}
	var output := FileAccess.open("res://tests/bulldrome_test_results.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t") + "\n")
	print("BULLDROME TESTS " + JSON.stringify(report))
	view.free()
	quit(0 if failures == 0 else 1)

func _capture_preview() -> void:
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(2.4, 1.65, 3.0)
	camera.look_at(Vector3(0, 0.65, 0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 3.8
	camera.current = true
	var light := DirectionalLight3D.new()
	root.add_child(light)
	light.rotation_degrees = Vector3(-45, -30, 0)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.12, 0.14, 0.17)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.5
	root.add_child(environment)
	await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	check(image.save_png("res://tests/bulldrome_preview.png") == OK, "native rendered original-texture idle screenshot")
	camera.free()
	light.free()
	environment.free()
