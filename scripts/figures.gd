extends RefCounted
## Draws the people: the agent and the guards, as jointed figures.
##
## Each figure is a little skeleton. A pose places the hips, the feet, the
## shoulders and the hands; knees and elbows are then solved with two-bone
## inverse kinematics (given where a foot must be, where must the knee go?).
## Limbs are drawn as thick rounded strokes with a darker outline, back limbs
## first and front limbs last, so the figures read clearly at 32 px tiles.
##
## Coordinates: `foot` is the point on the floor under the figure; "fwd" is
## +1 or -1 for which way it faces. Everything is drawn in screen pixels.

var canvas: CanvasItem
var tint: Callable   # colour filter (night vision), Color -> Color

const THIGH := 11.0
const SHIN := 11.0
const UPPER_ARM := 8.5
const FOREARM := 8.5

# The agent: matte black suit, dark harness, the famous three green lenses.
const A_SUIT := Color(0.07, 0.08, 0.10)
const A_SUIT_HI := Color(0.16, 0.18, 0.22)
const A_EDGE := Color(0.30, 0.36, 0.44)
const A_GEAR := Color(0.20, 0.21, 0.19)
const A_STRAP := Color(0.26, 0.24, 0.20)
const A_SKIN := Color(0.62, 0.48, 0.40)
const LENS := Color(0.35, 1.0, 0.45)

# Guards: navy uniform, khaki belt, peaked cap.
const G_SHIRT := Color(0.30, 0.36, 0.50)
const G_SHIRT_HI := Color(0.40, 0.47, 0.62)
const G_PANTS := Color(0.15, 0.17, 0.23)
const G_BELT := Color(0.42, 0.34, 0.20)
const G_BOOT := Color(0.08, 0.08, 0.09)
const G_EDGE := Color(0.05, 0.06, 0.08)
const SKINS := [Color(0.85, 0.66, 0.52), Color(0.62, 0.44, 0.32), Color(0.45, 0.30, 0.22), Color(0.92, 0.75, 0.62)]


func _init(on: CanvasItem, color_filter: Callable) -> void:
	canvas = on
	tint = color_filter


func _t(c: Color) -> Color:
	return tint.call(c)


## Where the middle joint (knee/elbow) goes so that two bones of lengths
## l1 and l2 reach from a to c. `bend` picks which side it bulges to.
static func ik(a: Vector2, c: Vector2, l1: float, l2: float, bend: float) -> Vector2:
	var d := clampf(a.distance_to(c), 0.01, l1 + l2 - 0.01)
	var dir := (c - a) / maxf(a.distance_to(c), 0.01)
	# Law of cosines: distance along a->c to the joint's foot, then the height.
	var along := (l1 * l1 - l2 * l2 + d * d) / (2.0 * d)
	var up := sqrt(maxf(l1 * l1 - along * along, 0.0))
	return a + dir * along + Vector2(-dir.y, dir.x) * up * bend


# Body parts are recorded while a figure is posed, then drawn in two passes:
# every outline first, then every fill. That gives one clean silhouette
# instead of a wireframe of separately outlined limbs.
var _recording := false
var _parts: Array = []   # [kind, data..., fill]


func _begin() -> void:
	_recording = true
	_parts.clear()


func _flush(edge: Color, width := 2.5) -> void:
	_recording = false
	var e := _t(edge)
	for part in _parts:
		if part[0] == "seg":
			canvas.draw_line(part[1], part[2], e, part[3] + width)
			canvas.draw_circle(part[1], (part[3] + width) / 2.0, e)
			canvas.draw_circle(part[2], (part[3] + width) / 2.0, e)
		else:
			var pv: PackedVector2Array = part[1]
			var closed := pv.duplicate()
			closed.append(pv[0])
			canvas.draw_polyline(closed, e, width, true)
	for part in _parts:
		var f := _t(part[part.size() - 1])
		if part[0] == "seg":
			canvas.draw_line(part[1], part[2], f, part[3])
			canvas.draw_circle(part[1], part[3] / 2.0, f)
			canvas.draw_circle(part[2], part[3] / 2.0, f)
		else:
			canvas.draw_colored_polygon(part[1], f)
	_parts.clear()


func limb(a: Vector2, b: Vector2, w: float, fill: Color, edge: Color) -> void:
	if _recording:
		_parts.append(["seg", a, b, w, fill])
		return
	canvas.draw_line(a, b, _t(edge), w + 2.5)
	canvas.draw_circle(a, (w + 2.5) / 2.0, _t(edge))
	canvas.draw_circle(b, (w + 2.5) / 2.0, _t(edge))
	canvas.draw_line(a, b, _t(fill), w)
	canvas.draw_circle(a, w / 2.0, _t(fill))
	canvas.draw_circle(b, w / 2.0, _t(fill))


func _poly(points: Array, fill: Color, edge: Color) -> void:
	var pv := PackedVector2Array(points)
	if _recording:
		_parts.append(["poly", pv, fill])
		return
	canvas.draw_colored_polygon(pv, _t(fill))
	pv.append(points[0])
	canvas.draw_polyline(pv, _t(edge), 1.5)


func _head_part(at: Vector2, r: float, fill: Color) -> void:
	var pts := []
	for k in 14:
		pts.append(at + Vector2.from_angle(TAU * k / 14.0) * r)
	_poly(pts, fill, Color.BLACK)


func _leg(hip: Vector2, foot: Vector2, fwd: float, fill: Color, boot: Color, edge: Color, w := 5.0) -> void:
	var knee := ik(hip, foot, THIGH, SHIN, -fwd)   # knees bend forward
	limb(hip, knee, w, fill, edge)
	limb(knee, foot + Vector2(0, -2), w - 0.5, fill, edge)
	_poly([foot + Vector2(-3 * fwd, -4), foot + Vector2(5 * fwd, -3), foot + Vector2(6 * fwd, 0), foot + Vector2(-3 * fwd, 0)], boot, edge)


func _arm(shoulder: Vector2, hand: Vector2, fwd: float, fill: Color, glove: Color, edge: Color, bend := 1.0) -> void:
	var elbow := ik(shoulder, hand, UPPER_ARM, FOREARM, fwd * bend)   # elbows bend back
	limb(shoulder, elbow, 4.0, fill, edge)
	limb(elbow, hand, 3.5, fill, edge)
	limb(hand, hand + Vector2(0.01, 0), 4.6, glove, edge)


## Torso as a tapered quad from hips to shoulders.
func _torso(hip: Vector2, neck: Vector2, hip_w: float, chest_w: float, fill: Color, edge: Color) -> void:
	var axis := (neck - hip).normalized()
	var side := Vector2(-axis.y, axis.x)
	_poly([hip + side * hip_w, hip - side * hip_w, neck - side * chest_w, neck + side * chest_w], fill, edge)


# --- the agent --------------------------------------------------------------

## pose: "sneak", "run", "climb", "hang", "shoot", "takedown", "fall".
## phase 0..1 animates the cycle (one full stride). aim is the pistol target
## for "shoot". rim 0..1 is how much lamp light catches his outline.
func agent(foot: Vector2, fwd: float, pose: String, phase: float, nv: bool, aim := Vector2.ZERO, rim := 0.0) -> void:
	var edge := A_EDGE.lerp(Color(1.0, 0.85, 0.6), rim)
	if pose == "hang":
		_agent_hang(foot, fwd, phase, nv, edge)
		return
	if pose == "crawl":
		_agent_crawl(foot, fwd, phase, nv, edge)
		return
	if pose == "climb":
		_agent_climb(foot, phase, nv, edge)
		return
	var cyc := phase * TAU
	# Defaults: the sneaking stance. Low, wide, leaning in, weight forward.
	var hip_h := 20.0
	var lean := 0.62
	var stride := 0.0
	var lift := 0.0
	var stance := 5.0
	match pose:
		"sneak":
			# stride is set so a full step cycle covers exactly one tile
			# (4 x stride = 32 px): planted feet don't slide on the floor.
			hip_h = 20.0 - absf(sin(cyc)) * 0.8
			stride = 8.0
			lift = 3.0
		"run":
			hip_h = 20.5 - absf(sin(cyc)) * 1.5
			lean = 0.32
			stride = 8.5
			lift = 7.0
			stance = 0.0
		"hide":
			# Standing tall with his back to the doorway, arms tight at his sides.
			hip_h = 21.5
			lean = 0.0
			stance = 2.5
		"idle":
			# Crouched and still; only a slow breath moves him.
			hip_h = 20.0 + sin(phase * 1.6) * 0.4
			cyc = 0.0
		"fall":
			hip_h = 21.0
			lean = 0.05
		"shoot", "takedown":
			hip_h = 19.5
			lean = 0.18
	var hip := foot + Vector2(0, -hip_h)
	var neck := hip + Vector2(sin(lean) * fwd, -cos(lean)) * 15.0
	var head := neck + Vector2(sin(lean) * fwd * 4.0, -7.0)
	var f_front := foot + Vector2((stance + sin(cyc) * stride) * fwd, -maxf(0.0, cos(cyc)) * lift)
	var f_back := foot + Vector2((-stance - sin(cyc) * stride) * fwd, -maxf(0.0, -cos(cyc)) * lift)
	if pose == "fall":
		f_front = foot + Vector2(5 * fwd, -5)
		f_back = foot + Vector2(-4 * fwd, -1)
	var shoulder := neck + Vector2(-fwd * 0.5, 2.0)
	var back_hand := shoulder + Vector2((-4.0 - sin(cyc) * stride * 0.7) * fwd, 13.0)
	var front_hand := shoulder + Vector2((4.0 + sin(cyc) * stride * 0.7) * fwd, 13.0)
	if pose == "hide":
		back_hand = shoulder + Vector2(-2.5 * fwd, 15.0)
		front_hand = shoulder + Vector2(2.0 * fwd, 15.0)
	elif pose in ["sneak", "idle"]:
		# Hands up and ready, close to the chest.
		back_hand = shoulder + Vector2(8.0 * fwd, 7.0)
		front_hand = shoulder + Vector2(11.0 * fwd, 4.0 + sin(cyc) * 0.8)
	elif pose == "fall":
		back_hand = shoulder + Vector2(-9 * fwd, -8)
		front_hand = shoulder + Vector2(8 * fwd, -9)
	elif pose == "takedown":
		var reach := sin(phase * PI)
		front_hand = shoulder + Vector2((9.0 + reach * 6.0) * fwd, 2.0 - reach * 4.0)
		back_hand = shoulder + Vector2((6.0 + reach * 4.0) * fwd, 6.0)
	var dir := Vector2(fwd, 0)
	if pose == "shoot":
		dir = (aim - shoulder).normalized()
		front_hand = shoulder + dir * 15.0
		back_hand = shoulder + dir * 13.0 + Vector2(0, 2)
	var back := A_SUIT.darkened(0.35)
	var front := A_SUIT.lightened(0.06)
	_begin()
	_leg(hip + Vector2(-fwd, 0), f_back, fwd, back, G_BOOT, edge)
	_arm(shoulder, back_hand, fwd, back, A_GEAR, edge, -0.4 if pose == "shoot" else 1.0)
	_poly(_rect_pts(neck.lerp(hip, 0.45) + Vector2(-8.5 * fwd, 0), Vector2(6, 11), lean * fwd), A_GEAR, edge)   # backpack
	_torso(hip, neck, 4.5, 6.0, A_SUIT, edge)
	_head_part(head, 5.6, A_SUIT_HI.darkened(0.35))
	_leg(hip + Vector2(fwd, 0), f_front, fwd, front, G_BOOT, edge)
	_arm(shoulder, front_hand, fwd, front, A_GEAR, edge, -0.4 if pose == "shoot" else 1.0)
	_flush(edge)
	var axis := (neck - hip).normalized()
	canvas.draw_line(hip + Vector2(axis.y, -axis.x) * -3.0 * fwd, neck + Vector2(axis.y, -axis.x) * -4.0 * fwd, _t(A_SUIT_HI), 1.5)
	# Details on top of the silhouette: harness, belt pouch, face, goggles.
	canvas.draw_line(hip.lerp(neck, 0.1) + Vector2(-4 * fwd, 0), neck + Vector2(3 * fwd, 1), _t(A_STRAP), 1.8)
	canvas.draw_line(hip + Vector2(-4.5, -1.5), hip + Vector2(4.5, -1.5), _t(A_STRAP), 2.2)
	canvas.draw_rect(Rect2(hip + Vector2(fwd * 1.0 - 2.0, -4.5), Vector2(4, 4)), _t(A_GEAR.lightened(0.1)))
	if pose == "shoot":
		var muzzle := front_hand + dir * 8.0
		canvas.draw_line(front_hand, muzzle, _t(Color(0.1, 0.1, 0.11)), 3.0)
		canvas.draw_line(front_hand + dir * 5.0, muzzle + dir * 4.0, _t(Color(0.15, 0.15, 0.16)), 3.5)   # suppressor
		if phase < 0.2:
			canvas.draw_circle(muzzle + dir * 6.0, 3.5, Color(1, 0.85, 0.4, 0.8))
	_agent_face(head, fwd, nv)


static func _rect_pts(c: Vector2, size: Vector2, ang: float) -> Array:
	var h := size / 2.0
	var out := []
	for v in [Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)]:
		out.append(c + v.rotated(ang))
	return out


## Balaclava slit and the goggle rig: a band round the head, an arm forward,
## and three lenses in a triangle. Flipped down over the eyes with night
## vision on; parked up on the forehead otherwise.
func _agent_face(head: Vector2, fwd: float, nv: bool) -> void:
	canvas.draw_rect(Rect2(head + Vector2(1.0 if fwd > 0 else -5.0, -0.5), Vector2(4, 1.8)), _t(A_SKIN))
	canvas.draw_line(head + Vector2(-5.5 * fwd, -2.5), head + Vector2(3.5 * fwd, -2.5), _t(A_STRAP), 1.6)
	var lens_at := head + Vector2(5.5 * fwd, -0.5 if nv else -5.5)
	canvas.draw_line(head + Vector2(2.5 * fwd, -3), lens_at, _t(A_GEAR), 2.2)
	_draw_lenses(lens_at, fwd, nv)


func _draw_lenses(at: Vector2, fwd: float, nv: bool) -> void:
	var glow := 1.0 if nv else 0.85
	var offs := [Vector2(0.8 * fwd, -2.0), Vector2(0.8 * fwd, 2.0), Vector2(-1.4 * fwd, 0)]
	canvas.draw_circle(at, 3.6, _t(Color(0.12, 0.13, 0.12)))
	for o in offs:
		canvas.draw_circle(at + o, 2.6, Color(LENS, 0.12 * glow))
	for o in offs:
		canvas.draw_circle(at + o, 1.15, Color(LENS, glow))


func _agent_hang(foot: Vector2, fwd: float, phase: float, nv: bool, edge: Color) -> void:
	# `foot` is the floor of the pipe tile; the pipe runs near its top.
	var grip := foot + Vector2(0, -26)
	var swing := sin(phase * TAU) * 1.5
	var shoulder := grip + Vector2(swing * 0.3, 14)
	var hip := shoulder + Vector2(swing * 0.6, 15)
	var back := A_SUIT.darkened(0.35)
	_begin()
	limb(shoulder + Vector2(-3, 0), grip + Vector2(-4, 0), 3.8, back, edge)
	_leg(hip + Vector2(-1, 0), hip + Vector2(-3 + swing, 21), fwd, back, G_BOOT, edge)
	_poly(_rect_pts(shoulder.lerp(hip, 0.4) + Vector2(-7.5 * fwd, 0), Vector2(6, 11), 0.0), A_GEAR, edge)
	_torso(hip, shoulder - Vector2(0, 1), 4.0, 5.5, A_SUIT, edge)
	_head_part(shoulder + Vector2(fwd * 2.5, -4.5), 5.6, A_SUIT_HI.darkened(0.35))
	_leg(hip + Vector2(1, 0), hip + Vector2(3 + swing * 1.4, 20), fwd, A_SUIT.lightened(0.06), G_BOOT, edge)
	limb(shoulder + Vector2(3, 0), grip + Vector2(4, 0), 3.8, A_SUIT.lightened(0.06), edge)
	limb(grip + Vector2(-4, 0), grip + Vector2(-4, 0.01), 4.6, A_GEAR, edge)
	limb(grip + Vector2(4, 0), grip + Vector2(4, 0.01), 4.6, A_GEAR, edge)
	_flush(edge)
	_agent_face(shoulder + Vector2(fwd * 2.5, -4.5), fwd, nv)


## Crawling on elbows and knees inside an air duct. `foot` is the bottom of
## the duct's tile; the duct floor sits 28 px above it.
func _agent_crawl(foot: Vector2, fwd: float, phase: float, nv: bool, edge: Color) -> void:
	var floor_y := foot.y - 28.0
	var x := foot.x
	var c := sin(phase * TAU)
	var hip := Vector2(x - 7.0 * fwd, floor_y - 5.5)
	var neck := Vector2(x + 6.0 * fwd, floor_y - 7.0)
	var head := Vector2(x + 11.5 * fwd, floor_y - 8.5)
	var back := A_SUIT.darkened(0.35)
	var front := A_SUIT.lightened(0.06)
	_begin()
	# knees down, feet trailing behind, alternating
	limb(hip, Vector2(x - (1.0 + c * 2.5) * fwd, floor_y - 1.0), 4.5, back, edge)
	limb(Vector2(x - (1.0 + c * 2.5) * fwd, floor_y - 1.0), Vector2(x - 14.0 * fwd, floor_y - 2.0), 4.0, back, edge)
	limb(Vector2(x - 2.0 * fwd, floor_y - 9.0), Vector2(x - 2.0 * fwd, floor_y - 9.0) + Vector2(-9 * fwd, 0), 5.0, A_GEAR, edge)   # backpack
	limb(neck, Vector2(x + (11.0 - c * 3.0) * fwd, floor_y - 1.0), 3.8, back, edge)
	_torso(hip, neck, 4.0, 5.0, A_SUIT, edge)
	_head_part(head, 5.0, A_SUIT_HI.darkened(0.35))
	limb(hip, Vector2(x - (1.0 - c * 2.5) * fwd, floor_y - 1.0), 4.5, front, edge)
	limb(Vector2(x - (1.0 - c * 2.5) * fwd, floor_y - 1.0), Vector2(x - 15.0 * fwd, floor_y - 1.5), 4.0, front, edge)
	limb(neck, Vector2(x + (11.0 + c * 3.0) * fwd, floor_y - 1.0), 3.8, front, edge)
	_flush(edge)
	var lens_at := head + Vector2(4.0 * fwd, -0.5 if nv else -3.5)
	canvas.draw_line(head + Vector2(1.5 * fwd, -2), lens_at, _t(A_GEAR), 2.0)
	_draw_lenses(lens_at, fwd, nv)


func _agent_climb(foot: Vector2, phase: float, nv: bool, edge: Color) -> void:
	# Seen from behind on the ladder: alternating hands and feet.
	var c := sin(phase * TAU)
	var hip := foot + Vector2(0, -19)
	var neck := hip + Vector2(0, -15)
	var head := neck + Vector2(0, -7)
	_begin()
	_leg(hip + Vector2(-3, 0), foot + Vector2(-5, -2 - maxf(c, 0) * 6), 1.0, A_SUIT, G_BOOT, edge, 4.5)
	_leg(hip + Vector2(3, 0), foot + Vector2(5, -2 - maxf(-c, 0) * 6), -1.0, A_SUIT, G_BOOT, edge, 4.5)
	_torso(hip, neck, 5.0, 6.5, A_SUIT, edge)
	_head_part(head, 5.6, A_SUIT_HI.darkened(0.35))
	_arm(neck + Vector2(-5, 1), neck + Vector2(-8, -10 - c * 4), -1.0, A_SUIT, A_GEAR, edge)
	_arm(neck + Vector2(5, 1), neck + Vector2(8, -10 + c * 4), 1.0, A_SUIT, A_GEAR, edge)
	_poly(_rect_pts(neck + Vector2(0, 7), Vector2(10, 11), 0.0), A_GEAR, edge)
	_flush(edge)
	canvas.draw_line(neck + Vector2(-4, 2), hip + Vector2(-4, 0), _t(A_STRAP), 1.5)
	canvas.draw_line(neck + Vector2(4, 2), hip + Vector2(4, 0), _t(A_STRAP), 1.5)
	canvas.draw_line(head + Vector2(-5.5, -2), head + Vector2(5.5, -2), _t(A_STRAP), 1.6)
	canvas.draw_circle(head + Vector2(0, -5), 2.2, _t(Color(0.12, 0.13, 0.12)))
	canvas.draw_circle(head + Vector2(0, -5), 1.0, Color(LENS, 0.9 if nv else 0.6))


# --- guards -----------------------------------------------------------------

## A uniformed guard. walk 0..1 is the step cycle (0 = standing). `look`
## shows alert state: 0 calm, 1 suspicious, 2 has seen you. `torch` adds a
## flashlight held forward. `who` varies skin, build and moustache.
func guard(foot: Vector2, fwd: float, walk: float, moving: bool, look: int, torch: bool, who: int) -> void:
	var skin: Color = SKINS[who % SKINS.size()]
	var bulk := 1.0 + float(who % 3) * 0.12
	var cyc := walk * TAU
	var stride := 6.0 if moving else 0.0
	var bob := absf(sin(cyc)) * 1.0 if moving else 0.0
	var hip := foot + Vector2(0, -22 + bob)
	var neck := hip + Vector2(fwd * (1.5 if look == 2 else 0.5), -17)
	var head := neck + Vector2(fwd * 1.0, -7.5)
	var f_front := foot + Vector2((2.5 + sin(cyc) * stride) * fwd, -maxf(0.0, cos(cyc)) * 3.0 * float(moving))
	var f_back := foot + Vector2((-2.5 - sin(cyc) * stride) * fwd, -maxf(0.0, -cos(cyc)) * 3.0 * float(moving))
	var shoulder := neck + Vector2(0, 2.5)
	var back_hand := shoulder + Vector2((-3.0 - sin(cyc) * stride * 0.7) * fwd, 15.5)
	var front_hand := shoulder + Vector2((3.0 + sin(cyc) * stride * 0.7) * fwd, 15.5)
	if torch:
		front_hand = shoulder + Vector2(13.0 * fwd, 3.0)
	elif look >= 1:
		front_hand = hip + Vector2(-fwd * 5.5, 1)   # hand on the holster
	_begin()
	_leg(hip + Vector2(-fwd, 0), f_back, fwd, G_PANTS.darkened(0.3), G_BOOT, G_EDGE)
	_arm(shoulder + Vector2(-fwd, 0), back_hand, fwd, G_SHIRT.darkened(0.3), skin.darkened(0.3), G_EDGE)
	_torso(hip, neck, 5.0 * bulk, 6.5 * bulk, G_SHIRT, G_EDGE)
	_leg(hip + Vector2(fwd, 0), f_front, fwd, G_PANTS, G_BOOT, G_EDGE)
	_head_part(head, 5.8, skin)
	_poly([head + Vector2(-6.2, -1.5), head + Vector2(6.2, -1.5), head + Vector2(5.2, -8), head + Vector2(-5.2, -8)], G_PANTS, G_EDGE)   # cap
	_arm(shoulder + Vector2(fwd, 0), front_hand, fwd, G_SHIRT.lightened(0.05), skin, G_EDGE)
	if torch:
		limb(front_hand, front_hand + Vector2(7 * fwd, -1), 4.0, Color(0.2, 0.2, 0.22), G_EDGE)
	_flush(G_EDGE, 2.0)
	# Shirt details: placket, pocket, badge, belt with buckle and holster.
	canvas.draw_line(neck + Vector2(fwd * 2.0, 2), hip + Vector2(fwd * 2.0, -2), _t(G_SHIRT_HI), 1.0)
	canvas.draw_rect(Rect2(neck + Vector2(0.0 if fwd > 0 else -5.0, 4), Vector2(5, 4)), _t(G_SHIRT_HI))
	canvas.draw_circle(neck + Vector2(-fwd * 2.5, 5), 1.4, _t(Color(0.95, 0.8, 0.3)))
	canvas.draw_line(hip + Vector2(-5.5 * bulk, -1.5), hip + Vector2(5.5 * bulk, -1.5), _t(G_BELT), 3.0)
	canvas.draw_rect(Rect2(hip + Vector2(fwd * 3.0 - 1.0, -3), Vector2(2, 3)), _t(Color(0.85, 0.75, 0.4)))
	canvas.draw_rect(Rect2(hip + Vector2(-fwd * 6.0 - 2.0, -1), Vector2(4, 7)), _t(Color(0.1, 0.1, 0.1)))
	# Face: ear, eye (wider when he has seen you), moustache on some, cap brim and badge.
	canvas.draw_circle(head + Vector2(-fwd * 1.5, 0.5), 1.5, _t(skin.darkened(0.2)))
	canvas.draw_circle(head + Vector2(fwd * 3.0, -0.5), 1.0 if look < 2 else 1.5, _t(Color(0.08, 0.08, 0.1)))
	if look == 2:
		canvas.draw_line(head + Vector2(fwd * 1.5, -3.0), head + Vector2(fwd * 4.5, -3.5), _t(Color(0.1, 0.08, 0.06)), 1.2)
	if who % 2 == 1:
		canvas.draw_line(head + Vector2(fwd * 2.0, 2.5), head + Vector2(fwd * 5.5, 2.5), _t(Color(0.15, 0.1, 0.08)), 1.6)
	canvas.draw_line(head + Vector2(fwd * 2, -1.5), head + Vector2(fwd * 9, -0.5), _t(G_BOOT), 2.0)
	canvas.draw_circle(head + Vector2(fwd * 1.0, -5.5), 1.1, _t(Color(0.95, 0.8, 0.3)))
	if torch:
		canvas.draw_circle(front_hand + Vector2(8 * fwd, -1), 2.3, _t(Color(1, 0.95, 0.7)))


## A knocked-out guard lying on his back, cap knocked off.
func guard_down(foot: Vector2, fwd: float, who: int) -> void:
	var skin: Color = SKINS[who % SKINS.size()]
	var head := foot + Vector2(-13 * fwd, -5)
	var hip := foot + Vector2(3 * fwd, -4)
	_begin()
	limb(hip, hip + Vector2(10 * fwd, -2), 5.0, G_PANTS, G_EDGE)
	limb(hip + Vector2(10 * fwd, -2), hip + Vector2(16 * fwd, 0), 5.0, G_PANTS, G_EDGE)
	_torso(hip, head + Vector2(5 * fwd, 0), 4.5, 6.0, G_SHIRT, G_EDGE)
	limb(head + Vector2(6 * fwd, -2), head + Vector2(10 * fwd, -9), 3.5, G_SHIRT, G_EDGE)
	_head_part(head, 5.5, skin)
	_poly([head + Vector2(-16 * fwd, 4), head + Vector2(-8 * fwd, 4), head + Vector2(-9 * fwd, -1), head + Vector2(-15 * fwd, -1)], G_PANTS, G_EDGE)
	_flush(G_EDGE, 2.0)
	canvas.draw_line(head + Vector2(-2, -1), head + Vector2(1, -1), _t(Color(0.1, 0.1, 0.1)), 1.2)
