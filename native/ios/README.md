# BlockPartyVoice for iOS (source only, NOT compiled)

Same API and signals as the Android plugin (`native/android`), so `voice_chat.gd` works
unchanged once this is built. Written without Apple tools: it has never been compiled,
linked or run. Building it needs a Mac with Xcode.

Build outline (on a Mac):
1. Get Godot 4.7 headers matching the engine (`godot` source tree, `scons platform=ios target=template_release`).
2. Add WebRTC: the `WebRTC.xcframework` from `stream-video-swift-webrtc` (Swift Package) or the
   `WebRTC-lib` CocoaPod. Both ship Google's libwebrtc with the Objective-C API used here.
3. Build `blockparty_voice.mm` + `blockparty_voice_module.mm` into `BlockPartyVoice.xcframework`
   (static library), then place it with `BlockPartyVoice.gdip` in `game/ios/plugins/`.
4. In the iOS export preset enable the plugin and set the microphone usage text
   (`privacy/microphone_usage_description`).

No recording: audio only flows peer to peer while voice is on.
