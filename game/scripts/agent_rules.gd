class_name AgentRules
extends RefCounted
## 0.7.1: rules for AI agents, picked with dropdowns and switches in Plux Admin.
## The server sends SCHEMA to the admin app, so new options need no app update.
## Each choice adds a fixed sentence to the agent's instructions; some are also
## enforced on the result (allowed objects, most objects), so the AI can't ignore them.

const SCHEMA := [
	# For every agent
	{"key": "tone", "label": "Tone", "type": "choice", "for": ["all"], "default": "friendly",
		"choices": [["friendly", "Friendly"], ["funny", "Funny"], ["serious", "Serious"]],
		"rule": {"friendly": "Be warm and friendly.", "funny": "Be playful and a little funny.", "serious": "Be calm and to the point."}},
	{"key": "strict", "label": "Strictness", "type": "choice", "for": ["all"], "default": "normal",
		"choices": [["relaxed", "Relaxed"], ["normal", "Normal"], ["strict", "Strict"]],
		"rule": {"relaxed": "Only refuse things that are clearly unsafe.", "normal": "Refuse anything unsafe or unkind.", "strict": "When in doubt, refuse and pick the safest option."}},
	{"key": "age", "label": "Age rating", "type": "choice", "for": ["all"], "default": "all",
		"choices": [["all", "All ages"], ["9", "9+"], ["13", "13+"]],
		"rule": {"all": "Everything must be suitable for young children.", "9": "Everything must be suitable for players aged 9 and up.", "13": "Everything must be suitable for players aged 13 and up."}},
	{"key": "lang", "label": "Language", "type": "choice", "for": ["all"], "default": "en",
		"choices": [["en", "English"], ["auto", "Same as the player"]],
		"rule": {"en": "Write any text in English.", "auto": "Write any text in the same language the player used."}},
	{"key": "length", "label": "Response length", "type": "choice", "for": ["support_helper", "npc", "custom"], "default": "short",
		"choices": [["short", "Short"], ["medium", "Medium"], ["long", "Detailed"]],
		"rule": {"short": "Keep replies to one or two sentences.", "medium": "Keep replies to a short paragraph.", "long": "Give full, detailed replies."}},
	{"key": "no_violence", "label": "No violence", "type": "toggle", "for": ["all"], "default": true,
		"rule": {"on": "No violence, weapons or gore."}},
	{"key": "no_scary", "label": "No scary themes", "type": "toggle", "for": ["all"], "default": false,
		"rule": {"on": "No horror or scary themes."}},
	{"key": "no_personal", "label": "No personal info", "type": "toggle", "for": ["all"], "default": true,
		"rule": {"on": "Never ask for or repeat personal information such as real names, addresses, phone numbers or passwords."}},
	# Studio Builder and Game Editor
	{"key": "size", "label": "Game size", "type": "choice", "for": ["studio_builder", "game_editor"], "default": "medium",
		"choices": [["small", "Small"], ["medium", "Medium"], ["large", "Large"]],
		"rule": {"small": "Make a short course that takes under a minute.", "medium": "Make a course that takes one to two minutes.", "large": "Make a long course that takes a few minutes."}},
	{"key": "difficulty", "label": "Difficulty", "type": "choice", "for": ["studio_builder", "game_editor"], "default": "normal",
		"choices": [["easy", "Easy"], ["normal", "Normal"], ["hard", "Hard"]],
		"rule": {"easy": "Keep gaps small and hazards few, so beginners can finish.", "normal": "Mix easy and tricky parts.", "hard": "Make it a real challenge, with wider gaps and more hazards."}},
	{"key": "max_parts", "label": "Most objects", "type": "choice", "for": ["studio_builder", "game_editor"], "default": "60",
		"choices": [["30", "30"], ["60", "60"], ["90", "90"]],
		"rule": {"30": "Use at most 30 parts.", "60": "Use at most 60 parts.", "90": "Use at most 90 parts."}},
	{"key": "theme", "label": "Theme", "type": "choice", "for": ["studio_builder"], "default": "any",
		"choices": [["any", "Player's choice"], ["sky", "Sky islands"], ["lava", "Volcano"], ["ice", "Ice world"], ["candy", "Candy land"], ["space", "Space"]],
		"rule": {"any": "", "sky": "Unless the player asks otherwise, theme it as floating sky islands.", "lava": "Unless the player asks otherwise, theme it as a volcano.", "ice": "Unless the player asks otherwise, theme it as an ice world.", "candy": "Unless the player asks otherwise, theme it as a bright candy land.", "space": "Unless the player asks otherwise, theme it in space."}},
	{"key": "allow_lava", "label": "Lava", "group": "Allowed objects", "type": "toggle", "for": ["studio_builder", "game_editor"], "default": true, "kind": "lava", "rule": {"off": "Do not use lava."}},
	{"key": "allow_bounce", "label": "Jump pads", "group": "Allowed objects", "type": "toggle", "for": ["studio_builder", "game_editor"], "default": true, "kind": "bounce", "rule": {"off": "Do not use jump pads."}},
	{"key": "allow_spinner", "label": "Hammers", "group": "Allowed objects", "type": "toggle", "for": ["studio_builder", "game_editor"], "default": true, "kind": "spinner", "rule": {"off": "Do not use spinning hammers."}},
	{"key": "allow_mover", "label": "Moving platforms", "group": "Allowed objects", "type": "toggle", "for": ["studio_builder", "game_editor"], "default": true, "kind": "mover", "rule": {"off": "Do not use moving platforms."}},
	{"key": "allow_ice", "label": "Ice", "group": "Allowed objects", "type": "toggle", "for": ["studio_builder", "game_editor"], "default": true, "kind": "ice", "rule": {"off": "Do not use ice."}},
	{"key": "allow_coin", "label": "Stars", "group": "Allowed objects", "type": "toggle", "for": ["studio_builder", "game_editor"], "default": true, "kind": "coin", "rule": {"off": "Do not use stars."}},
	# Chat Moderator
	{"key": "block_swear", "label": "Swearing", "group": "Block", "type": "toggle", "for": ["chat_moderator"], "default": true, "rule": {"on": "Flag swearing."}},
	{"key": "block_bully", "label": "Bullying", "group": "Block", "type": "toggle", "for": ["chat_moderator"], "default": true, "rule": {"on": "Flag bullying and insults."}},
	{"key": "block_links", "label": "Links", "group": "Block", "type": "toggle", "for": ["chat_moderator"], "default": true, "rule": {"on": "Flag links to other sites."}},
	{"key": "block_contact", "label": "Contact details", "group": "Block", "type": "toggle", "for": ["chat_moderator"], "default": true, "rule": {"on": "Flag phone numbers, emails, addresses and social media handles."}},
	{"key": "block_spam", "label": "Spam", "group": "Block", "type": "toggle", "for": ["chat_moderator"], "default": true, "rule": {"on": "Flag spam and repeated messages."}},
	{"key": "action", "label": "Action", "type": "choice", "for": ["chat_moderator"], "default": "hide",
		"choices": [["warn", "Warn the player"], ["hide", "Hide the message"], ["mute", "Mute for 10 minutes"]],
		"rule": {"warn": "When you flag a message, the action is: warn the player.", "hide": "When you flag a message, the action is: hide it.", "mute": "When you flag a message, the action is: mute the player for 10 minutes."}},
]


static func applies(opt: Dictionary, agent_id: String, builtin: bool) -> bool:
	var f: Array = opt.get("for", ["all"])
	return f.has("all") or f.has(agent_id) or (not builtin and f.has("custom"))


static func clean_opts(raw, agent_id: String, builtin: bool) -> Dictionary:
	var out := {}
	var d: Dictionary = raw if raw is Dictionary else {}
	for opt in SCHEMA:
		if not applies(opt, agent_id, builtin):
			continue
		var v = d.get(opt.key, opt.default)
		if opt.type == "toggle":
			out[opt.key] = v if v is bool else opt.default
		else:
			var ok := false
			for c in opt.choices:
				if str(v) == c[0]:
					ok = true
			out[opt.key] = str(v) if ok else opt.default
	return out


## The agent's full instructions: one sentence per choice, then the admin's extra rules.
static func compose(agent: Dictionary) -> String:
	var opts := clean_opts(agent.get("opts", {}), str(agent.get("id", "")), bool(agent.get("builtin", false)))
	var lines := []
	if str(agent.get("job", "")).strip_edges() != "" and not bool(agent.get("builtin", false)):
		lines.append("Your job: " + str(agent.job).strip_edges())
	for opt in SCHEMA:
		if not opts.has(opt.key):
			continue
		var v = opts[opt.key]
		var key: String = ("on" if v else "off") if opt.type == "toggle" else str(v)
		var t := str(opt.rule.get(key, ""))
		if t != "":
			lines.append("- " + t)
	var extra := str(agent.get("rules", "")).strip_edges()
	if extra != "":
		lines.append("Extra rules:\n" + extra)
	return "\n".join(PackedStringArray(lines))


## Enforces what can be checked on a Studio level: allowed objects and most objects.
static func enforce_level(level: Dictionary, agent: Dictionary) -> Dictionary:
	var opts := clean_opts(agent.get("opts", {}), str(agent.get("id", "")), bool(agent.get("builtin", false)))
	if not opts.has("max_parts"):
		return level
	var banned := {}
	for opt in SCHEMA:
		if opt.has("kind") and opts.has(opt.key) and not opts[opt.key]:
			banned[opt.kind] = true
	var cap := int(opts.max_parts)
	var parts := []
	for p in level.get("parts", []):
		var k := str(p[0]) if p is Array and p.size() > 0 else ""
		if banned.has(k):
			if k == "lava" or k == "ice":
				var q: Array = p.duplicate()
				q[0] = "block"
				parts.append(q)
			continue
		if parts.size() < cap:
			parts.append(p)
	level["parts"] = parts
	return level
