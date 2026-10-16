class_name SandboxSpecial
extends RefCounted

const Geometry = preload("res://scripts/attack_events.gd")
const MOVES = {
	"laser":{"windup":36,"active":24,"recovery":30,"damage":20,"impact":20,"radius":0.35},
	"stink":{"windup":30,"active":45,"recovery":30,"damage":12,"impact":5,"radius":2.2},
	"tusk":{"windup":30,"active":20,"recovery":24,"damage":15,"impact":15,"radius":0.22,"half_length":0.45,"speed":0.45,"range":8.0,"ttl":20,"count":1},
	"slam":{"windup":30,"ascent":45,"hover":24,"lock":24,"descent":10,"active":6,"recovery":60,"height":5.0,"track_speed":0.08,"ascent_budget":1.2,"track_budget":2.0,"spin_step":0x1800,"landing_speed":0.25,"radius":2.0,"interval":360,"damage":25,"impact":25},
}
const ARENA_HALF = 10.0
const SLAM = MOVES.slam
var landing_point := Vector3.ZERO
var _base_yaw: int = 0
var _travel: float = 0.0
var cancelled: bool = false
var kind: String = ""
var stage: String = ""
var age: int = 0
var attack_id: int = 0
var origin := Vector3.ZERO
var yaw: int = 0
var _history: Dictionary = {}
# One bounded projectile slot; producer owns motion, history and lifetime, never the view.
var projectile: Dictionary = {}

func airborne() -> bool:
	return kind == "slam" and origin.y > 0.0

func cancel() -> void:
	if airborne():
		cancelled = true
		stage = "landing"
		_history.clear()
	else:
		reset()

func _slam_tick(observed: Variant) -> void:
	if cancelled:
		origin.y = move_toward(origin.y,0.0,SLAM.landing_speed)
		if origin.y == 0.0:
			reset()
		return
	var lift_tick: int = age-SLAM.windup
	var lock_tick: int = SLAM.windup+SLAM.ascent+SLAM.hover
	var drop_tick: int = lock_tick+SLAM.lock
	var impact_tick: int = drop_tick+SLAM.descent
	if age < SLAM.windup:
		stage = "windup"
		yaw = (yaw+int(SLAM.spin_step*float(age)/SLAM.windup*0.25))&65535
	elif age < lock_tick:
		stage = "ascent" if lift_tick < SLAM.ascent else "hover"
		origin.y = SLAM.height*minf(float(lift_tick)/SLAM.ascent,1.0)
		yaw = (yaw+SLAM.spin_step)&65535
		var track_limit: float = SLAM.ascent_budget if stage == "ascent" else SLAM.track_budget
		if observed is Vector3 and _travel < track_limit:
			var delta: Vector3 = observed*0.01-origin
			delta.y = 0
			var step: Vector3 = delta.limit_length(minf(SLAM.track_speed,track_limit-_travel))
			origin += step
			_travel += step.length()
	elif age < drop_tick:
		if age == lock_tick:
			landing_point = Vector3(origin.x,0,origin.z)
		stage = "locked"
		yaw = (yaw+SLAM.spin_step)&65535
	elif age < impact_tick:
		stage = "descent"
		origin.y = SLAM.height*(1.0-float(age-drop_tick)/SLAM.descent)
		yaw = (yaw+SLAM.spin_step)&65535
	elif age < impact_tick+SLAM.active:
		stage = "active"
		origin = landing_point
	elif age < impact_tick+SLAM.active+SLAM.recovery:
		stage = "recovery"
		var delta: int = ((_base_yaw-yaw+32768)&65535)-32768
		yaw = (yaw+clampi(delta,-0x1000,0x1000))&65535
	else:
		reset()

func reset() -> void:
	kind = ""
	stage = ""
	age = 0
	_history.clear()
	projectile.clear()
	cancelled = false
	_travel = 0.0
	landing_point = Vector3.ZERO

func begin(move: String, position: Vector3, facing: int) -> bool:
	if not MOVES.has(move):
		return false
	reset()
	kind = move
	stage = "windup"
	origin = position*0.01
	yaw = facing & 65535
	_base_yaw = yaw
	landing_point = Vector3(origin.x,0,origin.z)
	attack_id += 1
	return true

func _forward() -> Vector3:
	return Vector3(0,0,1).rotated(Vector3.UP,yaw*TAU/65536.0)

func mouth() -> Vector3:
	return origin+Vector3(0,1.05,0)+_forward()*1.35

func tick(observed: Variant = null) -> void:
	if kind == "":
		return
	age += 1
	if kind == "slam":
		_slam_tick(observed)
		return
	var move: Dictionary = MOVES[kind]
	if age >= move.windup+move.active+move.recovery:
		reset()
	elif age >= move.windup+move.active:
		stage = "recovery"
		projectile.clear()
	elif age >= move.windup:
		stage = "active"
		if kind == "tusk":
			if age == move.windup:
				var start := mouth()
				var bound: float = ARENA_HALF-move.radius-move.half_length
				if maxf(absf(start.x),absf(start.z)) <= bound:
					projectile = {"active":true,"position":start,"previous":start,"age":0,"distance":0.0,"expired":false}
			elif projectile.get("active",false):
				projectile.previous = projectile.position
				projectile.age += 1
				var travel: float = minf(move.speed,move.range-float(projectile.distance))
				var forward := _forward()
				var bound: float = ARENA_HALF-move.radius-move.half_length
				for axis in [0,2]:
					if absf(forward[axis]) > 0.00001:
						travel = minf(travel,maxf(0.0,(signf(forward[axis])*bound-projectile.position[axis])/forward[axis]))
				projectile.position += forward*travel
				projectile.distance += travel
				projectile.expired = travel < move.speed or projectile.distance >= move.range or projectile.age >= move.ttl

func volume() -> Dictionary:
	if kind == "" or kind == "tusk":
		return {}
	if kind == "slam":
		return {"kind":"capsule","a":landing_point+Vector3(0,0.4,0),"b":landing_point+Vector3(0,1.2,0),"radius":SLAM.radius} if stage == "active" else {}
	var forward := _forward()
	if kind == "laser":
		var start: Vector3 = origin+Vector3(0,1.05,0)+forward*0.8
		return {"kind":"capsule","a":start,"b":start+forward*10.0,"radius":MOVES.laser.radius}
	return {"kind":"sphere","a":origin-forward+Vector3(0,0.7,0),"radius":MOVES.stink.radius}

func _projectile_sweep() -> Dictionary:
	var extent: Vector3 = _forward()*MOVES.tusk.half_length
	return {"kind":"capsule","a":projectile.previous-extent,"b":projectile.position+extent,"radius":MOVES.tusk.radius}

# One attack-wide target history (one tusk per launch), including multiple hurtboxes.
func contacts(targets: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if stage != "active" or (kind == "tusk" and not projectile.get("active",false)):
		return result
	var shape: Dictionary = _projectile_sweep() if kind == "tusk" else volume()
	for target in targets:
		var identity: Array = [target.identity,target.generation]
		if not target.eligible or _history.has(identity):
			continue
		for hurtbox in target.volumes:
			if Geometry.volumes_intersect(shape,hurtbox):
				_history[identity] = true
				result.append({"event":"contact","attack_id":attack_id,"special":kind,"position":shape.a,"target_identity":target.identity,"target_generation":target.generation,"damage":MOVES[kind].damage,"impact":MOVES[kind].impact,"policy":"original_sandbox_move; inspiration only, not original game rules"})
				if kind == "tusk":
					projectile.active = false
				break
		if kind == "tusk" and not projectile.active:
			break
	if kind == "tusk" and projectile.expired:
		projectile.active = false
	return result

func snapshot() -> Dictionary:
	return {"kind":kind,"stage":stage,"age":age,"attack_id":attack_id,"origin":origin,"yaw":yaw,"volume":volume(),"mouth":mouth(),"projectile":projectile.duplicate(true),"landing_point":landing_point,"tracked_distance":_travel,"cancelled":cancelled,"airborne":airborne(),"name":"helicopter_slam" if kind == "slam" else kind}
