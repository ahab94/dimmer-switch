extends RefCounted
## The rules of one level as pure functions of time.
##
## Nothing here moves on its own: "where is guard 2 at tick 900?" or "is this
## tile lit when lamps 0 and 3 are shot out?" are plain function calls. The
## game asks about *now*; the autopilot asks about the future. Because both
## call the same functions, the bot's forecast can never drift from what the
## player sees.
##
## Time is counted in physics ticks (60 per second) and stays an int, so there
## is no floating-point drift between a real run and a forecast.

const TILE := 32

# Light levels a tile can have. Guards see further the brighter the tile.
const DARK := 0
const DIM := 1
const LIT := 2
const GUARD_RANGE := [1, 5, 9]     # tiles a guard can see you at, by light level
const CAMERA_RANGE := [0, 5, 8]    # cameras are blind in the dark
const TORCH_RANGE := 5             # a flashlight lights this many tiles ahead
const LAMP_RADIUS := 5.0
const LIT_AMOUNT := 0.4            # light amount (0..1) at or above this is LIT
const DIM_AMOUNT := 0.15
const SHOOT_RANGE := 9.0
const RUN_NOISE := 4.0             # guards within this many tiles hear you run
const SHATTER_NOISE := 3.0         # ...or hear a lamp break
# Ticks the objective takes, standing still at it (multiples of 6).
const OBJECTIVE_TICKS := {"hack": 60, "photo": 30, "bug": 48, "docs": 30, "item": 30, "switch": 30}


func objective_ticks() -> int:
	return OBJECTIVE_TICKS.get(objective.get("kind", "hack"), 60)


## The master switch (mission 10) puts out every lamp at once.
func objective_blackout() -> bool:
	return objective.get("kind", "") == "switch"


func all_lamps_mask() -> int:
	return (1 << lamps.size()) - 1

var name := ""
var code := ""
var brief := ""
var tip := ""
var w := 0
var h := 0
var rows: Array[String] = []
var start := Vector2i.ZERO
var exit := Vector2i(-1, -1)
var keycard := Vector2i(-1, -1)
var objective_tile := Vector2i(-1, -1)   # the I tile; none = exit always open
var objective := {}   # {kind, text, done}: what the mission is for
var ammo := 0
var lamps: Array[Vector2i] = []
var guards: Array[Dictionary] = []
var cameras: Array[Dictionary] = []
var lasers: Array[Dictionary] = []
var period := 1   # every enemy repeats after this many ticks (capped)

var _light_cache := {}   # lamp mask -> PackedFloat32Array of light amounts


func setup(level: Dictionary) -> void:
	name = level.get("name", "")
	code = level.get("code", "")
	brief = level.get("brief", "")
	tip = level.get("tip", "")
	ammo = level.get("ammo", 0)
	rows.clear()
	for r in level["map"]:
		rows.append(r)
	h = rows.size()
	w = rows[0].length()
	for y in h:
		for x in w:
			match rows[y][x]:
				"P": start = Vector2i(x, y)
				"X": exit = Vector2i(x, y)
				"K": keycard = Vector2i(x, y)
				"I": objective_tile = Vector2i(x, y)
				"L": lamps.append(Vector2i(x, y))
	objective = level.get("objective", {})
	for g in level.get("guards", []):
		guards.append(_make_guard(g))
	for c in level.get("cameras", []):
		var cam: Dictionary = c.duplicate()
		cam["range"] = cam.get("range", CAMERA_RANGE[LIT])
		cam["fov"] = cam.get("fov", 22.0)
		cameras.append(cam)
	for l in level.get("lasers", []):
		var las: Dictionary = l.duplicate()
		las["on"] = las.get("on", 0)
		las["off"] = las.get("off", 0)
		las["phase"] = las.get("phase", 0)
		lasers.append(las)
	_compute_period()


# --- map --------------------------------------------------------------------

func cell(p: Vector2i) -> String:
	if p.x < 0 or p.y < 0 or p.x >= w or p.y >= h:
		return "#"
	return rows[p.y][p.x]


func is_solid(p: Vector2i) -> bool:
	return cell(p) == "#"


## Doors block sight and light, but you can stand in one (that opens it).
func blocks_sight(p: Vector2i) -> bool:
	var c := cell(p)
	return c == "#" or c == "D" or c == "R"


func can_enter(p: Vector2i, has_key: bool) -> bool:
	var c := cell(p)
	if c == "#":
		return false
	if c == "R":
		return has_key
	return true


## Can the player rest on this tile without falling?
func supported(p: Vector2i, hanging: bool) -> bool:
	if hanging:
		return cell(p) == "="
	if cell(p) == "H":
		return true   # clinging to a ladder
	var below := cell(p + Vector2i.DOWN)
	return below == "#" or below == "H"


## Straight-line visibility between two points in tile units. We sample the
## line every quarter tile, which is plenty at this scale and much simpler
## than an exact grid walk. `target` itself is allowed to be a door tile
## (someone standing in a doorway can be seen).
func line_clear(a: Vector2, b: Vector2, target: Vector2i) -> bool:
	var dist := a.distance_to(b)
	var steps := int(ceil(dist * 4.0))
	for i in range(1, steps):
		var p := a.lerp(b, float(i) / steps)
		var t := Vector2i(int(floor(p.x)), int(floor(p.y)))
		if t != target and blocks_sight(t):
			return false
	return true


# --- light ------------------------------------------------------------------

func lamp_origin(i: int) -> Vector2:
	return Vector2(lamps[i]) + Vector2(0.5, 0.3)


## 0..1 brightness of every tile, given which lamps are shot out (bit i set
## means lamp i is broken). Cached per mask: there are only a few lamps.
func light_amounts(mask: int) -> PackedFloat32Array:
	if _light_cache.has(mask):
		return _light_cache[mask]
	var out := PackedFloat32Array()
	out.resize(w * h)
	for i in lamps.size():
		if mask & (1 << i):
			continue
		var o := lamp_origin(i)
		var r := int(ceil(LAMP_RADIUS))
		for y in range(lamps[i].y - r, lamps[i].y + r + 1):
			for x in range(lamps[i].x - r, lamps[i].x + r + 1):
				var t := Vector2i(x, y)
				if x < 0 or y < 0 or x >= w or y >= h or is_solid(t):
					continue
				var c := Vector2(x + 0.5, y + 0.5)
				var d := o.distance_to(c)
				if d >= LAMP_RADIUS or not line_clear(o, c, t):
					continue
				var a := 1.0 - d / LAMP_RADIUS
				out[y * w + x] = maxf(out[y * w + x], a)
	_light_cache[mask] = out
	return out


func light_level(p: Vector2i, mask: int) -> int:
	if p.x < 0 or p.y < 0 or p.x >= w or p.y >= h:
		return DARK
	var a := light_amounts(mask)[p.y * w + p.x]
	if a >= LIT_AMOUNT:
		return LIT
	if a >= DIM_AMOUNT:
		return DIM
	return DARK


## The lamp the player would shoot from tile `from`: the nearest unbroken lamp
## in range with a clear line. Shared by the game and the autopilot so they
## always agree on which bulb pops. Returns -1 if none.
func shoot_target(from: Vector2i, mask: int) -> int:
	var best := -1
	var best_d := INF
	var eye := Vector2(from) + Vector2(0.5, 0.4)
	for i in lamps.size():
		if mask & (1 << i):
			continue
		var o := lamp_origin(i)
		var d := eye.distance_to(o)
		if d <= SHOOT_RANGE and d < best_d and line_clear(eye, o, lamps[i]):
			best = i
			best_d = d
	return best


# --- guards -----------------------------------------------------------------
# A guard walks along one row between x0 and x1, pausing `wait` ticks at each
# end to look ahead, then turns around. With x0 == x1 he stands still and
# turns around every `wait` ticks (wait 0 = never turns). Optional "torch":
# he carries a flashlight, so tiles right in front of him count as lit.

func _make_guard(g: Dictionary) -> Dictionary:
	var out := g.duplicate()
	out["x1"] = g.get("x1", g["x0"])
	out["step"] = g.get("step", 20)
	out["wait"] = g.get("wait", 120)
	out["phase"] = g.get("phase", 0)
	out["face"] = g.get("face", 1)
	out["torch"] = g.get("torch", false)
	var walk: int = absi(out["x1"] - out["x0"]) * out["step"]
	if walk == 0:
		out["cycle"] = 2 * out["wait"] if out["wait"] > 0 else 1
	else:
		out["cycle"] = 2 * (walk + out["wait"])
	return out


## Where guard i is and which way he faces, `lt` ticks into his own clock.
## Returns {x: float tile column, tile: Vector2i, face: +1 right / -1 left}.
func guard_at(i: int, lt: int) -> Dictionary:
	var g := guards[i]
	var x0: int = g["x0"]
	var x1: int = g["x1"]
	var wait: int = g["wait"]
	var t: int = posmod(lt, g["cycle"])
	var x := float(x0)
	var face: int = g["face"]
	if x0 == x1:
		if wait > 0 and t >= wait:
			face = -face
	else:
		var dir := 1 if x1 > x0 else -1
		var walk: int = absi(x1 - x0) * g["step"]
		if t < walk:
			x = x0 + dir * float(t) / g["step"]
			face = dir
		elif t < walk + wait:
			x = x1
			face = dir
		elif t < 2 * walk + wait:
			x = x1 - dir * float(t - walk - wait) / g["step"]
			face = -dir
		else:
			x = x0
			face = -dir
	return {"x": x, "tile": Vector2i(int(floor(x + 0.5)), g["row"]), "face": face}


## How far guard i (in `state`) sees along his row before a wall, in tiles.
func guard_view_length(i: int, state: Dictionary) -> int:
	var tile: Vector2i = state["tile"]
	var face: int = state["face"]
	for d in range(1, GUARD_RANGE[LIT] + 1):
		if blocks_sight(tile + Vector2i(face * d, 0)):
			return d - 1
	return GUARD_RANGE[LIT]


## Does a guard in `state` see tile p? Guards look straight ahead along their
## own row: nobody ever looks up, which is what makes pipes useful.
## Returns the distance in tiles if seen, or -1.
func guard_sees(i: int, state: Dictionary, p: Vector2i, mask: int) -> int:
	var tile: Vector2i = state["tile"]
	if p.y != tile.y:
		return -1
	var face: int = state["face"]
	var d := (p.x - tile.x) * face
	if d < 1 or d > GUARD_RANGE[LIT]:
		return -1
	for k in range(1, d):
		if blocks_sight(tile + Vector2i(face * k, 0)):
			return -1
	var lvl := light_level(p, mask)
	if guards[i]["torch"] and d <= TORCH_RANGE:
		lvl = LIT
	if cell(p) == "O" and lvl <= DIM:
		return -1   # tucked into a shadowy alcove
	return d if d <= GUARD_RANGE[lvl] else -1


# --- cameras ----------------------------------------------------------------
# A camera hangs at `pos` and sweeps smoothly between angles a0 and a1
# (degrees, 0 = right, 90 = straight down) once per `period` ticks.

func camera_angle(i: int, t: int) -> float:
	var c := cameras[i]
	var s: float = float(posmod(t + c.get("phase", 0), c["period"])) / c["period"]
	var u := (1.0 - cos(TAU * s)) * 0.5
	return lerpf(c["a0"], c["a1"], u)


func camera_eye(i: int) -> Vector2:
	return Vector2(cameras[i]["pos"]) + Vector2(0.5, 0.25)


## Distance in tiles if camera i sees tile p at tick t, else -1. Cameras need
## light: shooting out the lamp near one blinds it.
func camera_sees(i: int, t: int, p: Vector2i, mask: int) -> float:
	var c := cameras[i]
	var eye := camera_eye(i)
	var target := Vector2(p) + Vector2(0.5, 0.5)
	var d := eye.distance_to(target)
	var lvl := light_level(p, mask)
	if cell(p) == "O" and lvl <= DIM:
		return -1.0
	if cell(p) == "=":
		return -1.0   # inside an air duct
	if d > minf(c["range"], CAMERA_RANGE[lvl]) or d < 0.1:
		return -1.0
	var ang := rad_to_deg((target - eye).angle())
	if absf(angle_difference(deg_to_rad(ang), deg_to_rad(camera_angle(i, t)))) > deg_to_rad(c["fov"]):
		return -1.0
	if not line_clear(eye, target, p):
		return -1.0
	return d


# --- lasers -----------------------------------------------------------------
# A vertical tripwire in column x from row y0 to y1. It cycles on for `on`
# ticks and off for `off` ticks; off 0 means always on.

func laser_on(i: int, t: int) -> bool:
	var l := lasers[i]
	if l["off"] <= 0:
		return true
	return posmod(t + l["phase"], l["on"] + l["off"]) < l["on"]


func laser_hits(i: int, t: int, p: Vector2i) -> bool:
	var l := lasers[i]
	return p.x == l["x"] and p.y >= l["y0"] and p.y <= l["y1"] and laser_on(i, t)


# --- the forecast the autopilot uses ----------------------------------------

## Is tile p dangerous at tick t if nobody has been disturbed? (Guard clocks
## then equal t + phase.) Covers being seen, bumping into a guard, and lasers.
## Bit i of `ko` means guard i is knocked out. Guards can walk past you while
## you hide in an alcove, so there is no bumping there.
func danger(t: int, p: Vector2i, mask: int, ko := 0) -> bool:
	for i in guards.size():
		if ko & (1 << i):
			continue
		var s := guard_at(i, t + guards[i]["phase"])
		if (s["tile"] == p and cell(p) != "O") or guard_sees(i, s, p, mask) >= 0:
			return true
	for i in cameras.size():
		if camera_sees(i, t, p, mask) >= 0.0:
			return true
	for i in lasers.size():
		if laser_hits(i, t, p):
			return true
	return false


## Would anyone notice a knocked-out guard at tick t? Only stationary guards
## (x0 == x1) can be planned around, since their body lies on a known tile.
func body_seen(t: int, mask: int, ko: int) -> bool:
	if ko == 0:
		return false
	for j in guards.size():
		if not (ko & (1 << j)):
			continue
		var body: Vector2i = guard_at(j, 0)["tile"]
		for i in guards.size():
			if ko & (1 << i):
				continue
			if guard_sees(i, guard_at(i, t + guards[i]["phase"]), body, mask) >= 0:
				return true
		for i in cameras.size():
			if camera_sees(i, t, body, mask) >= 0.0:
				return true
	return false


## Would a noise at `at` (tiles) with this radius reach any undisturbed guard?
func noise_heard(t: int, at: Vector2, radius: float, ko := 0) -> bool:
	for i in guards.size():
		if ko & (1 << i):
			continue
		var s := guard_at(i, t + guards[i]["phase"])
		if Vector2(s["x"] + 0.5, s["tile"].y + 0.5).distance_to(at) <= radius:
			return true
	return false


func _compute_period() -> void:
	var p := 1
	for g in guards:
		p = _lcm(p, g["cycle"])
	for c in cameras:
		p = _lcm(p, c["period"])
	for l in lasers:
		if l["off"] > 0:
			p = _lcm(p, l["on"] + l["off"])
	# A huge period just means the autopilot can't fold time; it still works.
	period = p if p <= 200000 else 0


static func _lcm(a: int, b: int) -> int:
	var x := a
	var y := b
	while y != 0:
		var r := x % y
		x = y
		y = r
	return a / x * b
