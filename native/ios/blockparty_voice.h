// BlockPartyVoice iOS plugin (uncompiled source; see README.md).
#pragma once

#include "core/object/class_db.h"
#include "core/object/object.h"

#ifdef __OBJC__
@class BPVoiceEngine;
#else
typedef void BPVoiceEngine;
#endif

class BlockPartyVoice : public Object {
	GDCLASS(BlockPartyVoice, Object);

	static BlockPartyVoice *singleton;
	BPVoiceEngine *engine = nullptr;

protected:
	static void _bind_methods();

public:
	static BlockPartyVoice *get_singleton() { return singleton; }

	// Same names as the Android plugin so voice_chat.gd needs no changes.
	bool hasMicPermission();
	void start(String ice_json);
	void stop();
	void setMicEnabled(bool enabled);
	void setSpeakerMuted(bool muted);
	void connectPeer(int peer_id, bool make_offer);
	void setRemoteDescription(int peer_id, String type, String sdp);
	void addIceCandidate(int peer_id, String mid, int index, String candidate);
	void closePeer(int peer_id);
	void pollLevels();

	// Called from the engine (main thread).
	void emit_on_main(const StringName &signal, const Array &args);

	BlockPartyVoice();
	~BlockPartyVoice();
};
