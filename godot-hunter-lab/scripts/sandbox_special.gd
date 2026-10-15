class_name SandboxSpecial
extends RefCounted

const Geometry = preload("res://scripts/attack_events.gd")
const MOVES = {
	"laser":{"windup":36,"active":24,"recovery":30,"damage":20,"impact":20,"radius":0.35},
	"stink":{"windup":30,"active":45,"recovery":30,"damage":12,"impact":5,"radius":2.2},
}
var kind: String = ""
var stage: String = ""
var age: int = 0
var attack_id: int = 0
var origin := Vector3.ZERO
var yaw: int = 0
var _history: Dictionary = {}

func reset() -> void:
	kind = ""
	stage = ""
	age = 0
	_history.clear()

func begin(move: String, position: Vector3, facing: int) -> bool:
	if not MOVES.has(move):
		return false
	reset()
	kind = move
	stage = "windup"
	origin = position*0.01
	yaw = facing & 65535
	attack_id += 1
	return true

func tick() -> void:
	if kind == "":
		return
	age += 1
	var move: Dictionary = MOVES[kind]
	if age >= move.windup+move.active+move.recovery:
		reset()
	elif age >= move.windup+move.active:
		stage = "recovery"
	elif age >= move.windup:
		stage = "active"

func volume() -> Dictionary:
	if kind == "":
		return {}
	var forward := Vector3(0,0,1).rotated(Vector3.UP,yaw*TAU/65536.0)
	if kind == "laser":
		var start: Vector3 = origin+Vector3(0,1.05,0)+forward*0.8
		return {"kind":"capsule","a":start,"b":start+forward*10.0,"radius":MOVES.laser.radius}
	return {"kind":"sphere","a":origin-forward+Vector3(0,0.7,0),"radius":MOVES.stink.radius}

# 一次攻击的时钟、固定几何与目标history由此对象独占；session仅提交incoming。
func contacts(targets: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if stage != "active":
		return result
	var shape := volume()
	for target in targets:
		var identity: Array = [target.identity,target.generation]
		if not target.eligible or _history.has(identity):
			continue
		for hurtbox in target.volumes:
			if Geometry.volumes_intersect(shape,hurtbox):
				_history[identity] = true
				result.append({"event":"contact","attack_id":attack_id,"special":kind,"position":shape.a,"target_identity":target.identity,"target_generation":target.generation,"damage":MOVES[kind].damage,"impact":MOVES[kind].impact,"policy":"original_sandbox_move; inspiration only, not original game rules"})
				break
	return result

func snapshot() -> Dictionary:
	return {"kind":kind,"stage":stage,"age":age,"attack_id":attack_id,"origin":origin,"yaw":yaw,"volume":volume()}
