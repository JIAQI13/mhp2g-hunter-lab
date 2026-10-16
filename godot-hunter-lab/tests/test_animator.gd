extends SceneTree

const Animator = preload("res://scripts/hunter_animator.gd")
const RESTORED_PRIMARY = [201,202,204,207,210,216,1211]
var checks: int = 0
var failures: int = 0

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("ASSERT FAIL: " + label)

func close_scalar(actual: float, expected: float, label: String, tolerance: float = 0.00003) -> void:
	check(absf(actual - expected) <= tolerance, label + " actual=" + str(actual))

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var started: int = Time.get_ticks_usec()
	create_timer(20.0).timeout.connect(func():
		push_error("ASSERT FAIL: test did not reach explicit quit")
		quit(1))
	var animator = Animator.new()
	check(animator.load_data(), "standalone JSON loads without Python/source reports")
	if animator.data.is_empty():
		quit(1)
		return
	check(animator.pose.size() == 21 and animator.world_pose.size() == 21, "21 parent-first bones")
	check(animator.data.clips.size() == 132, "118 golden clips plus exactly14 restored recovery clips")
	check(animator.data.absent_clips.size() == 2, "two absent clips retain explicit metadata")
	close_scalar(animator.data.clips["403:0"].loop_start, 62.0, "403 parsed loop binary32=62")
	check(animator.data.gs_variants.size() == 28, "28 executable GS variants")
	var seen: Dictionary = {}
	var references: int = 0
	for variant in animator.data.gs_variants:
		seen[int(variant.sub)] = true
		for phase in variant.phases:
			for key in phase.clips:
				check(animator.data.clips.has(key), "GS phase reference " + key)
				references += 1
	for sub in range(30):
		check(seen.has(sub) == (sub != 13 and sub != 23), "GS coverage/no-op " + str(sub))
	check(animator.data.normal_actions.size() == 36, "normal state metadata complete")
	check(animator.data.weapon_attach.bone == 10 and animator.data.weapon_attach.Euler_unit == "radians", "attachment units/bone")
	check(animator.set_animation(1, 0, 0), "bind initial pair")
	var before: Array = animator.tracks.duplicate(true)
	check(not animator.set_animation(1010, 0, 0) and animator.tracks == before, "absent pair leaves both tracks unchanged")
	check(not animator.set_animation(9999, 6, 0) and animator.tracks == before, "unknown pair atomic")
	check(not animator.load_data("res://assets/not_present.json") and animator.tracks == before, "failed load retains current data/tracks")
	check(animator.tick(-1).is_empty() and animator.tracks == before, "negative step atomic")
	check(animator.tick(INF).is_empty() and animator.tracks == before, "infinite step atomic")
	check(animator.tick(NAN).is_empty() and animator.tracks == before, "NaN step atomic")
	var malformed: Dictionary = animator.data.duplicate(true)
	malformed.clips["1:0"].nodes[0].channels = [{"component": 9, "keys": [[0, 0, 0, 0]]}]
	check(not animator._valid_data(malformed), "unknown boundary component rejected")
	malformed = animator.data.duplicate(true)
	malformed.bones[1].defaults[0] = null
	check(not animator._valid_data(malformed), "unknown bind not zero-filled")
	var sampled_clips: int = 0
	var samples: int = 0
	var pairs: int = 0
	for key in animator.data.clips:
		var primary: int = int(key.get_slice(":",0)) - (100 if key.ends_with(":1") else 0)
		if primary in RESTORED_PRIMARY:
			continue
		var clip: Dictionary = animator.data.clips[key]
		for time in [0.0, float(clip.end) / 2.0, float(clip.end)]:
			for floating in [false, true]:
				var sampled: Dictionary = animator._sample(clip, time, floating)
				check(sampled.size() == clip.bindings.size(), "binding coverage " + key)
				for bone in sampled:
					var node: Dictionary = sampled[bone]
					check(node.origin.is_finite() and node.scale.is_finite() and node.rotation.is_finite(), "finite sample " + key)
				samples += 1
		sampled_clips += 1
		if key.ends_with(":0"):
			check(animator.set_animation(int(key.get_slice(":", 0)), 0, 0), "real pair bind " + key)
			var result: Dictionary = animator.tick(2.0)
			check(result.frames[0] == 2.0 and result.pose.size() == 21, "sample then raw step " + key)
			check(result.pose[1].origin == Vector3.ZERO, "root T cleared " + key)
			for i in range(21):
				var parent: int = int(animator.data.bones[i].parent)
				var expected: Transform3D = result.world_pose[parent] * result.pose[i] if parent >= 0 else result.pose[i]
				check(result.world_pose[i].is_equal_approx(expected), "parent * local " + key)
			pairs += 1
	close_scalar(Animator._curve([[0.0, 0.0, 0.0, 1.0], [0.0, 10.0, 0.0, 0.0]], 5.0), 1.25, "Hermite outgoing tangent multiplied by dt")
	close_scalar(Animator._curve([[0.0, 0.0, 0.0, 0.0], [0.0, 10.0, 1.0, 0.0]], 5.0), -1.25, "Hermite incoming tangent multiplied by dt")
	close_scalar(Animator._curve([[7.0, 0.0, 0.0, 0.0]], 100.0), 7.0, "single key endpoint clamp")
	var old_node: Dictionary = Animator._make_node([1, 2, 3, 0, 0, 0, 10, 20, 30])
	var new_node: Dictionary = Animator._make_node([3, 4, 5, 0, 0, PI / 2, 20, 30, 40])
	var mixed: Dictionary = Animator._blend_pose({0: old_node}, {0: new_node}, 0.5)[0]
	check(mixed.scale == Vector3(2, 3, 4) and mixed.origin == Vector3(15, 25, 35), "blend scale and T separately from normalized basis")
	check(mixed.rotation.is_equal_approx(Basis(Vector3(0, 0, 1), PI / 4)), "basis normalized/cross reconstruction")
	var scaled: Transform3D = Transform3D(new_node.rotation.scaled_local(new_node.scale), new_node.origin)
	close_scalar(scaled.basis.x.length(), 3.0, "local R*D(S) column X scale")
	close_scalar(scaled.basis.y.length(), 4.0, "local R*D(S) column Y scale")
	close_scalar(scaled.basis.z.length(), 5.0, "local R*D(S) column Z scale")
	var integer_sample: Dictionary = animator._sample(animator.data.clips["3:0"], 1.75)
	var float_sample: Dictionary = animator._sample(animator.data.clips["3:0"], 1.75, true)
	close_scalar(integer_sample[1].origin.z, 27.845385753299954, "source integer pose sample")
	close_scalar(float_sample[1].origin.z, 31.196945586310875, "source float root sample")
	var rotation_sample: Dictionary = animator._sample(animator.data.clips["1506:1"], 17.5)
	var expected_basis: Basis = Basis(Vector3(0, 0, 1), -0.18592415807587612) * Basis(Vector3(0, 1, 0), 0.06651511323677066) * Basis(Vector3(1, 0, 0), 0.25525156950202976)
	check(rotation_sample[10].rotation.is_equal_approx(expected_basis), "source normalized rotation RzRyRx, not default YXZ")
	animator.set_animation(3, 0, 0)
	close_scalar(animator.tick(2).root_delta.z, 8.885867091488393, "source negative-previous root wrapper")
	animator.set_animation(1406, 6, 0)
	check(animator.tracks[0].blend_remaining == 4 and animator.tracks[0].old_frame == 2, "s16 trunc blend/2 plus one and old snapshot")
	close_scalar(animator.tick(2).root_delta.z, 8.809047177166079, "source blend root uses fixed old_frame")
	var snapshot: Dictionary = animator.tracks[0].old_pose.duplicate(true)
	animator.tick(0)
	check(animator.tracks[0].old_pose == snapshot and animator.tracks[0].currentframe == 0.0, "old pose/frame does not advance while blending")
	animator.tick(0)
	animator.tick(0)
	check(animator.tracks[0].blend_remaining == 0 and animator.tracks[0].currentframe == 0, "frozen playback still consumes blend calls")
	animator.set_animation(3, -6, 0)
	for i in range(4):
		check(animator.tick(2).root_delta == Vector3.ZERO, "negative blend suppress root " + str(i))
	animator.set_animation(403, 0, 264)
	check(not animator.animation_ended(), "bind activates")
	check(animator.tick(0).active[0], "equal end active")
	var loop_result: Dictionary = animator.tick(7)
	check(loop_result.frames[0] == 62.0 and not loop_result.active[0] and animator.animation_ended(), "loop discards overshoot; inactive feedback")
	check(animator.tick(0).active[0] and not animator.animation_ended(), "loop inactive for one invocation")
	animator.set_animation(1406, 0, int(animator.data.clips["1406:0"].end))
	check(not animator.tick(2).active[0] and animator.animation_ended(), "nonloop end clamps/inactive")
	animator.set_animation(1, 0, 0)
	for i in range(90):
		animator.tick(0.2)
	close_scalar(animator.tracks[0].currentframe, 17.999996185302734, "90 slow steps binary32", 0.00000001)
	check(not animator.ge(18), "f32 threshold remains below 18 after 90 calls")
	animator.tick(0.2)
	check(animator.ge(18) and animator.crossed(18), "GE/crossed after next f32 tick")
	animator.tick(0)
	check(not animator.crossed(18), "frozen call creates no crossing edge")
	animator.set_animation(3, 6, 30)
	check(not animator.ge(10), "GE disabled during blend")
	animator.set_animation(1406, 6, 0)
	check(animator.tracks[0].old_clip == "1:0", "multiple setters before tick preserve first snapshot")
	animator.set_animation(65537, 0, 65537)
	check(animator.tracks[0].clip == "1:0" and animator.tracks[0].currentframe == 1, "source primary signed16/start unsigned16 narrowing")
	print("ANIMATOR TESTS checks=%d failures=%d clips=%d samples=%d pairs=%d GSvariants=%d GSrefs=%d" % [checks, failures, sampled_clips, samples, pairs, seen.size(), references])
	var legacy_checks: int = checks
	check(sampled_clips == 118 and samples == 708 and pairs == 59,"original118 golden subset exact coverage")
	_test_restored(animator)
	_test_data_selected_tracks()
	print("GENERAL ANIMATOR TESTS checks=%d failures=%d" % [checks, failures])
	var output := FileAccess.open(preload("res://tests/result_output.gd").path("res://tests/animator_test_results.json"), FileAccess.WRITE)
	output.store_string(JSON.stringify({"schema_version": 1, "checks": checks, "legacy_checks": legacy_checks, "failures": failures, "clips": sampled_clips, "samples": samples, "pairs": pairs, "total_clips":132, "restored_clips":14, "restored_samples":84, "restored_pairs":7, "elapsed_seconds": float(Time.get_ticks_usec() - started) / 1000000.0, "engine": Engine.get_version_info()}, "\t") + "\n")
	quit(0 if failures == 0 else 1)

func _test_restored(animator: HunterAnimator) -> void:
	var clips: int = 0
	var samples: int = 0
	for primary in RESTORED_PRIMARY:
		for group in [0,1]:
			var key: String = "%d:%d" % [primary+100*group,group]
			check(animator.data.clips.has(key),"restored exact identity "+key)
			if not animator.data.clips.has(key):
				continue
			clips += 1
			var clip: Dictionary = animator.data.clips[key]
			for time in [0.0,float(clip.end)/2,float(clip.end)]:
				for floating in [false,true]:
					var sampled: Dictionary = animator._sample(clip,time,floating)
					check(sampled.size() == clip.bindings.size(),"restored binding coverage "+key)
					for bone in sampled:
						var node: Dictionary = sampled[bone]
						check(node.origin.is_finite() and node.scale.is_finite() and node.rotation.is_finite(),"restored finite sample "+key)
					samples += 1
		check(animator.set_animation(primary,0,0),"restored actual paired bind "+str(primary))
		var result: Dictionary = animator.tick(2)
		check(result.frames == [2.0,2.0] and result.pose[1].origin == Vector3.ZERO,"restored root extracted once "+str(primary))
		for i in range(21):
			var parent: int = int(animator.data.bones[i].parent)
			var expected: Transform3D = result.world_pose[parent]*result.pose[i] if parent >= 0 else result.pose[i]
			check(result.world_pose[i].is_equal_approx(expected),"restored parent local "+str(primary))
	check(clips == 14 and samples == 84,"all14 restored recovery clips independently sampled")

func _test_data_selected_tracks() -> void:
	var base: Dictionary = {"schema_version": 1, "track_count": 1, "clip_id_stride": 200, "root_bone": 0,
		"bones": [{"parent": -1, "defaults": [1, 1, 1, 0, 0, 0, 0, 0, 0]},
			{"parent": 0, "defaults": [1, 1, 1, 0, 0, 0, 9, 0, 0]}],
		"clips": {"1001:0": {"end": 10, "loop": true, "loop_start": 2.5, "bindings": [0],
			"nodes": [{"channels": [{"component": 6, "keys": [[0, 0, 1, 1], [10, 10, 1, 1]]}]}]}}}
	var path: String = "user://animator_general_test.json"
	var output := FileAccess.open(path, FileAccess.WRITE)
	output.store_string(JSON.stringify(base))
	output.close()
	var animator = Animator.new()
	check(animator.load_data(path) and animator.tracks.size() == 1, "data selects one actual track")
	check(animator.set_animation(1001, 0, 0), "one track requires no fabricated secondary")
	var result: Dictionary = animator.tick(2)
	check(result.root_delta == Vector3(2, 0, 0) and result.pose[0].origin == Vector3.ZERO, "data-selected bone0 root extracted/cleared once")
	check(result.frames.size() == 1 and result.active.size() == 1 and result.events.size() == 1, "all output arrays follow actual tracks")
	check(result.pose[1].origin.x == 9, "unbound bone retains pose")
	animator.set_animation(1001, 0, 10)
	check(animator.tick(1).frames[0] == 2.5, "one track preserves fractional loop_start")
	base.track_count = 2
	base.clips["1201:1"] = {"end": 10, "loop": false, "loop_start": 0, "bindings": [1], "nodes": [{"channels": []}]}
	output = FileAccess.open(path, FileAccess.WRITE)
	output.store_string(JSON.stringify(base))
	output.close()
	check(animator.load_data(path) and animator.tracks.size() == 2 and animator.set_animation(1001, 0, 0), "two tracks with non-hunter stride200")
	check(animator.tracks[1].clip == "1201:1" and animator.tick(2).frames.size() == 2, "secondary follows declared stride/group")
	var bad: Dictionary = base.duplicate(true)
	bad.clips["1201:1"].bindings = [0]
	check(not animator._valid_data(bad), "cross-group root overwrite rejected")
	base.track_count = 1
	base.clips.erase("1201:1")
	base.root_bone = -1
	output = FileAccess.open(path, FileAccess.WRITE)
	output.store_string(JSON.stringify(base))
	output.close()
	check(animator.load_data(path) and animator.set_animation(1001, 0, 3), "explicit disabled root supported")
	result = animator.tick(2)
	check(result.root_delta == Vector3.ZERO and result.pose[0].origin.x == 3, "disabled root neither extracted nor cleared")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
