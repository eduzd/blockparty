class_name PloxCatalog
extends RefCounted
## The starting avatar shop (0.6.0). Prices are in Plux, the in-app currency,
## earned by playing; there is no real-money purchase yet. The server keeps the
## live catalogue (admins can add, edit and price items and set limited stock),
## and these are only the items it starts with.
##
## slot: hat | face | back | effect. art: how ItemArt draws it.
## stock: -1 = unlimited, otherwise the total number of copies ever sold.
## rare: limited items, numbered (#1, #2...) and tradable later.

const SLOTS := ["hat", "face", "back", "effect"]
const SLOT_NAMES := {"hat": "Hats", "face": "Face", "back": "Back", "effect": "Effects"}
const ARTS := ["cap", "tophat", "crown", "party", "beanie", "halo", "horns", "propeller", "bow", "chef",
	"shades", "glasses", "mask", "monocle", "blush", "wings", "cape", "jetpack", "backpack", "guitar",
	"sparkle", "fire", "hearts", "rainbow", "snow", "bubbles"]

const DEFAULT_ITEMS := [
	{"id": "cap_sky", "name": "Sky Cap", "slot": "hat", "art": "cap", "col": "#1E88E5", "price": 40},
	{"id": "beanie_pink", "name": "Cosy Beanie", "slot": "hat", "art": "beanie", "col": "#EC407A", "price": 60},
	{"id": "party_hat", "name": "Party Hat", "slot": "hat", "art": "party", "col": "#FFCA28", "price": 80},
	{"id": "bow_red", "name": "Big Bow", "slot": "hat", "art": "bow", "col": "#EF5350", "price": 90},
	{"id": "chef_hat", "name": "Chef Hat", "slot": "hat", "art": "chef", "col": "#FFFFFF", "price": 120},
	{"id": "propeller", "name": "Propeller Cap", "slot": "hat", "art": "propeller", "col": "#26C6DA", "price": 150},
	{"id": "top_hat", "name": "Top Hat", "slot": "hat", "art": "tophat", "col": "#37474F", "price": 200},
	{"id": "horns", "name": "Little Horns", "slot": "hat", "art": "horns", "col": "#FF7043", "price": 250},
	{"id": "halo", "name": "Halo", "slot": "hat", "art": "halo", "col": "#FFD54F", "price": 300},
	{"id": "crown_gold", "name": "Golden Crown", "slot": "hat", "art": "crown", "col": "#FFC107", "price": 1500, "rare": true, "stock": 50},
	{"id": "shades", "name": "Cool Shades", "slot": "face", "art": "shades", "col": "#212121", "price": 60},
	{"id": "glasses", "name": "Round Glasses", "slot": "face", "art": "glasses", "col": "#5D4037", "price": 50},
	{"id": "blush", "name": "Rosy Cheeks", "slot": "face", "art": "blush", "col": "#F48FB1", "price": 30},
	{"id": "monocle", "name": "Fancy Monocle", "slot": "face", "art": "monocle", "col": "#FFC107", "price": 180},
	{"id": "ninja_mask", "name": "Ninja Mask", "slot": "face", "art": "mask", "col": "#263238", "price": 140},
	{"id": "backpack", "name": "Backpack", "slot": "back", "art": "backpack", "col": "#66BB6A", "price": 70},
	{"id": "cape_red", "name": "Hero Cape", "slot": "back", "art": "cape", "col": "#E53935", "price": 160},
	{"id": "guitar", "name": "Guitar", "slot": "back", "art": "guitar", "col": "#FF7043", "price": 220},
	{"id": "jetpack", "name": "Jetpack", "slot": "back", "art": "jetpack", "col": "#90A4AE", "price": 400},
	{"id": "wings_angel", "name": "Angel Wings", "slot": "back", "art": "wings", "col": "#FFFFFF", "price": 2500, "rare": true, "stock": 25},
	{"id": "fx_sparkle", "name": "Sparkles", "slot": "effect", "art": "sparkle", "col": "#FFCA28", "price": 120},
	{"id": "fx_hearts", "name": "Floating Hearts", "slot": "effect", "art": "hearts", "col": "#EC407A", "price": 150},
	{"id": "fx_bubbles", "name": "Bubbles", "slot": "effect", "art": "bubbles", "col": "#4FC3F7", "price": 100},
	{"id": "fx_snow", "name": "Snowfall", "slot": "effect", "art": "snow", "col": "#E3F2FD", "price": 140},
	{"id": "fx_fire", "name": "Fire Aura", "slot": "effect", "art": "fire", "col": "#FF7043", "price": 600},
	{"id": "fx_rainbow", "name": "Rainbow Ring", "slot": "effect", "art": "rainbow", "col": "#AB47BC", "price": 5000, "rare": true, "stock": 10},
]


## Checks an item an admin sends. Returns the cleaned item or {} when invalid.
static func clean_item(d) -> Dictionary:
	if not (d is Dictionary):
		return {}
	var id := str(d.get("id", "")).to_lower().strip_edges()
	var ok_id := id.length() >= 2 and id.length() <= 32
	for ch in id:
		if not (ch in "abcdefghijklmnopqrstuvwxyz0123456789_"):
			ok_id = false
	var slot := str(d.get("slot", ""))
	var art := str(d.get("art", ""))
	if not ok_id or not SLOTS.has(slot) or not ARTS.has(art):
		return {}
	var col := str(d.get("col", "#1E88E5"))
	if not Color.html_is_valid(col):
		col = "#1E88E5"
	var price = d.get("price", 100)
	var stock = d.get("stock", -1)
	var out := {"id": id, "name": str(d.get("name", id)).strip_edges().substr(0, 30), "slot": slot, "art": art,
		"col": col, "price": clampi(int(price) if (price is int or price is float) else 100, 0, 10000000),
		"rare": bool(d.get("rare", false)) if d.get("rare", false) is bool else false,
		"stock": clampi(int(stock) if (stock is int or stock is float) else -1, -1, 1000000),
		"hidden": bool(d.get("hidden", false)) if d.get("hidden", false) is bool else false}
	if out.name == "":
		out.name = id
	return out
