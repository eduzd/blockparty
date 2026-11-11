@tool
extends EditorPlugin
## Export-time only: puts the Android voice plugin (AAR) and Google's libwebrtc
## into Android builds. Needs Gradle builds (export preset: use_gradle_build).

const WEBRTC_DEPENDENCY := "io.getstream:stream-webrtc-android:1.3.10"

var _export_plugin: VoiceExportPlugin


func _enter_tree() -> void:
	_export_plugin = VoiceExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null


class VoiceExportPlugin extends EditorExportPlugin:
	func _get_name() -> String:
		return "BlockPartyVoice"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		# Relative to res://addons/
		return PackedStringArray(["blockparty_voice/bin/BlockPartyVoice-release.aar"])

	func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		return PackedStringArray([WEBRTC_DEPENDENCY])
