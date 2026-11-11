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


func packs() -> Array:
	return LiveConfig.clean_packs(plox.cfg.s("plux_packs"))


## Whether this player can buy right now, and why not.
func can_buy(uid: String) -> String:
	if not plox.cfg.b("f_buy_plux"):
		return "Buying Plux isn't open yet. You can earn Plux by playing games."
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
		"sandbox": plox.cfg.s("pay_mode") == "sandbox", "coins": int(plox.wallet(uid).coins)}


func _expire(now: int) -> void:
	for id in orders:
		var o: Dictionary = orders[id]
		if o.status == "created" and now - int(o.created) > ORDER_TTL_S:
			o.status = "expired"
			plox._db("update plox_orders set status = 'expired' where id = $1 and status = 'created'", [id])


func start(uid: String, msg: Dictionary, now: int) -> Dictionary:
	var res := {"t": "s_pay_start_res", "ok": false, "why": ""}
	_expire(now)
	var why := can_buy(uid)
	if why != "":
		res.why = why
		return res
	var pack := {}
	for p in packs():
		if p.id == str(msg.get("pack", "")):
			pack = p
	if pack.is_empty():
		res.why = "That pack isn't sold any more."
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
		if plox.cfg.s("pay_mode") != "sandbox" or can_buy(uid) != "":
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
	return {"orders": out, "paid_test": paid_test, "paid_real": snappedf(paid_real, 0.01), "live_ready": _live_ready()}
