class_name PloxPay
extends RefCounted
## Buying Plux with real money (0.7.0).
##
## The phone never says "I paid". It asks for an order, pays the provider, and
## the server credits Plux only after it has confirmed the payment itself:
##   sandbox   - test mode, no money moves. Only usernames on the tester list can
##               use it, and every order is marked as a test in the admin app.
##   play / razorpay / stripe - live providers. Each one plugs in at _verify_live():
##               the server checks the purchase with the provider using a secret the
##               phone never sees. None is set up yet, so live orders are refused.
## An order is credited at most once: memory and the database both move it from
## "created" to "paid" in one step, and a provider payment id can only ever be
## used for one order (unique in the database).

const ORDER_TTL_S := 86400
const MAX_OPEN := 5

var plox                         # PloxHub
var orders := {}                 # id -> {id, uid, pack, plux, price, cur, provider, mode, status, created, paid, ref}
var used_refs := {}              # provider payment id -> order id
var pro := {}                    # uid -> {tier, until, source, auto, allow}  (Plux Pro, 0.7.0)
const PRO_DAYS := 30


func _init(p_plox) -> void:
	plox = p_plox


func load_rows(rows: Array) -> void:
	for r in rows:
		var o := {"id": str(r.id), "uid": str(r.uid), "pack": str(r.pack), "plux": int(r.plux), "price": float(str(r.price)),
			"cur": str(r.cur), "provider": str(r.provider), "mode": str(r.mode), "status": str(r.status),
			"created": int(r.created), "paid": int(r.paid), "ref": str(r.pay_ref) if r.pay_ref != null else ""}
		orders[o.id] = o
		if o.ref != "":
			used_refs[o.ref] = o.id


func load_pro(rows: Array) -> void:
	for r in rows:
		pro[str(r.uid)] = {"tier": str(r.tier), "until": int(r.until_ts), "source": str(r.source), "auto": bool(r.auto_renew), "allow": int(r.last_allow)}


func tiers() -> Array:
	return LiveConfig.clean_tiers(plox.cfg.s("pro_tiers"))


func tier_of(uid: String) -> Dictionary:
	var p: Dictionary = pro.get(uid, {})
	if p.is_empty() or int(p.until) <= int(Time.get_unix_time_from_system()):
		return {}
	for t in tiers():
		if t.id == p.tier:
			return t
	# Tier removed from the list later: still Pro, with the first tier's perks.
	var all := tiers()
	return all[0] if not all.is_empty() else {"id": p.tier, "name": "Plux Pro", "plux_month": 0, "buy_bonus": 0, "ai_extra": 0, "outfits": 10}


func is_pro(uid: String) -> bool:
	return not tier_of(uid).is_empty()


func _save_pro(uid: String) -> void:
	var p: Dictionary = pro[uid]
	plox._db("insert into plox_pro (uid, tier, until_ts, source, auto_renew, last_allow) values ($1, $2, $3, $4, $5, $6) on conflict (uid) do update set tier = excluded.tier, until_ts = excluded.until_ts, source = excluded.source, auto_renew = excluded.auto_renew, last_allow = excluded.last_allow",
		[uid, p.tier, int(p.until), p.source, bool(p.auto), int(p.allow)])


## Pays the monthly Plux allowance when one is due. Called when the player shows up.
func pro_tick(uid: String, now: int) -> void:
	var t := tier_of(uid)
	if t.is_empty():
		return
	var p: Dictionary = pro[uid]
	if now - int(p.allow) < PRO_DAYS * 86400:
		return
	p.allow = now
	_save_pro(uid)
	var n := int(t.plux_month)
	if n > 0:
		var w: Dictionary = plox.wallet(uid)
		w.coins = int(w.coins) + n
		plox._db("update plox_wallet set coins = coins + $2 where uid = $1", [uid, n])
		plox.count("pro_allowance", n)
		plox.hub._push(uid, {"t": "s_plux", "coins": int(w.coins), "got": n, "why": "pro"})


## Turns Pro on (or extends it) for `days`. Used by confirmed payments and the admin.
func grant_pro(uid: String, tier: String, days: int, source: String, now: int) -> void:
	var p: Dictionary = pro.get(uid, {"tier": tier, "until": 0, "source": source, "auto": false, "allow": 0})
	var was := int(p.until) > now
	p.tier = tier
	p.source = source
	p.until = (int(p.until) if was else now) + days * 86400
	p.auto = source != "admin"
	pro[uid] = p
	if not was:
		p.allow = 0   # a new membership pays its first allowance now
	_save_pro(uid)
	pro_tick(uid, now)
	plox.hub._push(uid, {"t": "s_pro", "pro": pro_status(uid)})


func remove_pro(uid: String) -> void:
	if not pro.has(uid):
		return
	pro[uid].until = 0
	pro[uid].auto = false
	_save_pro(uid)
	plox.hub._push(uid, {"t": "s_pro", "pro": pro_status(uid)})


func pro_status(uid: String) -> Dictionary:
	var t := tier_of(uid)
	var p: Dictionary = pro.get(uid, {})
	return {"active": not t.is_empty(), "tier": t, "until": int(p.get("until", 0)), "auto": bool(p.get("auto", false)), "source": str(p.get("source", ""))}


func pro_info(uid: String) -> Dictionary:
	var why := can_buy(uid, "f_pro")
	return {"t": "s_pro_res", "tiers": tiers(), "open": why == "", "why": why, "sandbox": plox.cfg.s("pay_mode") == "sandbox",
		"me": pro_status(uid), "trade_pro_only": plox.cfg.b("trade_pro_only")}


func pro_cancel(uid: String) -> Dictionary:
	if not is_pro(uid):
		return {"t": "s_pro_cancel_res", "ok": false, "why": "You don't have Plux Pro."}
	pro[uid].auto = false
	_save_pro(uid)
	# Live providers: also cancel the subscription with the provider here.
	return {"t": "s_pro_cancel_res", "ok": true, "me": pro_status(uid)}


## A renewal confirmed by the provider (live) or by the test button (sandbox).
func pro_renewed(uid: String, ref: String, now: int) -> bool:
	if used_refs.has(ref) or not pro.has(uid) or not bool(pro[uid].auto):
		return false
	used_refs[ref] = "renew"
	grant_pro(uid, str(pro[uid].tier), PRO_DAYS, str(pro[uid].source), now)
	return true


func packs() -> Array:
	return LiveConfig.clean_packs(plox.cfg.s("plux_packs"))


## Whether this player can buy right now, and why not.
func can_buy(uid: String, flag := "f_buy_plux") -> String:
	if not plox.cfg.b(flag):
		return "Plux Pro isn't open yet." if flag == "f_pro" else "Buying Plux isn't open yet. You can earn Plux by playing games."
	if plox.ban_reason(uid) != "":
		return "This account can't buy right now."
	if plox.cfg.s("pay_mode") == "sandbox":
		var un: String = str(plox.hub.users.get(uid, {}).get("username", ""))
		var testers := []
		for t in plox.cfg.s("pay_testers").to_lower().split(",", false):
			testers.append(t.strip_edges().trim_prefix("@"))
		if un == "" or not (un in testers):
			return "Buying Plux is being tested and isn't open to everyone yet."
		return ""
	if plox.cfg.s("pay_provider") == "none" or not _live_ready():
		return "Payments aren't set up yet."
	return ""


func _live_ready() -> bool:
	# A live provider needs its server-side secret and verification code (see _verify_live).
	return false


func store_info(uid: String) -> Dictionary:
	var why := can_buy(uid)
	return {"t": "s_packs_res", "packs": packs(), "open": why == "", "why": why,
		"sandbox": plox.cfg.s("pay_mode") == "sandbox", "coins": int(plox.wallet(uid).coins),
		"pro_bonus": int(tier_of(uid).get("buy_bonus", 0))}


func _expire(now: int) -> void:
	for id in orders:
		var o: Dictionary = orders[id]
		if o.status == "created" and now - int(o.created) > ORDER_TTL_S:
			o.status = "expired"
			plox._db("update plox_orders set status = 'expired' where id = $1 and status = 'created'", [id])


func start(uid: String, msg: Dictionary, now: int) -> Dictionary:
	var res := {"t": "s_pay_start_res", "ok": false, "why": ""}
	_expire(now)
	var want := str(msg.get("pack", ""))
	var is_pro_order := want.begins_with("pro:")
	var why := can_buy(uid, "f_pro" if is_pro_order else "f_buy_plux")
	if why != "":
		res.why = why
		return res
	var pack := {}
	if is_pro_order:
		for t in tiers():
			if "pro:" + t.id == want:
				pack = {"id": want, "plux": 0, "bonus": 0, "price": t.price, "cur": t.cur}
	else:
		for p in packs():
			if p.id == want:
				pack = p.duplicate()
				# Pro members get bonus Plux on every pack.
				var tb := tier_of(uid)
				if not tb.is_empty():
					pack.bonus = int(pack.bonus) + int(int(pack.plux) * int(tb.buy_bonus) / 100)
	if pack.is_empty():
		res.why = "That isn't sold any more."
		return res
	var open := 0
	for id in orders:
		if orders[id].uid == uid and orders[id].status == "created":
			open += 1
	if open >= MAX_OPEN:
		res.why = "Finish or wait out your other purchases first."
		return res
	var mode: String = plox.cfg.s("pay_mode")
	var o := {"id": "ord_" + Crypto.new().generate_random_bytes(10).hex_encode(), "uid": uid, "pack": pack.id,
		"plux": int(pack.plux) + int(pack.bonus), "price": float(pack.price), "cur": pack.cur,
		"provider": "sandbox" if mode == "sandbox" else plox.cfg.s("pay_provider"), "mode": mode,
		"status": "created", "created": now, "paid": 0, "ref": ""}
	orders[o.id] = o
	plox._db("insert into plox_orders (id, uid, pack, plux, price, cur, provider, mode, status, created) values ($1, $2, $3, $4, $5, $6, $7, $8, 'created', $9)",
		[o.id, uid, o.pack, o.plux, str(o.price), o.cur, o.provider, mode, now])
	res.ok = true
	res["order"] = _card(o)
	return res


## The phone says it finished paying. The server checks with the provider itself.
func confirm(uid: String, msg: Dictionary, now: int) -> Dictionary:
	var res := {"t": "s_pay_res", "ok": false, "why": ""}
	var id := str(msg.get("order", ""))
	if not orders.has(id) or orders[id].uid != uid:
		res.why = "That purchase doesn't exist."
		return res
	var o: Dictionary = orders[id]
	if o.status == "paid":
		res.why = "This purchase was already added."
		res["order"] = _card(o)
		return res
	if o.status != "created":
		res.why = "This purchase has %s." % o.status
		return res
	var ref := ""
	if o.provider == "sandbox":
		# Test mode only: stands in for the provider saying "paid". Refused once
		# the store is switched to live, or for anyone who isn't a tester.
		if plox.cfg.s("pay_mode") != "sandbox" or can_buy(uid, "f_pro" if o.pack.begins_with("pro:") else "f_buy_plux") != "":
			res.why = "Test purchases are off."
			return res
		ref = "sandbox_" + o.id
	else:
		ref = _verify_live(o, msg)
		if ref == "":
			res.why = "The payment couldn't be confirmed. You haven't been charged Plux for it."
			return res
	if not credit(id, ref, now):
		res.why = "This payment was already used."
		return res
	res.ok = true
	res["order"] = _card(o)
	res["eco"] = plox._eco(uid)
	res["pro"] = pro_status(uid)
	return res


## Live providers plug in here. Returns the provider's payment id once the server
## has confirmed with the provider that it was paid in full, else "".
##   play:     Google Play Developer API purchases.products.get with the purchase
##             token (service-account key on the server), then acknowledge.
##   razorpay: HMAC-SHA256(order_id|payment_id, key_secret) == razorpay_signature,
##             then fetch the payment and check amount, currency and status.
##   stripe:   a signed checkout.session.completed webhook, or retrieve the session.
func _verify_live(_o: Dictionary, _msg: Dictionary) -> String:
	return ""


## Credits an order exactly once. Returns false when it was already credited or
## the payment id was already used for another order.
func credit(id: String, ref: String, now: int) -> bool:
	var o: Dictionary = orders[id]
	if o.status != "created" or used_refs.has(ref):
		return false
	o.status = "paid"
	o.paid = now
	o.ref = ref
	used_refs[ref] = id
	if str(o.pack).begins_with("pro:"):
		plox._db("update plox_orders set status = 'paid', paid = $2, pay_ref = $3 where id = $1 and status = 'created'", [id, now, ref])
		grant_pro(o.uid, str(o.pack).trim_prefix("pro:"), PRO_DAYS, o.provider, now)
		plox.count("pro_subs")
		plox._audit_as("system", "pro_bought", "%s started %s (%s)" % [str(plox.hub.users.get(o.uid, {}).get("username", o.uid)), o.pack, "TEST" if o.mode == "sandbox" else o.provider])
		return true
	var w: Dictionary = plox.wallet(o.uid)
	w.coins = int(w.coins) + int(o.plux)
	# One statement: the order flips to paid and the wallet grows together, or
	# neither happens (the order isn't 'created' any more, or the ref was used).
	plox._db("with o as (update plox_orders set status = 'paid', paid = $2, pay_ref = $3 where id = $1 and status = 'created' "
		+ "and not exists (select 1 from plox_orders where pay_ref = $3) returning uid, plux) "
		+ "update plox_wallet w set coins = w.coins + o.plux from o where w.uid = o.uid", [id, now, ref])
	plox.count("plux_sold", int(o.plux))
	plox.count("orders_paid")
	plox._audit_as("system", "plux_bought", "%s bought %d Plux (%s %.2f %s, %s)" % [str(plox.hub.users.get(o.uid, {}).get("username", o.uid)), int(o.plux), o.pack, float(o.price), o.cur, "TEST" if o.mode == "sandbox" else o.provider])
	plox.hub._push(o.uid, {"t": "s_plux", "coins": int(w.coins), "got": int(o.plux), "why": "bought"})
	return true


func _card(o: Dictionary) -> Dictionary:
	return {"id": o.id, "pack": o.pack, "plux": int(o.plux), "price": float(o.price), "cur": o.cur, "provider": o.provider,
		"test": o.mode == "sandbox", "status": o.status, "created": int(o.created), "paid": int(o.paid)}


func mine(uid: String) -> Array:
	var out := []
	for id in orders:
		if orders[id].uid == uid:
			out.append(_card(orders[id]))
	out.sort_custom(func(a, b): return int(a.created) > int(b.created))
	return out.slice(0, 30)


func admin_list() -> Dictionary:
	var list := orders.values()
	list.sort_custom(func(a, b): return int(a.created) > int(b.created))
	var out := []
	var paid_real := 0.0
	var paid_test := 0
	for o in list:
		if o.status == "paid":
			if o.mode == "sandbox":
				paid_test += 1
			else:
				paid_real += float(o.price)
		if out.size() < 80:
			var c := _card(o)
			c["username"] = str(plox.hub.users.get(o.uid, {}).get("username", ""))
			out.append(c)
	var members := []
	var now := int(Time.get_unix_time_from_system())
	for uid in pro:
		if int(pro[uid].until) > now:
			members.append({"uid": uid, "username": str(plox.hub.users.get(uid, {}).get("username", "")), "tier": pro[uid].tier, "until": int(pro[uid].until), "source": pro[uid].source, "auto": bool(pro[uid].auto)})
	return {"orders": out, "pro": members, "paid_test": paid_test, "paid_real": snappedf(paid_real, 0.01), "live_ready": _live_ready()}
