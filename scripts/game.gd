extends Node2D
## Dimmer Switch: runs the missions, draws everything, handles menus and saves.
##
## The rules live in world.gd (what's lit, who sees what, as functions of
## time) and sim.gd (one tick of play). This node only turns key presses into
## sim input, steps the sim at 60 ticks a second in _physics_process, and
## draws the result in _draw(). There are no sprites: every shape is drawn in
## code each frame.

const Levels := preload("res://scripts/levels.gd")
const World := preload("res://scripts/world.gd")
const Sim := preload("res://scripts/sim.gd")
const Autopilot := preload("res://scripts/autopilot.gd")
const Figures := preload("res://scripts/figures.gd")
const TouchControls := preload("res://scripts/touch_controls.gd")

const T := World.TILE
const HUD_H := 70.0
const SAVE_PATH := "user://progress.cfg"
const WATTS_PER_LAMP := 60
const MAX_ZOOM := 1.5
const PORTRAIT_ZOOM := 1.6

enum State { MENU, BRIEF, PLAYING, PAUSED, CAUGHT, COMPLETE }

# Palette. The world is a dark, cold night; lamps are warm; you glow green.
const C_BG := Color(0.02, 0.03, 0.06)
const C_AIR_DARK := Color(0.035, 0.045, 0.075)
const C_AIR_LIT := Color(0.46, 0.39, 0.24)
const C_WALL_DARK := Color(0.09, 0.10, 0.14)
const C_WALL_LIT := Color(0.34, 0.31, 0.26)
const C_LAMP := Color(1.0, 0.86, 0.5)
const C_GOGGLE := Color(0.35, 1.0, 0.45)
const C_SUIT := Color(0.05, 0.06, 0.08)
const C_SUIT_EDGE := Color(0.32, 0.38, 0.46)
const C_GUARD := Color(0.36, 0.40, 0.50)
const C_GUARD_DARK := Color(0.20, 0.22, 0.28)
const C_SIGHT := Color(1.0, 0.25, 0.2)
const C_EXIT := Color(0.3, 1.0, 0.6)
const C_KEY := Color(0.3, 0.85, 1.0)
const C_DOOR := Color(0.72, 0.45, 0.2)
const C_LOCK := Color(0.9, 0.2, 0.25)
const C_TEXT := Color(0.86, 0.9, 0.95)
const C_DIM_TEXT := Color(0.55, 0.6, 0.68)
const C_ALERT := Color(1.0, 0.3, 0.25)
const C_WARN := Color(1.0, 0.8, 0.25)

var screen := Vector2(1280, 720)   # layout size; 720x1280 in portrait
var portrait := false              # 9:16 for phones and Shorts (--portrait)
var state := State.MENU
var level_index := 0
var world: World
var sim: Sim
var origin := Vector2.ZERO   # world drawing happens in map pixels; _wx maps them to the screen
var zoom := 1.0
var cam_x := 0.0              # map x (pixels) shown at the centre of the screen
var _wx := Transform2D()
var night_vision := false
var unlocked := 1
var best_times := {}
var best_ratings := {}
var save_enabled := true
var menu_cursor := 0
var font: Font
var figures   # scripts/figures.gd: draws the agent and the guards
var touch := false   # on-screen controls (phones, tablets; --touch to test with a mouse)
var _touch = null    # scripts/touch_controls.gd when touch is on
var _menu_rows: Array[Rect2] = []   # where each mission row was drawn, for taps

# Buffered presses: a tap during a move still happens when the move ends.
var _want_shoot := false
var _want_takedown := false
var _flash := 0.0          # white flash when a lamp shatters
var _shake := 0.0
var _sv := Vector2.ZERO     # this frame's screen-shake offset
var _corner_cache := PackedFloat32Array()
var _corner_cache_mask := -1
var _shards: Array[Dictionary] = []   # falling glass {p, v, life}
var _anim := 0.0           # seconds, for bobbing and blinking
var _toast := ""
var _toast_timer := 0.0
var _new_best := false
var _caught_at := 0.0

# Dev flags (after `--` on the command line).
var autopilot := false
var trace := false
var reckless := false
var clumsy := false         # sneaks straight ahead into trouble (fail clips)
var exit_on_end := false
var log_events := false
var timeout := 0.0
var screenshot_path := ""
var screenshot_wait := 1.0
var clean := false          # hide dev labels in footage
var end_hold := 0.0        # seconds to keep showing the result before quitting
var nv_off_until := -1.0   # autopilot keeps the goggles off until this time (videos)
var _plan: Array = []
var _plan_next := 0
var _wall_time := 0.0


func _ready() -> void:
	font = ThemeDB.fallback_font
	figures = Figures.new(self, _c)
	_setup_input()
	_parse_flags()
	touch = DisplayServer.is_touchscreen_available() or "--touch" in OS.get_cmdline_user_args()
	if "--touch" in OS.get_cmdline_user_args():
		Input.emulate_touch_from_mouse = true   # a mouse stands in for a finger when testing
	if touch:
		_touch = TouchControls.new()
		add_child(_touch)   # a child draws after (on top of) this node
		_touch.tapped.connect(_on_tap)
		get_window().size_changed.connect(_fit_layout)
	_fit_layout()
	_load_progress()
	var forced := -1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--level="):
			forced = int(a.get_slice("=", 1))
	if forced >= 0:
		load_level(clampi(forced, 0, Levels.LEVELS.size() - 1))   # shows the briefing unless a bot plays
	else:
		state = State.MENU
	if screenshot_path != "":
		_take_screenshot_later()


## Picks the layout size. On desktop it's the project's 1280x720 (or what
## override.cfg says, for video recording). On a touch screen it follows the
## device's shape: upright phones get a 720-wide portrait layout, sideways
## ones a 720-tall landscape one, stretched to the real screen with no bars.
## Runs again when the phone rotates.
func _fit_layout() -> void:
	if touch:
		var win := DisplayServer.window_get_size()
		if win.x > 0 and win.y > 0:
			var size: Vector2i
			if win.y > win.x:
				size = Vector2i(720, maxi(1280, roundi(720.0 * win.y / win.x)))
			else:
				size = Vector2i(maxi(1280, roundi(720.0 * win.x / win.y)), 720)
			get_window().content_scale_size = size
			screen = Vector2(size)
	else:
		screen = get_viewport().get_visible_rect().size
	portrait = screen.y > screen.x
	if world != null:
		_fit_zoom()
		cam_x = _cam_target(true)
	if _touch:
		var band := Rect2(0, screen.y * 0.75, screen.x, screen.y * 0.25) if portrait else Rect2(0, screen.y - 170, screen.x, 170)
		_touch.layout(band, Vector2(screen.x - 62, HUD_H + 6) if not portrait else Vector2(screen.x - 62, 140))
		_touch.playing = state == State.PLAYING


## Taps outside the on-screen controls: menus and "tap to continue".
func _on_tap(pos: Vector2) -> void:
	match state:
		State.MENU:
			for i in _menu_rows.size():
				if _menu_rows[i].has_point(pos) and i < unlocked:
					menu_cursor = i
					load_level(i)
		State.BRIEF, State.PAUSED:
			state = State.PLAYING
		State.CAUGHT:
			load_level(level_index)
			state = State.PLAYING
		State.COMPLETE:
			if level_index + 1 < Levels.LEVELS.size():
				load_level(level_index + 1)
			else:
				_to_menu()


func _parse_flags() -> void:
	for a in OS.get_cmdline_user_args():
		match a.get_slice("=", 0):
			"--autopilot": autopilot = true
			"--trace": trace = true
			"--reckless": reckless = true
			"--clumsy": clumsy = true
			"--exit-on-end": exit_on_end = true
			"--log-events": log_events = true
			"--nv": night_vision = true
			"--clean": clean = true
			"--timeout": timeout = float(a.get_slice("=", 1))
			"--screenshot": screenshot_path = a.get_slice("=", 1)
			"--wait": screenshot_wait = float(a.get_slice("=", 1))
			"--end-hold": end_hold = float(a.get_slice("=", 1))
			"--nv-off-until": nv_off_until = float(a.get_slice("=", 1))
	if autopilot or reckless or clumsy or exit_on_end:
		save_enabled = false


## InputMap actions are created in code so the project file stays tiny.
## Each action lists the keys that trigger it.
func _setup_input() -> void:
	var map := {
		"left": [KEY_LEFT, KEY_A], "right": [KEY_RIGHT, KEY_D],
		"up": [KEY_UP, KEY_W], "down": [KEY_DOWN, KEY_S],
		"run": [KEY_SHIFT], "shoot": [KEY_F, KEY_J], "takedown": [KEY_E, KEY_K],
		"nv": [KEY_N, KEY_Q], "retry": [KEY_R], "back": [KEY_ESCAPE],
		"confirm": [KEY_ENTER, KEY_SPACE, KEY_KP_ENTER],
	}
	for action in map:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for k in map[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(action, ev)


# --- levels -----------------------------------------------------------------

func load_level(i: int) -> void:
	level_index = i
	world = World.new()
	world.setup(Levels.LEVELS[i])
	sim = Sim.new()
	sim.setup(world)
	# Zoom in as far as the building's height allows (capped so you still see
	# a guard's full sight line), then follow the agent sideways.
	_fit_zoom()
	cam_x = _cam_target(true)
	_want_shoot = false
	_want_takedown = false
	_shards.clear()
	_corner_cache = PackedFloat32Array()
	_new_best = false
	_plan = []
	_plan_next = 0
	if autopilot:
		var bot = Autopilot.new()
		bot.trace = trace
		_plan = bot.plan(world)
		if world.lasers.size() > 0 and nv_off_until < 0.0:
			night_vision = true
	state = State.BRIEF if not (autopilot or reckless or clumsy or exit_on_end) else State.PLAYING


# --- the loop ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_anim += delta
	_wall_time += delta
	_toast_timer = maxf(0.0, _toast_timer - delta)
	_flash = maxf(0.0, _flash - delta * 3.0)
	_shake = maxf(0.0, _shake - delta * 2.0)
	for s in _shards:
		s["v"] += Vector2(0, 900) * delta
		s["p"] += s["v"] * delta
		s["life"] -= delta
	_shards = _shards.filter(func(s): return s["life"] > 0.0)
	if timeout > 0.0 and _wall_time > timeout and exit_on_end:
		_report("timeout")
	if _touch and _touch.playing != (state == State.PLAYING):
		_touch.playing = state == State.PLAYING
		_touch.release_all()   # never leave a finger "stuck" on a control
	if world != null:
		cam_x = lerpf(cam_x, _cam_target(false), clampf(delta * 4.0, 0.0, 1.0))
	if state == State.PLAYING:
		if nv_off_until >= 0.0 and not night_vision and sim.tick >= int(nv_off_until * 60.0):
			night_vision = true
			if log_events:
				print("EVENT t=%.2f nv_on" % (sim.tick / 60.0))
		sim.step(_gather_input())
		_handle_events()
		if sim.outcome == "complete":
			_on_complete()
		elif sim.outcome == "caught":
			state = State.CAUGHT
			_caught_at = _anim
			_shake = 1.0
			if exit_on_end:
				_report("caught")
	queue_redraw()


func _fit_zoom() -> void:
	if portrait:
		zoom = minf(PORTRAIT_ZOOM, (screen.y * (0.5 if touch else 0.6)) / (world.h * T))
	else:
		var band := 170.0 if touch else 40.0
		zoom = minf(MAX_ZOOM, (screen.y - HUD_H - band) / (world.h * T))


func _cam_target(_snap: bool) -> float:
	var half := screen.x / 2.0 / zoom
	var map_w := world.w * T
	if map_w <= half * 2.0:
		return map_w / 2.0
	# Look ahead: keep more of the floor in front of him on screen (that's
	# where the guards and lamps he's dealing with are), and when he shoots,
	# frame the lamp too.
	var px: float = (sim.visual_pos().x + 0.5) * T
	var lead := half * 0.4
	var target := px + sim.face * lead
	if sim.action.get("type", "") == "shoot":
		var lamp: Vector2i = world.lamps[sim.action["lamp"]]
		target = (px + (lamp.x + 0.5) * T) / 2.0
	return clampf(target, half, map_w - half)


func _gather_input() -> Dictionary:
	if autopilot:
		if sim.wants_input() and _plan_next < _plan.size():
			_plan_next += 1
			return _plan[_plan_next - 1]
		return {}
	if reckless or clumsy:
		return {"dir": Vector2i.RIGHT, "run": reckless}
	var dir := Vector2i(int(Input.is_action_pressed("right")) - int(Input.is_action_pressed("left")),
		int(Input.is_action_pressed("down")) - int(Input.is_action_pressed("up")))
	var input := {"dir": dir, "run": Input.is_action_pressed("run")}
	if sim.wants_input():
		input["shoot"] = _want_shoot
		input["takedown"] = _want_takedown
		_want_shoot = false
		_want_takedown = false
	return input


func _handle_events() -> void:
	for e in sim.events:
		if log_events:
			print("EVENT t=%.2f %s" % [sim.tick / 60.0, e])
		match e:
			"shatter":
				_flash = 0.6
				_shake = 0.25
				var lamp: Vector2i = world.lamps[_last_shot_lamp()]
				var at := origin + Vector2(lamp) * T + Vector2(T / 2.0, 8)
				for k in 10:
					_shards.append({"p": at, "v": Vector2(randf_range(-120, 120), randf_range(-160, 20)), "life": 0.9})
				_toast = "-%dW  Lights out." % WATTS_PER_LAMP
				_toast_timer = 1.4
			"click":
				_toast = "Nothing to shoot." if sim.ammo > 0 else "Out of ammo."
				_toast_timer = 1.2
			"key":
				_toast = "Keycard acquired."
				_toast_timer = 1.6
			"locked":
				_toast = "Locked. Find the keycard."
				_toast_timer = 1.2
			"takedown":
				_toast = "Nap time."
				_toast_timer = 1.2
			"heard":
				_toast = "Huh? What was that?"
				_toast_timer = 1.2
			"objective":
				_toast = str(world.objective.get("done", "Done."))
				_toast_timer = 2.4
			"blackout":
				_flash = 0.9
				_shake = 0.6
			"exit_locked":
				_toast = "Not yet: " + str(world.objective.get("text", "finish the objective")) + "."
				_toast_timer = 1.8


func _last_shot_lamp() -> int:
	for i in range(world.lamps.size() - 1, -1, -1):
		if sim.mask & (1 << i):
			return i
	return 0


func _on_complete() -> void:
	state = State.COMPLETE
	var secs: float = sim.tick / 60.0
	var key := str(level_index)
	if not best_times.has(key) or secs < best_times[key]:
		best_times[key] = secs
		_new_best = true
	var r: String = sim.rating()
	var order := ["NOTICED", "SHADOW", "GHOST"]
	if not best_ratings.has(key) or order.find(r) > order.find(best_ratings[key]):
		best_ratings[key] = r
	unlocked = maxi(unlocked, mini(level_index + 2, Levels.LEVELS.size()))
	_save_progress()
	if exit_on_end:
		_report("complete")


func _report(what: String) -> void:
	print("RESULT level=%d %s time=%.2f rating=%s alerts=%d" % [
		level_index + 1, what, sim.tick / 60.0, sim.rating(), 1 if sim.outcome == "caught" else 0])
	if end_hold > 0.0:
		await get_tree().create_timer(end_hold).timeout
	get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	# Mouse clicks work in menus on desktop too (touch screens route through
	# the touch controls instead).
	if not touch and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if state != State.PLAYING:
			_on_tap(event.position)
		return
	# Keys, and the on-screen buttons (which send InputEventAction).
	if not (event is InputEventKey or event is InputEventAction) or not event.is_pressed() or event.is_echo():
		return
	match state:
		State.MENU:
			if event.is_action("up"):
				menu_cursor = (menu_cursor + Levels.LEVELS.size() - 1) % Levels.LEVELS.size()
			elif event.is_action("down"):
				menu_cursor = (menu_cursor + 1) % Levels.LEVELS.size()
			elif event.is_action("confirm") and menu_cursor < unlocked:
				load_level(menu_cursor)
		State.BRIEF:
			if event.is_action("confirm"):
				state = State.PLAYING
			elif event.is_action("back"):
				state = State.MENU
		State.PLAYING:
			if event.is_action("shoot"):
				_want_shoot = true
			elif event.is_action("takedown"):
				_want_takedown = true
			elif event.is_action("nv"):
				night_vision = not night_vision
			elif event.is_action("retry"):
				load_level(level_index)
				state = State.PLAYING
			elif event.is_action("back"):
				state = State.PAUSED
		State.PAUSED:
			if event.is_action("back") or event.is_action("confirm"):
				state = State.PLAYING
			elif event.is_action("retry"):
				load_level(level_index)
				state = State.PLAYING
			elif event.is_action("nv"):
				pass
			elif event is InputEventKey and event.keycode == KEY_M:
				_to_menu()
		State.CAUGHT:
			if event.is_action("retry") or event.is_action("confirm"):
				load_level(level_index)
				state = State.PLAYING
			elif event.is_action("back"):
				_to_menu()
		State.COMPLETE:
			if event.is_action("confirm"):
				if level_index + 1 < Levels.LEVELS.size():
					load_level(level_index + 1)
				else:
					_to_menu()
			elif event.is_action("retry"):
				load_level(level_index)
				state = State.PLAYING
			elif event.is_action("back"):
				_to_menu()


func _to_menu() -> void:
	state = State.MENU
	menu_cursor = mini(level_index + (1 if sim and sim.outcome == "complete" else 0), unlocked - 1)


# --- saves ------------------------------------------------------------------

func _load_progress() -> void:
	var cfg := ConfigFile.new()
	if not save_enabled or cfg.load(SAVE_PATH) != OK:
		return
	unlocked = cfg.get_value("progress", "unlocked", 1)
	best_times = cfg.get_value("progress", "best_times", {})
	best_ratings = cfg.get_value("progress", "best_ratings", {})
	menu_cursor = mini(unlocked - 1, Levels.LEVELS.size() - 1)


func _save_progress() -> void:
	if not save_enabled:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "unlocked", unlocked)
	cfg.set_value("progress", "best_times", best_times)
	cfg.set_value("progress", "best_ratings", best_ratings)
	cfg.save(SAVE_PATH)


func _take_screenshot_later() -> void:
	await get_tree().create_timer(screenshot_wait).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(screenshot_path)
	print("screenshot saved: ", screenshot_path)
	get_tree().quit()


# --- drawing ----------------------------------------------------------------

## Night vision trades colour for sight: everything turns green and the dark
## gets readable. Every world colour goes through here.
func _c(col: Color) -> Color:
	if not night_vision:
		return col
	var l := col.get_luminance()
	return Color(l * 0.3, clampf(0.08 + l * 1.5, 0.0, 1.0), l * 0.35, col.a)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, screen), C_BG)
	if state == State.MENU:
		_draw_menu()
		return
	_sv = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * _shake * 6.0
	var ty := HUD_H + (screen.y - HUD_H - (170.0 if touch else 34.0) - world.h * T * zoom) / 2.0
	if portrait:
		# Below where Shorts captions sit; higher on phones, above the controls.
		ty = screen.y * (0.47 if touch else 0.56) - world.h * T * zoom / 2.0
	_wx = Transform2D(0.0, Vector2(zoom, zoom), 0.0, Vector2(screen.x / 2.0 - cam_x * zoom, ty) + _sv)
	_draw_sky(ty)
	draw_set_transform_matrix(_wx)
	_draw_backdrop()
	_draw_tiles()
	_draw_lamps()
	_draw_lasers()
	_draw_cameras()
	var hidden := _player_hidden()
	if hidden:
		_draw_player()   # tucked into the doorway: guards pass in front of him
	_draw_guards()
	if not hidden:
		_draw_player()
	_draw_ducts_front()
	for s in _shards:
		draw_rect(Rect2(s["p"], Vector2(3, 3)), Color(1, 0.95, 0.8, clampf(s["life"], 0, 1)))
	draw_set_transform_matrix(Transform2D())
	if night_vision:
		_draw_nv_overlay()
	if _flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, screen), Color(1, 0.95, 0.8, _flash * 0.25))
	_draw_hud()
	match state:
		State.BRIEF: _draw_brief()
		State.PAUSED: _draw_panel("PAUSED", ["Tap to resume"] if touch else ["ESC / ENTER  resume", "R  restart mission", "M  mission select"], C_TEXT)
		State.CAUGHT: _draw_caught()
		State.COMPLETE: _draw_complete()


func _tile_rect(p: Vector2i) -> Rect2:
	return Rect2(origin + Vector2(p) * T, Vector2(T, T))


func _draw_tiles() -> void:
	var light: PackedFloat32Array = world.light_amounts(sim.mask)
	var corners := _corner_light(light)
	var player_tile: Vector2i = sim.occupied()
	for y in world.h:
		for x in world.w:
			var p := Vector2i(x, y)
			var r := _tile_rect(p)
			var ch: String = world.cell(p)
			if ch == "#":
				var a := 0.0
				for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
					var n: Vector2i = p + d
					if n.x >= 0 and n.y >= 0 and n.x < world.w and n.y < world.h:
						a = maxf(a, light[n.y * world.w + n.x] * 0.8)
				draw_rect(r, _c(C_WALL_DARK.lerp(C_WALL_LIT, a)))
				# A thin highlight on floors you can walk on, so ledges read clearly.
				if world.cell(p + Vector2i.UP) != "#":
					draw_rect(Rect2(r.position, Vector2(T, 3)), _c(Color(0.28, 0.32, 0.42).lerp(C_WALL_LIT * 1.3, a)))
				elif (x + y) % 3 == 0:
					draw_rect(Rect2(r.position + Vector2(4, 12), Vector2(10, 2)), _c(Color(0, 0, 0, 0.25)))
				continue
			var amt: float = light[y * world.w + x]
			# Smooth light: colour each corner by the average light around it
			# and let the GPU blend across the tile, so pools fade instead of
			# showing tile steps.
			var quad := PackedVector2Array([r.position, r.position + Vector2(T, 0), r.end, r.position + Vector2(0, T)])
			var qc := PackedColorArray()
			for corner in [Vector2i(x, y), Vector2i(x + 1, y), Vector2i(x + 1, y + 1), Vector2i(x, y + 1)]:
				qc.append(_c(C_AIR_DARK.lerp(C_AIR_LIT, corners[corner.y * (world.w + 1) + corner.x])))
			draw_polygon(quad, qc)
			match ch:
				"H":
					var rail := _c(Color(0.45, 0.42, 0.38).lerp(Color(0.8, 0.7, 0.5), amt))
					draw_line(r.position + Vector2(8, 0), r.position + Vector2(8, T), rail, 2.0)
					draw_line(r.position + Vector2(24, 0), r.position + Vector2(24, T), rail, 2.0)
					for k in 3:
						var yy := r.position.y + 5 + k * 11
						draw_line(Vector2(r.position.x + 8, yy), Vector2(r.position.x + 24, yy), rail, 2.0)
				"=":
					# The inside of an air duct, seen through its cut-away front.
					draw_rect(_duct_rect(p), _c(Color(0.05, 0.055, 0.07).lerp(Color(0.2, 0.18, 0.14), amt * 0.5)))
				"O":
					# A deep doorway recess: you step back into it, out of the corridor.
					var floor_y := r.end.y
					var door := Rect2(r.position.x + 3, floor_y - 54, T - 6, 54)
					var top_c := _c(Color(0.0, 0.0, 0.0, 0.85 if amt < World.DIM_AMOUNT else 0.5))
					var bot_c := _c(Color(0.02, 0.02, 0.03, 0.6 if amt < World.DIM_AMOUNT else 0.3))
					draw_polygon(PackedVector2Array([door.position, Vector2(door.end.x, door.position.y), door.end, Vector2(door.position.x, door.end.y)]),
						PackedColorArray([top_c, top_c, bot_c, bot_c]))
					var frame := _c(Color(0.25, 0.27, 0.33).lerp(Color(0.65, 0.56, 0.4), amt))
					draw_rect(Rect2(door.position.x - 3, door.position.y - 3, 3, door.size.y + 3), frame)
					draw_rect(Rect2(door.end.x, door.position.y - 3, 3, door.size.y + 3), frame)
					draw_rect(Rect2(door.position.x - 3, door.position.y - 4, door.size.x + 6, 4), frame)
				"D", "R":
					var open := player_tile == p
					var dc: Color = C_DOOR if ch == "D" else (C_LOCK if not sim.has_key else Color(0.35, 0.8, 0.45))
					if open:
						draw_rect(Rect2(r.position + Vector2(T - 6, 0), Vector2(6, T)), _c(dc.darkened(0.3)))
					else:
						draw_rect(Rect2(r.position + Vector2(4, 0), Vector2(T - 8, T)), _c(dc.darkened(0.45 - amt * 0.3)))
						draw_rect(Rect2(r.position + Vector2(4, 0), Vector2(T - 8, T)), _c(dc), false, 2.0)
						draw_circle(r.position + Vector2(T - 10, T * 0.55), 2.5, _c(dc.lightened(0.4)))
						if ch == "R":
							draw_rect(Rect2(r.position + Vector2(12, 10), Vector2(8, 7)), _c(Color(1, 0.9, 0.5)))
				"X":
					# Locked (grey, red light) until the objective is done.
					var open_exit: bool = sim.objective_done
					var ec: Color = C_EXIT if open_exit else Color(0.45, 0.48, 0.52)
					var glow := 0.6 + 0.4 * sin(_anim * 3.0)
					draw_rect(Rect2(r.position + Vector2(4, 2), Vector2(T - 8, T - 2)), _c(Color(ec, (0.18 * glow) if open_exit else 0.08)))
					draw_rect(Rect2(r.position + Vector2(4, 2), Vector2(T - 8, T - 2)), _c(ec), false, 2.0)
					_text(r.position + Vector2(T / 2.0, -6), "EXIT" if open_exit else "LOCKED", 12, _c(ec), HORIZONTAL_ALIGNMENT_CENTER)
					if not open_exit:
						draw_circle(r.position + Vector2(T / 2.0, 8), 2.5, Color(1, 0.2, 0.2, 0.6 + 0.4 * sin(_anim * 5.0)))
				"I":
					_draw_objective(r, amt)
				"K":
					if not sim.has_key:
						var bob := sin(_anim * 4.0) * 3.0
						draw_rect(Rect2(r.position + Vector2(9, 12 + bob), Vector2(14, 10)), _c(C_KEY))
						draw_rect(Rect2(r.position + Vector2(11, 15 + bob), Vector2(5, 2)), _c(Color(0.05, 0.2, 0.3)))


## The thing the mission is for, drawn by kind, with a pulsing marker
## until it's done.
func _draw_objective(r: Rect2, amt: float) -> void:
	var kind: String = world.objective.get("kind", "hack")
	var done: bool = sim.objective_done
	var fl := r.end.y
	var cx := r.position.x + T / 2.0
	var wood := _c(Color(0.32, 0.24, 0.17).lerp(Color(0.6, 0.45, 0.3), amt))
	var busy: bool = sim.action.get("type", "") == "interact"
	if kind in ["hack", "bug", "docs"]:
		draw_rect(Rect2(cx - 14, fl - 14, 28, 4), wood)               # desk top
		draw_rect(Rect2(cx - 12, fl - 10, 3, 10), wood.darkened(0.2))
		draw_rect(Rect2(cx + 9, fl - 10, 3, 10), wood.darkened(0.2))
	match kind:
		"hack":
			draw_rect(Rect2(cx - 9, fl - 29, 18, 13), _c(Color(0.15, 0.16, 0.18)))
			var scr := Color(0.3, 1.0, 0.5) if done else Color(0.3, 0.75, 1.0)
			draw_rect(Rect2(cx - 7, fl - 27, 14, 9), _c(Color(scr, 0.8)))
			if busy:
				for k in 3:
					var wl := fposmod(_anim * 40.0 + k * 5.0, 12.0)
					draw_rect(Rect2(cx - 6, fl - 26 + k * 3, wl, 1), _c(Color(0.05, 0.1, 0.15)))
			draw_rect(Rect2(cx - 2, fl - 16, 4, 2), _c(Color(0.15, 0.16, 0.18)))
		"bug":
			draw_rect(Rect2(cx - 6, fl - 19, 12, 5), _c(Color(0.12, 0.12, 0.13)))   # phone
			draw_rect(Rect2(cx - 8, fl - 22, 16, 3), _c(Color(0.18, 0.18, 0.2)))    # handset
			if done:
				draw_circle(Vector2(cx + 5, fl - 15), 1.5, Color(1, 0.2, 0.2, 0.5 + 0.5 * sin(_anim * 6.0)))
		"docs":
			if not done:
				draw_rect(Rect2(cx - 8, fl - 17, 16, 3), _c(Color(0.95, 0.8, 0.3)))   # folder
		"photo":
			var board := Rect2(cx - 13, fl - 48, 26, 18)
			draw_rect(board, _c(Color(0.15, 0.3, 0.6).lerp(Color(0.35, 0.5, 0.8), amt)))
			for k in 3:
				draw_line(board.position + Vector2(3, 4 + k * 5), board.position + Vector2(23 - k * 5, 4 + k * 5), _c(Color(0.85, 0.9, 1.0)), 1.0)
			draw_rect(board, _c(Color(0.75, 0.75, 0.8)), false, 1.5)
			if busy and fmod(_anim, 0.5) < 0.08:
				draw_rect(Rect2(board.position - Vector2(6, 6), board.size + Vector2(12, 12)), Color(1, 1, 1, 0.6))
		"item":
			draw_rect(Rect2(cx - 7, fl - 14, 14, 14), _c(Color(0.35, 0.37, 0.42)))   # pedestal
			draw_rect(Rect2(cx - 8, fl - 30, 16, 16), _c(Color(0.7, 0.85, 1.0, 0.25)))
			draw_rect(Rect2(cx - 8, fl - 30, 16, 16), _c(Color(0.7, 0.85, 1.0, 0.7)), false, 1.0)
			if not done:
				draw_circle(Vector2(cx, fl - 22), 4.0, Color(1, 0.95, 0.6, 0.9))
				draw_circle(Vector2(cx, fl - 22), 8.0, Color(1, 0.95, 0.6, 0.2 + 0.1 * sin(_anim * 4.0)))
		"switch":
			draw_rect(Rect2(cx - 11, fl - 46, 22, 30), _c(Color(0.35, 0.36, 0.3)))
			draw_rect(Rect2(cx - 11, fl - 46, 22, 30), _c(Color(0.95, 0.75, 0.1)), false, 1.5)
			var lever_end := Vector2(cx, fl - 22) if done else Vector2(cx, fl - 42)
			draw_line(Vector2(cx, fl - 32), lever_end, _c(Color(0.75, 0.75, 0.78)), 3.0)
			draw_circle(lever_end, 3.0, _c(Color(0.85, 0.15, 0.15)))
	if not done and not busy:
		var bob := sin(_anim * 4.0) * 3.0
		var my := fl - 62 + bob
		draw_colored_polygon(PackedVector2Array([Vector2(cx, my - 6), Vector2(cx + 5, my), Vector2(cx, my + 6), Vector2(cx - 5, my)]), C_WARN)


## An air duct runs high in the corridor, above the guards' caps. Its
## logical tile is the one below the ceiling row, but it's drawn up there.
func _duct_rect(p: Vector2i) -> Rect2:
	var r := _tile_rect(p)
	return Rect2(r.position.x, r.position.y - 16, T, 24)


## Front of the ducts, drawn after the player so he's inside them: top and
## bottom sheet metal, seams with rivets, a slatted underside, end caps.
func _draw_ducts_front() -> void:
	var light: PackedFloat32Array = world.light_amounts(sim.mask)
	for y in world.h:
		for x in world.w:
			var p := Vector2i(x, y)
			if world.cell(p) != "=":
				continue
			var amt: float = light[y * world.w + x]
			var metal := _c(Color(0.36, 0.39, 0.44).lerp(Color(0.78, 0.72, 0.58), amt))
			var dr := _duct_rect(p)
			draw_rect(Rect2(dr.position, Vector2(T, 4)), metal)
			draw_rect(Rect2(dr.position, Vector2(T, 1.5)), _c(metal.lightened(0.35)))
			draw_rect(Rect2(dr.position.x, dr.end.y - 4, T, 4), metal.darkened(0.15))
			for k in 4:   # slats on the underside
				draw_rect(Rect2(dr.position.x + 2 + k * 8, dr.end.y - 3, 5, 2), _c(Color(0.05, 0.05, 0.06)))
			draw_rect(Rect2(dr.end.x - 2, dr.position.y, 2, dr.size.y), metal.darkened(0.25))   # seam
			draw_circle(dr.position + Vector2(T - 5, 7), 1.1, metal.lightened(0.3))
			draw_circle(dr.position + Vector2(T - 5, dr.size.y - 7), 1.1, metal.lightened(0.3))
			for side in [-1, 1]:
				if world.cell(p + Vector2i(side, 0)) != "=":
					var ex := dr.position.x if side < 0 else dr.end.x - 5
					draw_rect(Rect2(ex, dr.position.y, 5, dr.size.y), metal)
					for k in 3:
						draw_rect(Rect2(ex + 1, dr.position.y + 5 + k * 5, 3, 2), _c(Color(0.05, 0.05, 0.06)))


## Light at each tile corner: the mean of the open tiles touching it.
func _corner_light(light: PackedFloat32Array) -> PackedFloat32Array:
	if _corner_cache_mask == sim.mask and _corner_cache.size() > 0:
		return _corner_cache
	var out := PackedFloat32Array()
	out.resize((world.w + 1) * (world.h + 1))
	for cy in world.h + 1:
		for cx in world.w + 1:
			var sum := 0.0
			var n := 0
			for t in [Vector2i(cx - 1, cy - 1), Vector2i(cx, cy - 1), Vector2i(cx - 1, cy), Vector2i(cx, cy)]:
				if t.x >= 0 and t.y >= 0 and t.x < world.w and t.y < world.h and not world.is_solid(t):
					sum += light[t.y * world.w + t.x]
					n += 1
			out[cy * (world.w + 1) + cx] = sum / n if n > 0 else 0.0
	_corner_cache = out
	_corner_cache_mask = sim.mask
	return out


## The building is a cut-away slice of a tower at night. The sky and the
## skyline are drawn in screen space and scroll slower than the building
## (parallax), which sells depth for free.
func _draw_sky(top: float) -> void:
	var sky := PackedVector2Array([Vector2(0, HUD_H), Vector2(screen.x, HUD_H), Vector2(screen.x, top), Vector2(0, top)])
	draw_polygon(sky, PackedColorArray([_c(Color(0.02, 0.03, 0.08)), _c(Color(0.02, 0.03, 0.08)), _c(Color(0.08, 0.09, 0.18)), _c(Color(0.08, 0.09, 0.18))]))
	var par := -cam_x * 0.15
	for k in 40:
		var sx := fposmod(float((k * 211) % 1280) + par * 0.3, screen.x)
		var sy := HUD_H + float((k * 97) % int(maxf(top - HUD_H - 10, 10)))
		var tw := 0.5 + 0.5 * sin(_anim * 1.5 + k)
		draw_circle(Vector2(sx, sy), 1.0, _c(Color(0.8, 0.85, 1.0, 0.25 + 0.4 * tw)))
	if top - HUD_H > 70:
		draw_circle(Vector2(1120, HUD_H + 40), 22.0, _c(Color(0.95, 0.93, 0.8, 0.9)))
		draw_circle(Vector2(1130, HUD_H + 34), 20.0, _c(Color(0.02, 0.03, 0.08)))
	for k in 24:
		var bx := fposmod(k * 74.0 + par, 24 * 74.0) - 74.0
		var bh := minf(30.0 + float((k * 53) % 90), top - HUD_H)
		draw_rect(Rect2(bx, top - bh, 66, bh), _c(Color(0.04, 0.05, 0.1)))
		for wy in range(int(top - bh + 8), int(top) - 6, 16):
			if (k * 5 + wy / 16) % 4 == 0:
				draw_rect(Rect2(bx + 10 + (wy % 3) * 14, wy, 7, 8), _c(Color(C_LAMP, 0.25)))


## Roof and street, in map pixels (drawn wide so panning never shows an edge).
func _draw_backdrop() -> void:
	var mw: float = world.w * T
	var bottom: float = world.h * T
	draw_rect(Rect2(0, -8, mw, 8), _c(Color(0.12, 0.13, 0.18)))
	draw_line(Vector2(120, -8), Vector2(120, -50), _c(Color(0.3, 0.3, 0.35)), 2.0)
	draw_circle(Vector2(120, -52), 2.5, Color(1, 0.2, 0.2, 0.5 + 0.5 * sin(_anim * 4.0)))
	draw_rect(Rect2(-2000, bottom, mw + 4000, 1200), _c(Color(0.05, 0.05, 0.07)))
	draw_rect(Rect2(-2000, bottom + 4, mw + 4000, 3), _c(Color(0.16, 0.17, 0.2)))
	# Sidewalk and the road below the cut-away.
	draw_rect(Rect2(-2000, bottom + 7, mw + 4000, 26), _c(Color(0.09, 0.09, 0.11)))
	draw_rect(Rect2(-2000, bottom + 33, mw + 4000, 5), _c(Color(0.2, 0.2, 0.23)))
	draw_rect(Rect2(-2000, bottom + 38, mw + 4000, 120), _c(Color(0.04, 0.04, 0.05)))
	var x := -400.0
	while x < mw + 400.0:
		draw_rect(Rect2(x + 60, bottom + 95, 50, 6), _c(Color(0.55, 0.5, 0.3, 0.6)))
		x += 160.0


func _draw_lamps() -> void:
	for i in world.lamps.size():
		var r := _tile_rect(world.lamps[i])
		var top := r.position + Vector2(T / 2.0, 0)
		draw_line(top, top + Vector2(0, 5), _c(Color(0.4, 0.4, 0.45)), 2.0)
		var shade := PackedVector2Array([top + Vector2(-5, 5), top + Vector2(5, 5), top + Vector2(10, 12), top + Vector2(-10, 12)])
		draw_colored_polygon(shade, _c(Color(0.3, 0.32, 0.36)))
		if sim.mask & (1 << i):
			draw_circle(top + Vector2(0, 13), 3.0, _c(Color(0.15, 0.15, 0.15)))
			continue
		var flicker := 0.92 + 0.08 * sin(_anim * 23.0 + i * 1.7)
		# A soft cone of light below the shade (purely visual: world.gd decides
		# what is actually lit).
		var cone := PackedVector2Array([top + Vector2(-9, 12), top + Vector2(9, 12), top + Vector2(70, 120), top + Vector2(-70, 120)])
		var cols := PackedColorArray([Color(C_LAMP, 0.22 * flicker), Color(C_LAMP, 0.22 * flicker), Color(C_LAMP, 0.0), Color(C_LAMP, 0.0)])
		if night_vision:
			for k in cols.size():
				cols[k] = _c(cols[k])
		draw_polygon(cone, cols)
		for k in 3:
			draw_circle(top + Vector2(0, 13), 14.0 - k * 4.0, _c(Color(C_LAMP, 0.10 + k * 0.08)))
		draw_circle(top + Vector2(0, 13), 3.5, _c(Color(1, 0.97, 0.85)))


func _draw_lasers() -> void:
	for i in world.lasers.size():
		var l: Dictionary = world.lasers[i]
		var x: float = origin.x + l["x"] * T + T / 2.0
		var y0: float = origin.y + l["y0"] * T
		var y1: float = origin.y + (l["y1"] + 1) * T
		var on: bool = world.laser_on(i, sim.tick)
		var em := Color(0.75, 0.15, 0.15) if on else Color(0.3, 0.12, 0.12)
		draw_rect(Rect2(x - 5, y0, 10, 4), _c(em))
		draw_rect(Rect2(x - 5, y1 - 4, 10, 4), _c(em))
		# The beam itself only shows through the goggles.
		if on and night_vision:
			draw_line(Vector2(x, y0 + 4), Vector2(x, y1 - 4), Color(1, 0.15, 0.1, 0.35), 7.0)
			draw_line(Vector2(x, y0 + 4), Vector2(x, y1 - 4), Color(1, 0.5, 0.45), 2.0)


func _draw_cameras() -> void:
	for i in world.cameras.size():
		var c: Dictionary = world.cameras[i]
		var eye: Vector2 = origin + world.camera_eye(i) * T
		var ang := deg_to_rad(world.camera_angle(i, sim.tick))
		var fov := deg_to_rad(c["fov"])
		var seeing: bool = world.camera_sees(i, sim.tick, sim.occupied(), sim.mask) >= 0.0
		var pts := PackedVector2Array([eye])
		var n := 10
		for k in n + 1:
			var a := ang - fov + 2.0 * fov * k / n
			pts.append(eye + Vector2.from_angle(a) * _ray_length(world.camera_eye(i), a, c["range"]) * T)
		var col := C_ALERT if seeing else C_WARN
		draw_colored_polygon(pts, _c(Color(col, 0.14)))
		var mount: Vector2 = origin + Vector2(c["pos"]) * T + Vector2(T / 2.0, 0)
		draw_rect(Rect2(mount + Vector2(-6, 0), Vector2(12, 4)), _c(Color(0.45, 0.47, 0.5)))
		draw_set_transform_matrix(_wx * Transform2D(ang, eye))
		draw_rect(Rect2(Vector2(-8, -5), Vector2(16, 10)), _c(Color(0.55, 0.57, 0.6)))
		draw_rect(Rect2(Vector2(8, -3), Vector2(4, 6)), _c(Color(0.2, 0.2, 0.22)))
		draw_set_transform_matrix(_wx)
		var blink := 1.0 if fmod(_anim, 1.0) < 0.5 else 0.3
		draw_circle(eye + Vector2(-4, -2), 2.0, Color(1, 0.2, 0.2, blink))


## How far a ray from `from` (tile units) travels before hitting a wall.
func _ray_length(from: Vector2, ang: float, max_len: float) -> float:
	var d := 0.0
	var dir := Vector2.from_angle(ang)
	while d < max_len:
		var p := from + dir * d
		if world.blocks_sight(Vector2i(int(floor(p.x)), int(floor(p.y)))):
			return d
		d += 0.2
	return max_len


func _draw_guards() -> void:
	for i in world.guards.size():
		var gs: Dictionary = sim.guard_state[i]
		var s: Dictionary = sim.guard_now(i)
		var x: float = s["x"]
		var row: int = s["tile"].y
		var foot := origin + Vector2(x * T + T / 2.0, (row + 1) * T)
		var face: int = s["face"]
		if gs["ko"]:
			figures.guard_down(foot, face, i)
			_text(foot + Vector2(0, -16 - fmod(_anim * 10.0, 8.0)), "z", 14, _c(C_DIM_TEXT), HORIZONTAL_ALIGNMENT_CENTER)
			continue
		# Sight line: the tiles where he would spot you right now. Brighter
		# tiles are seen from further away, so the band follows the light.
		var tile: Vector2i = s["tile"]
		var len: int = world.guard_view_length(i, s)
		for d in range(1, len + 1):
			var p := tile + Vector2i(face * d, 0)
			if world.guard_sees(i, s, p, sim.mask) >= 0 or world.cell(p) == "O":
				var a := 0.16 * (1.0 - float(d) / (len + 2))
				if world.cell(p) == "O" and world.guard_sees(i, s, p, sim.mask) < 0:
					continue
				draw_rect(Rect2(origin + Vector2(p) * T + Vector2(0, 6), Vector2(T, T - 6)), _c(Color(C_SIGHT, a + (0.12 if gs["seeing"] else 0.0))))
		if world.guards[i]["torch"]:
			var hand := foot + Vector2(face * 10, -20)
			var beam := PackedVector2Array([hand, hand + Vector2(face * World.TORCH_RANGE * T, -18), hand + Vector2(face * World.TORCH_RANGE * T, 22)])
			draw_polygon(beam, PackedColorArray([_c(Color(1, 0.95, 0.7, 0.35)), _c(Color(1, 0.95, 0.7, 0.0)), _c(Color(1, 0.95, 0.7, 0.0))]))
		var moving: bool = gs["stare"] == 0 and absf(float(world.guard_at(i, gs["lt"] + 1)["x"]) - x) > 0.0001
		var look := 2 if gs["seeing"] else (1 if gs["stare"] > 0 else 0)
		figures.guard(foot, face, fposmod(x * 0.5, 1.0), moving, look, world.guards[i]["torch"], i)
		if gs["seeing"]:
			_text(foot + Vector2(0, -50), "!", 22, C_ALERT, HORIZONTAL_ALIGNMENT_CENTER)
		elif gs["stare"] > 0:
			_text(foot + Vector2(0, -50), "?", 20, C_WARN, HORIZONTAL_ALIGNMENT_CENTER)


func _player_hidden() -> bool:
	var occ: Vector2i = sim.occupied()
	var still: bool = sim.action.is_empty() or sim.action["type"] == "wait"
	return world.cell(occ) == "O" and sim.light_here() <= World.DIM and still


func _draw_player() -> void:
	var vp: Vector2 = sim.visual_pos()
	var foot := origin + vp * T + Vector2(T / 2.0, T)
	var occ: Vector2i = sim.occupied()
	var rim: float = clampf(world.light_amounts(sim.mask)[occ.y * world.w + occ.x], 0.0, 1.0) * 0.7
	var a: Dictionary = sim.action
	var type: String = a.get("type", "")
	var prog: float = 0.0 if a.is_empty() else float(a["elapsed"]) / a["total"]
	var on_ladder: bool = world.cell(sim.tile) == "H" and world.cell(sim.tile + Vector2i.DOWN) != "#"
	var pose := "sneak"
	# One full stride per tile, so feet keep pace with the ground.
	var phase := prog
	var aim := Vector2.ZERO
	if type == "grab":
		pose = "climb"   # pulling himself up into the vent
	elif sim.hanging:
		pose = "crawl"
	elif type == "climb" or (a.is_empty() and on_ladder):
		pose = "climb"
	elif type == "run":
		pose = "run"
	elif type == "sneak":
		pass
	elif type in ["", "wait"]:
		pose = "idle"   # standing still: no stride, just a slow breath
		phase = _anim
	if _player_hidden():
		pose = "hide"
	elif type == "fall":
		pose = "fall"
	elif type == "shoot":
		pose = "shoot"
		aim = origin + Vector2(world.lamps[a.get("lamp", 0)]) * T + Vector2(T / 2.0, 13)
	elif type == "takedown":
		pose = "takedown"
	elif type == "interact":
		pose = "use"
		phase = _anim
	if pose == "hide":
		# Pressed into the shadows: drawn darker, only the goggles glow.
		figures.tint = func(c: Color) -> Color: return _c(c.darkened(0.5))
		figures.agent(foot, sim.face, pose, phase, night_vision, aim, 0.0)
		figures.tint = _c
		# The door frame in front of him sells that he's inside the recess.
		var r := _tile_rect(sim.occupied())
		var frame := _c(Color(0.25, 0.27, 0.33))
		draw_rect(Rect2(r.position.x, r.end.y - 57, 4, 57), frame)
		draw_rect(Rect2(r.end.x - 4, r.end.y - 57, 4, 57), frame)
		draw_rect(Rect2(r.position.x, r.end.y - 58, T, 4), frame)
		return
	figures.agent(foot, sim.face, pose, phase, night_vision, aim, rim)
	if type == "interact":
		var bar := Rect2(foot + Vector2(-20, -66), Vector2(40, 5))
		draw_rect(bar, Color(0.1, 0.1, 0.12, 0.9))
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * prog, bar.size.y)), C_WARN)


func _draw_nv_overlay() -> void:
	for y in range(0, int(screen.y), 4):
		draw_line(Vector2(0, y), Vector2(screen.x, y), Color(0, 0, 0, 0.12), 1.0)
	if not portrait:
		_text(Vector2(screen.x - 20, HUD_H + 26), "NV", 16, Color(C_GOGGLE, 0.8), HORIZONTAL_ALIGNMENT_RIGHT)


# --- HUD and overlays -------------------------------------------------------

func _text(pos: Vector2, s: String, size: int, col: Color, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	var w := width
	var p := pos
	if align == HORIZONTAL_ALIGNMENT_CENTER and width < 0:
		w = 1000.0
		p.x -= 500.0
	elif align == HORIZONTAL_ALIGNMENT_RIGHT and width < 0:
		w = 1000.0
		p.x -= 1000.0
	draw_string(font, p, s, align, w, size, col)


func _draw_hud() -> void:
	if portrait:
		_draw_hud_portrait()
		return
	draw_rect(Rect2(0, 0, screen.x, HUD_H - 6), Color(0.03, 0.04, 0.07, 0.95))
	draw_line(Vector2(0, HUD_H - 6), Vector2(screen.x, HUD_H - 6), Color(0.2, 0.25, 0.32), 2.0)
	_text(Vector2(20, 26), world.code, 14, C_GOGGLE)
	_text(Vector2(20, 50), world.name, 22, C_TEXT)
	# Light meter: the most important number in the game.
	var lx := 360.0
	_text(Vector2(lx, 22), "LIGHT", 12, C_DIM_TEXT)
	var lvl: int = sim.light_here()
	var names := ["DARK", "DIM", "LIT"]
	var cols := [Color(0.3, 0.45, 0.4), Color(0.75, 0.65, 0.35), Color(1.0, 0.85, 0.4)]
	for k in 3:
		var r := Rect2(lx + k * 62, 30, 58, 24)
		var on := k == lvl
		draw_rect(r, Color(cols[k], 0.85 if on else 0.12))
		_text(r.position + Vector2(29, 17), names[k], 13, Color(0.05, 0.05, 0.05) if on else C_DIM_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	if world.cell(sim.occupied()) == "O" and lvl <= World.DIM:
		_text(Vector2(lx + 190, 22), "HIDDEN", 12, C_GOGGLE, HORIZONTAL_ALIGNMENT_RIGHT)
	# Detection meter.
	var dx := 580.0
	_text(Vector2(dx, 22), "DETECTION", 12, C_DIM_TEXT)
	draw_rect(Rect2(dx, 30, 220, 24), Color(0.12, 0.13, 0.17))
	var det: float = sim.detection
	if det > 0.0:
		draw_rect(Rect2(dx, 30, 220 * det, 24), C_WARN.lerp(C_ALERT, det))
	draw_rect(Rect2(dx, 30, 220, 24), Color(0.35, 0.38, 0.45), false, 1.5)
	# Kit: ammo, keycard, goggles.
	var kx := 840.0
	_text(Vector2(kx, 22), "AMMO", 12, C_DIM_TEXT)
	for k in world.ammo:
		var filled: bool = k < sim.ammo
		draw_rect(Rect2(kx + k * 12, 32, 7, 20), C_WARN if filled else Color(0.2, 0.2, 0.24))
	if world.ammo == 0:
		_text(Vector2(kx, 50), "none", 14, C_DIM_TEXT)
	if world.keycard.x >= 0:
		_text(Vector2(kx + 80, 22), "KEY", 12, C_DIM_TEXT)
		draw_rect(Rect2(kx + 80, 32, 22, 16), C_KEY if sim.has_key else Color(0.2, 0.2, 0.24))
	_text(Vector2(kx + 130, 22), "GOGGLES", 12, C_DIM_TEXT)
	_text(Vector2(kx + 130, 50), "NV ON" if night_vision else ("off" if touch else "off  [N]"), 16, C_GOGGLE if night_vision else C_DIM_TEXT)
	_text(Vector2(screen.x - 20, 50), "%.1f s" % (sim.tick / 60.0), 20, C_TEXT, HORIZONTAL_ALIGNMENT_RIGHT)
	# Tip line under the map.
	if not clean and not touch:
		_text(Vector2(screen.x / 2.0, screen.y - 12), world.tip, 15, C_DIM_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	if _toast_timer > 0.0:
		var a := clampf(_toast_timer * 2.0, 0.0, 1.0)
		_text(Vector2(screen.x / 2.0, HUD_H + 30), _toast, 20, Color(C_TEXT, a), HORIZONTAL_ALIGNMENT_CENTER)
	if autopilot and not clean:
		_text(Vector2(screen.x - 20, 22), "AUTOPILOT", 12, C_GOGGLE, HORIZONTAL_ALIGNMENT_RIGHT)
	_draw_objective_line(Vector2(20, HUD_H + 22))


## "OBJECTIVE: ..." until it's done, then "EXTRACT".
func _draw_objective_line(at: Vector2) -> void:
	if world.objective.is_empty():
		return
	if sim.objective_done:
		_text(at, "EXTRACT  Get to the exit", 16, C_EXIT)
	else:
		_text(at, "OBJECTIVE  " + str(world.objective.get("text", "")), 16, C_WARN)


## Phones and Shorts: two compact rows on top. Toasts sit just above the
## building, where they don't collide with video captions.
func _draw_hud_portrait() -> void:
	draw_rect(Rect2(0, 0, screen.x, 104), Color(0.03, 0.04, 0.07, 0.95))
	draw_line(Vector2(0, 104), Vector2(screen.x, 104), Color(0.2, 0.25, 0.32), 2.0)
	_text(Vector2(18, 30), world.code + "  " + world.name, 22, C_TEXT)
	_text(Vector2(screen.x - 18, 30), "%.1f s" % (sim.tick / 60.0), 20, C_TEXT, HORIZONTAL_ALIGNMENT_RIGHT)
	var lvl: int = sim.light_here()
	var names := ["DARK", "DIM", "LIT"]
	var cols := [Color(0.3, 0.45, 0.4), Color(0.75, 0.65, 0.35), Color(1.0, 0.85, 0.4)]
	for k in 3:
		var r := Rect2(18 + k * 70, 52, 66, 34)
		var on := k == lvl
		draw_rect(r, Color(cols[k], 0.85 if on else 0.12))
		_text(r.position + Vector2(33, 23), names[k], 15, Color(0.05, 0.05, 0.05) if on else C_DIM_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	var dx := 250.0
	var dw := screen.x - dx - 18
	draw_rect(Rect2(dx, 52, dw, 34), Color(0.12, 0.13, 0.17))
	var det: float = sim.detection
	if det > 0.0:
		draw_rect(Rect2(dx, 52, dw * det, 34), C_WARN.lerp(C_ALERT, det))
	draw_rect(Rect2(dx, 52, dw, 34), Color(0.35, 0.38, 0.45), false, 1.5)
	_text(Vector2(dx + dw / 2.0, 75), "HIDDEN" if world.cell(sim.occupied()) == "O" and lvl <= World.DIM else "DETECTION", 15, C_GOGGLE if world.cell(sim.occupied()) == "O" and lvl <= World.DIM else C_DIM_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	_draw_objective_line(Vector2(18, 132))
	if _toast_timer > 0.0:
		var a := clampf(_toast_timer * 2.0, 0.0, 1.0)
		var top: float = _wx.origin.y - 40.0
		_text(Vector2(screen.x / 2.0, top), _toast, 30, Color(C_TEXT, a), HORIZONTAL_ALIGNMENT_CENTER)
	if night_vision:
		_text(Vector2(screen.x - 18, _wx.origin.y - 12), "NV", 18, Color(C_GOGGLE, 0.8), HORIZONTAL_ALIGNMENT_RIGHT)


func _draw_panel(title: String, lines: Array, col: Color) -> void:
	draw_rect(Rect2(Vector2.ZERO, screen), Color(0, 0, 0, 0.55))
	var h := 120.0 + lines.size() * 30.0
	var pw := minf(660.0, screen.x - 30.0)
	var r := Rect2(screen.x / 2.0 - pw / 2.0, screen.y / 2.0 - h / 2.0, pw, h)
	draw_rect(r, Color(0.04, 0.05, 0.08, 0.96))
	draw_rect(r, col, false, 2.0)
	_text(Vector2(screen.x / 2.0, r.position.y + 60), title, 40, col, HORIZONTAL_ALIGNMENT_CENTER)
	for k in lines.size():
		_text(Vector2(screen.x / 2.0, r.position.y + 105 + k * 30), lines[k], 19, C_TEXT, HORIZONTAL_ALIGNMENT_CENTER)


## A small briefing card: who, why, and the one thing to do.
func _draw_brief() -> void:
	draw_rect(Rect2(Vector2.ZERO, screen), Color(0, 0, 0, 0.45))
	var w := minf(600.0, screen.x - 30.0)
	var r := Rect2(screen.x / 2.0 - w / 2.0, screen.y / 2.0 - 120, w, 240)
	draw_rect(r, Color(0.03, 0.045, 0.07, 0.97))
	draw_rect(Rect2(r.position, Vector2(4, r.size.y)), C_GOGGLE)
	draw_rect(r, Color(C_GOGGLE, 0.6), false, 1.5)
	var x := r.position.x + 26
	_text(Vector2(x, r.position.y + 30), "MISSION BRIEFING  //  THIRD SHIFT", 13, C_GOGGLE)
	_text(Vector2(x, r.position.y + 64), "%s  %s" % [world.code, world.name], 26, C_TEXT)
	# Wraps onto a second line on narrow (phone) screens.
	draw_multiline_string(font, Vector2(x, r.position.y + 94), world.brief, HORIZONTAL_ALIGNMENT_LEFT, w - 50, 16, 2, C_DIM_TEXT)
	if not world.objective.is_empty():
		_text(Vector2(x, r.position.y + 140), "OBJECTIVE", 13, C_WARN)
		_text(Vector2(x, r.position.y + 164), str(world.objective.get("text", "")), 20, C_TEXT)
		_text(Vector2(x, r.position.y + 188), "then reach the EXIT", 14, C_DIM_TEXT)
	_text(Vector2(r.end.x - 20, r.end.y - 16), "TAP TO START" if touch else "ENTER", 14, C_GOGGLE, HORIZONTAL_ALIGNMENT_RIGHT)


func _draw_caught() -> void:
	var why: String = sim.caught_by
	var quip := {"spotted": "Somebody turned around.", "bumped into a guard": "Personal space, agent.",
		"tripped a laser": "Should've worn the goggles."}
	# Hold the panel back for a moment so the "!" and the alarm read first.
	var since := _anim - _caught_at
	draw_rect(Rect2(Vector2.ZERO, screen), Color(1, 0.1, 0.1, 0.18 * absf(sin(since * 9.0))))
	if since < 0.9:
		return
	var said := {"spotted": "were spotted"}
	_draw_panel("SPOTTED", ["You %s." % said.get(why, why), quip.get(why, ""), "", "Tap to retry" if touch else "R / ENTER retry    ESC missions"], C_ALERT)


func _draw_complete() -> void:
	var secs: float = sim.tick / 60.0
	var shots: int = world.ammo - sim.ammo
	var lines := [
		"Time  %.1f s%s" % [secs, "   NEW BEST" if _new_best and save_enabled else ""],
		"Rating  %s" % sim.rating(),
		"Done: " + str(world.objective.get("text", "")) if not world.objective.is_empty() else "",
		"Lamps shot %d  (%d W saved)   Takedowns %d" % [shots, shots * WATTS_PER_LAMP, sim.kos],
		"",
		("Tap for the next mission" if touch else "ENTER next mission    R replay    ESC missions") if level_index + 1 < Levels.LEVELS.size() else "Every shift done. Thanks for playing!",
	]
	_draw_panel("EXTRACTED", lines, C_EXIT)


func _draw_menu() -> void:
	# A dark city skyline with a few lit windows, for mood.
	for k in 26:
		var bx := k * 52.0
		var bh := 120.0 + float((k * 73) % 160)
		draw_rect(Rect2(bx, screen.y - bh, 48, bh), Color(0.05, 0.06, 0.1))
		for wy in range(int(screen.y - bh + 12), int(screen.y) - 10, 22):
			for wx in [8, 28]:
				if (k * 7 + wy / 22 + wx) % 5 == 0:
					draw_rect(Rect2(bx + wx, wy, 10, 12), Color(C_LAMP, 0.35))
	_text(Vector2(screen.x / 2.0, 110), "DIMMER SWITCH", 64, C_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	for k in 3:
		draw_circle(Vector2(screen.x / 2.0 - 16 + k * 16, 140 + (0 if k == 1 else 4)), 5.0, C_GOGGLE)
	if portrait:
		_text(Vector2(screen.x / 2.0, 180), "Every lamp is your enemy.", 20, C_DIM_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	else:
		_text(Vector2(screen.x / 2.0, 180), "A light-and-shadow stealth game. Every lamp is your enemy.", 20, C_DIM_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	var y0 := 230.0
	for i in Levels.LEVELS.size():
		var L: Dictionary = Levels.LEVELS[i]
		var locked := i >= unlocked
		var sel := i == menu_cursor
		var r := Rect2(screen.x / 2.0 - 300, y0 + i * 40, 600, 34)
		if touch and portrait:
			r = Rect2(screen.x / 2.0 - 300, y0 + i * 64, 600, 54)          # finger-sized rows
		elif touch:
			r = Rect2(screen.x / 2.0 + (10 if i >= 5 else -610), y0 + (i % 5) * 70, 600, 58)   # two columns
		if _menu_rows.size() <= i:
			_menu_rows.append(r)
		_menu_rows[i] = r
		draw_rect(r, Color(0.08, 0.12, 0.1, 0.95) if sel else Color(0.04, 0.05, 0.08, 0.9))
		if sel:
			draw_rect(r, C_GOGGLE, false, 2.0)
		var col := C_DIM_TEXT if locked else C_TEXT
		_text(r.position + Vector2(16, r.size.y / 2.0 + 6), L["code"], 16, C_GOGGLE if not locked else C_DIM_TEXT)
		_text(r.position + Vector2(100, r.size.y / 2.0 + 6), "LOCKED" if locked else L["name"], 18, col)
		var key := str(i)
		if best_times.has(key):
			_text(r.position + Vector2(584, r.size.y / 2.0 + 6), "%s  %.1f s" % [best_ratings.get(key, ""), best_times[key]], 15, C_DIM_TEXT, HORIZONTAL_ALIGNMENT_RIGHT)
	if touch:
		_text(Vector2(screen.x / 2.0, screen.y - 40), "Tap a mission to play", 18, C_DIM_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
		return
	_text(Vector2(screen.x / 2.0, screen.y - 40), "UP/DOWN choose   ENTER play   |   move WASD/arrows   SHIFT run   F shoot lamp   E use / takedown   N night vision", 15, C_DIM_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
