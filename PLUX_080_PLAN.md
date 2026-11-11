# Plux 0.8.0: any-game AI builder (work log for the task "Plux 0.8.0: AI builds any game from the prompt")

Status: design done, code started. Nothing committed, built or deployed.

## Findings
- Today Studio games are PloxLevel obby parts [kind,x,y,z,sx,sy,sz,rotY,color]; kinds block/lava/bounce/spinner/mover/coin/ice/checkpoint. studio_play.gd plays them with LocalPlayer (third person). So every AI game is an obby.
- Server: plox_hub.gd _ai_build -> _ai_call -> _ai_try (PloxLevel.ai_system_prompt, PloxLevel.clean, AgentRules.enforce_level, PloxLevel.playability/quality, repair loop). Games stored in games[gid].data (PloxLevel), _game_card uses data.parts.size() and data.sky. _save_game cleans with PloxLevel.clean. LEVEL_MSG_BYTES 16000.
- Agent rule no_violence defaults ON ("No violence, weapons or gore"): shooter prompts must be cartoon blasters (enemies pop into sparkles).
- Admin task edits the same working tree (admin/, plox_hub.gd, plox_pay.gd, live_config.gd). Commit only own hunks.
- Deploy: commit on platform-shell, push to /home/sprite/blockparty, merge to main, push GitHub, Render Manual Deploy (browser). APK export command in /home/sprite/PROJECT_NOTES.md; 0.7.2 is versionCode 10.

## Design (spec v1)
Keys: v=1, title, intro, plan{genre,loop,controls,win,theme}, world{size,floor ground|none|water,floor_color,floor_mat,sky,fog,light,music,gravity,walls}, controls platformer|topdown|side|firstperson|vehicle, player{spawn,speed,jump,lives,health,abilities[shoot,dash,double_jump,kick,boost],color}, entities[{id,shape,pos(bottom-centre),size,rot,color,mat,solid,hidden,template,tags,repeat{count,step},circle{count,radius},behaviors[]}], triggers[{on,target,by,value,once,do[]}], rules{win{type,value,target},lose[],timer,lives,laps,checkpoints,waves[]}, hud[].
Behaviours: move rotate bob rise shrink chase flee follow wander race shoot spawn damage bounce boost collect push destructible checkpoint teleport.
Files: game/scripts/plox_spec.gd (data: clean/validate/mechanics/ai prompt/from_level), game/scripts/spec_play.gd (runtime), hooks in plox_hub.gd (_ai_call/_ai_try branch when msg.spec==1, _save_game, _game_card) and studio_pages.gd/main.gd (play spec games).

## Progress (end of first run)
Written, not yet compiled or tested, not committed:
- game/scripts/plox_spec.gd: spec v1 clean/clamp, aliases, repeat/circle copies, find(), from_level() (old obby -> spec), summary().
- game/scripts/plox_spec_check.gd: reach model (floor grid + jump arcs), problems() (refs, win reachable, score available, enemies beatable, laps checkpoints...), mechanics(prompt) (race/vehicle/laps, shooter, waves, tower defense, collect N + timer, maze, chase, top-down, side, first-person, sumo/shrink, soccer, rising lava, obby, double jump), enforce_agent().
- game/scripts/plox_spec_ai.gd: full Studio Builder system prompt with the spec reference and genre recipes, user/edit/repair messages, find_spec().
- game/scripts/touch_controls.gd: show_jump flag, action_down (hold to auto-fire). (small edit, uncommitted)
Next, in order:
1. game/scripts/spec_play.gd runtime (design notes: node origin = bottom-centre; layers 1 world, 2 player, 4 actors, 8 rigid; touch tests by local AABB; modes platformer/topdown/side/firstperson/vehicle; projectiles list with auto-aim; waves; laps with next-gate marker; triggers/actions; HUD pills; win/lose panel; finished signal same as StudioPlay).
2. Hook plox_hub.gd: _ai_build sends spec when client says spec:1 (0.8.0) — _ai_try uses PloxSpecAi + PloxSpec.clean + PloxSpecCheck.problems/mechanics with repair loop (2 rounds); _save_game/_game_card accept specs; old 0.7.2 clients keep getting PloxLevel. Raise ai_max_tokens and LEVEL_MSG_BYTES (spec JSON ~20-40 KB).
3. studio_pages.gd/main.gd: play spec games with SpecPlay; convert old levels with PloxSpec.from_level.
4. Headless tests (godot --headless) for each recipe; then live tests with 10 prompts (tests/live_ai_prompts.js pattern).
5. Commit own files only (git add -p), pull/rebase, push, Render manual deploy, live checks, export APK versionCode 11 / 0.8.0, Gofile.
