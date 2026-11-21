#!/usr/bin/env python3
"""Writes the 0.8.0 part A sample games into game/tests/specs/."""
import json, os, random

OUT = os.path.join(os.path.dirname(__file__), "specs")
os.makedirs(OUT, exist_ok=True)

# 1. A 0.7-style lava obby (PloxLevel parts: kind,x,y,z,sx,sy,sz,rotY,color; centre positions).
obby = {"title": "Lava Leap", "sky": 1, "spawn": [0, 1.5, 0], "goal": [0, 3.5, -43], "parts": [
    ["block", 0, 0, 0, 6, 1, 6, 0, 0],
    ["block", 0, 0, -8, 4, 1, 4, 0, 1],
    ["lava", 0, 0, -11, 4, 1, 2, 0, 0],
    ["checkpoint", 0, 0, -15, 4, 1, 6, 0, 2],
    ["block", 0, 0, -22, 4, 1, 4, 0, 3],
    ["bounce", 0, 0, -27, 3, 1, 3, 0, 4],
    ["block", 0, 2, -34, 4, 1, 8, 0, 5],
    ["spinner", 0, 2.9, -33, 5, 0.5, 0.5, 0, 6],
    ["coin", 0, 4, -36, 1, 1, 1, 0, 0],
    ["block", 0, 2, -43, 4, 1, 4, 0, 1],
    ["mover", 9, 0, -22, 3, 1, 3, 0, 2],
    ["lava", 0, -2, -30, 14, 1, 30, 0, 0],
]}
json.dump(obby, open(os.path.join(OUT, "lava_obby_level.json"), "w"), indent=1)

# 2. Collect 20 coins before the countdown ends, in a candy city.
random.seed(7)
ents = []
for i, (x, z) in enumerate([(-18, -18), (18, -18), (-18, 18), (18, 18), (0, -22), (-22, 0), (22, 0)]):
    ents.append({"id": f"house{i}", "shape": "house", "pos": [x, 0, z], "size": [7, 6, 7], "color": random.choice(["#FF80AB", "#B388FF", "#80D8FF", "#FFD180"]), "mat": "candy"})
for i in range(8):
    a = i * 0.785
    ents.append({"id": f"pop{i}", "shape": "mushroom", "pos": [round(11 * __import__('math').cos(a), 1), 0, round(11 * __import__('math').sin(a), 1)], "size": [2, 3, 2], "color": "#FF4081"})
ents.append({"id": "coin", "shape": "coin", "pos": [-14, 0.6, -8], "color": "#FFC107", "tags": ["coin"], "repeat": {"count": 8, "step": [4, 0, 0]},
             "behaviors": [{"type": "collect", "score": 1}]})
ents.append({"id": "ringcoin", "shape": "coin", "pos": [0, 0.6, 0], "color": "#FFC107", "tags": ["coin"], "circle": {"count": 10, "radius": 6},
             "behaviors": [{"type": "collect", "score": 1}]})
ents.append({"id": "southcoin", "shape": "coin", "pos": [-10, 0.6, 9], "color": "#FFC107", "tags": ["coin"], "repeat": {"count": 6, "step": [4, 0, 0]},
             "behaviors": [{"type": "collect", "score": 1}]})
ents.append({"id": "gumdrop", "shape": "gem", "pos": [8, 0.6, -14], "color": "#00E5FF", "behaviors": [{"type": "collect", "score": 0, "time": 5}]})
candy = {"v": 1, "title": "Candy City Coin Rush", "intro": "Grab 20 coins before time runs out!",
         "plan": {"genre": "collect against the clock", "loop": "run around the city picking up coins", "controls": "platformer", "win": "20 coins", "theme": "candy city"},
         "world": {"size": 60, "floor": "ground", "floor_color": "#F8BBD0", "floor_mat": "candy", "sky": "candy", "light": "bright", "music": "happy", "walls": True},
         "controls": "platformer", "player": {"spawn": [0, 0, 16], "speed": 8, "jump": 9},
         "entities": ents,
         "triggers": [{"on": "score", "value": 10, "do": [{"act": "message", "text": "Halfway there!"}]}],
         "rules": {"win": {"type": "score", "value": 20}, "lose": ["time_up"], "timer": 60},
         "hud": ["score", "timer"]}
json.dump(candy, open(os.path.join(OUT, "candy_coins.json"), "w"), indent=1)

# 3. Top-down maze: reach the exit while a ghost chases you.
N, C = 8, 5.0            # 8x8 cells of 5 m -> 40 m maze
random.seed(3)
vis = [[False] * N for _ in range(N)]
wall_e = [[True] * N for _ in range(N)]   # wall on the east side of cell (x,z)
wall_s = [[True] * N for _ in range(N)]   # wall on the south side
stack = [(0, 0)]
vis[0][0] = True
while stack:
    x, z = stack[-1]
    nb = [(dx, dz) for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)) if 0 <= x + dx < N and 0 <= z + dz < N and not vis[x + dx][z + dz]]
    if not nb:
        stack.pop(); continue
    dx, dz = random.choice(nb)
    if dx == 1: wall_e[x][z] = False
    if dx == -1: wall_e[x - 1][z] = False
    if dz == 1: wall_s[x][z] = False
    if dz == -1: wall_s[x][z - 1] = False
    vis[x + dx][z + dz] = True
    stack.append((x + dx, z + dz))
# braid a few loops so the ghost can be dodged
for _ in range(14):
    x, z = random.randrange(N - 1), random.randrange(N - 1)
    if random.random() < 0.5: wall_e[x][z] = False
    else: wall_s[x][z] = False
h = N * C / 2
walls = []
for x in range(N - 1):      # vertical walls, merged along z
    z = 0
    while z < N:
        if wall_e[x][z]:
            z0 = z
            while z < N and wall_e[x][z]: z += 1
            walls.append(((x + 1) * C - h, (z0 + z) / 2 * C - h, 0.8, (z - z0) * C + 0.8))
        else:
            z += 1
for z in range(N - 1):      # horizontal walls, merged along x
    x = 0
    while x < N:
        if wall_s[x][z]:
            x0 = x
            while x < N and wall_s[x][z]: x += 1
            walls.append(((x0 + x) / 2 * C - h, (z + 1) * C - h, (x - x0) * C + 0.8, 0.8))
        else:
            x += 1
ents = [{"id": f"w{i}", "shape": "box", "pos": [round(x, 2), 0, round(z, 2)], "size": [round(sx, 2), 3, round(sz, 2)], "color": "#4A3B6B", "mat": "stone", "tags": ["wall"]}
        for i, (x, z, sx, sz) in enumerate(walls)]
ents.append({"id": "exit", "shape": "ring", "pos": [h - C / 2, 0, h - C / 2], "size": [3, 3, 0.4], "color": "#69F0AE", "mat": "glow", "solid": False})
ents.append({"id": "ghost", "shape": "ghost", "pos": [-h + C / 2, 0, h - C / 2], "color": "#ECEFF1", "mat": "glow",
             "behaviors": [{"type": "chase", "target": "player", "speed": 3.6}, {"type": "damage", "kill": True}]})
for i in range(5):
    ents.append({"id": f"lamp{i}", "shape": "lamp", "pos": [-h + 0.8 + i * 9.6, 0, -h + 0.8], "size": [0.6, 3.5, 0.6], "color": "#FFD54F"})
maze = {"v": 1, "title": "Ghost Maze", "intro": "Find the green exit. Don't let the ghost catch you!",
        "plan": {"genre": "maze chase", "controls": "topdown", "win": "reach the exit", "theme": "spooky maze"},
        "world": {"size": N * C, "floor": "ground", "floor_color": "#2B2340", "floor_mat": "stone", "sky": "spooky", "light": "dim", "music": "spooky", "walls": True},
        "controls": "topdown", "player": {"spawn": [-h + C / 2, 0, -h + C / 2], "speed": 6, "jump": 0, "lives": 3},
        "entities": ents,
        "rules": {"win": {"type": "reach", "target": "exit"}, "lose": ["no_lives"]},
        "hud": ["lives"]}
json.dump(maze, open(os.path.join(OUT, "ghost_maze.json"), "w"), indent=1)
print("maze walls", len(walls), "entities", len(ents))


# ---------------------------------------------------------------- part B samples
import math

# 4. Three-lap car race around a volcano, against three rival cars.
R, NG = 34.0, 10
ents = [
    {"id": "volcano", "shape": "cone", "pos": [0, 0, 0], "size": [30, 22, 30], "color": "#4E342E", "mat": "stone"},
    {"id": "crater", "shape": "cylinder", "pos": [0, 20.5, 0], "size": [7, 1.2, 7], "color": "#FF5722", "mat": "lava", "solid": False},
    {"id": "lava_pool", "shape": "cylinder", "pos": [0, 0.02, 0], "size": [34, 0.1, 34], "color": "#FF5722", "mat": "lava", "solid": False},
]
for i in range(20):   # dark asphalt ring for the track (decoration only)
    a = i * math.tau / 20
    ents.append({"id": f"road{i}", "shape": "box", "pos": [round(R * math.sin(a), 2), 0.03, round(R * math.cos(a), 2)],
                 "size": [13, 0.06, 11.6], "rot": [0, round(math.degrees(a) + 90, 1), 0], "color": "#37474F", "mat": "asphalt", "solid": False})
for i in range(14):   # rocks and glowing lamps outside the track
    a = i * math.tau / 14 + 0.2
    ents.append({"id": f"rock{i}", "shape": "rock" if i % 2 else "lamp", "pos": [round(48 * math.sin(a), 1), 0, round(48 * math.cos(a), 1)],
                 "size": [4, 3, 4] if i % 2 else [1, 5, 1], "color": "#5D4037" if i % 2 else "#FFAB40"})
gates = []
for i in range(1, NG + 1):   # gate i sits i/NG of the way round; the last one is the start/finish line
    a = (i % NG) * math.tau / NG
    gid = f"gate{i}"
    gates.append(gid)
    ents.append({"id": gid, "shape": "box", "pos": [round(R * math.sin(a), 2), 0, round(R * math.cos(a), 2)], "size": [14, 4, 1.5],
                 "rot": [0, round(math.degrees(a) + 90, 1), 0], "color": "#FFD54F", "solid": False, "hidden": False, "mat": "glass"})
ents.append({"id": "finish_flag", "shape": "flag", "pos": [0, 0, R + 8], "size": [1, 6, 1], "color": "#FFFFFF"})
for i, (col, spd) in enumerate([("#E53935", 13.5), ("#43A047", 12.5), ("#FDD835", 11.5)]):
    ents.append({"id": f"rival{i + 1}", "shape": "car", "pos": [R, 0, 0], "size": [2, 1.3, 3.6], "color": col, "mat": "metal",
                 "tags": ["rival"], "behaviors": [{"type": "race", "speed": spd}]})
race = {"v": 1, "title": "Volcano Grand Prix", "intro": "Three laps round the volcano. Beat the rivals to the line!",
        "plan": {"genre": "racing", "loop": "drive through the gates in order, three laps", "controls": "vehicle", "win": "finish first", "theme": "volcano"},
        "world": {"size": 110, "floor": "ground", "floor_color": "#3E2723", "floor_mat": "stone", "sky": "sunset", "light": "dim", "music": "race", "walls": True},
        "controls": "vehicle", "player": {"spawn": [5, 0, R], "speed": 19, "color": "#1E88E5"},
        "entities": ents,
        "triggers": [{"on": "lap", "value": 2, "do": [{"act": "message", "text": "Last lap, floor it!"}]}],
        "rules": {"win": {"type": "laps", "value": 3}, "laps": 3, "checkpoints": gates, "lose": ["beaten"]},
        "hud": ["laps"]}
json.dump(race, open(os.path.join(OUT, "volcano_race.json"), "w"), indent=1)

# 5. Zombie waves in a graveyard: shoot them before they reach you.
ents = []
for i in range(8):
    a = i * math.tau / 8 + 0.39
    x, z = round(19 * math.sin(a), 1), round(19 * math.cos(a), 1)
    ents.append({"id": f"grave{i}", "shape": "grave", "pos": [x, 0, z], "size": [1.6, 2, 0.5], "rot": [0, round(math.degrees(a), 1), 0], "color": "#90A4AE", "mat": "stone"})
    ents.append({"id": f"rise{i}", "shape": "box", "pos": [round(16.5 * math.sin(a), 1), 0, round(16.5 * math.cos(a), 1)], "size": [1, 0.1, 1],
                 "color": "#4E342E", "solid": False, "tags": ["grave_spawn"]})
for i in range(6):
    a = i * math.tau / 6
    ents.append({"id": f"tree{i}", "shape": "tree", "pos": [round(23 * math.sin(a), 1), 0, round(23 * math.cos(a), 1)], "size": [3, 7, 3], "color": "#37474F"})
for i in range(4):
    a = i * math.tau / 4 + 0.78
    ents.append({"id": f"lamp{i}", "shape": "lamp", "pos": [round(9 * math.sin(a), 1), 0, round(9 * math.cos(a), 1)], "size": [0.8, 4.5, 0.8], "color": "#B2FF59"})
ents.append({"id": "zombie", "template": True, "shape": "character", "pos": [0, 0, -16], "size": [1, 2, 1], "color": "#7CB342",
             "tags": ["enemy"], "behaviors": [{"type": "chase", "speed": 2.4}, {"type": "damage", "amount": 1, "knock": 5},
                                               {"type": "destructible", "hp": 2, "score": 10}]})
ents.append({"id": "heart", "shape": "heart", "pos": [-6, 0.8, 6], "color": "#FF5252", "behaviors": [{"type": "collect", "heal": 2, "score": 0}]})
ents.append({"id": "heart2", "shape": "heart", "pos": [6, 0.8, -6], "color": "#FF5252", "behaviors": [{"type": "collect", "heal": 2, "score": 0}]})
zombies = {"v": 1, "title": "Graveyard Shift", "intro": "Zombies rise from the graves. Hold FIRE and survive three waves!",
           "plan": {"genre": "wave survival shooter", "loop": "shoot the zombies as they rise", "controls": "platformer", "win": "survive 3 waves", "theme": "graveyard at night"},
           "world": {"size": 52, "floor": "ground", "floor_color": "#33402B", "floor_mat": "grass", "sky": "spooky", "light": "dim", "fog": 0.02, "music": "spooky", "walls": True},
           "controls": "platformer", "player": {"spawn": [0, 0, 0], "speed": 7, "jump": 9, "lives": 3, "health": 5, "abilities": ["shoot"],
                                               "shot": {"rate": 0.25, "damage": 1, "speed": 30, "color": "#FFEE58"}},
           "entities": ents,
           "triggers": [{"on": "wave", "value": 3, "do": [{"act": "message", "text": "Here comes the horde!"}]}],
           "rules": {"win": {"type": "waves"}, "lose": ["no_lives"], "wave_gap": 3,
                     "waves": [{"template": "zombie", "count": 4, "every": 1.4, "at": "grave_spawn"},
                               {"template": "zombie", "count": 6, "every": 1.1, "at": "grave_spawn"},
                               {"template": "zombie", "count": 9, "every": 0.8, "at": "grave_spawn"}]},
           "hud": ["wave", "score", "health", "lives"]}
json.dump(zombies, open(os.path.join(OUT, "zombie_graveyard.json"), "w"), indent=1)

# 6. Sumo on a shrinking platform: dash the bots off before they shove you.
ents = [{"id": "ring", "shape": "cylinder", "pos": [0, -1, 0], "size": [22, 1, 22], "color": "#FFB74D", "mat": "wood",
         "behaviors": [{"type": "shrink", "to": 0.45, "time": 45, "delay": 6}]},
        {"id": "ring_edge", "shape": "cylinder", "pos": [0, -1.05, 0], "size": [22.6, 0.9, 22.6], "color": "#E53935", "solid": False,
         "behaviors": [{"type": "shrink", "to": 0.45, "time": 45, "delay": 6}]}]
for i, col in enumerate(["#8E24AA", "#00897B", "#F4511E"]):
    a = i * math.tau / 3 + math.pi / 3
    ents.append({"id": f"bot{i + 1}", "shape": "character", "pos": [round(7 * math.sin(a), 1), 0, round(7 * math.cos(a), 1)], "size": [1.2, 2, 1.2],
                 "color": col, "tags": ["enemy"], "behaviors": [{"type": "chase", "speed": 2.6}, {"type": "damage", "amount": 0, "knock": 7},
                                                                 {"type": "destructible", "hp": 99, "score": 100}]})
sumo = {"v": 1, "title": "Sumo Smash", "intro": "Tap DASH to shove the bots off. The ring is shrinking!",
        "plan": {"genre": "sumo brawler", "loop": "dash into bots to knock them off", "controls": "platformer", "win": "last one standing", "theme": "sky arena"},
        "world": {"size": 60, "floor": "none", "sky": "day", "light": "bright", "music": "action", "walls": False},
        "controls": "platformer", "player": {"spawn": [0, 0, -4], "speed": 7, "jump": 8, "lives": 1, "abilities": ["dash"]},
        "entities": ents,
        "rules": {"win": {"type": "defeat_all"}, "lose": ["no_lives", "time_up"], "timer": 120},
        "hud": ["enemies", "timer"]}
json.dump(sumo, open(os.path.join(OUT, "sumo_shrink.json"), "w"), indent=1)
