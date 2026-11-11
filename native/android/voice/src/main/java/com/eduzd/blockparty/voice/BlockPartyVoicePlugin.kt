package com.eduzd.blockparty.voice

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.audio.JavaAudioDeviceModule
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Room voice chat for Block Party over WebRTC (Google libwebrtc: Opus, echo cancellation,
 * noise suppression, auto gain). Peer-to-peer mesh: one PeerConnection per other talker in
 * the room. Signalling (offers, answers, ICE candidates) is carried by the game's own
 * WebSocket; this plugin only produces and consumes it. Nothing is recorded or saved.
 *
 * Every WebRTC call runs on one worker thread. Signals are emitted on Godot's render thread.
 */
class BlockPartyVoicePlugin(godot: Godot) : GodotPlugin(godot) {

    companion object {
        private const val TAG = "BlockPartyVoice"
        private const val LOCAL_TRACK_ID = "bp-mic"
        private const val STREAM_ID = "bp"

        private val SIG_STARTED = SignalInfo("voice_started")
        private val SIG_STOPPED = SignalInfo("voice_stopped")
        private val SIG_ERROR = SignalInfo("voice_error", String::class.java)
        private val SIG_LOCAL_DESC = SignalInfo(
            "local_description", Integer::class.java, String::class.java, String::class.java
        )
        private val SIG_ICE = SignalInfo(
            "ice_candidate", Integer::class.java, String::class.java, Integer::class.java, String::class.java
        )
        private val SIG_PEER_STATE = SignalInfo("peer_state", Integer::class.java, String::class.java)
        private val SIG_LEVELS = SignalInfo("audio_levels", String::class.java)
    }

    private class Peer(val id: Int, val pc: PeerConnection) {
        val pendingCandidates = ArrayList<IceCandidate>()
        var hasRemote = false
    }

    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "bp-voice").apply { isDaemon = true }
    }

    // Touched only on the worker thread.
    private var factory: PeerConnectionFactory? = null
    private var adm: JavaAudioDeviceModule? = null
    private var audioSource: AudioSource? = null
    private var localTrack: AudioTrack? = null
    private val peers = HashMap<Int, Peer>()
    private var iceServers: List<PeerConnection.IceServer> = emptyList()
    private var running = false
    private var micOn = false
    private var savedAudioMode = AudioManager.MODE_NORMAL

    override fun getPluginName() = "BlockPartyVoice"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SIG_STARTED, SIG_STOPPED, SIG_ERROR, SIG_LOCAL_DESC, SIG_ICE, SIG_PEER_STATE, SIG_LEVELS
    )

    // ------------------------------------------------------------------ API used by GDScript

    /** True when the microphone permission has been granted. */
    @UsedByGodot
    fun hasMicPermission(): Boolean {
        val ctx = context ?: return false
        return ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * Opens the voice engine. iceJson: [{"urls":["stun:..."], "username":"", "credential":""}].
     * The mic starts muted. Emits voice_started or voice_error.
     */
    @UsedByGodot
    fun start(iceJson: String) {
        worker.execute {
            try {
                if (running) {
                    emit(SIG_STARTED)
                    return@execute
                }
                if (!hasMicPermission()) {
                    emit(SIG_ERROR, "mic_permission")
                    return@execute
                }
                val ctx = context!!.applicationContext
                iceServers = parseIceServers(iceJson)
                if (factory == null) {
                    PeerConnectionFactory.initialize(
                        PeerConnectionFactory.InitializationOptions.builder(ctx)
                            .createInitializationOptions()
                    )
                    adm = JavaAudioDeviceModule.builder(ctx)
                        .setUseHardwareAcousticEchoCanceler(true)
                        .setUseHardwareNoiseSuppressor(true)
                        .setAudioRecordErrorCallback(recordErrors)
                        .setAudioTrackErrorCallback(trackErrors)
                        .createAudioDeviceModule()
                    factory = PeerConnectionFactory.builder()
                        .setAudioDeviceModule(adm)
                        .createPeerConnectionFactory()
                }
                val constraints = MediaConstraints().apply {
                    mandatory.add(MediaConstraints.KeyValuePair("googEchoCancellation", "true"))
                    mandatory.add(MediaConstraints.KeyValuePair("googNoiseSuppression", "true"))
                    mandatory.add(MediaConstraints.KeyValuePair("googAutoGainControl", "true"))
                    mandatory.add(MediaConstraints.KeyValuePair("googHighpassFilter", "true"))
                }
                audioSource = factory!!.createAudioSource(constraints)
                localTrack = factory!!.createAudioTrack(LOCAL_TRACK_ID, audioSource).apply {
                    setEnabled(false)
                }
                micOn = false
                adm?.setMicrophoneMute(true)
                adm?.setSpeakerMute(false)
                routeAudio(true)
                running = true
                emit(SIG_STARTED)
            } catch (t: Throwable) {
                Log.e(TAG, "start failed", t)
                emit(SIG_ERROR, "start_failed: ${t.message}")
            }
        }
    }

    /** Closes every connection, releases the mic and restores normal audio. */
    @UsedByGodot
    fun stop() {
        worker.execute { stopInternal() }
    }

    /** Mute (false) or unmute (true) the local microphone. */
    @UsedByGodot
    fun setMicEnabled(enabled: Boolean) {
        worker.execute {
            micOn = enabled
            localTrack?.setEnabled(enabled)
            adm?.setMicrophoneMute(!enabled)
        }
    }

    /** Silence (true) or restore (false) everyone else. */
    @UsedByGodot
    fun setSpeakerMuted(muted: Boolean) {
        worker.execute { adm?.setSpeakerMute(muted) }
    }

    /** Starts a connection to another talker. The newcomer makes the offer. */
    @UsedByGodot
    fun connectPeer(peerId: Int, makeOffer: Boolean) {
        worker.execute {
            val peer = ensurePeer(peerId) ?: return@execute
            if (makeOffer) {
                peer.pc.createOffer(object : SdpAdapter("offer $peerId") {
                    override fun onCreateSuccess(desc: SessionDescription) {
                        worker.execute { setLocal(peerId, desc) }
                    }
                }, offerConstraints())
            }
        }
    }

    /** Applies an offer or answer received through the game server. */
    @UsedByGodot
    fun setRemoteDescription(peerId: Int, type: String, sdp: String) {
        worker.execute {
            val peer = ensurePeer(peerId) ?: return@execute
            val sdpType = when (type) {
                "offer" -> SessionDescription.Type.OFFER
                "answer" -> SessionDescription.Type.ANSWER
                else -> {
                    emit(SIG_ERROR, "bad_sdp_type")
                    return@execute
                }
            }
            peer.pc.setRemoteDescription(object : SdpAdapter("remote $type $peerId") {
                override fun onSetSuccess() {
                    worker.execute {
                        val p = peers[peerId] ?: return@execute
                        p.hasRemote = true
                        for (c in p.pendingCandidates) p.pc.addIceCandidate(c)
                        p.pendingCandidates.clear()
                        if (sdpType == SessionDescription.Type.OFFER) {
                            p.pc.createAnswer(object : SdpAdapter("answer $peerId") {
                                override fun onCreateSuccess(desc: SessionDescription) {
                                    worker.execute { setLocal(peerId, desc) }
                                }
                            }, offerConstraints())
                        }
                    }
                }
            }, SessionDescription(sdpType, sdp))
        }
    }

    /** Adds an ICE candidate received through the game server. */
    @UsedByGodot
    fun addIceCandidate(peerId: Int, mid: String, index: Int, candidate: String) {
        worker.execute {
            val peer = peers[peerId] ?: return@execute
            val c = IceCandidate(mid, index, candidate)
            if (peer.hasRemote) peer.pc.addIceCandidate(c) else peer.pendingCandidates.add(c)
        }
    }

    /** Ends the connection to one talker (they left voice or the room). */
    @UsedByGodot
    fun closePeer(peerId: Int) {
        worker.execute {
            peers.remove(peerId)?.let { disposePeer(it) }
        }
    }

    /**
     * Reads live audio levels (0..1) for the speaking indicators and emits audio_levels as
     * {"me": 0.1, "peers": {"3": 0.4}}. Levels only, no audio leaves the plugin.
     */
    @UsedByGodot
    fun pollLevels() {
        worker.execute {
            if (!running) return@execute
            val result = JSONObject()
            val peerLevels = JSONObject()
            result.put("peers", peerLevels)
            result.put("me", 0.0)
            val snapshot = peers.values.toList()
            if (snapshot.isEmpty()) {
                emit(SIG_LEVELS, result.toString())
                return@execute
            }
            var remaining = snapshot.size
            for (peer in snapshot) {
                peer.pc.getStats { report ->
                    worker.execute {
                        for (stats in report.statsMap.values) {
                            val level = (stats.members["audioLevel"] as? Number)?.toDouble() ?: continue
                            when (stats.type) {
                                "inbound-rtp" -> peerLevels.put(peer.id.toString(), level)
                                "media-source" -> if (micOn) {
                                    result.put("me", maxOf(result.optDouble("me", 0.0), level))
                                }
                            }
                        }
                        remaining -= 1
                        if (remaining == 0) emit(SIG_LEVELS, result.toString())
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------ lifecycle

    override fun onMainDestroy() {
        worker.execute { stopInternal() }
        super.onMainDestroy()
    }

    // ------------------------------------------------------------------ internals (worker thread)

    private fun ensurePeer(peerId: Int): Peer? {
        peers[peerId]?.let { return it }
        val f = factory
        val track = localTrack
        if (!running || f == null || track == null) {
            emit(SIG_ERROR, "not_started")
            return null
        }
        val config = PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        }
        val pc = f.createPeerConnection(config, PeerObserver(peerId))
        if (pc == null) {
            emit(SIG_ERROR, "peer_failed")
            return null
        }
        pc.addTrack(track, listOf(STREAM_ID))
        val peer = Peer(peerId, pc)
        peers[peerId] = peer
        return peer
    }

    private fun setLocal(peerId: Int, desc: SessionDescription) {
        val peer = peers[peerId] ?: return
        peer.pc.setLocalDescription(object : SdpAdapter("local $peerId") {
            override fun onSetSuccess() {
                emit(SIG_LOCAL_DESC, peerId, desc.type.canonicalForm(), desc.description)
            }
        }, desc)
    }

    private fun disposePeer(peer: Peer) {
        try {
            peer.pc.close()
            peer.pc.dispose()
        } catch (t: Throwable) {
            Log.w(TAG, "dispose peer ${peer.id}", t)
        }
    }

    private fun stopInternal() {
        if (!running) return
        for (peer in peers.values) disposePeer(peer)
        peers.clear()
        try {
            localTrack?.dispose()
            audioSource?.dispose()
        } catch (t: Throwable) {
            Log.w(TAG, "dispose track", t)
        }
        localTrack = null
        audioSource = null
        micOn = false
        running = false
        routeAudio(false)
        emit(SIG_STOPPED)
    }

    private fun offerConstraints() = MediaConstraints().apply {
        mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
        mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", "false"))
    }

    private fun parseIceServers(json: String): List<PeerConnection.IceServer> {
        val out = ArrayList<PeerConnection.IceServer>()
        try {
            val arr = JSONArray(json)
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val urls = ArrayList<String>()
                val raw = o.opt("urls")
                if (raw is JSONArray) {
                    for (j in 0 until raw.length()) urls.add(raw.getString(j))
                } else if (raw is String) {
                    urls.add(raw)
                }
                if (urls.isEmpty()) continue
                val b = PeerConnection.IceServer.builder(urls)
                val user = o.optString("username", "")
                val cred = o.optString("credential", "")
                if (user.isNotEmpty()) b.setUsername(user)
                if (cred.isNotEmpty()) b.setPassword(cred)
                out.add(b.createIceServer())
            }
        } catch (t: Throwable) {
            Log.w(TAG, "bad ice json", t)
        }
        return out
    }

    /** Voice goes to a headset when one is plugged in, otherwise to the loudspeaker. */
    private fun routeAudio(on: Boolean) {
        val am = context?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        try {
            if (on) {
                savedAudioMode = am.mode
                am.mode = AudioManager.MODE_IN_COMMUNICATION
                if (Build.VERSION.SDK_INT >= 31) {
                    val devices = am.availableCommunicationDevices
                    val headset = devices.firstOrNull {
                        it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                            it.type == AudioDeviceInfo.TYPE_USB_HEADSET
                    }
                    val speaker = devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                    (headset ?: speaker)?.let { am.setCommunicationDevice(it) }
                } else {
                    val outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    val headset = outputs.any {
                        it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                            it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                            it.type == AudioDeviceInfo.TYPE_USB_HEADSET
                    }
                    @Suppress("DEPRECATION")
                    am.isSpeakerphoneOn = !headset
                }
            } else {
                if (Build.VERSION.SDK_INT >= 31) {
                    am.clearCommunicationDevice()
                } else {
                    @Suppress("DEPRECATION")
                    am.isSpeakerphoneOn = false
                }
                am.mode = savedAudioMode
            }
        } catch (t: Throwable) {
            Log.w(TAG, "audio routing", t)
        }
    }

    private fun emit(signal: SignalInfo, vararg args: Any) {
        runOnRenderThread { emitSignal(signal, *args) }
    }

    private val recordErrors = object : JavaAudioDeviceModule.AudioRecordErrorCallback {
        override fun onWebRtcAudioRecordInitError(errorMessage: String?) {
            emit(SIG_ERROR, "mic_init: $errorMessage")
        }

        override fun onWebRtcAudioRecordStartError(
            errorCode: JavaAudioDeviceModule.AudioRecordStartErrorCode?, errorMessage: String?
        ) {
            emit(SIG_ERROR, "mic_start: $errorMessage")
        }

        override fun onWebRtcAudioRecordError(errorMessage: String?) {
            emit(SIG_ERROR, "mic: $errorMessage")
        }
    }

    private val trackErrors = object : JavaAudioDeviceModule.AudioTrackErrorCallback {
        override fun onWebRtcAudioTrackInitError(errorMessage: String?) {
            emit(SIG_ERROR, "speaker_init: $errorMessage")
        }

        override fun onWebRtcAudioTrackStartError(
            errorCode: JavaAudioDeviceModule.AudioTrackStartErrorCode?, errorMessage: String?
        ) {
            emit(SIG_ERROR, "speaker_start: $errorMessage")
        }

        override fun onWebRtcAudioTrackError(errorMessage: String?) {
            emit(SIG_ERROR, "speaker: $errorMessage")
        }
    }

    private inner class PeerObserver(private val peerId: Int) : PeerConnection.Observer {
        override fun onIceCandidate(candidate: IceCandidate) {
            emit(SIG_ICE, peerId, candidate.sdpMid ?: "0", candidate.sdpMLineIndex, candidate.sdp)
        }

        override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) {
            emit(SIG_PEER_STATE, peerId, newState.name.lowercase())
        }

        override fun onSignalingChange(state: PeerConnection.SignalingState) {}
        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {}
        override fun onIceConnectionReceivingChange(receiving: Boolean) {}
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) {}
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) {}
        override fun onAddStream(stream: MediaStream) {}
        override fun onRemoveStream(stream: MediaStream) {}
        override fun onDataChannel(channel: DataChannel) {}
        override fun onRenegotiationNeeded() {}
        override fun onAddTrack(receiver: RtpReceiver, streams: Array<out MediaStream>) {}
    }

    private open inner class SdpAdapter(private val what: String) : SdpObserver {
        override fun onCreateSuccess(desc: SessionDescription) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(error: String?) {
            emit(SIG_ERROR, "sdp_create $what: $error")
        }

        override fun onSetFailure(error: String?) {
            emit(SIG_ERROR, "sdp_set $what: $error")
        }
    }
}
