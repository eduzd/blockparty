class_name PloxTrade
extends RefCounted
## Trading between friends (0.7.0).
##
## A trade offer names the exact copies (oids) each side gives, plus optional Plux.
## Nothing is held while an offer waits; when the other player accepts, every
## part is checked again and the swap happens in one step in memory (the server
## is single-threaded) and in ONE SQL statement in Neon, so the database can
## never end up with an item copied, lost or half-moved: either every row moves
## and both wallets change, or nothing does.

const MAX_ITEMS := 4          # per side
const MAX_PENDING := 10       # open offers one player can have sent
const EXPIRE_S := 3 * 86400   # open offers lapse after three days
const KEEP_DONE := 30         # finished trades kept per player for the list

var plox                      # PloxHub
var trades := {}              # id -> {id, from, to, give:[oid], get:[oid], cg, cw, status, created, updated, why}


func _init(p_plox) -> void:
	plox = p_plox


func load_rows(rows: Array) -> void:
	for r in rows:
		var t := {"id": str(r.id), "from": str(r.from_uid), "to": str(r.to_uid),
			"give": _split(str(r.give)), "get": _split(str(r.get_oids)), "cg": int(r.coins_give), "cw": int(r.coins_get),
			"status": str(r.status), "created": int(r.created), "updated": int(r.updated), "why": str(r.why)}
		trades[t.id] = t


static func _split(s: String) -> Array:
	var out := []
	for p in s.split(",", false):
		out.append(p)
	return out


static func _join(a: Array) -> String:
	return ",".join(PackedStringArray(a))


## The copy a player owns, as a card the phone can draw. {} when they don't own it.
func _copy(uid: String, oid: String) -> Dictionary:
	var mine: Dictionary = plox.owned.get(uid, {})
	if not mine.has(oid):
		return {}
	var o: Dictionary = mine[oid]
	var it: Dictionary = plox.items.get(o.item, {})
	return {"oid": oid, "item": o.item, "serial": int(o.serial), "name": str(it.get("name", o.item)),
		"art": it.get("art", ""), "col": it.get("col", "#FFFFFF"), "slot": it.get("slot", ""),
		"rare": bool(it.get("rare", false)), "price": int(it.get("price", 0))}


## What a friend owns, for picking what to ask for.
func inventory(uid: String) -> Array:
	var out := []
	for oid in plox.owned.get(uid, {}):
		var c := _copy(uid, oid)
		if not c.is_empty():
			out.append(c)
	out.sort_custom(func(a, b): return (1 if a.rare else 0) > (1 if b.rare else 0) or (a.rare == b.rare and str(a.name) < str(b.name)))
	return out


func _card(t: Dictionary, viewer: String) -> Dictionary:
	var give := []
	for oid in t.give:
		var c := _copy(t.from, oid)
		give.append(c if not c.is_empty() else {"oid": oid, "gone": true})
	var get := []
	for oid in t.get:
		var c := _copy(t.to, oid)
		get.append(c if not c.is_empty() else {"oid": oid, "gone": true})
	var fu: Dictionary = plox.hub.users.get(t.from, {})
	var tu: Dictionary = plox.hub.users.get(t.to, {})
	return {"id": t.id, "from": t.from, "to": t.to, "from_name": str(fu.get("name", "Player")), "to_name": str(tu.get("name", "Player")),
		"from_av": int(fu.get("av", -1)), "to_av": int(tu.get("av", -1)),
		"give": give, "get": get, "cg": int(t.cg), "cw": int(t.cw), "status": t.status,
		"created": int(t.created), "updated": int(t.updated), "why": str(t.get("why", "")), "mine": t.from == viewer}


func list_for(uid: String, now: int) -> Array:
	_expire(now)
	var open := []
	var done := []
	for id in trades:
		var t: Dictionary = trades[id]
		if t.from != uid and t.to != uid:
			continue
		if t.status == "open":
			open.append(t)
		else:
			done.append(t)
	open.sort_custom(func(a, b): return int(a.created) > int(b.created))
	done.sort_custom(func(a, b): return int(a.updated) > int(b.updated))
	var out := []
	for t in open + done.slice(0, KEEP_DONE):
		out.append(_card(t, uid))
	return out


func open_count_for(uid: String) -> int:
	var n := 0
	for id in trades:
		if trades[id].status == "open" and trades[id].to == uid:
			n += 1
	return n


func _expire(now: int) -> void:
	for id in trades:
		var t: Dictionary = trades[id]
		if t.status == "open" and now - int(t.created) > EXPIRE_S:
			_close(t, "expired", "It waited too long.", now)


func _close(t: Dictionary, status: String, why: String, now: int) -> void:
	t.status = status
	t.why = why
	t.updated = now
	plox._db("update plox_trades set status = $2, why = $3, updated = $4 where id = $1 and status = 'open'", [t.id, status, why, now])


## Checks every part of an offer against what both players own right now.
## Returns "" when it is fine, else the reason shown to the player.
func _check(from: String, to: String, give: Array, get: Array, cg: int, cw: int) -> String:
	if not plox.cfg.b("f_trading"):
		return "Trading is switched off right now."
	if from == to:
		return "You can't trade with yourself."
	if plox.cfg.b("trade_pro_only") and not (plox.pay.is_pro(from) and plox.pay.is_pro(to)):
		return "Trading is for Plux Pro members (both players)."
	if not plox.hub.users.has(to) or not plox.hub.users.has(from):
		return "That player doesn't exist."
	if not plox.hub.friends.get(from, {}).has(to):
		return "You can only trade with friends."
	if plox.ban_reason(to) != "" or plox.ban_reason(from) != "":
		return "That account can't trade right now."
	if give.size() > MAX_ITEMS or get.size() > MAX_ITEMS:
		return "Up to %d items on each side." % MAX_ITEMS
	if give.is_empty() and get.is_empty():
		return "Pick at least one item."
	if cg < 0 or cw < 0 or (cg > 0 and cw > 0):
		return "Add Plux on one side only."
	var seen := {}
	var from_items := {}
	var to_items := {}
	for oid in plox.owned.get(from, {}):
		from_items[plox.owned[from][oid].item] = oid
	for oid in plox.owned.get(to, {}):
		to_items[plox.owned[to][oid].item] = oid
	for oid in give:
		if seen.has(oid) or not plox.owned.get(from, {}).has(oid):
			return "An item on offer isn't owned any more."
		seen[oid] = true
		var item: String = plox.owned[from][oid].item
		if to_items.has(item) and not (to_items[item] in get):
			return "%s already has %s." % [str(plox.hub.users[to].get("name", "They")), str(plox.items.get(item, {}).get("name", "that item"))]
	for oid in get:
		if seen.has(oid) or not plox.owned.get(to, {}).has(oid):
			return "An item asked for isn't owned any more."
		seen[oid] = true
		var item: String = plox.owned[to][oid].item
		if from_items.has(item) and not (from_items[item] in give):
			return "%s already has %s." % [str(plox.hub.users[from].get("name", "You")), str(plox.items.get(item, {}).get("name", "that item"))]
	if cg > 0 and int(plox.wallet(from).coins) < cg:
		return "Not enough Plux for this offer."
	if cw > 0 and int(plox.wallet(to).coins) < cw:
		return "They don't have that much Plux."
	return ""


static func _oids(v) -> Array:
	var out := []
	if v is Array:
		for x in v:
			var s := str(x)
			if s.length() > 0 and s.length() <= 40 and s.is_valid_hex_number(false):
				out.append(s)
			if out.size() > MAX_ITEMS + 1:
				break
	return out


static func _coins(v) -> int:
	if v is int or v is float:
		if is_nan(float(v)) or is_inf(float(v)):
			return -1
		return clampi(int(v), -1, 100000000)
	return 0


func offer(me: String, msg: Dictionary, now: int) -> Dictionary:
	var res := {"t": "s_trade_res", "ok": false, "why": "", "act": "offer"}
	_expire(now)
	var to := str(msg.get("to", ""))
	var give := _oids(msg.get("give"))
	var get := _oids(msg.get("get"))
	var cg := _coins(msg.get("cg", 0))
	var cw := _coins(msg.get("cw", 0))
	var mine := 0
	for id in trades:
		if trades[id].status == "open" and trades[id].from == me:
			mine += 1
	if mine >= MAX_PENDING:
		res.why = "You have %d offers waiting. Cancel one first." % MAX_PENDING
		return res
	var why := _check(me, to, give, get, cg, cw)
	if why != "":
		res.why = why
		return res
	var t := {"id": Crypto.new().generate_random_bytes(8).hex_encode(), "from": me, "to": to, "give": give, "get": get,
		"cg": cg, "cw": cw, "status": "open", "created": now, "updated": now, "why": ""}
	trades[t.id] = t
	plox._db("insert into plox_trades (id, from_uid, to_uid, give, get_oids, coins_give, coins_get, status, created, updated) values ($1, $2, $3, $4, $5, $6, $7, 'open', $8, $8)",
		[t.id, me, to, _join(give), _join(get), cg, cw, now])
	plox.count("trade_offers")
	res.ok = true
	res["trade"] = _card(t, me)
	plox.hub._push(to, {"t": "s_trade_new", "trade": _card(t, to)})
	return res


func accept(me: String, id: String, now: int) -> Dictionary:
	var res := {"t": "s_trade_res", "ok": false, "why": "", "act": "accept"}
	_expire(now)
	if not trades.has(id) or trades[id].to != me:
		res.why = "That trade doesn't exist."
		return res
	var t: Dictionary = trades[id]
	if t.status != "open":
		res.why = "This trade is already %s." % t.status
		return res
	var why := _check(t.from, t.to, t.give, t.get, int(t.cg), int(t.cw))
	if why != "":
		_close(t, "failed", why, now)
		res.why = "The trade can't go through: " + why
		res["trade"] = _card(t, me)
		plox.hub._push(t.from, {"t": "s_trade_upd", "trade": _card(t, t.from)})
		return res
	# Everything checked: swap in memory. No await between here and the SQL line.
	var a: String = t.from
	var b: String = t.to
	if not plox.owned.has(a):
		plox.owned[a] = {}
	if not plox.owned.has(b):
		plox.owned[b] = {}
	for oid in t.give:
		plox.owned[b][oid] = plox.owned[a][oid]
		plox.owned[a].erase(oid)
	for oid in t.get:
		plox.owned[a][oid] = plox.owned[b][oid]
		plox.owned[b].erase(oid)
	var wa: Dictionary = plox.wallet(a)
	var wb: Dictionary = plox.wallet(b)
	var delta := int(t.cw) - int(t.cg)   # what a gains
	wa.coins = int(wa.coins) + delta
	wb.coins = int(wb.coins) - delta
	# Items that left are taken off.
	for pair in [[a, wa], [b, wb]]:
		var have := {}
		for oid in plox.owned[pair[0]]:
			have[plox.owned[pair[0]][oid].item] = true
		var eq := []
		for e in pair[1].eq:
			if have.has(e):
				eq.append(e)
		pair[1].eq = eq
	t.status = "done"
	t.why = ""
	t.updated = now
	# One statement, all or nothing. The checks inside it make sure the rows are
	# still where we think they are; if any is not, nothing at all changes.
	var n_give: int = t.give.size()
	var n_get: int = t.get.size()
	plox._db("with chk as (select 1 where (select count(*) from plox_owned where uid = $1 and oid = any(string_to_array($3, ','))) = $5::int "
		+ "and (select count(*) from plox_owned where uid = $2 and oid = any(string_to_array($4, ','))) = $6::int "
		+ "and (select coalesce(sum(case when uid = $1 then coins else 0 end), 0) from plox_wallet where uid in ($1, $2)) >= greatest(-($7::bigint), 0) "
		+ "and (select coalesce(sum(case when uid = $2 then coins else 0 end), 0) from plox_wallet where uid in ($1, $2)) >= greatest($7::bigint, 0)), "
		+ "m1 as (update plox_owned set uid = case when uid = $1 then $2 else $1 end, ts = $8::bigint where exists (select 1 from chk) and "
		+ "((uid = $1 and oid = any(string_to_array($3, ','))) or (uid = $2 and oid = any(string_to_array($4, ',')))) returning oid), "
		+ "m2 as (update plox_wallet set coins = coins + case when uid = $1 then $7::bigint else -($7::bigint) end, "
		+ "eq = case when uid = $1 then $10 else $11 end where exists (select 1 from chk) and uid in ($1, $2) returning uid) "
		+ "update plox_trades set status = 'done', updated = $8::bigint, why = '' where id = $9 and exists (select 1 from chk)",
		[a, b, _join(t.give), _join(t.get), n_give, n_get, delta, now, t.id, _join(wa.eq), _join(wb.eq)])
	# Every other open offer that used one of these copies or now can't be paid is stale.
	for oid2 in trades:
		var o: Dictionary = trades[oid2]
		if o.status != "open" or o.id == t.id:
			continue
		if o.from in [a, b] or o.to in [a, b]:
			var w2 := _check(o.from, o.to, o.give, o.get, int(o.cg), int(o.cw))
			if w2 != "":
				_close(o, "failed", w2, now)
				for u in [o.from, o.to]:
					plox.hub._push(u, {"t": "s_trade_upd", "trade": _card(o, u)})
	plox.count("trades")
	plox._audit_as("system", "trade", "%s <-> %s: %d item(s) for %d item(s), Plux %+d" % [str(plox.hub.users[a].get("name", a)), str(plox.hub.users[b].get("name", b)), n_give, n_get, delta])
	res.ok = true
	res["trade"] = _card(t, me)
	res["eco"] = plox._eco(me)
	plox.hub._push(a, {"t": "s_trade_upd", "trade": _card(t, a), "eco": plox._eco(a)})
	for u in [a, b]:
		for f in plox.hub.friends.get(u, {}):
			plox.hub._push(f, {"t": "s_look", "uid": u, "eq": plox.equipped_cards(u)})
	return res


func refuse(me: String, id: String, now: int, act: String) -> Dictionary:
	var res := {"t": "s_trade_res", "ok": false, "why": "", "act": act}
	if not trades.has(id):
		res.why = "That trade doesn't exist."
		return res
	var t: Dictionary = trades[id]
	if (act == "decline" and t.to != me) or (act == "cancel" and t.from != me):
		res.why = "That trade doesn't exist."
		return res
	if t.status != "open":
		res.why = "This trade is already %s." % t.status
		return res
	_close(t, "declined" if act == "decline" else "cancelled", "", now)
	res.ok = true
	res["trade"] = _card(t, me)
	var other: String = t.from if act == "decline" else t.to
	plox.hub._push(other, {"t": "s_trade_upd", "trade": _card(t, other)})
	return res


## For the admin app.
func admin_list(q: String) -> Array:
	var list := trades.values()
	list.sort_custom(func(x, y): return int(x.updated) > int(y.updated))
	var out := []
	for t in list:
		var c := _card(t, "")
		var fu: Dictionary = plox.hub.users.get(t.from, {})
		var tu: Dictionary = plox.hub.users.get(t.to, {})
		var hay := (str(c.from_name) + " " + str(c.to_name) + " " + str(fu.get("username", "")) + " " + str(tu.get("username", ""))).to_lower()
		if q != "" and not (q in hay or q == t.from or q == t.to):
			continue
		out.append(c)
		if out.size() >= 80:
			break
	return out
