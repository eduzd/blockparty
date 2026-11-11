// Registers the BlockPartyVoice singleton with Godot (uncompiled source).
#include "core/config/engine.h"
#include "blockparty_voice.h"

static BlockPartyVoice *voice_plugin = nullptr;

void register_blockparty_voice() {
	voice_plugin = memnew(BlockPartyVoice);
	Engine::get_singleton()->add_singleton(Engine::Singleton("BlockPartyVoice", voice_plugin));
}

void unregister_blockparty_voice() {
	if (voice_plugin) {
		memdelete(voice_plugin);
		voice_plugin = nullptr;
	}
}
