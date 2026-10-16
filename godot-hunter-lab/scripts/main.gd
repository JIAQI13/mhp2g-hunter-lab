extends Node3D

const Animator = preload("res://scripts/hunter_animator.gd")
const Controller = preload("res://scripts/hunter_controller.gd")
const HunterCombat = preload("res://scripts/hunter_combat.gd")
const MonsterController = preload("res://scripts/bulldrome_controller.gd")
const MonsterView = preload("res://scripts/bulldrome_view.gd")
const Session = preload("res://scripts/hunt_session.gd")
const Tactics = preload("res://scripts/llm_tactics.gd")
var llm = Tactics.new()
var llm_mode := CheckButton.new()
var llm_key := LineEdit.new()
var llm_status := Label.new()
var llm_banner := PanelContainer.new()
var llm_banner_title := Label.new()
var llm_banner_detail := Label.new()
var special_effect := Node3D.new()
var laser_warning: MeshInstance3D
var laser_beam: MeshInstance3D
var laser_core: MeshInstance3D
var stink_ring: MeshInstance3D
var stink_cloud: MeshInstance3D
var tusk_warning: MeshInstance3D
var tusk_charge: MeshInstance3D
var tusk_pool: Array[MeshInstance3D] = []
var tusk_trail: MeshInstance3D
var slam_warning: MeshInstance3D
var slam_impact: MeshInstance3D
var slam_spin: MeshInstance3D
var slam_shadow: MeshInstance3D
var monster_animator = Animator.new()
var monster = MonsterController.new()
var boar_view = MonsterView.new()
var hunt = Session.new()
var hunt_mode: bool = true
var hunt_snapshot: Dictionary = {}
var mode_button := Button.new()
var hunter_hp := ProgressBar.new()
var round_panel := PanelContainer.new()
var round_label := Label.new()
var monster_label := Label3D.new()
var player_flash: int = 0
var monster_flash: int = 0
var skin_updates: int = 0
var input_blocked_until_release: bool = false
var help := Label.new()
var combat_note := Label.new()
var combat: HunterCombat = HunterCombat.new()
var target_mesh: MeshInstance3D
var target_label := Label3D.new()
var target_reset_button := Button.new()
var damage_labels: Array[Dictionary] = []
var combat_events: Array[Dictionary] = []
var target_flash: int = 0
const DAMAGE_LABEL_TICKS = 36
const BUTTONS = {"triangle":0x1000,"circle":0x2000,"cross":0x4000,"square":0x8000,"shoulder":0x200,"kick":1}
var animator = Animator.new()
var controller = Controller.new()
var actor := Node3D.new()
var skeleton := Node3D.new()
var sword := Node3D.new()
var back_mount := Transform3D.IDENTITY
const SHEATHED_SWORD_SCALE = 0.55
var camera := Camera3D.new()
var joints: Array[MeshInstance3D] = []
var rods: Array[MeshInstance3D] = []
var actions: Array = []
var hud := Label.new()
var panel := PanelContainer.new()
var action_list := ItemList.new()
var speed := HSlider.new()
var play_button := Button.new()
var reset_button := Button.new()
var hz: float = 30.0
var accumulator: float = 0.0
var orbit: float = 1.15
var elevation: float = 0.28
var distance: float = 8.8
var lift: float = 0.0
var dragging: bool = false
var preview_ticks: int = -1
var preview_sub: int = 0
var preview_category: int = 0
var snapshots: Array[Dictionary] = []
var last_snapshot: Dictionary = {}
var test_frames: int = -1
var rendered: int = 0
var hotplug_count: int = 0
var danger_toggle := CheckButton.new()
var probe_toggle := CheckButton.new()
var window_skill := OptionButton.new()
var danger_marker := Node3D.new()
var probe_enabled: bool = false
var probe_stats := {"evaded":0,"hits":0,"misses":0,"geometry_checks":0}
var probe_result: Dictionary = {}
var body_spheres: Array[MeshInstance3D] = []
var attack_sphere: MeshInstance3D
const BODY_RADII = [0.30,0.20]
const ATTACK_RADIUS = 0.24

func _ready() -> void:
	configure_inputs()
	if not animator.load_data():
		push_error("hunter_data 无法加载")
		get_tree().quit(1)
		return
	if not animator.data.get("combat") is Dictionary or not combat.configure(animator.data.combat):
		push_error("hunter_combat 配置无法加载")
		get_tree().quit(1)
		return
	controller.configure(animator)
	controller.tick(0,0,0)
	lift = -minf(animator.world_pose[5].origin.y, animator.world_pose[8].origin.y) * 0.01 + 0.055
	build_world()
	build_hunter()
	if not monster_animator.load_data("res://assets/bulldrome_data.json") or not monster.configure(monster_animator):
		push_error("猪王原模型/动作配置失败，无法开始狩猎")
		get_tree().quit(1)
		return
	boar_view.name = "Bulldrome"
	add_child(boar_view)
	# 出生配置交给整局owner；重开时不在视图层补改实体位置。
	hunt.monster_spawn = Vector3(0,0,-250)
	if not boar_view.configure(monster_animator) or not hunt.configure(controller,monster,animator,monster_animator,lift,boar_view.lift):
		push_error("猪王材质/狩猎双Actor配置失败")
		get_tree().quit(1)
		return
	monster_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	monster_label.position.y = 2.6
	monster_label.font_size = 38
	monster_label.outline_size = 10
	boar_view.add_child(monster_label)
	for side in [-1,1]:
		box(self,Vector3(20,0.08,0.08),Vector3(0,0.04,side*Session.ARENA_HALF*0.01),Color("b8ba79"))
		box(self,Vector3(0.08,0.08,20),Vector3(side*Session.ARENA_HALF*0.01,0.04,0),Color("b8ba79"))
	monster.sandbox_specials_enabled = true
	build_special_effects()
	add_child(llm)
	build_ui()
	reset_hunt()
	configure_llm_from_local()
	Input.joy_connection_changed.connect(_joy_changed)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--test-frames="):
			test_frames = int(arg.split("=")[1])
	update_visuals()

func configure_llm_from_local() -> void:
	if llm.config_source == "local_file" and llm.has_key() and monster.sandbox_motion_enabled:
		set_llm_mode(true)

func set_llm_mode(value: bool) -> void:
	llm.set_mode(value and monster.sandbox_motion_enabled)
	llm_mode.set_pressed_no_signal(llm.enabled)
	llm_mode.disabled = not monster.sandbox_motion_enabled
	update_visuals()

func text_input_focused() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit

func configure_inputs() -> void:
	var keys = {"left":KEY_A,"right":KEY_D,"forward":KEY_W,"back":KEY_S,"triangle":KEY_J,"circle":KEY_K,"cross":KEY_SPACE,"square":KEY_U,"shoulder":KEY_SHIFT,"kick":KEY_F,"weapon":KEY_Q,"menu":KEY_ESCAPE,"previous":KEY_BRACKETLEFT,"next":KEY_BRACKETRIGHT,"play":KEY_ENTER,"danger":KEY_T,"probe":KEY_H,"target_reset":KEY_R,"mode":KEY_M,"llm":KEY_L}
	var buttons = {"triangle":JOY_BUTTON_Y,"circle":JOY_BUTTON_B,"cross":JOY_BUTTON_A,"square":JOY_BUTTON_X,"shoulder":JOY_BUTTON_RIGHT_SHOULDER,"kick":JOY_BUTTON_BACK,"menu":JOY_BUTTON_START,"previous":JOY_BUTTON_DPAD_LEFT,"next":JOY_BUTTON_DPAD_RIGHT,"danger":JOY_BUTTON_LEFT_SHOULDER,"target_reset":JOY_BUTTON_DPAD_UP,"mode":JOY_BUTTON_DPAD_DOWN}
	for action in keys:
		var name: String = "lab_" + action
		if not InputMap.has_action(name):
			InputMap.add_action(name,0.18)
		var event := InputEventKey.new()
		event.physical_keycode = keys[action]
		if not InputMap.action_has_event(name,event):
			InputMap.action_add_event(name,event)
	for action in buttons:
		var event := InputEventJoypadButton.new()
		event.button_index = buttons[action]
		if not InputMap.action_has_event("lab_"+action,event):
			InputMap.action_add_event("lab_"+action,event)
	var axes = {"left":[JOY_AXIS_LEFT_X,-1.0],"right":[JOY_AXIS_LEFT_X,1.0],"forward":[JOY_AXIS_LEFT_Y,-1.0],"back":[JOY_AXIS_LEFT_Y,1.0],"look_left":[JOY_AXIS_RIGHT_X,-1.0],"look_right":[JOY_AXIS_RIGHT_X,1.0],"look_up":[JOY_AXIS_RIGHT_Y,-1.0],"look_down":[JOY_AXIS_RIGHT_Y,1.0]}
	for action in axes:
		var name: String = "lab_"+action
		if not InputMap.has_action(name):
			InputMap.add_action(name,0.18)
		var event := InputEventJoypadMotion.new()
		event.axis = axes[action][0]
		event.axis_value = axes[action][1]
		if not InputMap.action_has_event(name,event):
			InputMap.action_add_event(name,event)

func material(color: Color, metal: float = 0.0) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.metallic = metal
	result.roughness = 0.55
	return result

func mesh_node(mesh: Mesh, parent: Node3D, color: Color, metal: float = 0.0) -> MeshInstance3D:
	var result := MeshInstance3D.new()
	result.mesh = mesh
	result.material_override = material(color,metal)
	parent.add_child(result)
	return result

func box(parent: Node3D, size: Vector3, at: Vector3, color: Color, metal: float = 0.0) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var result := mesh_node(mesh,parent,color,metal)
	result.position = at
	return result

func build_world() -> void:
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("152335")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("c8dfff")
	settings.ambient_light_energy = 0.7
	environment.environment = settings
	add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55,-35,0)
	light.light_energy = 1.5
	light.shadow_enabled = true
	add_child(light)
	var floor_body := StaticBody3D.new()
	floor_body.name = "Ground"
	add_child(floor_body)
	box(floor_body,Vector3(200,0.2,200),Vector3(0,-0.1,0),Color("263c48"))
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(200,0.2,200)
	collision.shape = shape
	collision.position.y = -0.1
	floor_body.add_child(collision)
	var grid_mesh := PlaneMesh.new()
	grid_mesh.size = Vector2(200,200)
	var grid := mesh_node(grid_mesh,self,Color("263c48"))
	grid.position.y = 0.015
	grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shader := Shader.new()
	shader.code = """shader_type spatial;
varying vec3 world_position;
void vertex() { world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
 vec2 cell = abs(fract(world_position.xz - 0.5) - 0.5);
 vec2 width = max(fwidth(world_position.xz), vec2(0.001));
 float line = 1.0 - min(min(cell.x / width.x, cell.y / width.y), 1.0);
 float fade = 1.0 - smoothstep(12.0, 35.0, distance(world_position, CAMERA_POSITION_WORLD));
 ALBEDO = mix(vec3(0.10, 0.17, 0.21), vec3(0.22, 0.31, 0.36), line * fade);
 ROUGHNESS = 0.85;
}"""
	var grid_material := ShaderMaterial.new()
	grid_material.shader = shader
	grid.material_override = grid_material
	box(self,Vector3(0.035,0.008,12),Vector3(0,0.025,0),Color("4ecfc2"))
	box(self,Vector3(12,0.008,0.035),Vector3(0,0.025,0),Color("ef9c52"))
	for info in [["+Z 前",Vector3(0,0.03,4),Color("4ecfc2")],["+X",Vector3(4,0.03,0),Color("ef9c52")]]:
		var label := Label3D.new()
		label.text = info[0]
		label.position = info[1]
		label.modulate = info[2]
		label.rotation_degrees.x = -90
		label.font_size = 64
		label.pixel_size = 0.008
		add_child(label)
	add_child(camera)
	camera.current = true
	camera.fov = 48
	camera.near = 0.1
	camera.far = 100
	camera.h_offset = 0.3
	danger_marker.name = "DangerFixture"
	add_child(danger_marker)
	danger_marker.position = Vector3(0,0,-4)
	box(danger_marker,Vector3(0.6,0.6,0.6),Vector3(0,0.3,0),Color("f2b654"))
	var marker_label := Label3D.new()
	marker_label.text = "危险条件标记 · 非怪物"
	marker_label.position.y = 1.0
	marker_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	marker_label.font_size = 36
	danger_marker.add_child(marker_label)
	for radius in BODY_RADII:
		body_spheres.append(probe_mesh(float(radius),Color("46c9d9")))
	attack_sphere = probe_mesh(ATTACK_RADIUS,Color("f28045"))
	target_mesh = box(self,combat.target_half_size*2,combat.target_center,Color("58949d"),0.25)
	target_mesh.name = "TrainingCube"
	target_label.position = combat.target_center+Vector3(0,combat.target_half_size.y+0.3,0)
	target_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	target_label.font_size = 38
	target_label.outline_size = 8
	add_child(target_label)

func probe_mesh(radius: float, color: Color) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius*2
	var node := mesh_node(mesh,self,color)
	var mat: StandardMaterial3D = node.material_override
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = 0.35
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func sync_configuration() -> void:
	if not hunt_mode:
		controller.danger_enabled = danger_toggle.button_pressed
	controller.evasion_skill_a1 = window_skill.selected == 1
	controller.evasion_skill_a2 = window_skill.selected == 2
	probe_enabled = probe_toggle.button_pressed

func update_danger_fixture() -> void:
	sync_configuration()
	if controller.danger_enabled:
		var delta: Vector3 = danger_marker.position-controller.state.position*0.01
		controller.danger_yaw = int(round(atan2(delta.x,delta.z)*65536.0/TAU)) & 65535

# 直接取模拟姿态，不依赖上一帧 actor 或骨架的渲染变换。
func body_probe_centers() -> Array[Vector3]:
	var centers: Array[Vector3] = []
	var yaw: float = int(controller.state.yaw)*TAU/65536.0
	for bone in [10,20]:
		var local: Vector3 = animator.world_pose[bone].origin*0.01+Vector3(0,lift,0)
		centers.append(controller.state.position*0.01+local.rotated(Vector3.UP,yaw))
	return centers

# 每次调用都是独立攻击，无 HP、待处理事件或攻击历史。
func probe_attack(center: Vector3, radius: float) -> Dictionary:
	if not center.is_finite() or not is_finite(radius) or radius < 0:
		return {"status":"invalid"}
	if not controller.attack_collision_allowed():
		probe_stats.evaded += 1
		probe_result = {"status":"evaded","center":center,"radius":radius}
		return probe_result
	probe_stats.geometry_checks += 1
	var centers := body_probe_centers()
	var overlap: bool = false
	for i in range(centers.size()):
		overlap = overlap or center.distance_squared_to(centers[i]) <= pow(radius+BODY_RADII[i],2)
	probe_stats["hits" if overlap else "misses"] += 1
	probe_result = {"status":"accepted" if overlap else "miss","center":center,"radius":radius}
	return probe_result

func build_hunter() -> void:
	actor.name = "Actor"
	add_child(actor)
	actor.add_child(skeleton)
	skeleton.position.y = lift
	# 9 骨盆、10 躯干、12/16 肩、19 颈、20 头；站姿肩线/脊柱定义背平面。
	var spine: Transform3D = animator.world_pose[10]
	var reference := Transform3D(spine.basis.orthonormalized(),spine.origin*0.01)
	var shoulders: Vector3 = (animator.world_pose[12].origin+animator.world_pose[16].origin)*0.005
	var up: Vector3 = (shoulders-animator.world_pose[9].origin*0.01).normalized()
	var shoulder_line: Vector3 = animator.world_pose[12].origin-animator.world_pose[16].origin
	var right := (shoulder_line-up*shoulder_line.dot(up)).normalized()
	var back := up.cross(right).normalized()
	# 柄在右肩上，刀身沿背斜向左胯；厚度轴朝背，不向身体旁伸出。
	var direction := (-up-right*0.38).normalized()
	var standing_mount := Transform3D(Basis(back.cross(direction),back,direction),shoulders+up*0.16+right*0.15+back*0.14)
	# 收刀显示约 1.27 m 长、0.22 m 宽（原几何的 .55）；非原武器资产尺寸。
	standing_mount.basis = standing_mount.basis.scaled(Vector3.ONE*SHEATHED_SWORD_SCALE)
	back_mount = reference.inverse()*standing_mount
	for i in range(animator.data.bones.size()):
		var sphere := SphereMesh.new()
		sphere.radius = 0.14 if i == 20 else 0.052
		sphere.height = sphere.radius * 2
		var joint := mesh_node(sphere,skeleton,Color("edbc74") if i == 20 else Color("f0d7a0"))
		joint.name = "Bone%d" % i
		joints.append(joint)
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.085 if i in [3,6,10,11,12,16,19] else 0.06
		cylinder.bottom_radius = cylinder.top_radius
		cylinder.height = 1.0
		var rod := mesh_node(cylinder,skeleton,Color("64b8cf") if i < 10 else Color("e3a55b"),0.2)
		rods.append(rod)
	skeleton.add_child(sword)
	sword.name = "ApproximateGreatsword"
	box(sword,Vector3(0.09,0.09,0.5),Vector3(0,0,0.23),Color("493b39"))
	box(sword,Vector3(0.62,0.12,0.10),Vector3(0,0,0.53),Color("f2b654"),0.65)
	box(sword,Vector3(0.40,0.095,1.46),Vector3(0,0,1.30),Color("dce6e9"),0.7)
	box(sword,Vector3(0.065,0.105,1.46),Vector3(0,0,1.30),Color("4f99b5"),0.55)
	var tip := PrismMesh.new()
	tip.size = Vector3(0.40,0.27,0.095)
	var tip_node := mesh_node(tip,sword,Color("dce6e9"),0.7)
	tip_node.rotation.x = PI / 2
	tip_node.position.z = 2.16
	for z in [0.0,0.53,1.3,2.3]:
		var joint := SphereMesh.new()
		joint.radius = 0.01
		joint.height = 0.02
		mesh_node(joint,sword,Color("ffcc66")).position = Vector3(0,0,z)

func build_tusk_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var move: Dictionary = SandboxSpecial.MOVES.tusk
	for ring in range(8):
		for side in range(12):
			for corner in [[ring,side],[ring+1,side+1],[ring+1,side],[ring,side],[ring,side+1],[ring+1,side+1]]:
				var t: float = float(corner[0])/8.0
				var angle: float = float(corner[1])*TAU/12.0
				var radius: float = move.radius*(1.0-t)
				surface.add_vertex(Vector3(sin(angle)*radius+0.06*t*t,cos(angle)*radius+0.16*t*t,(t*2.0-1.0)*move.half_length))
	for side in range(12):
		surface.add_vertex(Vector3(0,0,-move.half_length))
		for corner in [side+1,side]:
			var angle: float = corner*TAU/12.0
			surface.add_vertex(Vector3(sin(angle)*move.radius,cos(angle)*move.radius,-move.half_length))
	surface.generate_normals()
	return surface.commit()

func build_special_effects() -> void:
	add_child(special_effect)
	laser_warning = box(special_effect,Vector3(0.7,0.035,10),Vector3.ZERO,Color("efae35"))
	for z in [-4.0,-1.0,2.0,4.0]:
		for side in [-1,1]:
			var arrow := box(laser_warning,Vector3(0.08,0.04,0.42),Vector3(side*0.13,0.04,z),Color("fff5b2"))
			arrow.rotation.y = -side*PI/4
	var beam := CylinderMesh.new()
	beam.top_radius = 0.35
	beam.bottom_radius = 0.35
	beam.height = 10
	laser_beam = mesh_node(beam,special_effect,Color(1,0.58,0.08,0.38))
	var core := CylinderMesh.new()
	core.top_radius = 0.14
	core.bottom_radius = 0.14
	core.height = 10
	laser_core = mesh_node(core,special_effect,Color("fff5b2"))
	var ring := TorusMesh.new()
	ring.inner_radius = 2.14
	ring.outer_radius = 2.26
	stink_ring = mesh_node(ring,special_effect,Color("c5e654"))
	var cloud := SphereMesh.new()
	cloud.radius = 2.2
	cloud.height = 4.4
	stink_cloud = mesh_node(cloud,special_effect,Color(0.54,0.68,0.15,0.25))
	var tooth := build_tusk_mesh()
	tusk_warning = box(special_effect,Vector3(SandboxSpecial.MOVES.tusk.radius*2,0.025,SandboxSpecial.MOVES.tusk.range),Vector3.ZERO,Color(1,0.70,0.28,0.45))
	tusk_charge = mesh_node(tooth,special_effect,Color("ffc86a"))
	for i in range(SandboxSpecial.MOVES.tusk.count):
		tusk_pool.append(mesh_node(tooth,special_effect,Color("fff3d6")))
	tusk_trail = box(special_effect,Vector3(0.04,0.04,1),Vector3.ZERO,Color(1,0.75,0.38,0.45))
	var slam_ring := TorusMesh.new()
	slam_ring.inner_radius = SandboxSpecial.SLAM.radius-0.06
	slam_ring.outer_radius = SandboxSpecial.SLAM.radius+0.06
	slam_warning = mesh_node(slam_ring,special_effect,Color("ff7256"))
	slam_impact = mesh_node(slam_ring,special_effect,Color("ffd275"))
	var spin_ring := TorusMesh.new()
	spin_ring.inner_radius = 1.5
	spin_ring.outer_radius = 1.56
	slam_spin = mesh_node(spin_ring,special_effect,Color(0.42,0.86,1,0.55))
	var shadow := CylinderMesh.new()
	shadow.top_radius = 0.9
	shadow.bottom_radius = 0.9
	shadow.height = 0.008
	slam_shadow = mesh_node(shadow,special_effect,Color(0.02,0.05,0.07,0.55))
	for node in [laser_warning,laser_beam,laser_core,stink_ring,stink_cloud,tusk_warning,tusk_charge,tusk_trail,slam_warning,slam_impact,slam_spin,slam_shadow]+tusk_pool:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat: StandardMaterial3D = node.material_override
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = mat.albedo_color
	for node in tusk_pool:
		var mat: StandardMaterial3D = node.material_override
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.emission_energy_multiplier = 0.12
		mat.roughness = 0.65

func update_special_effects() -> void:
	var special: Dictionary = monster.sandbox_special.snapshot()
	special_effect.visible = hunt_mode and special.kind != ""
	for node in [tusk_warning,tusk_charge,tusk_trail,slam_warning,slam_impact,slam_spin,slam_shadow]:
		node.visible = false
	for node in tusk_pool:
		node.visible = false
	if not special_effect.visible:
		return
	if special.kind == "slam":
		slam_shadow.visible = true
		slam_shadow.position = Vector3(special.origin.x,0.035,special.origin.z)
		slam_spin.visible = special.stage in ["windup","ascent","hover","locked","descent"]
		slam_spin.position = special.origin+Vector3(0,0.5,0)
		slam_spin.rotation.y = special.yaw*TAU/65536.0
		slam_spin.scale = Vector3.ONE*(0.95+0.05*sin(special.age*0.7))
		slam_warning.visible = special.stage in ["locked","descent"]
		slam_warning.position = special.landing_point+Vector3(0,0.08,0)
		slam_impact.visible = special.stage == "active"
		slam_impact.position = special.landing_point+Vector3(0,0.12,0)
	var tusk: bool = special.kind == "tusk"
	if tusk:
		var facing: float = special.yaw*TAU/65536.0
		var forward := Vector3(0,0,1).rotated(Vector3.UP,facing)
		tusk_warning.visible = special.stage == "windup"
		tusk_charge.visible = special.stage == "windup"
		tusk_warning.position = special.mouth+forward*SandboxSpecial.MOVES.tusk.range*0.5
		tusk_warning.position.y = 0.055
		tusk_warning.rotation.y = facing
		tusk_charge.position = special.mouth
		tusk_charge.rotation.y = facing
		tusk_charge.scale = Vector3.ONE*(0.8+0.2*sin(special.age*0.6))
		var projectile: Dictionary = special.projectile
		if projectile.get("active",false):
			tusk_pool[0].visible = true
			tusk_pool[0].position = projectile.position
			tusk_pool[0].rotation.y = facing
			tusk_trail.visible = projectile.position != projectile.previous
			tusk_trail.position = (projectile.position+projectile.previous)*0.5-forward*SandboxSpecial.MOVES.tusk.half_length
			tusk_trail.rotation.y = facing
			tusk_trail.scale.z = projectile.position.distance_to(projectile.previous)
	var shape: Dictionary = special.volume
	var laser: bool = special.kind == "laser"
	var active: bool = special.stage == "active"
	laser_warning.visible = laser and special.stage != "recovery"
	laser_beam.visible = laser and active
	laser_core.visible = laser and active
	stink_ring.visible = special.kind == "stink" and special.stage != "recovery"
	stink_cloud.visible = special.kind == "stink" and active
	if laser:
		var center: Vector3 = (shape.a+shape.b)*0.5
		laser_warning.position = Vector3(center.x,0.05,center.z)
		laser_warning.rotation.y = special.yaw*TAU/65536.0
		var direction: Vector3 = (shape.b-shape.a).normalized()
		var right := direction.cross(Vector3.UP).normalized()
		var beam_transform := Transform3D(Basis(right,direction,right.cross(direction)),center)
		laser_beam.transform = beam_transform
		laser_core.transform = beam_transform
	elif special.kind == "stink":
		stink_ring.position = Vector3(shape.a.x,0.08,shape.a.z)
		stink_cloud.position = shape.a

func build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	hud.position = Vector2(20,18)
	hud.add_theme_font_size_override("font_size",14)
	hud.size.x = 430
	hud.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hud)
	llm_banner.anchor_left = 0.5
	llm_banner.anchor_right = 0.5
	llm_banner.offset_left = -180
	llm_banner.offset_right = 180
	llm_banner.offset_top = 18
	llm_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var banner_style := StyleBoxFlat.new()
	banner_style.bg_color = Color("17283e")
	banner_style.border_color = Color("ffce65")
	banner_style.set_border_width_all(2)
	banner_style.set_content_margin_all(10)
	llm_banner.add_theme_stylebox_override("panel",banner_style)
	root.add_child(llm_banner)
	var banner_column := VBoxContainer.new()
	banner_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	llm_banner.add_child(banner_column)
	llm_banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	llm_banner_title.add_theme_font_size_override("font_size",24)
	llm_banner_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_column.add_child(llm_banner_title)
	llm_banner_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	llm_banner_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	llm_banner_detail.custom_minimum_size.x = 336
	llm_banner_detail.add_theme_font_size_override("font_size",14)
	llm_banner_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_column.add_child(llm_banner_detail)
	help.text = "WASD / 左摇杆 移动    J/Y △ 拔刀/蓄力    K/B ○ 横斩    J+K 上捞\nSpace/A × 闪避/蹲    U/X □ 收刀    Shift/R1 冲刺；拔刀 R1+Y 防御\n松 J/Y 蓄力出刀；背离活猪王收刀冲刺后 A 飞扑    Q 拔刀\nM / 十字下 切换训练    R / 十字上 重开狩猎（训练仅重置方块）\nEsc/Start 动作库    [ ] / 十字左右 选择    Enter 播放并切回训练\n训练：T/L1 黄色危险夹具（非怪物） · H 独立无伤探针\n右摇杆 / 右鼠标 环绕 · 滚轮 缩放；未做实体手柄实测\n猪王原模型/动作/攻击形状；选招、HP100/1000、来袭20为沙盒\n受击HurtBox/身体推挡为近似；非原完整物理/防御/伤害系统"
	help.text += "\n六招：冲撞/转向攻击/激光/臭屁/猪牙/螺旋砸地（特殊为原创）\n螺旋砸地：蓄力升空5m，红圈锁点0.8秒后垂直砸落；走开可躲，落地恢复2秒可惩罚"
	help.position = Vector2(20,550)
	help.add_theme_font_size_override("font_size",12)
	help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(help)
	panel.position = Vector2(924,18)
	panel.size = Vector2(336,610)
	root.add_child(panel)
	hunter_hp.position = Vector2(20,265)
	hunter_hp.size = Vector2(310,22)
	hunter_hp.max_value = 100
	hunter_hp.show_percentage = false
	root.add_child(hunter_hp)
	var tactics_ui := VBoxContainer.new()
	tactics_ui.position = Vector2(20,298)
	tactics_ui.custom_minimum_size = Vector2(520,0)
	root.add_child(tactics_ui)
	llm_mode.text = "LLM战术沙盒 · L 开/关（仅指定relay外传游戏摘要）"
	llm_mode.tooltip_text = "L 切换；输入框打字不切换。启用不等于模型已采纳；本地key加载沿用自动开启。"
	tactics_ui.add_child(llm_mode)
	llm_mode.toggled.connect(set_llm_mode)
	llm_key.secret = true
	llm_key.max_length = 512
	llm_key.placeholder_text = "可选key：仅内存，Enter应用并清空；空值移除"
	tactics_ui.add_child(llm_key)
	llm_key.text_submitted.connect(func(value): llm.set_memory_key(value); llm_key.clear(); llm_key.release_focus())
	llm_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	llm_status.custom_minimum_size = Vector2(500,0)
	llm_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	llm_status.add_theme_font_size_override("font_size",12)
	var status_scroll := ScrollContainer.new()
	status_scroll.custom_minimum_size = Vector2(520,160)
	status_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tactics_ui.add_child(status_scroll)
	status_scroll.add_child(llm_status)
	var logs_button := Button.new()
	logs_button.text = "打开实际LLM日志目录（本地JSONL）"
	logs_button.tooltip_text = "实际目录："+ProjectSettings.globalize_path(llm.LOG_DIR)+"\n本运行文件："+ProjectSettings.globalize_path(llm.log_path)
	logs_button.pressed.connect(llm.open_logs)
	tactics_ui.add_child(logs_button)
	round_panel.position = Vector2(270,320)
	round_panel.size = Vector2(570,130)
	root.add_child(round_panel)
	round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	round_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	round_label.add_theme_font_size_override("font_size",30)
	round_panel.add_child(round_label)
	var column := VBoxContainer.new()
	panel.add_child(column)
	column.add_child(mode_button)
	mode_button.tooltip_text = "切换狩猎/训练会明确重置整局和双方位置（允许重新定位）；非重置的空中取消会先连续无伤降落。"
	mode_button.pressed.connect(func(): set_hunt_mode(not hunt_mode))
	var motion_mode := CheckButton.new()
	motion_mode.text = "连续快转沙盒（关闭：来源动作轨迹）"
	motion_mode.button_pressed = true
	motion_mode.tooltip_text = "沙盒：15tick转向攻击仍有record2伤害；连续步行/特殊18tick转身。来源轨迹：原分段yaw/END，非原完整AI，禁用LLM与原创特殊。此UI切换明确重开整局/双方复位；运行中直接关闭AI/模式而不reset时，空中猪王先连续无伤降落。"
	column.add_child(motion_mode)
	motion_mode.toggled.connect(func(value):
		monster.sandbox_motion_enabled = value
		monster.sandbox_specials_enabled = value
		set_llm_mode(false)
		reset_hunt())
	var title := Label.new()
	title.text = "动作库 · 选定初始姿态展示"
	column.add_child(title)
	actions = controller.get_actions()
	action_list.custom_minimum_size = Vector2(320,230)
	action_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(action_list)
	for action in actions:
		var prefix: String = "额外" if action.category == 1 and action.subaction == 99 else ["普通","大剑","防御"][int(action.category)]
		var only: String = " [仅dispatch]" if action.subaction in Controller.DISPATCH_ONLY and action.category == 1 else ""
		action_list.add_item("%s %02d · %s%s" % [prefix,action.subaction,action.name,only])
		action_list.set_item_tooltip(action_list.item_count-1,str(action.input_reachability))
	action_list.select(0)
	play_button.text = "播放选定动作（展示）"
	column.add_child(play_button)
	play_button.pressed.connect(play_selected)
	action_list.item_activated.connect(func(_index): play_selected())
	reset_button.text = "复位 · 收刀站姿"
	column.add_child(reset_button)
	reset_button.pressed.connect(reset_lab)
	var label := Label.new()
	label.text = "每模拟步一次源采样 · 15–60 Hz"
	column.add_child(label)
	speed.min_value = 15
	speed.max_value = 60
	speed.step = 1
	speed.value = 30
	column.add_child(speed)
	speed.value_changed.connect(func(value): hz = value)
	danger_toggle.text = "危险条件夹具（非怪物）"
	column.add_child(danger_toggle)
	danger_toggle.toggled.connect(func(_value): sync_configuration())
	window_skill.add_item("攻击窗口技能：无")
	window_skill.add_item("攻击窗口技能：回避+1")
	window_skill.add_item("攻击窗口技能：回避+2")
	column.add_child(window_skill)
	window_skill.item_selected.connect(func(_index): sync_configuration())
	probe_toggle.text = "逐调用攻击探针（不扣血）"
	column.add_child(probe_toggle)
	probe_toggle.toggled.connect(func(_value): sync_configuration())
	target_reset_button.text = "重置训练方块 · R / 十字上"
	column.add_child(target_reset_button)
	target_reset_button.pressed.connect(reset_target)
	combat_note.add_theme_font_size_override("font_size",14)
	column.add_child(combat_note)
	sync_configuration()

func _joy_changed(_device: int, _connected: bool) -> void:
	hotplug_count += 1

# 只重置 combat owner 和反馈；保留猎人动作，统计随 combat.reset 清零。
func reset_target() -> void:
	if hunt_mode:
		reset_hunt()
		return
	combat.reset()
	combat_events.clear()
	target_flash = 0
	for floating in damage_labels:
		floating.label.free()
	damage_labels.clear()
	update_target_visuals()

# 反馈寿命只随模拟调用推进；渲染不消费事件。
func tick_feedback() -> void:
	target_flash = maxi(0,target_flash-1)
	player_flash = maxi(0,player_flash-1)
	monster_flash = maxi(0,monster_flash-1)
	for index in range(damage_labels.size()-1,-1,-1):
		var floating: Dictionary = damage_labels[index]
		floating.ttl -= 1
		floating.label.position.y += 0.018
		if floating.ttl <= 0:
			floating.label.free()
			damage_labels.remove_at(index)

func show_damage(text: String, at: Vector3, color: Color) -> void:
	var label := Label3D.new()
	label.text = text
	label.position = at
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 72
	label.outline_size = 12
	label.modulate = color
	label.no_depth_test = true
	add_child(label)
	damage_labels.append({"label":label,"ttl":DAMAGE_LABEL_TICKS})

func tick_combat(snapshot: Dictionary) -> void:
	tick_feedback()
	combat_events = combat.tick(snapshot,animator,lift)
	for event in combat_events:
		if event.event == "hit":
			target_flash = 8
			var at: Vector3 = event.position+Vector3(0,0.5,0)
			at.y = maxf(at.y,target_label.position.y+0.6)
			show_damage(str(event.damage),at,Color("ffd25e"))
	update_target_visuals()

func tick_hunt(input: Dictionary) -> Dictionary:
	tick_feedback()
	sync_configuration()
	llm.advance(hunt,hunt_mode)
	hunt_snapshot = hunt.tick(input)
	llm.record(hunt)
	if hunt_snapshot.has("error") or not hunt_snapshot.get("ready",false):
		push_error("狩猎模拟失败："+str(hunt_snapshot))
		get_tree().quit(1)
		return hunt_snapshot
	combat_events = hunt_snapshot.events
	for event in combat_events:
		if event.event == "monster_damage":
			monster_flash = 8
			show_damage(str(event.damage),event.position+Vector3(0,1,0),Color("ffd25e"))
		elif event.event == "player_damage":
			player_flash = 10
			var guarded: bool = event.guarded
			show_damage(("防御 -" if guarded else "-")+str(event.applied_damage),controller.state.position*0.01+Vector3(0,2.2,0),Color("7be6ff") if guarded else Color("ff7666"))
	boar_view.set_hit_flash(monster_flash > 0)
	boar_view.sync(monster.state,monster_animator)
	skin_updates += 1
	return hunt_snapshot

func clear_mode_feedback() -> void:
	for floating in damage_labels:
		floating.label.free()
	damage_labels.clear()
	combat_events.clear()
	snapshots.clear()
	last_snapshot.clear()
	preview_ticks = -1
	accumulator = 0
	player_flash = 0
	monster_flash = 0
	target_flash = 0
	probe_stats = {"evaded":0,"hits":0,"misses":0,"geometry_checks":0}
	probe_result.clear()
	boar_view.set_hit_flash(false)

func reset_hunt() -> void:
	clear_mode_feedback()
	input_blocked_until_release = true
	monster.ai_enabled = true
	hunt.reset()
	llm.bind_round(hunt)
	animator.tick(0)
	monster_animator.tick(0)
	combat.reset()
	hunt_snapshot.clear()
	boar_view.sync(monster.state,monster_animator)
	skin_updates += 1
	update_visuals()

func set_hunt_mode(enabled: bool) -> void:
	if hunt_mode == enabled:
		return
	hunt_mode = enabled
	reset_hunt()
	if not enabled:
		reset_lab()
		input_blocked_until_release = true
	update_visuals()

func update_target_visuals() -> void:
	if not is_instance_valid(target_mesh):
		return
	target_mesh.visible = not hunt_mode and combat.target_alive
	target_label.visible = not hunt_mode
	var mat: StandardMaterial3D = target_mesh.material_override
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color("ff624d") if target_flash > 0 else Color("58949d")
	mat.albedo_color.a = 0.4 if target_flash > 0 else 0.32
	mat.emission_enabled = target_flash > 0
	mat.emission = Color("b52e12")
	target_label.text = "训练方块 %d / %d HP" % [combat.target_hp,combat.target_max_hp] if combat.target_alive else "击破！%d / 90 模拟调用后重生" % combat.respawn_remaining

func reset_lab() -> void:
	if hunt_mode:
		reset_hunt()
		return
	sync_configuration()
	controller.reset()
	reset_target()
	update_danger_fixture()
	controller.tick(0,0,0)
	probe_stats = {"evaded":0,"hits":0,"misses":0,"geometry_checks":0}
	probe_result.clear()
	preview_ticks = -1
	accumulator = 0
	snapshots.clear()
	last_snapshot.clear()
	update_visuals()

func play_selected() -> void:
	var selected := action_list.get_selected_items()
	if not selected.is_empty():
		var action: Dictionary = actions[selected[0]]
		preview_action(int(action.category),int(action.subaction))

func preview_action(category: int, sub: int) -> bool:
	set_hunt_mode(false)
	reset_lab()
	if category in [1,2] or category == 0 and sub in [3,5,10,15,49,50]:
		controller.state.flags410 |= 8
	preview_category = category
	preview_sub = sub
	preview_ticks = 0
	return controller.force_action(category,sub)

func input_snapshot() -> Dictionary:
	if text_input_focused():
		return {"held":0,"mag":0,"direction":int(controller.state.yaw),"bits":0}
	var held: int = 0
	for action in BUTTONS:
		if Input.is_action_pressed("lab_"+action):
			held |= BUTTONS[action]
	var motion := Input.get_vector("lab_left","lab_right","lab_forward","lab_back",0.18)
	var world := Vector3(motion.x,0,motion.y).rotated(Vector3.UP,orbit)
	var direction: int = int(controller.state.get("yaw",0))
	if world.length_squared() > 0.00001:
		direction = int(round(atan2(world.x,world.z)*65536.0/TAU)) & 65535
	var bits: int = 0
	if motion.x < -0.18:
		bits |= 0x800000
	if motion.x > 0.18:
		bits |= 0x200000
	if motion.y < -0.18:
		bits |= 0x100000
	if motion.y > 0.18:
		bits |= 0x400000
	return {"held":held,"mag":int(round(127*motion.length())),"direction":direction,"bits":bits}

func _input(event: InputEvent) -> void:
	if not is_node_ready() or controller.state.is_empty() or text_input_focused():
		return
	if event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		if event is InputEventKey and event.echo:
			return
		if event.is_action("lab_llm"):
			if event.is_action_pressed("lab_llm"):
				set_llm_mode(not llm.enabled)
			get_viewport().set_input_as_handled()
			return
		if event.is_action("lab_target_reset"):
			if event.is_action_pressed("lab_target_reset"):
				reset_target()
			return
		if event.is_action("lab_mode"):
			if event.is_action_pressed("lab_mode"):
				set_hunt_mode(not hunt_mode)
			return
		var snapshot := input_snapshot()
		# 只保留按钮边沿；移动/镜头方向不是命令历史，必须在消费tick实时采样。
		if snapshot.held != last_snapshot.get("held",0):
			snapshots.append({"held":snapshot.held})
		last_snapshot = {"held":snapshot.held}
		if snapshot.held != 0 or snapshot.mag > 0:
			preview_ticks = -1
		if not hunt_mode and event.is_action_pressed("lab_danger"):
			danger_toggle.button_pressed = not danger_toggle.button_pressed
		if not hunt_mode and event.is_action_pressed("lab_probe"):
			probe_toggle.button_pressed = not probe_toggle.button_pressed
		if event.is_action_pressed("lab_weapon"):
			preview_ticks = -1
			if not hunt_mode:
				controller.toggle_weapon()
			elif not controller.is_drawn() and not controller.is_recovering() and hunt.round_state == "running" and not input_blocked_until_release:
				snapshots.append({"held":Controller.TRIANGLE})
				snapshots.append({"held":snapshot.held})
		if event.is_action_pressed("lab_menu"):
			panel.visible = not panel.visible
		if event.is_action_pressed("lab_play"):
			play_selected()
		if event.is_action_pressed("lab_previous") or event.is_action_pressed("lab_next"):
			var selected := action_list.get_selected_items()
			var index: int = selected[0] if not selected.is_empty() else 0
			index = wrapi(index + (-1 if event.is_action_pressed("lab_previous") else 1),0,actions.size())
			action_list.select(index)
			action_list.ensure_current_is_visible()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			dragging = event.pressed
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(3.8,distance-0.4)
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = minf(12,distance+0.4)
	if event is InputEventMouseMotion and dragging:
		orbit -= event.relative.x*0.006
		elevation = clampf(elevation+event.relative.y*0.004,0.05,0.9)

func simulation_tick() -> Dictionary:
	var input: Dictionary = input_snapshot()
	if not snapshots.is_empty():
		input.held = snapshots.pop_front().held
	if input_blocked_until_release and preview_ticks < 0:
		var current := input_snapshot()
		input_blocked_until_release = current.held != 0 or current.mag > 0
		snapshots.clear()
		input = {"held":0,"mag":0,"direction":int(controller.state.yaw),"bits":0}
	if hunt_mode:
		return tick_hunt(input)
	update_danger_fixture()
	var live: bool = preview_ticks < 0
	var fixture_enabled: bool = controller.danger_enabled
	var fixture_yaw: int = controller.danger_yaw
	if preview_ticks >= 0:
		input = {"held":0,"mag":0,"direction":int(controller.state.yaw),"bits":0}
		if preview_category == 0 and preview_sub in [1,3,73,36,31,70,59,61]:
			input.mag = 80 if preview_sub in [73,59] else 127
			if preview_sub in [31,70]:
				input.held = Controller.R
		if preview_category == 0 and preview_sub in [32,68,69]:
			# 仅此展示调用提供背后危险，不永久改写实时夹具参数。
			controller.danger_enabled = true
			controller.danger_yaw = (int(controller.state.yaw)+32768)&65535
			if preview_ticks < 90:
				input.held = Controller.R
				if preview_sub in [32,69]:
					input.mag = 127
		if preview_category == 1 and Controller.CHARGE.has(preview_sub):
			# 按住直到蓄力计数达到 90 个模拟步后释放；各变体的起始阶段不同。
			if controller.state.charge < 90 and controller.state.cate == 1 and Controller.CHARGE.has(controller.state.sub):
				input.held = Controller.TRIANGLE
		if preview_category == 2 and preview_sub in [3,12,38] and preview_ticks < 90:
			input.held = Controller.R
		preview_ticks += 1
	var result: Dictionary = controller.tick(input.held,input.mag,input.direction,input.bits)
	tick_combat(result)
	controller.danger_enabled = fixture_enabled
	controller.danger_yaw = fixture_yaw
	if live and probe_enabled:
		probe_attack(body_probe_centers()[0],ATTACK_RADIUS)
	if not live and result.cate == 0 and result.sub == 0 and preview_ticks > 1:
		preview_ticks = -1
	return result

func _physics_process(delta: float) -> void:
	if not controller.state.get("ready",false):
		return
	accumulator = minf(accumulator+delta,8.0/hz)
	var count: int = 0
	while accumulator >= 1.0/hz and count < 8:
		simulation_tick()
		accumulator -= 1.0/hz
		count += 1

func _process(delta: float) -> void:
	if controller.state.is_empty() or joints.is_empty():
		return
	var look := Input.get_vector("lab_look_left","lab_look_right","lab_look_up","lab_look_down",0.18)
	orbit -= look.x*delta*2
	elevation = clampf(elevation+look.y*delta,0.05,0.9)
	update_visuals()
	rendered += 1
	if test_frames >= 0 and rendered >= test_frames:
		get_tree().quit()

func update_visuals() -> void:
	llm_mode.set_pressed_no_signal(llm.enabled)
	llm_mode.disabled = not monster.sandbox_motion_enabled
	llm_banner_title.text = "LLM 模式已开启 · L 关闭" if llm.enabled else "规则 AI · L 开启 LLM"
	llm_banner_title.modulate = Color("ffce65") if llm.enabled else Color("b6c9dc")
	llm_banner_detail.text = llm.mode_brief(hunt,hunt_mode)
	if not monster.sandbox_motion_enabled:
		llm_banner_detail.text = "来源动作模式 · LLM禁用"
	if llm.log_status.contains("失败") or llm.log_status.contains("上限") or llm.log_status.contains("不完整"):
		llm_banner_detail.text += "\n"+llm.log_status
	var configuration: String = llm.config_status
	if llm.config_source == "local_file":
		configuration += " / "+("LLM自动开启，仅指定relay外传游戏摘要" if llm.enabled else "LLM已关闭 · 不联网")
	llm_status.text = configuration+"\n"+llm.status+"\n选择："+llm.choice+"\n选择意图 ["+monster.decision_source+"]："+monster.llm_selection+" · "+str(monster.state.mode)+"\n追踪："+str(monster.state.tracking_stage)+"\n当前观测："+str(monster.state.observed_target)+" / 承诺 ["+str(monster.state.committed_source)+"]："+str(monster.state.committed_target)+"\n理由："+llm.reason+"\n累计请求%d · 实报usage %s · %d请求usage unknown\n无本地累计token/请求上限；服务额度未验证\n单次输出容量1024 token · 单在途 / 最小间隔5秒\n最近请求耗时%dms（完整响应/终止；非TTFT）\n采纳→实际执行延迟：unknown（未测step）\n" % [llm.requests,str(llm.usage) if llm.usage_known else "unknown",llm.unknown_usage_requests,llm.latency_ms]+llm.log_status
	update_target_visuals()
	update_special_effects()
	boar_view.visible = hunt_mode
	danger_marker.visible = not hunt_mode
	hunter_hp.visible = hunt_mode
	hunter_hp.value = controller.state.hp
	hunter_hp.modulate = Color("ff7666") if player_flash > 0 else Color("78dfa6")
	mode_button.text = "狩猎中 · M / 十字下 切换训练" if hunt_mode else "训练中 · M / 十字下 开始狩猎"
	reset_button.text = "重开整局 · 双方复位" if hunt_mode else "复位 · 收刀站姿"
	target_reset_button.text = "重开狩猎 · R / 十字上" if hunt_mode else "重置训练方块 · R / 十字上"
	combat_note.text = "中性：基础 raw100 · 肉质100%\n横斩36 / 上捞46 / 纵斩48\n蓄力1/2/3：71 / 96 / 143 · 踢2\n原招/激光20，臭屁12/牙15/砸25\n猪王HP0保留尸体；R重开整局\n原模型/动作/形状；选招与受击近似" if hunt_mode else "中性：基础 raw100 · 肉质100%\n斩味1 / 阶段1 / 目标1 · 无属性会心\n横斩36 / 上捞46 / 纵斩48\n蓄力1/2/3：71 / 96 / 143 · 踢2\n击破90模拟调用重生（非原值）\n原记录几何命中；非完整原游戏系统"
	danger_toggle.disabled = hunt_mode
	probe_toggle.disabled = hunt_mode
	round_panel.visible = hunt_mode and hunt.round_state != "running"
	round_label.text = ("狩猎成功" if hunt.round_state == "victory" else "猎人倒下")+"\n猎人 %d / 100 · 猪王 %d / 1000\nR / 十字上 / 重开按钮 再来一局" % [controller.state.hp,monster.state.hp]
	boar_view.sync_transform(monster.state)
	var special: Dictionary = monster.sandbox_special.snapshot()
	var move_text: String = {"laser":"激光波","stink":"臭屁","tusk":"猪牙弹 · 原创沙盒","slam":"螺旋砸地 · 原创沙盒"}.get(special.kind,special.kind)+" · "+{"windup":"起飞蓄力" if special.kind == "slam" else "范围预警","ascent":"旋转升空","hover":"高空有限移动","locked":"红圈已锁定 · 走开！","descent":"砸落","landing":"取消 · 安全降落","active":"落地冲击" if special.kind == "slam" else "释放","recovery":"恢复 · 可惩罚"}.get(special.stage,"") if special.kind != "" else str(monster.state.mode)
	monster_label.text = "大野猪王 %d / 1000 HP\n%s · %s" % [monster.state.hp,"连续沙盒" if monster.sandbox_motion_enabled else "来源动作轨迹",move_text]
	actor.position = controller.state.position*0.01
	actor.rotation.y = int(controller.state.yaw)*TAU/65536.0
	for i in range(joints.size()):
		var p: Vector3 = animator.world_pose[i].origin*0.01
		joints[i].position = p
		var parent: int = int(animator.data.bones[i].parent)
		var from: Vector3 = animator.world_pose[parent].origin*0.01 if parent >= 0 else p
		var delta := p-from
		rods[i].visible = delta.length() > 0.015
		# 重合的根节点/辅助节点仍保留为真实节点，但不显示粗大的重叠球体。
		joints[i].visible = i not in [0,1,2,9]
		if rods[i].visible:
			var y := delta.normalized()
			var reference := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
			var x := y.cross(reference).normalized()
			rods[i].transform = Transform3D(Basis(x,y,x.cross(y)),(p+from)*0.5)
			rods[i].scale.y = delta.length()
	if controller.is_drawn():
		var hand: Transform3D = animator.world_pose[14]
		sword.transform = Transform3D(hand.basis.orthonormalized().scaled(Vector3.ONE*0.87),hand.origin*0.01)
	else:
		var spine: Transform3D = animator.world_pose[10]
		var current_spine := Transform3D(spine.basis.orthonormalized(),spine.origin*0.01)
		sword.transform = current_spine*back_mount
	var centers := body_probe_centers()
	for i in range(body_spheres.size()):
		body_spheres[i].position = centers[i]
		body_spheres[i].visible = not hunt_mode and probe_enabled
	attack_sphere.visible = not hunt_mode and probe_enabled and not probe_result.is_empty()
	if not probe_result.is_empty():
		attack_sphere.position = probe_result.center
		attack_sphere.scale = Vector3.ONE*float(probe_result.radius)/ATTACK_RADIUS
		var mat: StandardMaterial3D = attack_sphere.material_override
		mat.albedo_color = Color(0.15,0.9,0.75,0.45) if probe_result.status == "evaded" else Color(1.0,0.25,0.08,0.45) if probe_result.status == "accepted" else Color(0.65,0.65,0.65,0.35)
	var focus := actor.position+Vector3(0,1.6,0)
	if hunt_mode:
		focus += (boar_view.position-actor.position).limit_length(6)*0.35
	camera.h_offset = 1.5 if hunt_mode and panel.visible else 0.3
	camera.position = focus+Vector3(sin(orbit)*cos(elevation),sin(elevation),cos(orbit)*cos(elevation))*distance
	camera.look_at(focus)
	var devices := Input.get_connected_joypads()
	var device_text: String = "物理手柄未连接（键盘可用；测试事件不是硬件实测）"
	if not devices.is_empty():
		device_text = "已连接："+Input.get_joy_name(devices[0])+"（未认证硬件实测）"
	var state: Dictionary = controller.state
	hud.text = "MHP2G · 猎人骨架动作实验室\n%s  |  %s\n动作 %d/%d  phase %d  primary %d  frame %.1f / %.1f\n耐力 %d / %d   蓄力 %d · 等级 %d   rate %.2f   模拟 %.0f Hz\n%s" % [({"light":"轻受击","down":"倒地受击","rise":"起身恢复","dead":"猎人死亡"}.get(state.recovery,state.get("name","待机"))),"拔刀" if controller.is_drawn() else "收刀",state.cate,state.sub,state.phase,state.primary,state.frames[0],state.frames[1],state.stamina,state.stamina_max,state.charge,state.level,state.rate,hz,device_text]
	if hunt_mode:
		hud.text = hud.text.replace("猎人骨架动作实验室","可玩狩猎沙盒")
		hud.text += "\n猎人 HP %d / 100 · %s\n猪王 HP %d / 1000 · %s\n原伤害 %d · 命中 %d · 来袭接触 %d · 模拟步 %d\n竞技场边界 ±10 · 身体半径 0.40 / 0.85（沙盒）" % [state.hp,state.recovery,monster.state.hp,monster.state.mode,hunt.last_monster_damage,hunt.hunter_hits,hunt.monster_hits,hunt.ticks]
		if combat_events.any(func(e): return e.event == "incoming_not_ready"):
			hud.text += "\n来袭来源不足：未知空中路径 not_ready（非成功防御）"
		return
	hud.text += "\n方块 HP %d / %d · 最近伤害 %d · 命中 %d · 累计伤害 %d" % [combat.target_hp,combat.target_max_hp,combat.last_damage,combat.hits,combat.total_damage]
	if not combat.target_alive:
		hud.text += "\n击破！重生剩余 %d / 90 模拟调用（沙盒非原值）" % combat.respawn_remaining
	hud.text += "\n窗口 %d · %s（仅攻击碰撞路径）  Y %.2f m\n危险夹具 %s · yaw %d   探针 %s · %s\n拒绝 %d / 重叠通过 %d / 未重叠 %d / 几何查询 %d" % [state.internal_window,"可检测" if controller.attack_collision_allowed() else "拒绝",actor.position.y,"开" if danger_toggle.button_pressed else "关",controller.danger_yaw,"开" if probe_enabled else "关",probe_result.get("status","未调用"),probe_stats.evaded,probe_stats.hits,probe_stats.misses,probe_stats.geometry_checks]
