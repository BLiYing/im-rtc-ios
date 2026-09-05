//
//  IMObjCAPICheck.m
//  IMRTCDemo
//
//  **这个文件存在的唯一目的是「编译即验证」**（CONVENTIONS §4）。
//
//  首批宿主 IMProgram 是 Objective-C 工程，所以 Engine 的公开面必须 ObjC 可用。
//  但 `@objc` 标注写没写、类型能不能桥接，在 Swift 那边是看不出来的——
//  只有真的从 ObjC 调一遍才知道。这段代码永远不会被执行，它只需要**编得过**。
//
//  新增公开 API 之后，在这里补一行调用。编不过就说明那个 API 对 ObjC 宿主不可用。
//

@import Foundation;
@import IMCallEngine;

@interface IMObjCAPICheck : NSObject <IMCallEngineDelegate>
@end

@implementation IMObjCAPICheck {
    IMCallEngine *_engine;
}

- (void)checkEngineAPI {
    NSURL *url = [NSURL URLWithString:@"ws://127.0.0.1:8787/v1/ws"];

    // 纯信令形态：不传媒体适配器也能用（登录、振铃、成员、静音通知一个都不少）。
    _engine = [[IMCallEngine alloc] initWithUrl:url deviceID:@"objc-demo"];
    _engine.delegate = self;

    // 换接入票：协议 §1.5 说 4401 的处置是「换新 token 后重连」，而换票是宿主的事。
    [_engine updateToken:@"new-token"];

    // block 接法（delegate 之外的第二种形式，CONVENTIONS §4 要求两种都提供）。
    NSUUID *token = [_engine addEventObserver:^(IMCallEvent * _Nonnull event) {
        if (event.name == IMCallEventNameCallBegin) {
            NSLog(@"[objc] callBegin room=%@ call=%@", event.roomID, event.callID);
        }
    }];
    [_engine removeEventObserver:token];

    // 挂画面：UI 拿到画面的唯一途径（CONVENTIONS §1）。
    [_engine attachView:@"bob" to:nil];
    [_engine attachLocalView:@"cam-1" to:nil];
}

- (void)checkAsyncAPI {
    // Swift 的 async 方法在 ObjC 里是 completionHandler 形式。
    [_engine login:@"token" completionHandler:^(NSError * _Nullable error) {
        if (error != nil) { return; }
        [self->_engine call:@[@"bob"] mediaType:@"video" isGroup:NO completionHandler:^{}];
        [self->_engine joinRoom:@"r-1" roomToken:@"rt" autoSubscribe:YES completionHandler:^{}];
        [self->_engine leaveRoomWithCompletionHandler:^{}];
        [self->_engine acceptWithCompletionHandler:^{}];
        [self->_engine hangupWithCompletionHandler:^{}];
        [self->_engine setMuted:@"mic-1" muted:YES completionHandler:^{}];
        [self->_engine publishMicrophoneWithCompletionHandler:^(NSString *cid, NSError *err) {}];
    }];
}

#pragma mark - IMCallEngineDelegate

- (void)callEngine:(IMCallEngine *)engine didConnect:(NSString *)sessionID resumed:(BOOL)resumed {
    NSLog(@"[objc] connected %@ resumed=%d", sessionID, resumed);
}

- (void)callEngine:(IMCallEngine *)engine didDisconnect:(NSInteger)code willReconnect:(BOOL)willReconnect {
    // 4401 = 接入票不好使，宿主该去换一枚新的再调 updateToken:。
    if (code == 4401) { [engine updateToken:@"refreshed-token"]; }
}

- (void)callEngineDidGetKickedOut:(IMCallEngine *)engine {
    NSLog(@"[objc] 登录态失效，回登录页");
}

- (void)callEngine:(IMCallEngine *)engine callDidBegin:(NSString *)callID roomID:(NSString *)roomID
         mediaType:(NSString *)mediaType isGroup:(BOOL)isGroup role:(NSString *)role {
    NSLog(@"[objc] callBegin %@ / %@", callID, roomID);
}

- (void)callEngine:(IMCallEngine *)engine callDidEnd:(NSString *)callID reason:(NSString *)reason
       durationSec:(NSInteger)durationSec endedBy:(NSString *)endedBy {
    NSLog(@"[objc] callEnd %@ reason=%@ %ld秒", callID, reason, (long)durationSec);
}

- (void)callEngine:(IMCallEngine *)engine user:(NSString *)uid audioAvailable:(BOOL)available {
    NSLog(@"[objc] %@ 麦克风 %d", uid, available);
}

- (void)callEngine:(IMCallEngine *)engine activeSpeakersDidChange:(NSArray<NSDictionary<NSString *, id> *> *)speakers {
    NSLog(@"[objc] 主讲人 %lu 位", (unsigned long)speakers.count);
}

- (void)callEngine:(IMCallEngine *)engine didFailWithError:(NSError *)error {
    NSLog(@"[objc] error %@ %ld", error.domain, (long)error.code);
}

@end
