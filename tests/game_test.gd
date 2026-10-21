extends SceneTree
## Mechanics and map checks. Run: godot --headless --path . --script res://tests/game_test.gd

const Levels := preload("res://scripts/levels.gd")
const World := preload("res://scripts/world.gd")
const Sim := preload("res://scripts/sim.gd")
const Autopilot := preload("res://scripts/autopilot.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func make(map: Array, extra := {}) -> World:
	var level := {"map": map}
	level.merge(extra)
	var w := World.new()
	w.setup(level)
	return w


func _init() -> void:
	test_maps()
	test_light()
	test_guard_vision()
	test_alcove()
	test_pipe_unseen()
	test_shoot_lamp()
	test_noise()
	test_takedown()
	test_laser()
	test_keycard()
	test_danger_grid_matches()
	print("GAME OK" if fails == 0 else "FAIL: %d checks failed" % fails)
	quit(0 if fails == 0 else 1)


func test_maps() -> void:
	for i in Levels.LEVELS.size():
		var L: Dictionary = Levels.LEVELS[i]
		var rows: Array = L["map"]
		for r in rows:
			check(r.length() == rows[0].length(), "level %d rows differ in width" % (i + 1))
		var text := "".join(rows)
		check(text.count("P") == 1, "level %d needs exactly one P" % (i + 1))
		check(text.count("X") == 1, "level %d needs exactly one X" % (i + 1))
		check(text.count("R") == 0 or text.count("K") == 1, "level %d has a locked door but no keycard" % (i + 1))
		var w := World.new()
		w.setup(L)
		check(w.supported(w.start, false), "level %d: player starts in mid-air" % (i + 1))
		check(w.lamps.size() <= 8, "level %d: too many lamps for the autopilot's mask" % (i + 1))
		check(w.guards.size() <= 4, "level %d: too many guards for the autopilot's ko mask" % (i + 1))
		for g in w.guards:
			check(w.cell(Vector2i(g["x0"], g["row"])) != "#", "level %d: guard inside a wall" % (i + 1))


const CORRIDOR := [
	"####################",
	"#..................#",
	"#..........L.......#",
	"#..................#",
	"#.P................#",
	"####################",
]


func test_light() -> void:
	var w := make(CORRIDOR)
	check(w.light_level(Vector2i(11, 4), 0) == World.LIT, "tile under a lamp should be lit")
	check(w.light_level(Vector2i(2, 4), 0) == World.DARK, "far tile should be dark")
	check(w.light_level(Vector2i(11, 4), 1) == World.DARK, "shot lamp gives no light")


func test_guard_vision() -> void:
	var w := make(CORRIDOR, {"guards": [{"row": 4, "x0": 18, "face": -1, "wait": 0}]})
	var s := w.guard_at(0, 0)
	check(w.guard_sees(0, s, Vector2i(11, 4), 0) == 7, "guard sees a lit tile 7 away")
	check(w.guard_sees(0, s, Vector2i(11, 4), 1) == -1, "guard can't see 7 away in the dark")
	check(w.guard_sees(0, s, Vector2i(17, 4), 1) == 1, "guard sees you adjacent even in the dark")
	check(w.guard_sees(0, s, Vector2i(11, 3), 0) == -1, "guards only look along their own row")
	var p := make(CORRIDOR, {"guards": [{"row": 4, "x0": 2, "x1": 10, "step": 10, "wait": 30}]})
	check(p.guard_at(0, 0)["face"] == 1 and p.guard_at(0, 50)["x"] == 7.0, "patrol walks right")
	check(p.guard_at(0, 100)["face"] == 1 and p.guard_at(0, 100)["x"] == 10.0, "patrol waits at the end")
	check(p.guard_at(0, 140)["face"] == -1, "patrol turns back")
	check(p.guard_at(0, p.guards[0]["cycle"])["x"] == 2.0, "patrol loops")


func test_alcove() -> void:
	var map := CORRIDOR.duplicate()
	map[4] = "#.P..O.............#"
	var w := make(map, {"guards": [{"row": 4, "x0": 8, "face": -1, "wait": 0}]})
	var s := w.guard_at(0, 0)
	check(w.guard_sees(0, s, Vector2i(5, 4), 0) == -1, "dark alcove hides you")
	check(w.guard_sees(0, s, Vector2i(4, 4), 0) == -1, "dark open floor 4 away is safe")
	check(not w.danger(0, Vector2i(5, 4), 0), "no bump danger in an alcove")


func test_pipe_unseen() -> void:
	var map := CORRIDOR.duplicate()
	map[3] = "#....==========....#"
	var w := make(map, {"guards": [{"row": 4, "x0": 12, "face": -1, "wait": 0}]})
	var sim := Sim.new()
	sim.setup(w)
	sim.tile = Vector2i(5, 4)
	_run(sim, {"dir": Vector2i.UP}, Sim.GRAB + 1)
	check(sim.hanging and sim.tile == Vector2i(5, 3), "UP under a pipe grabs it")
	for k in 10:
		_run(sim, {"dir": Vector2i.RIGHT}, Sim.SHIMMY)
	check(sim.tile.x >= 13 and sim.outcome == "" and sim.detection == 0.0, "shimmy over a lit guard unseen (at %s)" % sim.tile)
	_run(sim, {"dir": Vector2i.DOWN}, 20)
	check(not sim.hanging and sim.tile.y == 4, "DOWN drops off the pipe")


func test_shoot_lamp() -> void:
	var w := make(CORRIDOR, {"ammo": 1})
	var sim := Sim.new()
	sim.setup(w)
	sim.tile = Vector2i(6, 4)
	_run(sim, {"shoot": true}, 1)
	_run(sim, {}, Sim.SHOOT + 2)
	check(sim.mask == 1 and sim.ammo == 0, "shooting breaks the lamp and uses ammo")
	check(w.light_level(Vector2i(11, 4), sim.mask) == World.DARK, "it's dark after")


func test_noise() -> void:
	var w := make(CORRIDOR, {"guards": [{"row": 4, "x0": 10, "face": 1, "wait": 0}]})
	var sim := Sim.new()
	sim.setup(w)
	sim.tile = Vector2i(5, 4)
	_run(sim, {"dir": Vector2i.RIGHT, "run": true}, Sim.RUN + 2)
	check(sim.noises_heard == 1 and sim.guard_state[0]["look"] == -1, "running nearby makes a guard turn")
	var quiet := Sim.new()
	quiet.setup(w)
	quiet.tile = Vector2i(5, 4)
	_run(quiet, {"dir": Vector2i.RIGHT}, Sim.SNEAK + 2)
	check(quiet.noises_heard == 0, "sneaking is silent")


func test_takedown() -> void:
	var w := make(CORRIDOR, {"guards": [{"row": 4, "x0": 8, "face": 1, "wait": 0}]})
	var sim := Sim.new()
	sim.setup(w)
	sim.tile = Vector2i(7, 4)
	_run(sim, {"takedown": true}, 1)
	check(sim.guard_state[0]["ko"] and sim.kos == 1, "takedown from behind works")
	var front := make(CORRIDOR, {"guards": [{"row": 4, "x0": 8, "face": -1, "wait": 0}]})
	var s2 := Sim.new()
	s2.setup(front)
	s2.tile = Vector2i(7, 4)
	check(s2.takedown_target() == -1, "no takedown from the front")


func test_laser() -> void:
	var w := make(CORRIDOR, {"lasers": [{"x": 4, "y0": 3, "y1": 4, "on": 10, "off": 10}]})
	check(w.laser_on(0, 0) and not w.laser_on(0, 15), "laser cycles")
	var sim := Sim.new()
	sim.setup(w)
	_run(sim, {"dir": Vector2i.RIGHT}, 40)
	check(sim.outcome == "caught" and sim.caught_by == "tripped a laser", "walking into a live laser trips the alarm")


func test_keycard() -> void:
	var map := CORRIDOR.duplicate()
	map[4] = "#.P..R..K..........#"
	var w := make(map)
	var sim := Sim.new()
	sim.setup(w)
	_run(sim, {"dir": Vector2i.RIGHT}, 60)
	check(sim.tile.x == 4, "locked door stops you")
	sim.has_key = true
	_run(sim, {"dir": Vector2i.RIGHT}, 60)
	check(sim.tile.x > 5, "keycard opens it")


## The autopilot's precomputed grid must agree with world.danger() exactly,
## or it could plan a route the real game catches.
func test_danger_grid_matches() -> void:
	for i in Levels.LEVELS.size():
		var w := World.new()
		w.setup(Levels.LEVELS[i])
		for t in [0, 37, 300, 777]:
			var g := Autopilot.danger_grid(w, t, 0, 0)
			for y in w.h:
				for x in w.w:
					if bool(g[y * w.w + x]) != w.danger(t, Vector2i(x, y), 0):
						check(false, "level %d danger grid differs at %d,%d t=%d" % [i + 1, x, y, t])
						return


func _run(sim: Sim, input: Dictionary, ticks: int) -> void:
	for k in ticks:
		sim.step(input)
