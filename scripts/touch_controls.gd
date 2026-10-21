extends Node2D
## On-screen controls for phones and tablets (including the browser version).
##
## Left thumb: a joystick. Push it sideways to sneak, all the way to run, up
## or down to climb ladders and use vents. Right thumb: USE (objective or
## takedown), SHOOT (nearest lamp) and NV (night vision). A pause button sits
## top-left. Everything presses the same input actions as the keyboard, so
## the game doesn't care where input came from.
##
## Touch basics in Godot: every finger has an index. InputEventScreenTouch
## fires when a finger lands or lifts; InputEventScreenDrag while it moves.
## We remember which finger owns the joystick so both thumbs work at once.
## Any other tap is reported through `tapped` (menus, "tap to continue").

signal tapped(position: Vector2)

const STICK_RADIUS := 78.0
const KNOB_RADIUS := 34.0
const DEADZONE := 0.3
const RUN_AT := 0.85          # push the stick this far to run
const GREEN := Color(0.35, 1.0, 0.45)
const AMBER := Color(1.0, 0.8, 0.3)

var playing := false   # set by the game: stick and buttons only during a mission

var stick_center := Vector2.ZERO
var pause_rect := Rect2()
var buttons := {}       # action -> {center, radius, label, color}

var _stick_finger := -1
var _knob := Vector2.ZERO
var _held := {}         # action -> finger index, for the button glow


## Places the controls. `band` is the screen area reserved for them.
func layout(band: Rect2, pause_pos: Vector2) -> void:
	var y := band.get_center().y
	stick_center = Vector2(band.position.x + STICK_RADIUS + 34.0, y)
	var right := band.end.x - 34.0
	buttons = {
		"takedown": {"center": Vector2(right - 58.0, y + 8.0), "radius": 58.0, "label": "USE", "color": AMBER},
		"shoot": {"center": Vector2(right - 170.0, y + 34.0), "radius": 42.0, "label": "SHOOT", "color": Color(1, 0.55, 0.4)},
		"nv": {"center": Vector2(right - 150.0, y - 58.0), "radius": 34.0, "label": "NV", "color": GREEN},
	}
	pause_rect = Rect2(pause_pos, Vector2(44, 38))
	queue_redraw()


func release_all() -> void:
	_stick_finger = -1
	_knob = Vector2.ZERO
	_held.clear()
	_apply(Vector2.ZERO)
	queue_redraw()


const MOUSE := 99   # a pseudo finger index, so a mouse (or a touch laptop) works too


func _input(event: InputEvent) -> void:
	# Treat the left mouse button like a finger. Real phones send touch
	# events instead (mouse emulation is off), so nothing fires twice.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var t := InputEventScreenTouch.new()
		t.index = MOUSE
		t.position = event.position
		t.pressed = event.pressed
		event = t
	elif event is InputEventMouseMotion and _stick_finger == MOUSE:
		var d := InputEventScreenDrag.new()
		d.index = MOUSE
		d.position = event.position
		event = d
	if event is InputEventScreenTouch:
		var p: Vector2 = event.position
		if event.pressed:
			if pause_rect.grow(14).has_point(p):
				_fire("back")
			elif playing and _stick_finger == -1 and p.distance_to(stick_center) < STICK_RADIUS * 1.8:
				_stick_finger = event.index
				_drag_stick(p)
			elif playing and _button_at(p) != "":
				var action := _button_at(p)
				_held[action] = event.index
				_fire(action)
				queue_redraw()
			else:
				tapped.emit(p)
		elif event.index == _stick_finger:
			_stick_finger = -1
			_knob = Vector2.ZERO
			_apply(Vector2.ZERO)
			queue_redraw()
		else:
			for action in _held.keys():
				if _held[action] == event.index:
					_held.erase(action)
					queue_redraw()
	elif event is InputEventScreenDrag and event.index == _stick_finger:
		_drag_stick(event.position)


func _button_at(p: Vector2) -> String:
	for action in buttons:
		var b: Dictionary = buttons[action]
		if p.distance_to(b["center"]) < b["radius"] * 1.15:
			return action
	return ""


func _drag_stick(p: Vector2) -> void:
	_knob = (p - stick_center).limit_length(STICK_RADIUS)
	_apply(_knob / STICK_RADIUS)
	queue_redraw()


## The game moves tile by tile, so the stick acts like a d-pad: the stronger
## axis wins. A full push sideways also holds "run".
func _apply(v: Vector2) -> void:
	var dir := Vector2i.ZERO
	if v.length() >= DEADZONE:
		if absf(v.x) >= absf(v.y):
			dir.x = signi(int(signf(v.x)))
		else:
			dir.y = signi(int(signf(v.y)))
	_hold("right", dir.x > 0)
	_hold("left", dir.x < 0)
	_hold("down", dir.y > 0)
	_hold("up", dir.y < 0)
	_hold("run", dir.x != 0 and absf(v.x) >= RUN_AT)


func _hold(action: String, on: bool) -> void:
	if on and not Input.is_action_pressed(action):
		Input.action_press(action)
	elif not on and Input.is_action_pressed(action):
		Input.action_release(action)


## One-shot actions (shoot, use, nv, pause) go through the normal input
## pipeline, exactly like a key press.
func _fire(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)


func _draw() -> void:
	var font := ThemeDB.fallback_font
	draw_rect(pause_rect, Color(0.03, 0.05, 0.08, 0.75))
	draw_rect(pause_rect, Color(GREEN, 0.8), false, 1.5)
	var c := pause_rect.get_center()
	draw_rect(Rect2(c + Vector2(-9, -10), Vector2(6, 20)), GREEN)
	draw_rect(Rect2(c + Vector2(3, -10), Vector2(6, 20)), GREEN)
	if not playing:
		return
	draw_circle(stick_center, STICK_RADIUS, Color(0.03, 0.05, 0.08, 0.5))
	draw_arc(stick_center, STICK_RADIUS, 0, TAU, 48, Color(GREEN, 0.5), 2.0)
	draw_arc(stick_center, STICK_RADIUS * RUN_AT, 0, TAU, 48, Color(GREEN, 0.18), 1.0)
	for k in 4:   # little arrows so it reads as a d-pad
		var d := Vector2.from_angle(k * PI / 2.0)
		var tip := stick_center + d * (STICK_RADIUS - 10.0)
		draw_colored_polygon(PackedVector2Array([tip, tip - d * 10 + d.orthogonal() * 7, tip - d * 10 - d.orthogonal() * 7]), Color(GREEN, 0.4))
	draw_circle(stick_center + _knob, KNOB_RADIUS, Color(GREEN, 0.5 if _stick_finger >= 0 else 0.3))
	draw_arc(stick_center + _knob, KNOB_RADIUS, 0, TAU, 32, GREEN, 2.0)
	if _knob.length() >= STICK_RADIUS * RUN_AT and absf(_knob.x) > absf(_knob.y):
		draw_string(font, stick_center + Vector2(-40, -STICK_RADIUS - 10), "RUN", HORIZONTAL_ALIGNMENT_CENTER, 80, 18, AMBER)
	for action in buttons:
		var b: Dictionary = buttons[action]
		var held := _held.has(action)
		var col: Color = b["color"]
		draw_circle(b["center"], b["radius"], Color(col, 0.55 if held else 0.22))
		draw_arc(b["center"], b["radius"], 0, TAU, 40, Color(col, 0.9), 2.5)
		var size := 22 if b["radius"] > 50 else 17
		draw_string(font, b["center"] + Vector2(-50, size * 0.35), b["label"], HORIZONTAL_ALIGNMENT_CENTER, 100, size, Color.WHITE)
