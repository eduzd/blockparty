class_name PloxAi
extends RefCounted
## 0.7.2: reads AI replies the way real routers send them. Omni Route / Dot Route
## combos can answer as plain OpenAI JSON, as a stream ("data: ..." lines), with the
## text split into parts, with the answer only in a reasoning field, wrapped in code
## fences or prose, or cut off when the token limit is hit. These helpers pull the text
## out of any of those, find the level JSON inside it, repair small mistakes and
## close a reply that was cut off, so a good answer is never thrown away.

## Returns {"text", "reasoning", "finish", "shape"}.
static func reply_text(raw: String) -> Dictionary:
	var t := raw.strip_edges()
	if t.begins_with("data:") or t.contains("\ndata:") or t.begins_with("event:"):
		return _sse(t)
	var j = parse(t)
	if j is Dictionary:
		return _from_obj(j)
	return {"text": "", "reasoning": "", "finish": "", "shape": "not JSON"}


## JSON.parse without printing errors to the server log.
static func parse(s: String):
	var j := JSON.new()
	if j.parse(s) != OK:
		return null
	return j.data


static func _s(v) -> String:
	return "" if v == null else str(v)


static func _flat(v) -> String:
	if v is String:
		return v
	if v is Array:
		var out := ""
		for x in v:
			if x is String:
				out += x
			elif x is Dictionary:
				if x.get("type", "") in ["thinking", "reasoning"]:
					continue
				out += _flat(x.get("text", x.get("content", "")))
		return out
	if v is Dictionary:
		return _flat(v.get("text", v.get("content", "")))
	return ""


static func _from_obj(j: Dictionary) -> Dictionary:
	var out := {"text": "", "reasoning": "", "finish": "", "shape": ""}
	var ch = j.get("choices")
	if ch is Array and not ch.is_empty() and ch[0] is Dictionary:
		var c0: Dictionary = ch[0]
		out.shape = "openai"
		out.finish = _s(c0.get("finish_reason"))
		var m = c0.get("message", c0.get("delta"))
		if m is Dictionary:
			out.text = _flat(m.get("content"))
			out.reasoning = _flat(m.get("reasoning_content", m.get("reasoning", "")))
			if out.text.strip_edges() == "" and m.get("tool_calls") is Array and not (m.tool_calls as Array).is_empty():
				var tc = m.tool_calls[0]
				if tc is Dictionary and tc.get("function") is Dictionary:
					out.text = _s(tc.function.get("arguments"))
			if out.text.strip_edges() == "" and m.get("refusal") is String:
				out.reasoning = "refused: " + str(m.refusal)
		if out.text == "" and c0.get("text") is String:
			out.text = c0.text
	elif j.get("content") is Array:
		out.shape = "anthropic"
		out.text = _flat(j.content)
		out.finish = _s(j.get("stop_reason"))
	elif j.get("output_text") is String:
		out.shape = "responses"
		out.text = j.output_text
	elif j.get("output") is Array:
		out.shape = "responses"
		for o in j.output:
			if o is Dictionary and o.get("type", "") != "reasoning":
				out.text += _flat(o.get("content", ""))
	elif j.get("candidates") is Array and not (j.candidates as Array).is_empty() and j.candidates[0] is Dictionary:
		out.shape = "gemini"
		var cc = j.candidates[0].get("content")
		if cc is Dictionary:
			out.text = _flat(cc.get("parts", []))
		out.finish = _s(j.candidates[0].get("finishReason"))
	elif j.get("message") is Dictionary:
		out.shape = "ollama"
		out.text = _flat(j.message.get("content"))
	elif j.get("response") is String:
		out.shape = "ollama"
		out.text = j.response
	elif j.has("parts") or j.has("level"):
		# Some proxies hand back the model's JSON directly.
		out.shape = "bare"
		out.text = JSON.stringify(j)
	else:
		out.shape = "unknown"
	return out


static func _sse(t: String) -> Dictionary:
	var out := {"text": "", "reasoning": "", "finish": "", "shape": "stream"}
	for line in t.split("\n"):
		var l := line.strip_edges()
		if not l.begins_with("data:"):
			continue
		l = l.substr(5).strip_edges()
		if l == "" or l == "[DONE]":
			continue
		var j = parse(l)
		if not (j is Dictionary):
			continue
		var part := _from_obj(j)
		out.text += part.text
		out.reasoning += part.reasoning
		if part.finish != "":
			out.finish = part.finish
		# Anthropic-style streams
		if j.get("delta") is Dictionary and j.delta.get("text") is String:
			out.text += j.delta.text
	return out


## Finds the level object in a reply. Returns a Dictionary or null.
static func find_level(text: String):
	var s := _strip_think(text)
	var tries := []
	# Code fences first: ```json ... ```
	var at := s.find("```")
	while at >= 0:
		var nl := s.find("\n", at)
		var end := s.find("```", at + 3)
		if nl < 0:
			break
		if end < 0:
			tries.append(s.substr(nl + 1))   # fence never closed: reply was cut off
			break
		if end > nl:
			tries.append(s.substr(nl + 1, end - nl - 1))
		at = s.find("```", end + 3)
	tries.append(s)
	var best = null
	for chunk in tries:
		var got = _best_object(chunk)
		if got is Dictionary:
			if _level_of(got) != null:
				return _level_of(got)
			if best == null:
				best = got
	return best


static func _strip_think(s: String) -> String:
	for tag in ["think", "thinking", "reasoning"]:
		var a := s.find("<%s>" % tag)
		while a >= 0:
			var b := s.find("</%s>" % tag, a)
			if b < 0:
				break
			s = s.substr(0, a) + s.substr(b + tag.length() + 3)
			a = s.find("<%s>" % tag)
	return s


## A level, maybe wrapped in {"level": {...}} or {"game": {...}}.
static func _level_of(o):
	if not (o is Dictionary):
		return null
	if (o.get("parts") is Array and not (o.parts as Array).is_empty()) or (o.get("objects") is Array and not (o.objects as Array).is_empty()):
		return o
	for k in ["level", "game", "data", "result", "map", "course", "obby"]:
		var inner = o.get(k)
		if inner is Dictionary:
			var l = _level_of(inner)
			if l != null:
				if not l.has("title") and o.has("title"):
					l["title"] = o.title
				return l
	if o.get("levels") is Array and not (o.levels as Array).is_empty():
		return _level_of(o.levels[0])
	return null


## Tries every top-level {...} in the text, as is, repaired, and closed if cut off.
static func _best_object(s: String):
	var first = null
	var a := s.find("{")
	var n := 0
	while a >= 0 and n < 12:
		n += 1
		var b := _match_brace(s, a)
		var chunk := s.substr(a) if b < 0 else s.substr(a, b - a + 1)
		var o = parse(chunk)
		if not (o is Dictionary):
			o = parse(repair(chunk))
		if not (o is Dictionary) and b < 0:
			o = parse(close_cut(repair(chunk)))
		if o is Dictionary:
			if _level_of(o) != null:
				return o
			if first == null:
				first = o
		if b < 0:
			break
		a = s.find("{", b + 1)
	return first


## Index of the } that closes the { at a, or -1 if the text ends first. Knows strings.
static func _match_brace(s: String, a: int) -> int:
	var depth := 0
	var in_str := false
	var esc := false
	for i in range(a, s.length()):
		var c := s[i]
		if in_str:
			if esc:
				esc = false
			elif c == "\\":
				esc = true
			elif c == "\"":
				in_str = false
			continue
		if c == "\"":
			in_str = true
		elif c == "{" or c == "[":
			depth += 1
		elif c == "}" or c == "]":
			depth -= 1
			if depth == 0:
				return i
	return -1


## Fixes the small mistakes models make: smart quotes, // and /* */ comments,
## trailing commas, Python True/False/None, NaN.
static func repair(s: String) -> String:
	s = s.replace("\u201c", "\"").replace("\u201d", "\"").replace("\u2018", "'").replace("\u2019", "'")
	var out := ""
	var in_str := false
	var esc := false
	var i := 0
	var L := s.length()
	while i < L:
		var c := s[i]
		if in_str:
			out += c
			if esc:
				esc = false
			elif c == "\\":
				esc = true
			elif c == "\"":
				in_str = false
			elif c == "\n":
				out = out.substr(0, out.length() - 1) + "\\n"
			i += 1
			continue
		if c == "\"":
			in_str = true
			out += c
		elif c == "/" and i + 1 < L and s[i + 1] == "/":
			while i < L and s[i] != "\n":
				i += 1
			continue
		elif c == "/" and i + 1 < L and s[i + 1] == "*":
			var e := s.find("*/", i + 2)
			i = L if e < 0 else e + 2
			continue
		elif c == ",":
			var k := i + 1
			while k < L and s[k] in [" ", "\n", "\r", "\t"]:
				k += 1
			if k < L and (s[k] == "}" or s[k] == "]"):
				i += 1
				continue
			out += c
		elif c.unicode_at(0) >= 65 and c.unicode_at(0) <= 90 and (i == 0 or not _wordch(s[i - 1])):
			var handled := false
			for pair in [["True", "true"], ["False", "false"], ["None", "null"], ["NaN", "0"]]:
				if s.substr(i, pair[0].length()) == pair[0] and (i + pair[0].length() >= L or not _wordch(s[i + pair[0].length()])):
					out += pair[1]
					i += pair[0].length()
					handled = true
					break
			if handled:
				continue
			out += c
		else:
			out += c
		i += 1
	return out


static func _wordch(c: String) -> bool:
	var u := c.unicode_at(0)
	return (u >= 48 and u <= 57) or (u >= 65 and u <= 90) or (u >= 97 and u <= 122) or c == "_"


## Closes JSON that was cut off mid-way (the token limit): cuts back to the last
## complete value and adds the missing ] and }.
static func close_cut(s: String) -> String:
	var stack := ""
	var in_str := false
	var esc := false
	var cut := -1
	var cut_stack := ""
	for i in s.length():
		var c := s[i]
		if in_str:
			if esc:
				esc = false
			elif c == "\\":
				esc = true
			elif c == "\"":
				in_str = false
			continue
		if c == "\"":
			in_str = true
		elif c == "{" or c == "[":
			stack += c
		elif c == "}" or c == "]":
			stack = stack.substr(0, stack.length() - 1)
			cut = i + 1
			cut_stack = stack
			if stack == "":
				return s.substr(0, i + 1)
	if cut < 0:
		return s
	var out := s.substr(0, cut)
	for k in range(cut_stack.length() - 1, -1, -1):
		out += "}" if cut_stack[k] == "{" else "]"
	return out


## A short, safe preview of a reply for the usage log (never includes the key).
static func preview(s: String, n := 140) -> String:
	var p := s.strip_edges().replace("\n", " ").replace("\r", " ")
	while p.contains("  "):
		p = p.replace("  ", " ")
	return p.substr(0, n) + ("..." if p.length() > n else "")
