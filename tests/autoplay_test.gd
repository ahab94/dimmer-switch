extends SceneTree
## Plans every mission with the autopilot and replays the plan through the
## real simulation. Passing means each level is winnable without ever being
## noticed. Run: godot --headless --path . --script res://tests/autoplay_test.gd
## Optional: -- --level=N to check one mission.

const Levels := preload("res://scripts/levels.gd")
const World := preload("res://scripts/world.gd")
const Sim := preload("res://scripts/sim.gd")
const Autopilot := preload("res://scripts/autopilot.gd")


func _init() -> void:
	var only := -1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--level="):
			only = int(a.get_slice("=", 1))
	var failed := 0
	for i in Levels.LEVELS.size():
		if only >= 0 and i != only:
			continue
		var r := run_level(i)
		print("RESULT level=%d %s ticks=%d actions=%d expansions=%d plan_ms=%d %s" % [
			i + 1, r["outcome"], r["ticks"], r["actions"], r["expansions"], r["ms"], r["why"]])
		if r["outcome"] != "complete" or r["spotted"]:
			failed += 1
	print("AUTOPLAY OK" if failed == 0 else "FAIL: %d missions not beaten cleanly" % failed)
	quit(0 if failed == 0 else 1)


static func run_level(i: int) -> Dictionary:
	var world = World.new()
	world.setup(Levels.LEVELS[i])
	var bot = Autopilot.new()
	var t0 := Time.get_ticks_msec()
	var plan: Array = bot.plan(world)
	var ms := Time.get_ticks_msec() - t0
	var sim = Sim.new()
	sim.setup(world)
	var next := 0
	while sim.outcome == "" and sim.tick < 60 * 600:
		var input := {}
		if sim.wants_input() and next < plan.size():
			input = plan[next]
			next += 1
		sim.step(input)
		if plan.is_empty():
			break
	return {"outcome": sim.outcome if sim.outcome != "" else ("noplan" if plan.is_empty() else "timeout"),
		"ticks": sim.tick, "actions": plan.size(), "expansions": bot.expansions, "ms": ms,
		"spotted": sim.spotted, "why": sim.caught_by + (" (noticed)" if sim.spotted else "")}
