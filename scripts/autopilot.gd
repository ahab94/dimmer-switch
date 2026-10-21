extends RefCounted
## Plans a perfect, never-seen route through a level before it starts.
##
## It searches over (tile, hanging, lamps shot, keycard, time): every guard,
## camera and laser is a pure function of time (world.gd), so the bot can
## check "would I be seen if I step here at tick 840?" without simulating
## anything. This is A* where the cost is time, so the first route found is
## the fastest one that is never seen.
##
## Because the world repeats every `period` ticks, two visits to the same
## spot at the same point in the cycle are the same situation, which keeps
## the search small.
##
## The plan is a list of inputs, one per action, fed to the sim whenever the
## player is idle. Falls are automatic, so they produce no input.

const Sim := preload("res://scripts/sim.gd")
const World := preload("res://scripts/world.gd")
const Q := 6                 # time step: every action takes a multiple of this
const MAX_EXPANSIONS := 400000

var world
var trace := false
var expansions := 0
var _danger_memo := {}


func plan(level_world) -> Array:
	world = level_world
	var start := {"p": world.start, "hang": false, "mask": 0, "key": false, "ko": 0, "t": 0, "pen": 0, "last": ""}
	var open := _Heap.new()
	var seen := {}
	var parents := {}   # state key -> [parent key, input or null, state]
	var k0 := _key(start)
	parents[k0] = [null, null, start]
	open.push(_h(start), k0)
	seen[k0] = true
	expansions = 0
	while not open.empty():
		var key: int = open.pop()
		var s: Dictionary = parents[key][2]
		expansions += 1
		if expansions > MAX_EXPANSIONS:
			break
		if s["p"] == world.exit and world.supported(s["p"], s["hang"]):
			return _unwind(parents, key)
		for nxt in _successors(s):
			var ns: Dictionary = nxt[1]
			var nk := _key(ns)
			if seen.has(nk):
				continue
			seen[nk] = true
			var cls := _style(nxt[0])
			ns["pen"] = s["pen"] + _style_penalty(s["last"], cls)
			ns["last"] = cls if cls != "" else s["last"]
			parents[nk] = [key, nxt[0], ns]
			open.push(ns["t"] + _h(ns) + ns["pen"], nk)
	if trace:
		print("autopilot: no route after %d expansions" % expansions)
	return []


## Packs a state into one int (much faster to hash than a string).
func _key(s: Dictionary) -> int:
	var t: int = s["t"] % world.period if world.period > 0 else s["t"]
	var k: int = t / Q
	k = k * 16 + s["ko"]
	k = k * 2 + int(s["key"])
	k = k * 256 + s["mask"]
	k = k * 2 + int(s["hang"])
	k = k * 32 + s["p"].y
	return k * 64 + s["p"].x


# Style: among routes that are never seen, prefer ones that look like a
# person moving: keep a steady pace, don't dither back and forth, and wait
# in one go rather than in little stutters. These penalties only steer the
# search order (in ticks of "cost"); safety checks are unchanged.
const PACE_CHANGE := 30
const REVERSE := 60
const STOP_START := 18


static func _style(input) -> String:
	if input == null:
		return ""
	if input.has("wait"):
		return "wait"
	if input.has("shoot") or input.has("takedown"):
		return "act"
	var d: Vector2i = input["dir"]
	if d.y != 0:
		return "climb^" if d.y < 0 else "climbv"
	return ("run" if input.get("run", false) else "sneak") + (">" if d.x > 0 else "<")


static func _style_penalty(prev: String, cur: String) -> int:
	if prev == "" or cur == "" or prev == cur:
		return 0
	var pen := 0
	var ph := prev.begins_with("run") or prev.begins_with("sneak")
	var ch := cur.begins_with("run") or cur.begins_with("sneak")
	if ph and ch:
		if prev.right(1) != cur.right(1):
			pen += REVERSE
		if prev.left(3) != cur.left(3):
			pen += PACE_CHANGE
	if prev.begins_with("climb") and cur.begins_with("climb"):
		pen += REVERSE   # up then down (or down then up) is dithering
	elif ph != ch and not (prev == "wait" or cur == "wait"):
		pen += STOP_START / 2
	if (prev == "wait") != (cur == "wait"):
		pen += STOP_START
	return pen


## Estimated ticks to the exit (via the keycard if we still need it), at
## sneaking speed. That can overestimate, so routes aren't always the very
## fastest, but the search is many times quicker.
func _h(s: Dictionary) -> int:
	var p: Vector2i = s["p"]
	if world.keycard.x >= 0 and not s["key"]:
		return (_manhattan(p, world.keycard) + _manhattan(world.keycard, world.exit)) * Sim.SNEAK
	return _manhattan(p, world.exit) * Sim.SNEAK


static func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


func _unwind(parents: Dictionary, key: int) -> Array:
	var out: Array = []
	var k = key
	while parents[k][0] != null:
		if parents[k][1] != null:
			out.push_front(parents[k][1])
		k = parents[k][0]
	if trace:
		print("autopilot: %d actions, %d expansions" % [out.size(), expansions])
	return out


## Is it safe to be at tile a and/or b for every tick in (t, t+dur]?
func _safe(a: Vector2i, b: Vector2i, t: int, dur: int, mask: int, ko: int) -> bool:
	if not _safe_tile(a, t, dur, mask, ko):
		return false
	return b == a or _safe_tile(b, t, dur, mask, ko)


func _safe_tile(p: Vector2i, t: int, dur: int, mask: int, ko: int) -> bool:
	var idx: int = p.y * world.w + p.x
	for now in range(t + 1, t + dur + 1):
		if _grid(now, mask, ko)[idx]:
			return false
	return true


## Every dangerous tile at one tick, built once per (moment in the cycle,
## lamps, knockouts) and then reused: a few hundred checks per grid instead
## of re-asking every guard for every tile the search touches. It must agree
## exactly with world.danger(); tests/game_test.gd checks that.
func _grid(now: int, mask: int, ko: int) -> PackedByteArray:
	var tt: int = now % world.period if world.period > 0 else now
	var k: int = (tt * 16 + ko) * 256 + mask
	if _danger_memo.has(k):
		return _danger_memo[k]
	var g := danger_grid(world, now, mask, ko)
	_danger_memo[k] = g
	return g


static func danger_grid(w, now: int, mask: int, ko: int) -> PackedByteArray:
	var g := PackedByteArray()
	g.resize(w.w * w.h)
	if ko != 0 and w.body_seen(now, mask, ko):
		g.fill(1)
		return g
	for i in w.guards.size():
		if ko & (1 << i):
			continue
		var s: Dictionary = w.guard_at(i, now + w.guards[i]["phase"])
		var gt: Vector2i = s["tile"]
		if w.cell(gt) != "O":
			g[gt.y * w.w + gt.x] = 1
		for d in range(1, World.GUARD_RANGE[World.LIT] + 1):
			var p: Vector2i = gt + Vector2i(s["face"] * d, 0)
			if p.x < 0 or p.x >= w.w:
				break
			if w.guard_sees(i, s, p, mask) >= 0:
				g[p.y * w.w + p.x] = 1
	for i in w.cameras.size():
		var c: Dictionary = w.cameras[i]
		var r: int = int(ceil(c["range"]))
		var pos: Vector2i = c["pos"]
		for y in range(maxi(0, pos.y - r), mini(w.h, pos.y + r + 1)):
			for x in range(maxi(0, pos.x - r), mini(w.w, pos.x + r + 1)):
				if w.camera_sees(i, now, Vector2i(x, y), mask) >= 0.0:
					g[y * w.w + x] = 1
	for i in w.lasers.size():
		if w.laser_on(i, now):
			var l: Dictionary = w.lasers[i]
			for y in range(l["y0"], l["y1"] + 1):
				g[y * w.w + l["x"]] = 1
	return g


## Every action the player could take from state s that stays unseen.
## Each entry is [input or null (automatic), new state].
func _successors(s: Dictionary) -> Array:
	var out: Array = []
	var p: Vector2i = s["p"]
	var t: int = s["t"]
	var mask: int = s["mask"]
	var hang: bool = s["hang"]
	var key: bool = s["key"]
	var ko: int = s["ko"]
	if not world.supported(p, hang):
		_add(out, null, s, p + Vector2i.DOWN, false, Sim.FALL)
		return out
	_add(out, {"wait": Sim.WAIT}, s, p, hang, Sim.WAIT)
	for dx in [-1, 1]:
		var to := p + Vector2i(dx, 0)
		if not world.can_enter(to, key):
			continue
		if hang:
			if world.cell(to) == "=":
				_add(out, {"dir": Vector2i(dx, 0)}, s, to, true, Sim.SHIMMY)
			continue
		var on_ladder: bool = world.cell(p) == "H" and world.cell(p + Vector2i.DOWN) != "#"
		_add(out, {"dir": Vector2i(dx, 0)}, s, to, false, Sim.SNEAK)
		# Running is quick but loud: only when no guard could hear it land.
		var land := Vector2(to) + Vector2(0.5, 0.5)
		if not on_ladder and not world.noise_heard(t + Sim.RUN, land, World.RUN_NOISE + 0.5, ko) \
				and not world.noise_heard(t + Sim.RUN + 1, land, World.RUN_NOISE + 0.5, ko):
			_add(out, {"dir": Vector2i(dx, 0), "run": true}, s, to, false, Sim.RUN)
	var above := p + Vector2i.UP
	var below := p + Vector2i.DOWN
	if not hang:
		if world.cell(p) == "H" and world.can_enter(above, key):
			_add(out, {"dir": Vector2i.UP}, s, above, false, Sim.CLIMB)
		elif world.cell(above) == "=":
			_add(out, {"dir": Vector2i.UP}, s, above, true, Sim.GRAB)
		if world.cell(below) == "H":
			_add(out, {"dir": Vector2i.DOWN}, s, below, false, Sim.CLIMB)
	elif world.can_enter(below, key):
		_add(out, {"dir": Vector2i.DOWN}, s, below, false, Sim.FALL)
	if s.get("shots", 0) < world.ammo:
		var lamp: int = world.shoot_target(p, mask)
		if lamp >= 0:
			var at: Vector2 = world.lamp_origin(lamp)
			var safe_noise: bool = true
			for dt in [Sim.SHOOT, Sim.SHOOT + 1]:
				if world.noise_heard(t + dt, at, World.SHATTER_NOISE + 0.5, ko):
					safe_noise = false
			if safe_noise and _safe(p, p, t, Sim.SHOOT, mask, ko):
				var ns := s.duplicate()
				ns["t"] = t + Sim.SHOOT
				ns["mask"] = mask | (1 << lamp)
				ns["shots"] = s.get("shots", 0) + 1
				out.append([{"shoot": true}, ns])
	# Takedowns, only on guards who stand still (their body's tile is known).
	if not hang:
		for i in world.guards.size():
			var g: Dictionary = world.guards[i]
			if ko & (1 << i) or g["x0"] != g["x1"]:
				continue
			var gs: Dictionary = world.guard_at(i, t + g["phase"])
			var gt: Vector2i = gs["tile"]
			if gt.y == p.y and absi(gt.x - p.x) == 1 and gs["face"] == signi(gt.x - p.x):
				var nko: int = ko | (1 << i)
				if _safe(p, p, t, Sim.TAKEDOWN, mask, nko):
					var ns := s.duplicate()
					ns["t"] = t + Sim.TAKEDOWN
					ns["ko"] = nko
					out.append([{"takedown": true}, ns])
	return out


func _add(out: Array, input, s: Dictionary, to: Vector2i, hang: bool, dur: int) -> void:
	if not _safe(s["p"], to, s["t"], dur, s["mask"], s["ko"]):
		return
	var ns := s.duplicate()
	ns["p"] = to
	ns["hang"] = hang
	ns["t"] = s["t"] + dur
	if to == world.keycard:
		ns["key"] = true
	out.append([input, ns])


## A small binary min-heap of (priority, key) pairs.
class _Heap:
	var pri: Array[int] = []
	var keys: Array[int] = []

	func empty() -> bool:
		return pri.is_empty()

	func push(p: int, k: int) -> void:
		pri.append(p)
		keys.append(k)
		var i := pri.size() - 1
		while i > 0:
			var up := (i - 1) / 2
			if pri[up] <= pri[i]:
				break
			_swap(i, up)
			i = up

	func pop() -> int:
		var top := keys[0]
		var last := pri.size() - 1
		_swap(0, last)
		pri.pop_back()
		keys.pop_back()
		var i := 0
		var n := pri.size()
		while true:
			var l := 2 * i + 1
			var r := l + 1
			var m := i
			if l < n and pri[l] < pri[m]:
				m = l
			if r < n and pri[r] < pri[m]:
				m = r
			if m == i:
				break
			_swap(i, m)
			i = m
		return top

	func _swap(a: int, b: int) -> void:
		var tp := pri[a]
		pri[a] = pri[b]
		pri[b] = tp
		var tk := keys[a]
		keys[a] = keys[b]
		keys[b] = tk
