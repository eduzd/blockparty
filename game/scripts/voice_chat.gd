class_name VoiceChat
extends Node
## Room voice chat. Audio runs phone to phone over WebRTC in the native
## BlockPartyVoice plugin (Android). This node only does the bookkeeping:
## asks for the mic permission, joins/leaves voice, relays the setup messages
## through the game server, and tracks who is talking.
## Voice is off until the player turns it on, and the mic starts muted.
## Nothing is recorded or saved anywhere.

signal changed            # state, mute or talkers changed: redraw the HUD
signal notice(text: String)

enum State { UNAVAILABLE, OFF, ASKING, STARTING, ON }

const MIC_PERMISSION := "android.permission.RECORD_AUDIO"
const LEVEL_POLL_SEC := 0.25

var state := State.UNAVAILABLE
var mic_on := false
var talkers := {}          # id -> true: everyone else in voice in this room
var levels := {}           # id -> 0..1 (and "me")
var peer_states := {}      # id -> "connecting" / "connected" / "failed" ...
var unavailable_reason := ""

var _plugin: Object = null
var _net: NetClient
var _ice_json := "[]"
var _server_supports := false
var _level_accum := 0.0


func setup(net: NetClient) -> void:
	_net = net
	if Engine.has_singleton("BlockPartyVoice"):
		_plugin = Engine.get_singleton("BlockPartyVoice")
		_plugin.voice_started.connect(_on_started)
		_plugin.voice_stopped.connect(_on_stopped)
		_plugin.voice_error.connect(_on_error)
		_plugin.local_description.connect(_on_local_description)
		_plugin.ice_candidate.connect(_on_ice_candidate)
		_plugin.peer_state.connect(_on_peer_state)
		_plugin.audio_levels.connect(_on_levels)
		get_tree().on_request_permissions_result.connect(_on_permission_result)
	else:
		unavailable_reason = "Voice chat needs the Android app"


## Called with the server's welcome. Older servers don't relay voice.
func on_joined(welcome: Dictionary) -> void:
	talkers.clear()
	levels.clear()
	peer_states.clear()
	var v = welcome.get("voice")
	_server_supports = v is Dictionary
	if _server_supports:
		_ice_json = JSON.stringify(v.get("ice", []))
		for id in v.get("talkers", []):
			talkers[int(id)] = true
	if _plugin == null:
		state = State.UNAVAILABLE
	elif not _server_supports:
		state = State.UNAVAILABLE
		unavailable_reason = "This server doesn't support voice yet"
	elif state == State.UNAVAILABLE:
		state = State.OFF
	elif state == State.ON:
		# Reconnected to the server: rejoin voice with fresh connections.
		_plugin.stop()
		state = State.STARTING
	changed.emit()


## The player's voice toggle: off -> on (muted mic) -> off.
func toggle_voice() -> void:
	match state:
		State.UNAVAILABLE:
			notice.emit(unavailable_reason)
		State.OFF:
			_turn_on()
		State.ON:
			turn_off()


func toggle_mic() -> void:
	if state != State.ON:
		return
	mic_on = not mic_on
	_plugin.setMicEnabled(mic_on)
	changed.emit()


func turn_off() -> void:
	if state == State.UNAVAILABLE:
		return
	var was_on := state == State.ON or state == State.STARTING
	state = State.OFF
	mic_on = false
	peer_states.clear()
	levels.clear()
	if _plugin:
		_plugin.stop()
	if was_on and _net and _net.is_in_room():
		_net.send({"t": "vleave"})
	changed.emit()


## Leaving the room or the app: drop everything.
func shutdown() -> void:
	turn_off()
	talkers.clear()
	if _plugin:
		state = State.OFF
	else:
		state = State.UNAVAILABLE


func is_on() -> bool:
	return state == State.ON


func connected_count() -> int:
	var n := 0
	for id in peer_states:
		if peer_states[id] == "connected":
			n += 1
	return n


func _turn_on() -> void:
	if _plugin.hasMicPermission():
		_start_engine()
	else:
		state = State.ASKING
		changed.emit()
		if OS.get_name() == "Android":
			OS.request_permission(MIC_PERMISSION)
		else:
			# iOS: the plugin shows the system prompt; wait for the answer.
			for i in 60:
				await get_tree().create_timer(0.5).timeout
				if state != State.ASKING:
					return
				if _plugin.hasMicPermission():
					_start_engine()
					return
			state = State.OFF
			changed.emit()


func _on_permission_result(permission: String, granted: bool) -> void:
	if permission != MIC_PERMISSION or state != State.ASKING:
		return
	if granted:
		_start_engine()
	else:
		state = State.OFF
		notice.emit("Voice needs the microphone. You can allow it in Settings > Apps.")
		changed.emit()


func _start_engine() -> void:
	state = State.STARTING
	mic_on = false
	changed.emit()
	_plugin.start(_ice_json)


func _on_started() -> void:
	if state != State.STARTING:
		return
	state = State.ON
	_plugin.setMicEnabled(false)
	_net.send({"t": "vjoin"})
	notice.emit("Voice on. Your mic is muted until you tap it.")
	changed.emit()


func _on_stopped() -> void:
	if state == State.STARTING and _plugin:
		# Restart after a server reconnect.
		_plugin.start(_ice_json)


func _on_error(what: String) -> void:
	push_warning("voice: " + what)
	if what == "mic_permission" or what.begins_with("start_failed") or what.begins_with("mic_init"):
		state = State.OFF
		mic_on = false
		notice.emit("Couldn't start voice chat.")
		changed.emit()


## Messages from the game server.
func on_message(msg: Dictionary) -> bool:
	match msg.t:
		"vpeers":
			if state == State.ON:
				for id in msg.get("ids", []):
					var pid := int(id)
					talkers[pid] = true
					peer_states[pid] = "connecting"
					_plugin.connectPeer(pid, true)
				changed.emit()
		"vjoin":
			var pid := int(msg.get("id", -1))
			if pid >= 0:
				talkers[pid] = true
				if state == State.ON:
					peer_states[pid] = "connecting"   # they will send the offer
				changed.emit()
		"vleave":
			_drop_peer(int(msg.get("id", -1)))
		"leave":
			_drop_peer(int(msg.get("id", -1)))
			return false   # the game handles it too
		"vsig":
			if state != State.ON:
				return true
			var from := int(msg.get("from", -1))
			match msg.get("k"):
				"offer", "answer":
					_plugin.setRemoteDescription(from, str(msg.k), str(msg.get("sdp", "")))
				"ice":
					_plugin.addIceCandidate(from, str(msg.get("mid", "0")), int(msg.get("idx", 0)), str(msg.get("cand", "")))
		_:
			return false
	return true


func _drop_peer(pid: int) -> void:
	if pid < 0:
		return
	talkers.erase(pid)
	levels.erase(pid)
	peer_states.erase(pid)
	if state == State.ON:
		_plugin.closePeer(pid)
	changed.emit()


func _on_local_description(peer_id: int, type: String, sdp: String) -> void:
	if state == State.ON:
		_net.send({"t": "vsig", "to": peer_id, "k": type, "sdp": sdp})


func _on_ice_candidate(peer_id: int, mid: String, index: int, candidate: String) -> void:
	if state == State.ON:
		_net.send({"t": "vsig", "to": peer_id, "k": "ice", "mid": mid, "idx": index, "cand": candidate})


func _on_peer_state(peer_id: int, s: String) -> void:
	if not talkers.has(peer_id):
		return
	peer_states[peer_id] = s
	changed.emit()


func _on_levels(json: String) -> void:
	var d = JSON.parse_string(json)
	if not (d is Dictionary):
		return
	levels.clear()
	levels["me"] = float(d.get("me", 0.0))
	var p = d.get("peers", {})
	if p is Dictionary:
		for k in p:
			levels[int(k)] = float(p[k])
	changed.emit()


func _process(delta: float) -> void:
	if state != State.ON:
		return
	_level_accum += delta
	if _level_accum >= LEVEL_POLL_SEC:
		_level_accum = 0.0
		_plugin.pollLevels()


func _notification(what: int) -> void:
	# Don't keep the mic open in the background.
	if what == NOTIFICATION_APPLICATION_PAUSED and state == State.ON:
		turn_off()
		notice.emit("Voice turned off while the app was in the background.")
