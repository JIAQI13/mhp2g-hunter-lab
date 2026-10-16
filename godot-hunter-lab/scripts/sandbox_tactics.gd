class_name SandboxTactics
extends RefCounted

var rng := RandomNumberGenerator.new()
var recent: Array[String] = []

func _init() -> void:
	rng.randomize()

func reset() -> void:
	recent.clear()

func selected(move: String) -> void:
	recent.append(move)
	if recent.size() > 4:
		recent.pop_front()

func choose(distance: float, relative: int, action: String, specials: bool, ranges: Dictionary, slam_available: bool = true) -> Dictionary:
	var side: bool = absi(relative) >= 0x2000
	var weights: Dictionary = {"charge":3.0 if distance > ranges.stink else 0.5,"turn_attack":4.0 if distance <= ranges.turn_attack and side else 0.0}
	if specials:
		weights.laser = (4.0 if action in ["weapon_action","charging_weapon","guard"] else 2.0) if distance >= 300 and not side and action != "evading" else 0.0
		weights.tusk = 5.0 if distance >= 300 and distance <= ranges.tusk and not side and action not in ["evading","guard"] else 0.0
		weights.stink = 5.0 if distance <= ranges.stink and absi(relative) >= 0x6000 else (2.0 if distance <= 450 else 0.0)
		weights.slam = (3.0 if action in ["weapon_action","charging_weapon","guard"] else 1.5) if slam_available and distance <= ranges.slam and action != "evading" else 0.0
	for move in weights:
		for prior in recent:
			if prior == move:
				weights[move] *= 0.5
		if not recent.is_empty() and recent[-1] in ["laser","tusk"] and move in ["laser","tusk"]:
			weights[move] *= 0.15
		if not recent.is_empty() and move == recent[-1]:
			weights[move] *= 0.25
	var total: float = 0.0
	for weight in weights.values():
		total += weight
	var draw: float = rng.randf_range(0,total)
	var chosen: String = "charge"
	for move in weights:
		draw -= weights[move]
		if draw <= 0:
			chosen = move
			break
	return {"move":chosen,"tactic":"approach" if distance > ranges[chosen] else "observe"}
