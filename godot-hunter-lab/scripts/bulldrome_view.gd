class_name BulldromeView
extends Node3D

var lift: float = 0.0
var vertices: Array[PackedVector3Array] = []
var _surfaces: Array[Dictionary] = []
var _materials: Array[StandardMaterial3D] = []
var _instance: MeshInstance3D
var _mesh: ArrayMesh
var _data: Dictionary = {}

static func _vector(value: Array) -> Vector3:
	return Vector3(value[0], value[1], value[2])

static func _valid_mesh(value: Variant, bone_count: int) -> bool:
	if not value is Dictionary or value.get("schema_version") != 1 or value.get("display_scale") != 0.01 or value.get("axis_conversion") != "none":
		return false
	if not HunterAnimator._number(value.get("standing_min_y")) or not value.get("surfaces") is Array or value.surfaces.is_empty():
		return false
	if not value.get("materials") is Array or not value.get("textures") is Array or value.textures.is_empty():
		return false
	for texture in value.textures:
		if not texture is Dictionary or not texture.get("path") is String or not ResourceLoader.exists(texture.path, "Texture2D"):
			return false
	for material in value.materials:
		if not material is Dictionary or not HunterAnimator._integer(material.get("texture")) or material.texture < 0 or material.texture >= value.textures.size():
			return false
	for surface in value.surfaces:
		if not surface is Dictionary or not HunterAnimator._integer(surface.get("material")) or surface.material < 0 or surface.material >= value.materials.size():
			return false
		if not surface.get("vertices") is Array or surface.vertices.is_empty() or not surface.get("uvs") is Array or surface.uvs.size() != surface.vertices.size():
			return false
		if not surface.get("indices") is Array or surface.indices.is_empty() or surface.indices.size() % 3 != 0:
			return false
		for index in surface.indices:
			if not HunterAnimator._integer(index) or index < 0 or index >= surface.vertices.size():
				return false
		for uv in surface.uvs:
			if not uv is Array or uv.size() != 2 or not HunterAnimator._number(uv[0]) or not HunterAnimator._number(uv[1]):
				return false
		for vertex in surface.vertices:
			if not vertex is Array or vertex.is_empty():
				return false
			var total: float = 0.0
			for influence in vertex:
				if not influence is Dictionary or not HunterAnimator._integer(influence.get("bone")) or influence.bone < 0 or influence.bone >= bone_count:
					return false
				if not HunterAnimator._number(influence.get("weight")) or influence.weight <= 0 or influence.weight > 1:
					return false
				if not influence.get("local_bind") is Array or influence.local_bind.size() != 3:
					return false
				for scalar in influence.local_bind:
					if not HunterAnimator._number(scalar):
						return false
				total += influence.weight
			if absf(total - 1.0) > 0.000001:
				return false
	return true

func configure(animator: HunterAnimator) -> bool:
	if animator.data.get("body_pack") != 6127 or animator.world_pose.size() != animator.data.bones.size() or not _valid_mesh(animator.data.get("mesh"), animator.world_pose.size()):
		return false
	var mesh_data: Dictionary = animator.data.mesh
	var materials: Array[StandardMaterial3D] = []
	for source in mesh_data.materials:
		var material := StandardMaterial3D.new()
		material.albedo_texture = load(mesh_data.textures[int(source.texture)].path)
		if material.albedo_texture == null:
			return false
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.roughness = 1.0
		materials.append(material)
	_surfaces.clear()
	for source in mesh_data.surfaces:
		var surface: Dictionary = source.duplicate(true)
		for vertex in surface.vertices:
			for influence in vertex:
				influence.bone = int(influence.bone)
				influence.local_bind = _vector(influence.local_bind)
		surface.indices = PackedInt32Array(surface.indices)
		var uvs := PackedVector2Array()
		for uv in surface.uvs:
			uvs.append(Vector2(uv[0], uv[1]))
		surface.uvs = uvs
		_surfaces.append(surface)
	_materials = materials
	_data = animator.data
	lift = -float(mesh_data.standing_min_y) * 0.01
	if _instance == null:
		_instance = MeshInstance3D.new()
		add_child(_instance)
	_mesh = ArrayMesh.new()
	_instance.mesh = _mesh
	_instance.position.y = lift
	update_pose(animator)
	return true

func set_hit_flash(active: bool) -> void:
	for material in _materials:
		material.emission_enabled = active
		material.emission = Color("ff7850")
		material.emission_energy_multiplier = 0.7

func sync_transform(state: Dictionary) -> void:
	position = state.position*0.01
	rotation.y = int(state.yaw)*TAU/65536.0

func sync(state: Dictionary, animator: HunterAnimator) -> void:
	sync_transform(state)
	update_pose(animator)

func update_pose(animator: HunterAnimator) -> void:
	if _data.is_empty() or not is_same(animator.data, _data) or animator.world_pose.size() != _data.bones.size():
		return
	vertices.clear()
	_mesh.clear_surfaces()
	_instance.position.y = lift
	for surface in _surfaces:
		var points := PackedVector3Array()
		for vertex in surface.vertices:
			var point := Vector3.ZERO
			for influence in vertex:
				point += (animator.world_pose[influence.bone] * influence.local_bind) * float(influence.weight)
			points.append(point * 0.01)
		vertices.append(points)
		var normals := PackedVector3Array()
		normals.resize(points.size())
		for i in range(0, surface.indices.size(), 3):
			var a: int = surface.indices[i]
			var b: int = surface.indices[i + 1]
			var c: int = surface.indices[i + 2]
			var normal: Vector3 = (points[b] - points[a]).cross(points[c] - points[a])
			normals[a] += normal
			normals[b] += normal
			normals[c] += normal
		for i in range(normals.size()):
			normals[i] = normals[i].normalized()
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = points
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = surface.uvs
		arrays[Mesh.ARRAY_INDEX] = surface.indices
		_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_mesh.surface_set_material(_mesh.get_surface_count() - 1, _materials[int(surface.material)])
