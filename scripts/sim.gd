extends RefCounted
## One run of a level, advanced one physics tick at a time by step().
##
## The player moves tile to tile like in old cinematic platformers: every move
## takes a fixed number of ticks and is drawn as a smooth slide. That keeps
## the game fully deterministic (the autopilot can plan exact routes) while
## still looking fluid.
##
## Guards follow their patrol (world.gd) on their own clocks. When one gets
## suspicious he stops and stares, and his clock pauses; when he calms down he
## carries on from where he stopped, so the patrol never teleports.

const World := preload("res://scripts/world.gd")

# Ticks per action. All are multiples of 6, the autopilot's time step.
const SNEAK := 12
const RUN := 6
const CLIMB := 12
const SHIMMY := 18
const GRAB := 12
const FALL := 6
const SHOOT := 18
const TAKEDOWN := 24
const WAIT := 6

# The detection meter fills while anything sees you (faster up close) and
# drains slowly once you are out of sight. Full meter = alarm = mission over.
const SEE_BASE := 12.0      # ticks to fill when right next to a guard...
const SEE_PER_TILE := 5.0   # ...plus this many per tile of distance
const CAMERA_FILL := 40.0
const BODY_FILL := 30.0     # finding a knocked-out colleague is very alarming
const DECAY := 1.0 / 240.0
const NOISE_BUMP := 0.34
const CALM_AFTER := 90      # ticks unseen before a staring guard walks on
const HEARD_STARE := 120

var world
var tick := 0
var tile := Vector2i.ZERO
var hanging := false
var face := 1
var action := {}            # {} when idle, else {type, from, to, total, elapsed}
var mask := 0               # bit i set = lamp i shot out
var ammo := 0
var has_key := false
var objective_done := false   # true from the start when the mission has none
var detection := 0.0
var outcome := ""           # "", "complete" or "caught"
var caught_by := ""
var spotted := false        # the meter ever rose above zero
var kos := 0
var noises_heard := 0
var events: Array[String] = []
var _told_locked := false   # what happened this tick, for sounds and logs

# Per guard: {lt: own clock, ko: bool, stare: ticks left, look: facing override, seeing: bool}
var guard_state: Array[Dictionary] = []


func setup(level_world) -> void:
	world = level_world
	tile = world.start
	ammo = world.ammo
	objective_done = world.objective_tile.x < 0
	for g in world.guards:
		guard_state.append({"lt": g["phase"], "ko": false, "stare": 0, "look": 0, "seeing": false})


## The guard's position and facing right now, including staring overrides.
func guard_now(i: int) -> Dictionary:
	var s: Dictionary = world.guard_at(i, guard_state[i]["lt"])
	if guard_state[i]["stare"] > 0 and guard_state[i]["look"] != 0:
		s["face"] = guard_state[i]["look"]
	return s


## Where the player is drawn, in tile units (fractional during a move).
func visual_pos() -> Vector2:
	if action.is_empty():
		return Vector2(tile)
	var f: float = float(action["elapsed"]) / action["total"]
	return Vector2(action["from"]).lerp(Vector2(action["to"]), f)


## The tile that counts for being seen: the start of a move until halfway.
func occupied() -> Vector2i:
	if action.is_empty() or action["type"] in ["shoot", "takedown", "wait", "interact"]:
		return tile
	if action["elapsed"] * 2 < action["total"]:
		return action["from"]
	return action["to"]


## True when the next step() will read input: the current action ends this
## tick (or there is none) and the player won't be falling. The autopilot
## feeds its next move exactly then, so plans run tick-perfect.
func wants_input() -> bool:
	if action.is_empty():
		return world.supported(tile, hanging)
	if action["elapsed"] + 1 < action["total"]:
		return false
	return world.supported(action["to"], hanging or action["type"] == "grab")


func is_running() -> bool:
	return not action.is_empty() and action["type"] == "run"


func light_here() -> int:
	return world.light_level(occupied(), mask)


## input: {dir: Vector2i, run: bool, shoot: bool, takedown: bool, wait: int}
func step(input: Dictionary) -> void:
	events.clear()
	if outcome != "":
		return
	_advance_player(input)
	tick += 1
	_advance_guards()
	_detect()
	if outcome == "" and action.is_empty() and tile == world.exit:
		if objective_done:
			outcome = "complete"
			events.append("complete")
		elif not _told_locked:
			_told_locked = true
			events.append("exit_locked")
	if tile != world.exit:
		_told_locked = false


# --- player -----------------------------------------------------------------

func _advance_player(input: Dictionary) -> void:
	if not action.is_empty():
		action["elapsed"] += 1
		if action["elapsed"] >= action["total"]:
			_finish_action()
	if action.is_empty():
		_choose_action(input)


func _finish_action() -> void:
	var a := action
	action = {}
	tile = a["to"]
	match a["type"]:
		"grab":
			hanging = true
		"interact":
			objective_done = true
			events.append("objective")
			if world.objective_blackout():
				mask = world.all_lamps_mask()
				events.append("blackout")
		"run":
			_make_noise(Vector2(tile) + Vector2(0.5, 0.5), World.RUN_NOISE)
		"shoot":
			var lamp: int = a["lamp"]
			mask |= 1 << lamp
			events.append("shatter")
			_make_noise(world.lamp_origin(lamp), World.SHATTER_NOISE)
	if tile == world.keycard and not has_key:
		has_key = true
		events.append("key")


func _start(type: String, to: Vector2i, total: int) -> void:
	action = {"type": type, "from": tile, "to": to, "total": total, "elapsed": 0}


func _choose_action(input: Dictionary) -> void:
	# Gravity first: nothing to stand on means you fall, whatever you press.
	if not world.supported(tile, hanging):
		hanging = false
		_start("fall", tile + Vector2i.DOWN, FALL)
		return
	if input.get("wait", 0) > 0:
		_start("wait", tile, input["wait"])
		return
	if input.get("shoot", false):
		if ammo > 0:
			var lamp: int = world.shoot_target(tile, mask)
			if lamp >= 0:
				ammo -= 1
				face = 1 if world.lamps[lamp].x >= tile.x else -1
				_start("shoot", tile, SHOOT)
				action["lamp"] = lamp
				events.append("shot")
				return
		events.append("click")   # out of ammo or nothing to shoot
	# E is "use": the objective if you're standing at it, else a takedown.
	if (input.get("interact", false) or input.get("takedown", false)) and can_interact():
		_start("interact", tile, world.objective_ticks())
		events.append("interact")
		return
	if input.get("takedown", false):
		var g := takedown_target()
		if g >= 0:
			guard_state[g]["ko"] = true
			kos += 1
			face = 1 if guard_now(g)["tile"].x > tile.x else -1
			_start("takedown", tile, TAKEDOWN)
			events.append("takedown")
			return
	var dir: Vector2i = input.get("dir", Vector2i.ZERO)
	if dir.y < 0 and try_up():
		return
	if dir.y > 0 and try_down():
		return
	if dir.x != 0:
		try_side(dir.x, input.get("run", false))


func try_up() -> bool:
	var above := tile + Vector2i.UP
	if hanging:
		return false
	if world.cell(tile) == "H" and world.can_enter(above, has_key):
		_start("climb", above, CLIMB)
		return true
	if world.cell(above) == "=":
		_start("grab", above, GRAB)
		return true
	return false


func try_down() -> bool:
	var below := tile + Vector2i.DOWN
	if hanging:
		hanging = false
		_start("fall", below, FALL)
		events.append("drop")
		return true
	if world.cell(below) == "H":
		_start("climb", below, CLIMB)
		return true
	return false


func try_side(dx: int, run: bool) -> bool:
	face = dx
	var to := tile + Vector2i(dx, 0)
	if not world.can_enter(to, has_key):
		if world.cell(to) == "R":
			events.append("locked")
		return false
	if hanging:
		if world.cell(to) != "=":
			return false
		_start("shimmy", to, SHIMMY)
		return true
	var on_ladder: bool = world.cell(tile) == "H" and world.cell(tile + Vector2i.DOWN) != "#"
	if run and not on_ladder:
		_start("run", to, RUN)
	else:
		_start("sneak", to, SNEAK)
	return true


func can_interact() -> bool:
	return not objective_done and not hanging and tile == world.objective_tile


## A guard you can knock out: right next to you, on your row, facing away.
func takedown_target() -> int:
	if hanging:
		return -1
	for i in guard_state.size():
		if guard_state[i]["ko"]:
			continue
		var s := guard_now(i)
		var gt: Vector2i = s["tile"]
		if gt.y == tile.y and absi(gt.x - tile.x) == 1 and s["face"] == signi(gt.x - tile.x):
			return i
	return -1


# --- guards and detection ---------------------------------------------------

func _advance_guards() -> void:
	for gs in guard_state:
		if gs["ko"]:
			continue
		if gs["stare"] > 0:
			gs["stare"] -= 1
		else:
			gs["lt"] += 1


func _make_noise(at: Vector2, radius: float) -> void:
	for i in guard_state.size():
		var gs := guard_state[i]
		if gs["ko"]:
			continue
		var s := guard_now(i)
		var gp := Vector2(s["x"] + 0.5, s["tile"].y + 0.5)
		if gp.distance_to(at) <= radius:
			gs["stare"] = maxi(gs["stare"], HEARD_STARE)
			gs["look"] = 1 if at.x >= gp.x else -1
			detection = minf(1.0, detection + NOISE_BUMP)
			noises_heard += 1
			spotted = true
			events.append("heard")


func _detect() -> void:
	var p := occupied()
	var fill := 0.0
	for i in guard_state.size():
		var gs := guard_state[i]
		gs["seeing"] = false
		if gs["ko"]:
			continue
		var s := guard_now(i)
		if s["tile"] == p and world.cell(p) != "O":
			_caught("bumped into a guard")
			return
		var d: int = world.guard_sees(i, s, p, mask)
		if d >= 0:
			fill += 1.0 / (SEE_BASE + SEE_PER_TILE * d)
			gs["seeing"] = true
			gs["stare"] = CALM_AFTER
			gs["look"] = s["face"]
		# Bodies: a guard who sees a knocked-out colleague raises the alarm fast.
		for j in guard_state.size():
			if guard_state[j]["ko"] and world.guard_sees(i, s, guard_now(j)["tile"], mask) >= 0:
				fill += 1.0 / BODY_FILL
				gs["seeing"] = true
	for i in world.cameras.size():
		if world.camera_sees(i, tick, p, mask) >= 0.0:
			fill += 1.0 / CAMERA_FILL
		for j in guard_state.size():
			if guard_state[j]["ko"] and world.camera_sees(i, tick, guard_now(j)["tile"], mask) >= 0.0:
				fill += 1.0 / BODY_FILL
	for i in world.lasers.size():
		if world.laser_hits(i, tick, p):
			_caught("tripped a laser")
			return
	if fill > 0.0:
		if detection == 0.0:
			events.append("spotted")
		detection += fill
		spotted = true
	else:
		detection = maxf(0.0, detection - DECAY)
	if detection >= 1.0:
		_caught("spotted")


func _caught(why: String) -> void:
	detection = 1.0
	outcome = "caught"
	caught_by = why
	spotted = true
	events.append("caught")


## Ghost: never noticed, nobody knocked out. Shadow: never caught in the
## light but used takedowns. Otherwise you were noticed at some point.
func rating() -> String:
	if not spotted and kos == 0:
		return "GHOST"
	if not spotted:
		return "SHADOW"
	return "NOTICED"
