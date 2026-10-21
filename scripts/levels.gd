extends RefCounted
## The ten missions, as ASCII maps plus enemy settings.
##
## Map legend (40 columns; every row the same width):
##   #  solid wall or floor         .  empty air
##   P  player start                X  extraction (the exit)
##   H  ladder (UP/DOWN to climb)   =  pipe (UP from below to hang on it)
##   L  ceiling lamp                O  alcove: guards walk past you if it's not lit
##   D  door (blocks sight)         R  locked door (needs the keycard)
##   K  keycard
## You stand on a tile when the tile below is solid or a ladder.
##
## guards:  row, x0, x1 (patrol between them; x1 omitted = stands still),
##          step (ticks per tile), wait (ticks at each end, or between turns
##          when standing still; 0 = never turns), face (start facing for a
##          standing guard), phase (ticks into the patrol at start),
##          torch (carries a flashlight).
## cameras: pos, a0/a1 (sweep angles in degrees, 0 = right, 90 = down),
##          period (ticks per full sweep), optional range, fov, phase.
## lasers:  x, y0..y1 (a vertical beam), on/off ticks (off 0 = always on), phase.
##
## Timing numbers are ticks at 60 per second. Keep enemy cycles to round
## numbers so their least common multiple stays small; the autopilot folds
## time over that period.

const LEVELS := [
	{
		"code": "OP-01",
		"name": "Night Shift",
		"brief": "Third Shift needs a spy who works in the dark. Get to the roof.",
		"tip": "Arrows/WASD move. In the dark, guards only spot you up close. Hide in alcoves and let them walk past.",
		"ammo": 0,
		"map": [
			"########################################",
			"#......................................#",
			"#.X....................................#",
			"##################################H#####",
			"#.................................H....#",
			"#.................................H....#",
			"#.P..........O....................H....#",
			"########################################",
		],
		"guards": [
			{"row": 6, "x0": 32, "x1": 10, "step": 18, "wait": 90},
		],
		"cameras": [
		],
		"lasers": [
		],
	},
	{
		"code": "OP-02",
		"name": "Pools of Light",
		"brief": "Somebody left the lights on. Light is how they see you.",
		"tip": "Watch the LIGHT meter. Guards see you from far away in the light. A lit alcove hides nobody.",
		"ammo": 0,
		"map": [
			"########################################",
			"#.......L..............L...............#",
			"#.X..O..........O......................#",
			"###################################H####",
			"#......L..............L............H...#",
			"#..................................H...#",
			"#.P.......O..........O.............H...#",
			"########################################",
		],
		"guards": [
			{"row": 6, "x0": 33, "x1": 4, "step": 16, "wait": 100},
			{"row": 2, "x0": 6, "x1": 31, "step": 16, "wait": 100},
		],
		"cameras": [
		],
		"lasers": [
		],
	},
	{
		"code": "OP-03",
		"name": "Energy Audit",
		"brief": "This guard never blinks. Lights cost money. Save some.",
		"tip": "F shoots the nearest lamp (limited ammo). Breaking glass is loud up close. Dark tiles stay dark.",
		"ammo": 3,
		"map": [
			"########################################",
			"#..............................L.......#",
			"#....................................X.#",
			"##########################H#############",
			"#.................L.....L.H....#.......#",
			"#.........................H....#.......#",
			"#.P.......................H....#.......#",
			"########################################",
		],
		"guards": [
			{"row": 6, "x0": 29, "face": -1, "wait": 0},
			{"row": 2, "x0": 10, "x1": 24, "step": 16, "wait": 90},
		],
		"cameras": [
		],
		"lasers": [
		],
	},
	{
		"code": "OP-04",
		"name": "Squeaky Sneakers",
		"brief": "Three floors, one lazy security team. Some gaps need speed.",
		"tip": "Hold SHIFT to run. Running is twice as fast, but guards within 4 tiles hear it.",
		"ammo": 0,
		"map": [
			"########################################",
			"#...........L..........................#",
			"#....X..............O..................#",
			"#################################H######",
			"#.............................L..H.....#",
			"#................................H.....#",
			"#................................H.....#",
			"###################H####################",
			"#..............L...HL......#...........#",
			"#..................H.......#...........#",
			"#.P................H.......#...........#",
			"########################################",
		],
		"guards": [
			{"row": 10, "x0": 24, "face": -1, "wait": 90},
			{"row": 6, "x0": 22, "x1": 37, "step": 16, "wait": 60},
			{"row": 2, "x0": 8, "x1": 30, "step": 14, "wait": 60},
		],
		"cameras": [
		],
		"lasers": [
		],
	},
	{
		"code": "OP-05",
		"name": "Pipe Dreams",
		"brief": "Nobody ever looks up. Nobody.",
		"tip": "Press UP under a pipe to grab it, DOWN to drop. Guards only look straight ahead.",
		"ammo": 0,
		"map": [
			"########################################",
			"#................................L.....#",
			"#.............................X........#",
			"#####################################H##",
			"#...................L...........L....H.#",
			"#.............==============.========H.#",
			"#.P..................................H.#",
			"########################################",
		],
		"guards": [
			{"row": 6, "x0": 20, "face": -1, "wait": 0},
			{"row": 6, "x0": 28, "x1": 35, "step": 14, "wait": 100},
		],
		"cameras": [
		],
		"lasers": [
		],
	},
	{
		"code": "OP-06",
		"name": "Lights Out, Lads",
		"brief": "A guard is staring at the only way through. Give him a nap.",
		"tip": "E knocks out a guard from behind. Doors block sight. Other guards panic if they see a body.",
		"ammo": 0,
		"map": [
			"########################################",
			"#...................L..................#",
			"#....X........O........................#",
			"#############################H##########",
			"#...........#.......L.....#..H..L......#",
			"#...........#.............#..H.........#",
			"#.P.........D.............D..H.........#",
			"########################################",
		],
		"guards": [
			{"row": 6, "x0": 16, "face": 1, "wait": 0},
			{"row": 6, "x0": 33, "face": -1, "wait": 150},
			{"row": 2, "x0": 8, "x1": 30, "step": 16, "wait": 80},
		],
		"cameras": [
		],
		"lasers": [
		],
	},
	{
		"code": "OP-07",
		"name": "Smile, You're on Camera",
		"brief": "Cameras never get tired. They do need the lights on.",
		"tip": "Cameras sweep and see in light only. Shoot their lamp and they're blind.",
		"ammo": 1,
		"map": [
			"########################################",
			"#.............L.............L..........#",
			"#..X.................O.................#",
			"####################################H###",
			"#..........L.......L................H..#",
			"#...................................H..#",
			"#.P.....................O...........H..#",
			"########################################",
		],
		"guards": [
			{"row": 2, "x0": 10, "x1": 33, "step": 14, "wait": 80, "phase": 200},
		],
		"cameras": [
			{"pos": Vector2i(15, 4), "a0": 40, "a1": 140, "period": 240},
			{"pos": Vector2i(24, 1), "a0": 150, "a1": 60, "period": 300},
		],
		"lasers": [
		],
	},
	{
		"code": "OP-08",
		"name": "Invisible Red Tape",
		"brief": "The lasers here are invisible. Your goggles are not.",
		"tip": "N toggles night vision: it shows lasers. Touching a live laser trips the alarm instantly.",
		"ammo": 0,
		"map": [
			"########################################",
			"#.......L..............................#",
			"#...................................X..#",
			"##############################H#########",
			"#.....................L.......H........#",
			"#.......=======...............H........#",
			"#.P..............O............H........#",
			"########################################",
		],
		"guards": [
			{"row": 6, "x0": 21, "x1": 33, "step": 15, "wait": 90},
		],
		"cameras": [
		],
		"lasers": [
			{"x": 11, "y0": 6, "y1": 6},
			{"x": 20, "y0": 4, "y1": 6, "on": 90, "off": 90},
			{"x": 25, "y0": 4, "y1": 6, "on": 60, "off": 120, "phase": 30},
			{"x": 18, "y0": 1, "y1": 2, "on": 120, "off": 60},
			{"x": 26, "y0": 1, "y1": 2, "on": 60, "off": 60},
		],
	},
	{
		"code": "OP-09",
		"name": "Access Denied",
		"brief": "The roof is behind a locked door. The card is in the break room.",
		"tip": "Grab the keycard to open red doors.",
		"ammo": 2,
		"map": [
			"########################################",
			"#.....................L................#",
			"#...............................O....X.#",
			"###H######################H#############",
			"#..H...........L....#.....H...L........#",
			"#..H................#.....H............#",
			"#..H.....O..........R.....H...K........#",
			"####################################H###",
			"#...........L...........L...........H..#",
			"#...................................H..#",
			"#.P..............O..................H..#",
			"########################################",
		],
		"guards": [
			{"row": 10, "x0": 33, "x1": 6, "step": 16, "wait": 90},
			{"row": 6, "x0": 34, "x1": 22, "step": 14, "wait": 120},
			{"row": 2, "x0": 10, "x1": 30, "step": 14, "wait": 60, "phase": 100},
		],
		"cameras": [
		],
		"lasers": [
		],
	},
	{
		"code": "OP-10",
		"name": "Grid Down",
		"brief": "Final shift. They brought flashlights. Rude.",
		"tip": "Flashlight guards light up whatever they look at, alcoves included. Use everything you've learned.",
		"ammo": 2,
		"map": [
			"########################################",
			"#.......#...............L..............#",
			"#.X.....R.......O...........O..........#",
			"#####################################H##",
			"#.................L...........#...L..H.#",
			"#............================.#......H.#",
			"#...........K.................D......H.#",
			"######################H#################",
			"#.............L.......H................#",
			"#.........=========...H................#",
			"#.P...................H................#",
			"########################################",
		],
		"guards": [
			{"row": 10, "x0": 14, "face": 1, "wait": 0},
			{"row": 6, "x0": 15, "x1": 27, "step": 15, "wait": 60, "torch": true},
			{"row": 6, "x0": 35, "face": -1, "wait": 240},
			{"row": 2, "x0": 10, "x1": 34, "step": 15, "wait": 120},
		],
		"cameras": [
			{"pos": Vector2i(20, 1), "a0": 150, "a1": 40, "period": 480},
		],
		"lasers": [
			{"x": 7, "y0": 8, "y1": 10, "on": 60, "off": 60},
		],
	},

]
