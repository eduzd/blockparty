class_name PluxPages
extends RefCounted
## 0.7.0 pages built for the app shell: Get Plux, Plux Pro, Trades, New trade, Outfits.
## Every money step goes through the server: the phone only starts an order and,
## in test mode, confirms it. No real payment provider is connected yet.

var s: AppShell
var pending := {}        # the test order waiting for "Confirm"
var busy := ""           # what is waiting for the server
var packs_res := {}
var pro_res := {}
var outfits_res := {}
var inv_mine := []
var inv_theirs := {}     # uid -> items
var pick_give := {}
var pick_get := {}
var give_plux := 0
var note := ""

const PRO_GOLD := Color("#F5B700")


func _init(shell: AppShell) -> void:
	s = shell
	s.social.reply.connect(_on_reply)


## The small PRO tag shown next to a member's name.
static func pro_badge(small := false) -> Control:
	var l := Label.new()
	l.text = "PRO"
	l.add_theme_font_override("font", UiKit.font("dm", 800))
	l.add_theme_font_size_override("font_size", 10 if small else 12)
	l.add_theme_color_override("font_color", Color("#3A2A00"))
	l.add_theme_stylebox_override("normal", UiKit.pad(UiKit.box(PRO_GOLD, 50), 7 if small else 9, 2))
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	l.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return l


func _on_reply(t: String, msg: Dictionary) -> void:
	match t:
		"s_packs_res":
			packs_res = msg
		"s_pro_res":
			pro_res = msg
		"s_pro_cancel_res", "s_pro_renew_res":
			busy = ""
			if msg.get("me") is Dictionary:
				pro_res["me"] = msg.me
				s.social.eco["pro"] = msg.me
			if t == "s_pro_cancel_res":
				s._toast("Renewal turned off. Pro stays on until the end of this month." if msg.get("ok", false) else str(msg.get("why", "Couldn't cancel.")))
			else:
				s._toast("Test renewal: 30 more days added" if msg.get("ok", false) else "This membership doesn't renew.")
		"s_pay_start_res":
			busy = ""
			if bool(msg.get("ok", false)):
				pending = msg.get("order", {})
				if not bool(pending.get("test", false)):
					pending = {}
					s._toast("Real payments aren't connected yet.")
			else:
				s._toast(str(msg.get("why", "Couldn't start the purchase.")))
		"s_pay_res":
			busy = ""
			var was := pending
			pending = {}
			if bool(msg.get("ok", false)):
				if msg.get("pro") is Dictionary:
					s.social.eco["pro"] = msg.pro
					pro_res["me"] = msg.pro
				if str(was.get("pack", "")).begins_with("pro:"):
					s._toast("Welcome to Plux Pro! (test purchase)")
				else:
					s._toast("%s Plux added (test purchase)" % AppShell._fmt_plux(int(was.get("plux", 0))))
			else:
				s._toast(str(msg.get("why", "The purchase didn't go through.")))
		"s_outfits_res", "s_outfit_save_res", "s_outfit_del_res":
			busy = ""
			outfits_res = msg
			if t == "s_outfit_save_res":
				s._toast("Outfit saved" if msg.get("ok", false) else str(msg.get("why", "Couldn't save.")))
		"s_inv_res":
			if bool(msg.get("ok", false)):
				if str(msg.get("w", "")) == s.social.uid:
					inv_mine = msg.get("items", [])
				else:
					inv_theirs[str(msg.get("w", ""))] = msg.get("items", [])
		"s_trade_res":
			if busy.begins_with("trade"):
				var sent := busy == "trade_offer"
				busy = ""
				if bool(msg.get("ok", false)):
					if sent:
						pick_give.clear()
						pick_get.clear()
						give_plux = 0
						s._toast("Trade offer sent")
						s.pop()
						return
				else:
					s._toast(str(msg.get("why", "That didn't work.")))
		_:
			return
	s._mark_dirty()


func _ask(msg: Dictionary, what := "") -> bool:
	if not s.social.request(msg):
		s._offline_toast()
		return false
	busy = what
	s._mark_dirty()
	return true


func _price(p: Dictionary) -> String:
	var sym: String = {"USD": "$", "EUR": "€", "GBP": "£", "INR": "₹"}.get(str(p.get("cur", "USD")), str(p.get("cur", "")) + " ")
	return sym + ("%.2f" % float(p.get("price", 0)))


## The "this is a test, no money is taken" card with Confirm / Cancel.
func _pending_card(box: VBoxContainer) -> void:
	if pending.is_empty():
		return
	var card: Array = UiKit.card()
	var col := UiKit.vbox(6)
	var is_pro := str(pending.get("pack", "")).begins_with("pro:")
	var what := "Plux Pro for a month" if is_pro else "%s Plux" % AppShell._fmt_plux(int(pending.get("plux", 0)))
	col.add_child(UiKit.label("Test purchase: %s for %s" % [what, _price(pending)], "title_medium", UiKit.c("on_surface")))
	col.add_child(UiKit.label("Payments are in test mode. No money is taken, and nothing is charged to any card.", "body_small", UiKit.c("on_surface_variant")))
	var row := UiKit.hbox(8)
	var ok := UiKit.small_button("Waiting..." if busy == "confirm" else "Confirm test purchase", true, func():
		_ask({"t": "s_pay_confirm", "order": str(pending.get("id", ""))}, "confirm"), "check")
	ok.disabled = busy == "confirm"
	row.add_child(ok)
	row.add_child(UiKit.small_button("Cancel", false, func(): pending = {}; s._mark_dirty()))
	col.add_child(row)
	card[1].add_child(UiKit.margin(col, 16, 14, 16, 14))
	box.add_child(UiKit.margin(card[0], 0, 8, 0, 0))


# ------------------------------------------------------------------ Get Plux

func store_screen() -> Control:
	var page := UiKit.pinned_page("Get Plux", s.pop, null, [s._plux_pill_live()])
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	content.add_child(UiKit.end_padding())
	s.social.request({"t": "s_packs"})
	s._live(live, func(box: VBoxContainer):
		_pending_card(box)
		if packs_res.is_empty():
			box.add_child(UiKit.margin(UiKit.empty_state("sparkles", "Loading", "Getting the Plux packs..." if s.social.is_online() else "Connect to the internet to buy Plux."), 16, 16, 16, 0))
			return
		if not bool(packs_res.get("open", false)):
			box.add_child(UiKit.margin(UiKit.empty_state("sparkles", "Not open yet", str(packs_res.get("why", ""))), 16, 16, 16, 0))
		var bonus := int(packs_res.get("pro_bonus", 0))
		if bonus > 0:
			var h := UiKit.hbox(8)
			h.add_child(pro_badge())
			h.add_child(UiKit.label("You get %d%% extra Plux on every pack" % bonus, "body_medium", UiKit.c("on_surface")))
			box.add_child(UiKit.margin(h, 20, 12, 20, 0))
		var card: Array = UiKit.card()
		box.add_child(UiKit.margin(card[0], 0, 8, 0, 0))
		for p in packs_res.get("packs", []):
			var pk: Dictionary = p
			var extra := int(pk.get("bonus", 0)) + int(int(pk.get("plux", 0)) * bonus / 100)
			var h := UiKit.hbox(12)
			var coin := ItemArt.plux(36)
			coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			h.add_child(coin)
			var col := UiKit.vbox(0)
			col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			col.add_child(UiKit.label(AppShell._fmt_plux(int(pk.get("plux", 0)) + extra) + " Plux", "title_medium", UiKit.c("on_surface"), false))
			var sub := ("%s + %s bonus" % [AppShell._fmt_plux(int(pk.plux)), AppShell._fmt_plux(extra)]) if extra > 0 else str(pk.get("tag", ""))
			if sub != "":
				col.add_child(UiKit.label(sub, "body_small", UiKit.c("on_surface_variant"), false))
			h.add_child(col)
			var id := str(pk.get("id", ""))
			var b := UiKit.small_button(_price(pk), true, func(): _ask({"t": "s_pay_start", "pack": id}, "start"))
			b.disabled = not bool(packs_res.get("open", false)) or busy != "" or not pending.is_empty()
			b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			h.add_child(b)
			card[1].add_child(UiKit.margin(h, 16, 12, 14, 12))
		if bool(packs_res.get("sandbox", false)):
			box.add_child(UiKit.margin(UiKit.label("Test mode: buying here takes no real money.", "body_small", UiKit.c("on_surface_variant")), 20, 12, 20, 0))
	)
	return page[0]


# ------------------------------------------------------------------ Plux Pro

func pro_screen() -> Control:
	var page := UiKit.pinned_page("Plux Pro", s.pop)
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	content.add_child(UiKit.end_padding())
	s.social.request({"t": "s_pro"})
	s._live(live, func(box: VBoxContainer):
		_pending_card(box)
		if pro_res.is_empty():
			box.add_child(UiKit.margin(UiKit.empty_state("star", "Loading", "Getting Plux Pro..." if s.social.is_online() else "Connect to the internet to see Plux Pro."), 16, 16, 16, 0))
			return
		var me: Dictionary = pro_res.get("me", {})
		var hero: Array = UiKit.card()
		var hc := UiKit.vbox(6)
		var top := UiKit.hbox(10)
		top.add_child(pro_badge())
		var ht := "You're a Pro member" if bool(me.get("active", false)) else "Get more out of Plux"
		top.add_child(UiKit.label(ht, "title_large", UiKit.c("on_surface")))
		hc.add_child(top)
		if bool(me.get("active", false)):
			var tier: Dictionary = me.get("tier", {})
			var day := Time.get_date_string_from_unix_time(int(me.get("until", 0)))
			var line := "%s · %s on %s" % [str(tier.get("name", "Pro")), "Renews" if bool(me.get("auto", false)) else "Ends", day]
			if str(me.get("source", "")) == "admin":
				line = "%s · Given by Plux · Ends on %s" % [str(tier.get("name", "Pro")), day]
			hc.add_child(UiKit.label(line, "body_medium", UiKit.c("on_surface_variant")))
			if bool(me.get("auto", false)):
				var row := UiKit.hbox(8)
				var cb := UiKit.small_button("Cancel renewal", false, func(): _ask({"t": "s_pro_cancel"}, "cancel"))
				cb.disabled = busy != ""
				row.add_child(cb)
				if bool(pro_res.get("sandbox", false)):
					var rb := UiKit.small_button("Test a renewal", false, func(): _ask({"t": "s_pro_renew_test"}, "renew"))
					rb.disabled = busy != ""
					row.add_child(rb)
				hc.add_child(UiKit.margin(row, 0, 6, 0, 0))
		else:
			hc.add_child(UiKit.label("A monthly Plux allowance, bonus Plux on every pack, a Pro badge, Pro-only items and more.", "body_medium", UiKit.c("on_surface_variant")))
		hero[1].add_child(UiKit.margin(hc, 18, 16, 18, 16))
		box.add_child(UiKit.margin(hero[0], 0, 8, 0, 0))
		if not bool(pro_res.get("open", false)):
			box.add_child(UiKit.margin(UiKit.label(str(pro_res.get("why", "Plux Pro isn't open yet.")), "body_medium", UiKit.c("on_surface_variant")), 20, 12, 20, 0))
		var active_id := str(me.get("tier", {}).get("id", "")) if bool(me.get("active", false)) else ""
		for t in pro_res.get("tiers", []):
			var tier: Dictionary = t
			var card: Array = UiKit.card()
			var col := UiKit.vbox(4)
			var head := UiKit.hbox(8)
			var nm := UiKit.label(str(tier.get("name", "Pro")), "title_medium", UiKit.c("on_surface"), false)
			nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			head.add_child(nm)
			head.add_child(UiKit.label(_price(tier) + " / month", "title_small", UiKit.c("primary"), false))
			col.add_child(head)
			var perks := []
			if int(tier.get("plux_month", 0)) > 0:
				perks.append("%s Plux every month" % AppShell._fmt_plux(int(tier.plux_month)))
			if int(tier.get("buy_bonus", 0)) > 0:
				perks.append("%d%% bonus Plux when you buy Plux" % int(tier.buy_bonus))
			perks.append("Pro badge on your profile and in chat")
			perks.append("Pro-only items in the shop")
			if int(tier.get("ai_extra", 0)) > 0:
				perks.append("%d more AI Studio builds a day" % int(tier.ai_extra))
			if int(tier.get("outfits", 0)) > 0:
				perks.append("Save up to %d outfits" % int(tier.outfits))
			if bool(pro_res.get("trade_pro_only", false)):
				perks.append("Trade items with other Pro members")
			for p in perks:
				var pr := UiKit.hbox(8)
				var ic := UiKit.icon("check", 16, UiKit.SUCCESS)
				ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				pr.add_child(ic)
				pr.add_child(UiKit.label(p, "body_medium", UiKit.c("on_surface_variant")))
				col.add_child(pr)
			var id := str(tier.get("id", ""))
			var label := "Your plan" if id == active_id else ("Switch to this" if active_id != "" else "Get %s" % str(tier.get("name", "Pro")))
			var b := UiKit.primary_button(label, "star", func(): _ask({"t": "s_pay_start", "pack": "pro:" + id}, "start"))
			b.disabled = id == active_id or not bool(pro_res.get("open", false)) or busy != "" or not pending.is_empty()
			col.add_child(UiKit.margin(b, 0, 8, 0, 0))
			card[1].add_child(UiKit.margin(col, 16, 14, 16, 14))
			box.add_child(UiKit.margin(card[0], 0, 10, 0, 0))
		if bool(pro_res.get("sandbox", false)):
			box.add_child(UiKit.margin(UiKit.label("Test mode: no real money is taken.", "body_small", UiKit.c("on_surface_variant")), 20, 12, 20, 0))
	)
	return page[0]


# ------------------------------------------------------------------ Outfits

func outfits_screen() -> Control:
	var page := UiKit.pinned_page("Outfits", s.pop)
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	content.add_child(UiKit.end_padding())
	s.social.request({"t": "s_outfits"})
	s._live(live, func(box: VBoxContainer):
		var list: Array = outfits_res.get("outfits", [])
		var cap := int(outfits_res.get("cap", 3))
		var save := UiKit.primary_button("Save what I'm wearing", "plus", func(): _ask({"t": "s_outfit_save", "name": ""}, "save"))
		save.disabled = busy != "" or outfits_res.is_empty()
		box.add_child(UiKit.margin(save, 16, 8, 16, 0))
		box.add_child(UiKit.margin(UiKit.label("%d of %d saved" % [list.size(), cap], "body_small", UiKit.c("on_surface_variant")), 20, 6, 20, 0))
		if list.is_empty():
			box.add_child(UiKit.margin(UiKit.empty_state("user-circle", "No outfits yet", "Dress up in the shop, then save the look here to switch back in one tap."), 16, 12, 16, 0))
			return
		var card: Array = UiKit.card()
		box.add_child(UiKit.margin(card[0], 0, 8, 0, 0))
		for i in list.size():
			var o: Dictionary = list[i]
			var idx := i
			var eq: Array = o.get("eq", [])
			var cards := []
			for id in eq:
				if s.social.shop_by_id.has(id):
					var it: Dictionary = s.social.shop_by_id[id]
					cards.append({"art": it.art, "col": it.col, "slot": it.slot})
			var h := UiKit.hbox(12)
			h.add_child(ItemArt.dressed(48, str(s.social.data.name), int(s.social.data.get("av", -1)), cards))
			var col := UiKit.vbox(0)
			col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			col.add_child(UiKit.label(str(o.get("name", "Outfit")), "title_small", UiKit.c("on_surface"), false))
			col.add_child(UiKit.label("%d item%s" % [eq.size(), "" if eq.size() == 1 else "s"], "body_small", UiKit.c("on_surface_variant"), false))
			h.add_child(col)
			var wear := UiKit.small_button("Wear", true, func():
				# Only items still owned are put on; the server checks again.
				var keep := []
				for id in eq:
					if s.social.owns_item(id):
						keep.append(id)
				if s.social.request({"t": "s_equip", "eq": keep}):
					s._toast("Outfit on")
				else:
					s._offline_toast())
			wear.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			h.add_child(wear)
			var del := UiKit.icon_button("trash", func(): _ask({"t": "s_outfit_del", "i": idx}, "del"))
			del.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			h.add_child(del)
			card[1].add_child(UiKit.margin(h, 14, 10, 8, 10))
	)
	return page[0]


# ------------------------------------------------------------------ Trades

func _item_chip(it: Dictionary, picked: bool, cb: Callable) -> Control:
	var row := UiKit.TapRow.new()
	row.on_tap = cb
	var border := UiKit.c("primary") if picked else UiKit.c("outline_variant")
	row.add_theme_stylebox_override("panel", UiKit.box(UiKit.c("surface_container_high") if picked else UiKit.c("surface_container"), 14, border, 2 if picked else 1))
	var col := UiKit.vbox(2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var art := ItemArt.over(52, [{"art": it.get("art", ""), "col": it.get("col", "#FFFFFF"), "slot": it.get("slot", "")}])
	art.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(art)
	var nm := UiKit.label(str(it.get("name", "")), "label_medium", UiKit.c("on_surface"), false)
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.custom_minimum_size = Vector2(84, 0)
	col.add_child(nm)
	if bool(it.get("rare", false)):
		var r := UiKit.label("#%d" % int(it.get("serial", 0)) if int(it.get("serial", 0)) > 0 else "LIMITED", "label_small", UiKit.PINK, false)
		r.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(r)
	row.add_child(UiKit.margin(col, 6, 8, 6, 8))
	row.get_child(0).mouse_filter = Control.MOUSE_FILTER_IGNORE
	return row


func _items_flow(list: Array) -> Control:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", 8)
	f.add_theme_constant_override("v_separation", 8)
	for it in list:
		if it is Dictionary and not bool(it.get("gone", false)):
			f.add_child(_item_chip(it, false, func(): pass))
	return f


func trades_screen() -> Control:
	var page := UiKit.pinned_page("Trades", s.pop)
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	content.add_child(UiKit.end_padding())
	s.social.request({"t": "s_trades"})
	s._live(live, func(box: VBoxContainer):
		if not s.social.feature("trading"):
			box.add_child(UiKit.margin(UiKit.empty_state("arrows-right-left", "Trading is closed", "It'll be back soon."), 16, 16, 16, 0))
			return
		box.add_child(UiKit.margin(UiKit.label("Swap limited items and Plux with friends. Open a friend's profile and tap Trade to make an offer.", "body_medium", UiKit.c("on_surface_variant")), 20, 8, 20, 0))
		var list: Array = s.social.trades
		if list.is_empty():
			box.add_child(UiKit.margin(UiKit.empty_state("arrows-right-left", "No trades yet", "Offers you send and get show up here."), 16, 12, 16, 0))
			return
		var open := list.filter(func(t): return str(t.get("status", "")) == "open")
		var done := list.filter(func(t): return str(t.get("status", "")) != "open")
		if not open.is_empty():
			box.add_child(UiKit.section_title("Open"))
			for t in open:
				box.add_child(_trade_card(t))
		if not done.is_empty():
			box.add_child(UiKit.section_title("Finished"))
			for t in done:
				box.add_child(_trade_card(t))
	)
	return page[0]


func _trade_card(t: Dictionary) -> Control:
	var mine := bool(t.get("mine", false))
	var other := str(t.get("to_name", "")) if mine else str(t.get("from_name", ""))
	var card: Array = UiKit.card()
	var col := UiKit.vbox(6)
	var status := str(t.get("status", ""))
	var head := "You offered %s" % other if mine else "%s offered you" % other
	var st: String = {"open": "Waiting" if mine else "Your move", "done": "Done", "declined": "Declined", "cancelled": "Cancelled", "expired": "Expired", "failed": "Didn't go through"}.get(status, status.capitalize())
	var hh := UiKit.hbox(8)
	var hl := UiKit.label(head, "title_small", UiKit.c("on_surface"), false)
	hl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hh.add_child(hl)
	hh.add_child(UiKit.label(st, "label_medium", UiKit.c("tertiary") if status in ["open", "done"] else UiKit.c("on_surface_variant"), false))
	col.add_child(hh)
	# "give" is what the sender gives; show it from the viewer's side.
	var you_give: Array = t.get("give", []) if mine else t.get("get", [])
	var you_get: Array = t.get("get", []) if mine else t.get("give", [])
	var plux_give := int(t.get("cg", 0)) if mine else int(t.get("cw", 0))
	var plux_get := int(t.get("cw", 0)) if mine else int(t.get("cg", 0))
	for side in [["You get", you_get, plux_get], ["You give", you_give, plux_give]]:
		col.add_child(UiKit.label(side[0], "label_large", UiKit.c("on_surface_variant"), false))
		if not side[1].is_empty():
			col.add_child(_items_flow(side[1]))
		if int(side[2]) > 0:
			col.add_child(s._plux_amount(int(side[2]), "label_large", 16))
		if side[1].is_empty() and int(side[2]) == 0:
			col.add_child(UiKit.label("Nothing", "body_small", UiKit.c("on_surface_variant"), false))
	if str(t.get("why", "")) != "" and status != "open":
		col.add_child(UiKit.label(str(t.why), "body_small", UiKit.c("on_surface_variant")))
	if status == "open":
		var id := str(t.get("id", ""))
		var row := UiKit.hbox(8)
		if mine:
			var c := UiKit.small_button("Cancel offer", false, func(): _ask({"t": "s_trade_cancel", "id": id}, "trade"))
			c.disabled = busy != ""
			row.add_child(c)
		else:
			var a := UiKit.small_button("Accept", true, func(): _ask({"t": "s_trade_accept", "id": id}, "trade"), "check")
			a.disabled = busy != ""
			row.add_child(a)
			var d := UiKit.small_button("Decline", false, func(): _ask({"t": "s_trade_decline", "id": id}, "trade"))
			d.disabled = busy != ""
			row.add_child(d)
		col.add_child(UiKit.margin(row, 0, 4, 0, 0))
	card[1].add_child(UiKit.margin(col, 16, 14, 16, 14))
	return UiKit.margin(card[0], 0, 0, 0, 10)


func new_trade_screen(w: String) -> Control:
	var u: Dictionary = s.social.card_for(w)
	var page := UiKit.pinned_page("Trade", s.pop)
	var content: VBoxContainer = page[1]
	var live := UiKit.vbox()
	content.add_child(live)
	content.add_child(UiKit.end_padding())
	s.social.request({"t": "s_inv", "w": s.social.uid})
	s.social.request({"t": "s_inv", "w": w})
	s._live(live, func(box: VBoxContainer):
		var name := str(u.get("name", "your friend"))
		box.add_child(UiKit.margin(UiKit.label("Pick what you give and what you'd like from %s. They have 3 days to answer, and items are swapped only if both of you still have them." % name, "body_medium", UiKit.c("on_surface_variant")), 20, 8, 20, 4))
		var sections := [["You give", inv_mine, pick_give], ["You get from %s" % name, inv_theirs.get(w, []), pick_get]]
		for sec in sections:
			box.add_child(UiKit.section_title(sec[0]))
			var items: Array = sec[1]
			var picks: Dictionary = sec[2]
			if items.is_empty():
				box.add_child(UiKit.margin(UiKit.label("No items to trade.", "body_small", UiKit.c("on_surface_variant")), 20, 0, 20, 0))
				continue
			var f := HFlowContainer.new()
			f.add_theme_constant_override("h_separation", 8)
			f.add_theme_constant_override("v_separation", 8)
			for it in items:
				var oid := str(it.get("oid", ""))
				f.add_child(_item_chip(it, picks.has(oid), func():
					if picks.has(oid):
						picks.erase(oid)
					elif picks.size() < 8:
						picks[oid] = true
					s._mark_dirty()))
			box.add_child(UiKit.margin(f, 16, 0, 16, 0))
		box.add_child(UiKit.section_title("Add Plux"))
		var ph := UiKit.hbox(8)
		for amt in [0, 10, 50, 100, 500]:
			var a: int = amt
			ph.add_child(UiKit.chip("None" if a == 0 else str(a), give_plux == a, func(): give_plux = a; s._mark_dirty()))
		box.add_child(UiKit.margin(ph, 16, 0, 16, 0))
		var can := (not pick_give.is_empty() or not pick_get.is_empty() or give_plux > 0)
		var send := UiKit.primary_button("Sending..." if busy == "trade_offer" else "Send offer", "arrows-right-left", func():
			_ask({"t": "s_trade_offer", "to": w, "give": pick_give.keys(), "get": pick_get.keys(), "cg": give_plux, "cw": 0}, "trade_offer"))
		send.disabled = not can or busy != ""
		box.add_child(UiKit.margin(send, 16, 16, 16, 0))
	)
	return page[0]
