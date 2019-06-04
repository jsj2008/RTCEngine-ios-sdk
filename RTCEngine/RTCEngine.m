//
//  RTCEngine.m
//  RTCEngine
//
//  Created by xiang on 06/08/2018.
//  Copyright © 2018 RTCEngine. All rights reserved.
//

#import "RTCEngine.h"



@import WebRTC;

#import <SocketIO/SocketIO-Swift.h>

#import "RTCEngine+Internal.h"
#import "RTCMediaConstraintUtil.h"
#import "RTCSessionDescription+JSON.h"
#import "RTCStream.h"
#import "RTCStream+Internal.h"
#import "RTCNetUtils.h"
#import "RTCPeer.h"
#import "RTCPeerManager.h"


@implementation RTCConfig

@end


static RTCEngine *sharedRTCEngineInstance = nil;

@interface RTCEngine () <RTCVideoCapturerDelegate>
{
    NSString *roomId;
    RTCDefaultVideoDecoderFactory* decoderFactory;
    RTCDefaultVideoEncoderFactory* encoderFactory;
    NSMutableDictionary* streamsMap;
}



@property (nonatomic, strong) RTCConfig* config;

@property (nonatomic, strong) NSMutableDictionary* localStreams;
@property (nonatomic, strong) NSMutableDictionary* remoteStreams;
@property (nonatomic, strong) RTCStream* localStream;

@property (nonatomic, strong) NSArray<RTCIceServer*> *iceServers;
@property (nonatomic)   BOOL   closed;

@end

@implementation RTCEngine


-(instancetype) initWithDelegate:(id<RTCEngineDelegate>) delegate
{
    
    if (self = [super init]) {
        _delegate = delegate;
        _status = RTCEngineStatusNew;
        
        RTCInitializeSSL();
        
        _localStreams = [NSMutableDictionary dictionary];
        _remoteStreams = [NSMutableDictionary dictionary];
        
        decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
        encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
        
        streamsMap = [NSMutableDictionary dictionary];
        
        _connectionFactory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory decoderFactory:decoderFactory];
        
        _closed = false;
    }
    
    return self;
}



- (instancetype) initWichConfig:(RTCConfig *)config delegate:(id<RTCEngineDelegate>)delegate
{
    
    self = [self initWithDelegate:delegate];
    self.iceServers = config.iceServers;
    self.config = config;
    return self;
}


- (RTCStream*) createLocalStreamWithAudio:(BOOL)audio video:(BOOL)video
{
    
    RTCStream* stream = [[RTCStream alloc] initWithAudio:audio video:video];
    stream.local = true;
    stream.factory = _connectionFactory;
    stream.engine = self;
    return stream;
}


- (void) publish:(RTCStream *)stream
{
    if (_status != RTCEngineStatusConnected) {
        return;
    }
    
    // todo check this stream is published already
    _localStream = stream;
    
    // move to RTCStream ?
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    RTCIceTransportPolicy iceTransport = RTCIceTransportPolicyAll;
    
    
    //config.iceServers = _iceServers;
    config.bundlePolicy = RTCBundlePolicyMaxBundle;
    config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    config.iceTransportPolicy = iceTransport;
    config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    
    
    RTCMediaConstraints *connectionconstraints = [RTCMediaConstraintUtil connectionConstraints];
    RTCPeerConnection* peerconnection = [_connectionFactory peerConnectionWithConfiguration:config
                                                                                    constraints:connectionconstraints
                                                                                   delegate:nil];
    peerconnection.delegate = stream;
    
    RTCRtpTransceiverInit* transceiverInit = [[RTCRtpTransceiverInit alloc] init];
    transceiverInit.direction = RTCRtpTransceiverDirectionSendOnly;
    transceiverInit.streamIds = @[stream.streamId];
    
    if (stream.videoTrack) {
        stream.videoTransceiver = [peerconnection addTransceiverWithTrack:stream.videoTrack init:transceiverInit];
    } else {
        stream.videoTransceiver = [peerconnection addTransceiverOfType:RTCRtpMediaTypeVideo init:transceiverInit];
    }
    
    if (stream.audioTrack) {
        stream.audioTransceiver = [peerconnection addTransceiverWithTrack:stream.audioTrack init:transceiverInit];
    } else {
        stream.audioTransceiver = [peerconnection addTransceiverOfType:RTCRtpMediaTypeAudio init:transceiverInit];
    }
    
    stream.peerconnection = peerconnection;
    [self publishInternal:stream];
}


- (void) unpublish:(RTCStream *)stream
{
    
    if ([stream.streamId isEqualToString:_localStream.streamId]) {
        if(stream.videoTransceiver) {
            [stream.peerconnection removeTrack:stream.videoTransceiver.sender];
        }
        if(stream.audioTransceiver) {
            [stream.peerconnection removeTrack:stream.audioTransceiver.sender];
        }
        
        [self unpublishInternal:stream];
    }
}


- (void) subscribe:(NSString *)streamId
{
    
    if ([_remoteStreams objectForKey:streamId]) {
        return;
    }
    
    RTCStream* stream = [[RTCStream alloc] init];
    stream.audio = TRUE;
    stream.video = TRUE;
    stream.local = false;
    stream.engine = self;
    
    stream.publisherId = streamId;
    
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    config.iceServers = _iceServers;
    config.bundlePolicy = RTCBundlePolicyMaxBundle;
    config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    config.iceTransportPolicy = RTCIceTransportPolicyAll;
    config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    
    RTCMediaConstraints *connectionconstraints = [RTCMediaConstraintUtil connectionConstraints];
    RTCPeerConnection* peerconnection = [_connectionFactory peerConnectionWithConfiguration:config
                                                                                constraints:connectionconstraints
                                                                                   delegate:nil];
    peerconnection.delegate = stream;
    stream.peerconnection = peerconnection;
    
    
    RTCRtpTransceiverInit* transceiverInit = [[RTCRtpTransceiverInit alloc] init];
    transceiverInit.direction = RTCRtpTransceiverDirectionRecvOnly;
    transceiverInit.streamIds = @[stream.streamId];
    
    [peerconnection addTransceiverOfType:RTCRtpMediaTypeAudio init:transceiverInit];
    [peerconnection addTransceiverOfType:RTCRtpMediaTypeVideo init:transceiverInit];
    
    [self subscribeInternal:stream];
    
}



- (void) unsubscribe:(NSString *)streamId
{
    
    RTCStream* stream = [_remoteStreams objectForKey:streamId];
    
    if(stream == nil) {
        return;
    }
    
    if(stream.videoTransceiver) {
        [stream.videoTransceiver stop];
    }
    
    if(stream.audioTransceiver) {
        [stream.audioTransceiver stop];
    }
    
    [_remoteStreams removeObjectForKey:streamId];
}



-(void)joinRoom:(NSString *)room
{
    
    roomId = room;
    
    if (_status == RTCEngineStatusConnected) {
        return;
    }
    
    [self setupSignlingClient];
}


-(void)leaveRoom
{
    
    [self sendLeave];
    [self close];
}



#pragma mark - internal

- (void) setupSignlingClient
{
    
    
    NSURL* url = [[NSURL alloc] initWithString:_config.signallingServer];
    
    _manager = [[SocketManager alloc] initWithSocketURL:url
                                                 config:@{
                                                          @"compress": @YES,
                                                          @"forceWebsockets":@YES,
                                                          @"reconnectAttempts":@5,
                                                          @"reconnectWait":@10000,
                                                          @"connectParams": @{@"room":roomId}}];
    
    
    _socket = _manager.defaultSocket;
    __weak id weakSelf = self;
    [_socket on:@"connect" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull ack) {
        [weakSelf join];
    }];
    
    
    [_socket on:@"error" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull ack) {
        
    }];
    
    [_socket on:@"disconnect" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull ack) {
        
    }];
    
    [_socket on:@"reconnect" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull ack) {
        
    }];
    
    
    [_socket on:@"message" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull ack) {
        NSDictionary* _data = [data objectAtIndex:0];
        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate rtcengine:self didReceiveMessage:_data];
        });
    }];
    
    
    [_socket on:@"streampublished" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull ack) {
        
        NSDictionary* _data = [data objectAtIndex:0];
        [self handleStreamPublished:_data];
    }];
    
    
    [_socket on:@"streamunpublished" callback:^(NSArray * _Nonnull data, SocketAckEmitter * _Nonnull ack) {
        
        NSDictionary* _data = [data objectAtIndex:0];
        [self handleStreamUnpublished:_data];
    }];
    
    
    [_socket connect];
}


-(void) join
{
    
    NSDictionary* data = @{
                           @"room": roomId
                           };
    
    OnAckCallback* ack = [_socket emitWithAck:@"join" with:@[data]];
    
    __weak id weakSelf = self;
    [ack timingOutAfter:10.0 callback:^(NSArray * _Nonnull data) {
        NSDictionary* _data = [data objectAtIndex:0];
        [weakSelf handleJoined:_data];
    }];
}


- (void) sendLeave
{
    
    NSDictionary *data = @{};
    [_socket emit:@"leave" with:@[data]];
}


- (void) sendConfigure:(NSDictionary *)data
{
    [_socket emit:@"configure" with:@[data]];
}


- (void) close
{
    
    if (_closed) {
        return;
    }
    
    _closed = true;
    
    [_socket disconnect];
    
    for (RTCStream* stream in [_localStreams allValues]) {
        
//        if (stream.stream) {
//            [_peerconnection removeStream:stream.stream];
//
//            dispatch_async(dispatch_get_main_queue(), ^{
//                [_delegate rtcengine:self didRemoveLocalStream:stream];
//            });
//        }
        
        // todo  use new api
    }
    
    for (RTCStream* stream in [_remoteStreams allValues]) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            //[_delegate rtcengine:self didRemoveRemoteStream:stream];
        });
        
        [stream close];
    }
    
    [_remoteStreams removeAllObjects];
    [_localStreams removeAllObjects];
    
}



- (void) handleJoined:(NSDictionary*) data
{
    
    
    NSArray* streams = [data valueForKeyPath:@"room.streams"];
    
    for(NSDictionary* streamDict in streams){
        [streamsMap setObject:[streamDict objectForKey:@"data"] forKey:[streamDict objectForKey:@"publisherId"]];
    }
    
    __weak id weakSelf = self;
    
    [self setStatus:RTCEngineStatusConnected];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [_delegate rtcengineDidJoined];
    });
    
    for(NSDictionary* streamDict in streams){
        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate rtcengine:self didStreamPublished:[streamDict objectForKey:@"publisherId"]];
        });
    }
}


- (void) handleLocalStream:(RTCStream*)stream publishedWithData:(NSDictionary*)data
{
    
     __weak id weakSelf = self;
    // todo error handle
    RTCSessionDescription *answer = [RTCSessionDescription
                                     descriptionFromJSONDictionary:@{
                                                                     @"sdp":[data objectForKey:@"sdp"],
                                                                     @"type":@"answer"}];
    
    [stream.peerconnection setRemoteDescription:answer completionHandler:^(NSError * _Nullable error) {
        
        if (error) {
            NSLog(@"error %@", error);
            return;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_delegate rtcengine:self didLocalStreamPublished:stream];
        });
    }];
    
}


- (void) handleLocalStream:(RTCStream*)stream subscribedWithData:(NSDictionary*)data
{
    
    __weak id weakSelf = self;
    
    NSDictionary* attributes = [data objectForKey:@"stream"];
    
    NSLog(@"stream data %@", attributes);
    
    RTCSessionDescription *answer = [RTCSessionDescription
                                     descriptionFromJSONDictionary:@{
                                                                     @"sdp":[data objectForKey:@"sdp"],
                                                                     @"type":@"answer"}];
    
    [stream.peerconnection setRemoteDescription:answer completionHandler:^(NSError * _Nullable error) {
        
        if (error) {
            NSLog(@"error %@", error);
            return;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_delegate rtcengine:self didStreamSubscribed:stream];
        });
    
    }];
    
}




-(void) handleConfigure:(NSDictionary*)data
{
    NSString* msid = [data objectForKey:@"msid"];
    if(!msid){
        return;
    }
    
    RTCStream* remoteStream = [_remoteStreams objectForKey:msid];
    
    if(!remoteStream) {
        return;
    }
    
    if([data objectForKey:@"video"]){
        BOOL muting = [[data objectForKey:@"muting"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            [remoteStream onMuteAudio:muting];
        });
    }
    
    if([data objectForKey:@"audio"]) {
        BOOL muting = [[data objectForKey:@"muting"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
             [remoteStream onMuteAudio:muting];
        });
       
    }
}



-(void) publishInternal:(RTCStream*) stream
{
    
     __weak id weakSelf = self;
    
    [stream.peerconnection offerForConstraints:nil completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
        
        if (error) {
            // TODO delegate to outside
            return;
        }
        
        [stream.peerconnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
            
            
            if (error) {
                NSLog(@"error %@",error);
                return;
            }
            
            NSDictionary* data = @{
                                   @"sdp": sdp.sdp,
                                   @"stream": @{
                                           @"publisherId": stream.streamId,
                                           @"data": @{
                                                   @"bitrate":@500
                                                   }
                                           }
                                   };
            
            OnAckCallback* ack = [_socket emitWithAck:@"publish" with:@[data]];
            
            [ack timingOutAfter:10.0 callback:^(NSArray * _Nonnull data) {
                
                NSDictionary* _data = [data objectAtIndex:0];
                [weakSelf handleLocalStream:stream publishedWithData:_data];
            }];
        }];
    }];
}


- (void) unpublishInternal:(RTCStream*)stream
{
    __weak id weakSelf = self;
    
    NSDictionary* data = @{
                           @"stream":@{
                                   @"publisherId":stream.streamId
                                   }
                           };
    
    OnAckCallback* ack = [_socket emitWithAck:@"unpublish" with:@[data]];
    
    [ack timingOutAfter:10.0 callback:^(NSArray * _Nonnull data) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate rtcengine:self didLocalStreamUnPublished:stream];
        });
    }];
}


- (void) subscribeInternal:(RTCStream*)stream
{
    
    __weak id weakSelf = self;
    
    [stream.peerconnection offerForConstraints:nil completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
        
        if (error) {
            // TODO delegate to outside
            return;
        }
        
        [stream.peerconnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
            
            NSDictionary* data = @{
                                   @"sdp": sdp.sdp,
                                   @"stream": @{
                                           @"publisherId":stream.publisherId
                                           }
                                   };
            
            OnAckCallback* ack = [_socket emitWithAck:@"subscribe" with:@[data]];
            
            [ack timingOutAfter:10.0 callback:^(NSArray * _Nonnull data) {
                
                NSDictionary* _data = [data objectAtIndex:0];
                [weakSelf handleLocalStream:stream subscribedWithData:_data];
            }];
            
        }];
    }];
}


- (void) unsubscribeInternal:(RTCStream*)stream
{
    
    
    NSDictionary* data = @{
                           @"stream": @{
                                   @"publisherId":stream.publisherId,
                                   @"subscriberId":stream.streamId
                                   }
                           };
    
    OnAckCallback* ack = [_socket emitWithAck:@"unsubscribe" with:@[data]];
    
    [ack timingOutAfter:10.0 callback:^(NSArray * _Nonnull data) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate rtcengine:self didStreamUnsubscribed:stream];
        });
    }];
}


- (void) handleStreamPublished:(NSDictionary*)data
{
    
    NSLog(@"handleStreamPublished %@", data);
    
    NSString* publisherId = [data valueForKeyPath:@"stream.publisherId"];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate rtcengine:self didStreamPublished:publisherId];
    });
    
}


- (void) handleStreamUnpublished:(NSDictionary*)data
{
    
    NSLog(@"handleStreamUnpublished %@", data);
    
    NSString* publisherId = [data valueForKeyPath:@"stream.publisherId"];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate rtcengine:self didStreamUnpublished:publisherId];
    });
    
}


-(void) setStatus:(RTCEngineStatus)newStatus
{
    if (_status == newStatus) {
        return;
    }
    
    _status = newStatus;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [_delegate rtcengine:self didStateChange:_status];
    });
}












@end






