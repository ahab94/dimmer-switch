# Dimmer Switch (working title)

A side-view light-and-shadow stealth game. You are a spy in tri-lens night-vision goggles, working the night shift for an agency called **Third Shift**. Every lamp is your enemy.

## How it plays
- **Light is everything.** Guards spot you from 9 tiles away in light, 5 in dim light, and only right next to you in the dark. The LIGHT meter shows where you stand.
- **Shoot the lights.** Limited ammo; each broken lamp stays dark (and saves 60 W). Glass is loud up close.
- **Alcoves:** guards walk right past you in an unlit alcove.
- **Pipes:** hang from the ceiling. Nobody ever looks up.
- **Noise:** running is twice as fast, but guards within 4 tiles hear it.
- **Takedowns** from behind. Other guards (and cameras) raise the alarm if they find a body.
- **Cameras** sweep, but see only in the light. **Lasers** are invisible without night vision.
- **Flashlight guards** light up whatever they look at.
- Detection is a meter, not instant failure. Ratings: GHOST (never noticed, no takedowns), SHADOW, NOTICED.

## Controls
| Action | Keys |
| --- | --- |
| Move / climb / grab pipe / drop | WASD or arrow keys |
| Run | Shift |
| Shoot nearest lamp | F |
| Takedown | E |
| Night vision | N |
| Restart / pause | R / Esc |

## Missions
OP-01 Night Shift · OP-02 Pools of Light · OP-03 Energy Audit · OP-04 Squeaky Sneakers · OP-05 Pipe Dreams · OP-06 Lights Out, Lads · OP-07 Smile, You're on Camera · OP-08 Invisible Red Tape · OP-09 Access Denied · OP-10 Grid Down

## How it's built
Godot 4.7, GDScript, everything drawn in code. The rules (`world.gd`) are pure functions of time, so a planning autopilot can prove every mission winnable without being seen (`bash checks/verify.sh`).

## Roadmap
- [x] v0.1: 10 missions, light/shadow, alcoves, pipes, ladders, shooting lamps, noise, takedowns, doors, cameras, lasers + night vision, keycards, flashlight guards, autopilot gate, mission select, saves, jointed characters with poses, zoomed follow camera
- [ ] User playtest, then tune with a flawed "rookie" bot for a steady difficulty curve
- [ ] Synthesized audio: adaptive music, quiet footsteps, glass shatter
- [ ] Touch controls + portrait mode (Shorts)
- [ ] Final name, GitHub repo, release workflow, web build, videos
