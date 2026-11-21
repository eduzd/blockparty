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
