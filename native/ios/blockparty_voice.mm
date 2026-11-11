// BlockPartyVoice for iOS: room voice over WebRTC (Google libwebrtc Objective-C API).
// Mirrors native/android/.../BlockPartyVoicePlugin.kt. UNCOMPILED SOURCE: written
// without Xcode; expect small fixes on first build.

#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>

#include "blockparty_voice.h"
#include "core/io/json.h"

BlockPartyVoice *BlockPartyVoice::singleton = nullptr;

static NSString *to_ns(const String &s) { return [NSString stringWithUTF8String:s.utf8().get_data()]; }
static String to_gd(NSString *s) { return s ? String::utf8([s UTF8String]) : String(); }

// ---------------------------------------------------------------- engine (ObjC)

@interface BPPeer : NSObject
@property(nonatomic, assign) int peerId;
@property(nonatomic, strong) RTCPeerConnection *pc;
@property(nonatomic, strong) NSMutableArray<RTCIceCandidate *> *pending;
@property(nonatomic, assign) BOOL hasRemote;
@end
@implementation BPPeer
@end

@interface BPVoiceEngine : NSObject <RTCPeerConnectionDelegate>
@property(nonatomic, assign) BlockPartyVoice *owner;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) RTCPeerConnectionFactory *factory;
@property(nonatomic, strong) RTCAudioTrack *localTrack;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, BPPeer *> *peers;
@property(nonatomic, strong) NSArray<RTCIceServer *> *iceServers;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, assign) BOOL micOn;
@end

@implementation BPVoiceEngine

- (instancetype)init {
	if ((self = [super init])) {
		_queue = dispatch_queue_create("bp.voice", DISPATCH_QUEUE_SERIAL);
		_peers = [NSMutableDictionary dictionary];
	}
	return self;
}

- (void)emit:(const char *)name args:(Array)args {
	BlockPartyVoice *o = self.owner;
	StringName sig(name);
	dispatch_async(dispatch_get_main_queue(), ^{
		if (o) o->emit_on_main(sig, args);
	});
}

- (void)error:(NSString *)what {
	Array a;
	a.push_back(to_gd(what));
	[self emit:"voice_error" args:a];
}

- (NSArray<RTCIceServer *> *)parseIce:(NSString *)json {
	NSMutableArray *out = [NSMutableArray array];
	NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
	id arr = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
	if (![arr isKindOfClass:[NSArray class]]) return out;
	for (NSDictionary *o in arr) {
		if (![o isKindOfClass:[NSDictionary class]]) continue;
		id urls = o[@"urls"];
		NSArray *list = [urls isKindOfClass:[NSArray class]] ? urls : ([urls isKindOfClass:[NSString class]] ? @[ urls ] : nil);
		if (list.count == 0) continue;
		NSString *user = [o[@"username"] isKindOfClass:[NSString class]] ? o[@"username"] : nil;
		NSString *cred = [o[@"credential"] isKindOfClass:[NSString class]] ? o[@"credential"] : nil;
		[out addObject:[[RTCIceServer alloc] initWithURLStrings:list username:user credential:cred]];
	}
	return out;
}

- (void)configureSession:(BOOL)on {
	RTCAudioSession *session = [RTCAudioSession sharedInstance];
	[session lockForConfiguration];
	NSError *err = nil;
	if (on) {
		[session setCategory:AVAudioSessionCategoryPlayAndRecord
				 withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
					   error:&err];
		[session setMode:AVAudioSessionModeVoiceChat error:&err];
		[session setActive:YES error:&err];
	} else {
		[session setActive:NO error:&err];
	}
	[session unlockForConfiguration];
}

- (void)start:(NSString *)iceJson {
	dispatch_async(self.queue, ^{
		if (self.running) {
			[self emit:"voice_started" args:Array()];
			return;
		}
		if ([AVAudioSession sharedInstance].recordPermission != AVAudioSessionRecordPermissionGranted) {
			[self error:@"mic_permission"];
			return;
		}
		self.iceServers = [self parseIce:iceJson];
		if (!self.factory) {
			RTCInitializeSSL();
			self.factory = [[RTCPeerConnectionFactory alloc] init];
		}
		RTCMediaConstraints *c = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{
			@"googEchoCancellation" : @"true",
			@"googNoiseSuppression" : @"true",
			@"googAutoGainControl" : @"true"
		} optionalConstraints:nil];
		RTCAudioSource *src = [self.factory audioSourceWithConstraints:c];
		self.localTrack = [self.factory audioTrackWithSource:src trackId:@"bp-mic"];
		self.localTrack.isEnabled = NO;
		self.micOn = NO;
		[self configureSession:YES];
		self.running = YES;
		[self emit:"voice_started" args:Array()];
	});
}

- (void)stop {
	dispatch_async(self.queue, ^{
		if (!self.running) return;
		for (BPPeer *p in self.peers.allValues) [p.pc close];
		[self.peers removeAllObjects];
		self.localTrack = nil;
		self.running = NO;
		self.micOn = NO;
		[self configureSession:NO];
		[self emit:"voice_stopped" args:Array()];
	});
}

- (void)setMic:(BOOL)on {
	dispatch_async(self.queue, ^{
		self.micOn = on;
		self.localTrack.isEnabled = on;
	});
}

- (void)setSpeakerMuted:(BOOL)muted {
	dispatch_async(self.queue, ^{
		for (BPPeer *p in self.peers.allValues) {
			for (RTCRtpReceiver *r in p.pc.receivers) {
				if ([r.track isKindOfClass:[RTCAudioTrack class]]) r.track.isEnabled = !muted;
			}
		}
	});
}

- (BPPeer *)ensurePeer:(int)peerId {
	BPPeer *existing = self.peers[@(peerId)];
	if (existing) return existing;
	if (!self.running || !self.localTrack) {
		[self error:@"not_started"];
		return nil;
	}
	RTCConfiguration *cfg = [[RTCConfiguration alloc] init];
	cfg.iceServers = self.iceServers;
	cfg.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
	cfg.bundlePolicy = RTCBundlePolicyMaxBundle;
	cfg.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
	cfg.continualGatheringPolicy = RTCContinualGatheringPolicyGatherContinually;
	RTCMediaConstraints *c = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
	RTCPeerConnection *pc = [self.factory peerConnectionWithConfiguration:cfg constraints:c delegate:self];
	if (!pc) {
		[self error:@"peer_failed"];
		return nil;
	}
	[pc addTrack:self.localTrack streamIds:@[ @"bp" ]];
	BPPeer *p = [BPPeer new];
	p.peerId = peerId;
	p.pc = pc;
	p.pending = [NSMutableArray array];
	self.peers[@(peerId)] = p;
	return p;
}

- (int)idForPc:(RTCPeerConnection *)pc {
	for (BPPeer *p in self.peers.allValues) {
		if (p.pc == pc) return p.peerId;
	}
	return -1;
}

- (RTCMediaConstraints *)sdpConstraints {
	return [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{ @"OfferToReceiveAudio" : @"true", @"OfferToReceiveVideo" : @"false" }
												 optionalConstraints:nil];
}

- (void)setLocal:(int)peerId desc:(RTCSessionDescription *)desc {
	BPPeer *p = self.peers[@(peerId)];
	if (!p) return;
	[p.pc setLocalDescription:desc completionHandler:^(NSError *err) {
		if (err) {
			[self error:[NSString stringWithFormat:@"sdp_set local %d: %@", peerId, err.localizedDescription]];
			return;
		}
		Array a;
		a.push_back(peerId);
		a.push_back(to_gd([RTCSessionDescription stringForType:desc.type]));
		a.push_back(to_gd(desc.sdp));
		[self emit:"local_description" args:a];
	}];
}

- (void)connect:(int)peerId offer:(BOOL)offer {
	dispatch_async(self.queue, ^{
		BPPeer *p = [self ensurePeer:peerId];
		if (!p || !offer) return;
		[p.pc offerForConstraints:[self sdpConstraints] completionHandler:^(RTCSessionDescription *sdp, NSError *err) {
			if (err || !sdp) {
				[self error:@"sdp_create offer"];
				return;
			}
			dispatch_async(self.queue, ^{ [self setLocal:peerId desc:sdp]; });
		}];
	});
}

- (void)remote:(int)peerId type:(NSString *)type sdp:(NSString *)sdp {
	dispatch_async(self.queue, ^{
		BPPeer *p = [self ensurePeer:peerId];
		if (!p) return;
		RTCSdpType t;
		if ([type isEqualToString:@"offer"]) t = RTCSdpTypeOffer;
		else if ([type isEqualToString:@"answer"]) t = RTCSdpTypeAnswer;
		else {
			[self error:@"bad_sdp_type"];
			return;
		}
		RTCSessionDescription *desc = [[RTCSessionDescription alloc] initWithType:t sdp:sdp];
		[p.pc setRemoteDescription:desc completionHandler:^(NSError *err) {
			if (err) {
				[self error:[NSString stringWithFormat:@"sdp_set remote: %@", err.localizedDescription]];
				return;
			}
			dispatch_async(self.queue, ^{
				p.hasRemote = YES;
				for (RTCIceCandidate *c in p.pending) [p.pc addIceCandidate:c completionHandler:^(NSError *e){}];
				[p.pending removeAllObjects];
				if (t == RTCSdpTypeOffer) {
					[p.pc answerForConstraints:[self sdpConstraints] completionHandler:^(RTCSessionDescription *ans, NSError *e2) {
						if (e2 || !ans) {
							[self error:@"sdp_create answer"];
							return;
						}
						dispatch_async(self.queue, ^{ [self setLocal:peerId desc:ans]; });
					}];
				}
			});
		}];
	});
}

- (void)ice:(int)peerId mid:(NSString *)mid index:(int)index cand:(NSString *)cand {
	dispatch_async(self.queue, ^{
		BPPeer *p = self.peers[@(peerId)];
		if (!p) return;
		RTCIceCandidate *c = [[RTCIceCandidate alloc] initWithSdp:cand sdpMLineIndex:index sdpMid:mid];
		if (p.hasRemote) [p.pc addIceCandidate:c completionHandler:^(NSError *e){}];
		else [p.pending addObject:c];
	});
}

- (void)close:(int)peerId {
	dispatch_async(self.queue, ^{
		BPPeer *p = self.peers[@(peerId)];
		if (!p) return;
		[p.pc close];
		[self.peers removeObjectForKey:@(peerId)];
	});
}

- (void)pollLevels {
	dispatch_async(self.queue, ^{
		if (!self.running) return;
		NSArray<BPPeer *> *snapshot = self.peers.allValues;
		NSMutableDictionary *peerLevels = [NSMutableDictionary dictionary];
		__block double me = 0.0;
		__block NSUInteger remaining = snapshot.count;
		void (^finish)(void) = ^{
			NSDictionary *out = @{ @"me" : @(me), @"peers" : peerLevels };
			NSData *d = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
			Array a;
			a.push_back(to_gd([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]));
			[self emit:"audio_levels" args:a];
		};
		if (remaining == 0) {
			finish();
			return;
		}
		for (BPPeer *p in snapshot) {
			[p.pc statisticsWithCompletionHandler:^(RTCStatisticsReport *report) {
				dispatch_async(self.queue, ^{
					for (RTCStatistics *s in report.statistics.allValues) {
						NSNumber *lvl = s.values[@"audioLevel"];
						if (![lvl isKindOfClass:[NSNumber class]]) continue;
						if ([s.type isEqualToString:@"inbound-rtp"]) peerLevels[[@(p.peerId) stringValue]] = lvl;
						else if ([s.type isEqualToString:@"media-source"] && self.micOn) me = MAX(me, lvl.doubleValue);
					}
					if (--remaining == 0) finish();
				});
			}];
		}
	});
}

// RTCPeerConnectionDelegate
- (void)peerConnection:(RTCPeerConnection *)pc didGenerateIceCandidate:(RTCIceCandidate *)c {
	dispatch_async(self.queue, ^{
		int pid = [self idForPc:pc];
		if (pid < 0) return;
		Array a;
		a.push_back(pid);
		a.push_back(to_gd(c.sdpMid ?: @"0"));
		a.push_back(c.sdpMLineIndex);
		a.push_back(to_gd(c.sdp));
		[self emit:"ice_candidate" args:a];
	});
}

- (void)peerConnection:(RTCPeerConnection *)pc didChangeConnectionState:(RTCPeerConnectionState)state {
	static NSDictionary *names = @{
		@(RTCPeerConnectionStateNew) : @"new", @(RTCPeerConnectionStateConnecting) : @"connecting",
		@(RTCPeerConnectionStateConnected) : @"connected", @(RTCPeerConnectionStateDisconnected) : @"disconnected",
		@(RTCPeerConnectionStateFailed) : @"failed", @(RTCPeerConnectionStateClosed) : @"closed"
	};
	dispatch_async(self.queue, ^{
		int pid = [self idForPc:pc];
		if (pid < 0) return;
		Array a;
		a.push_back(pid);
		a.push_back(to_gd(names[@(state)] ?: @"new"));
		[self emit:"peer_state" args:a];
	});
}

- (void)peerConnection:(RTCPeerConnection *)pc didChangeSignalingState:(RTCSignalingState)s {}
- (void)peerConnection:(RTCPeerConnection *)pc didAddStream:(RTCMediaStream *)s {}
- (void)peerConnection:(RTCPeerConnection *)pc didRemoveStream:(RTCMediaStream *)s {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)pc {}
- (void)peerConnection:(RTCPeerConnection *)pc didChangeIceConnectionState:(RTCIceConnectionState)s {}
- (void)peerConnection:(RTCPeerConnection *)pc didChangeIceGatheringState:(RTCIceGatheringState)s {}
- (void)peerConnection:(RTCPeerConnection *)pc didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)c {}
- (void)peerConnection:(RTCPeerConnection *)pc didOpenDataChannel:(RTCDataChannel *)d {}

@end

// ---------------------------------------------------------------- Godot side

void BlockPartyVoice::_bind_methods() {
	ClassDB::bind_method(D_METHOD("hasMicPermission"), &BlockPartyVoice::hasMicPermission);
	ClassDB::bind_method(D_METHOD("start", "ice_json"), &BlockPartyVoice::start);
	ClassDB::bind_method(D_METHOD("stop"), &BlockPartyVoice::stop);
	ClassDB::bind_method(D_METHOD("setMicEnabled", "enabled"), &BlockPartyVoice::setMicEnabled);
	ClassDB::bind_method(D_METHOD("setSpeakerMuted", "muted"), &BlockPartyVoice::setSpeakerMuted);
	ClassDB::bind_method(D_METHOD("connectPeer", "peer_id", "make_offer"), &BlockPartyVoice::connectPeer);
	ClassDB::bind_method(D_METHOD("setRemoteDescription", "peer_id", "type", "sdp"), &BlockPartyVoice::setRemoteDescription);
	ClassDB::bind_method(D_METHOD("addIceCandidate", "peer_id", "mid", "index", "candidate"), &BlockPartyVoice::addIceCandidate);
	ClassDB::bind_method(D_METHOD("closePeer", "peer_id"), &BlockPartyVoice::closePeer);
	ClassDB::bind_method(D_METHOD("pollLevels"), &BlockPartyVoice::pollLevels);

	ADD_SIGNAL(MethodInfo("voice_started"));
	ADD_SIGNAL(MethodInfo("voice_stopped"));
	ADD_SIGNAL(MethodInfo("voice_error", PropertyInfo(Variant::STRING, "what")));
	ADD_SIGNAL(MethodInfo("local_description", PropertyInfo(Variant::INT, "peer_id"), PropertyInfo(Variant::STRING, "type"), PropertyInfo(Variant::STRING, "sdp")));
	ADD_SIGNAL(MethodInfo("ice_candidate", PropertyInfo(Variant::INT, "peer_id"), PropertyInfo(Variant::STRING, "mid"), PropertyInfo(Variant::INT, "index"), PropertyInfo(Variant::STRING, "candidate")));
	ADD_SIGNAL(MethodInfo("peer_state", PropertyInfo(Variant::INT, "peer_id"), PropertyInfo(Variant::STRING, "state")));
	ADD_SIGNAL(MethodInfo("audio_levels", PropertyInfo(Variant::STRING, "json")));
}

void BlockPartyVoice::emit_on_main(const StringName &signal, const Array &args) {
	Vector<Variant> v;
	for (int i = 0; i < args.size(); i++) v.push_back(args[i]);
	const Variant **ptrs = (const Variant **)alloca(sizeof(Variant *) * v.size());
	for (int i = 0; i < v.size(); i++) ptrs[i] = &v[i];
	emit_signalp(signal, ptrs, v.size());
}

// iOS asks for the mic the first time it is used; voice_chat.gd calls
// OS.request_permission, which on iOS returns at once, so ask here too.
bool BlockPartyVoice::hasMicPermission() {
	AVAudioSessionRecordPermission p = [AVAudioSession sharedInstance].recordPermission;
	if (p == AVAudioSessionRecordPermissionUndetermined) {
		[[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {}];
	}
	return p == AVAudioSessionRecordPermissionGranted;
}

void BlockPartyVoice::start(String ice_json) { [engine start:to_ns(ice_json)]; }
void BlockPartyVoice::stop() { [engine stop]; }
void BlockPartyVoice::setMicEnabled(bool enabled) { [engine setMic:enabled]; }
void BlockPartyVoice::setSpeakerMuted(bool muted) { [engine setSpeakerMuted:muted]; }
void BlockPartyVoice::connectPeer(int peer_id, bool make_offer) { [engine connect:peer_id offer:make_offer]; }
void BlockPartyVoice::setRemoteDescription(int peer_id, String type, String sdp) { [engine remote:peer_id type:to_ns(type) sdp:to_ns(sdp)]; }
void BlockPartyVoice::addIceCandidate(int peer_id, String mid, int index, String candidate) { [engine ice:peer_id mid:to_ns(mid) index:index cand:to_ns(candidate)]; }
void BlockPartyVoice::closePeer(int peer_id) { [engine close:peer_id]; }
void BlockPartyVoice::pollLevels() { [engine pollLevels]; }

BlockPartyVoice::BlockPartyVoice() {
	singleton = this;
	engine = [[BPVoiceEngine alloc] init];
	engine.owner = this;
}

BlockPartyVoice::~BlockPartyVoice() {
	engine.owner = nullptr;
	[engine stop];
	engine = nil;
	singleton = nullptr;
}
