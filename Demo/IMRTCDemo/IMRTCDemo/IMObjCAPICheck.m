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
@import IMCallEngineWebRTC;

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

    // 扬声器：设计文档 §7.5 的 setAudioRoute。
    [_engine setSpeakerOn:YES];

    // 挂画面：UI 拿到画面的唯一途径（CONVENTIONS §1）。
    [_engine attachView:@"bob" to:nil];
    [_engine attachLocalView:@"cam-1" to:nil];

    // 采集档位是宿主策略：宿主要能列出档位、也要能自己造一个。
    for (IMVideoProfile *profile in IMVideoProfile.presets) {
        NSLog(@"[objc] 档位 %@ %ldx%ld", profile.name, (long)profile.width, (long)profile.height);
    }
    // `default` 是 ObjC 的关键字，点语法写不出来，只能走方括号。
    NSLog(@"[objc] 缺省档位 %@", [IMVideoProfile default].name);

    // SDK 版本：与握手帧里的 sdk 字段同源。Swift 的全局常量 ObjC 看不见，走类属性。
    NSLog(@"[objc] SDK %@", IMCallEngine.sdkVersion);
}

// 带媒体的 Engine：ObjC 宿主不写 Swift 桥，直接用这个工厂（§7-2 拍板，HOST_INTEGRATION_DESIGN §3.3）。
- (void)checkWebRTCFactoryAPI {
    NSURL *url = [NSURL URLWithString:@"ws://127.0.0.1:8787/v1/ws"];
    IMCallEngine *withMedia = [IMCallEngine webRTCEngineWithURL:url deviceID:@"objc-demo-media"];
    withMedia.delegate = self;

    // 带选项发起群通话：群号 / user_data / 振铃超时原样进 call.invite（HOST_INTEGRATION_DESIGN §3.2）。
    IMCallOptions *options = [[IMCallOptions alloc] initWithIsGroup:YES chatGroupID:@"g-42"
                                                            userData:@"{}" timeoutSec:45];
    [withMedia call:@[@"bob", @"carol"] mediaType:@"video" options:options
    completionHandler:^{}];

    // 主动加入一通正在进行的群通话（call.join，2026-09-15 实现）。
    [withMedia joinCall:@"call-77a1" completionHandler:^{}];
}

// device_id 的入参校验（协议 §2.5）。宿主可以不等 login 就自己先验一遍。
- (void)checkDeviceIDAPI {
    // 用 UIDevice.current.name 当 device_id 是最常见的坑：默认叫「张三的 iPhone」，
    // 中文加空格，两条规则一起犯。identifierForVendor 的 UUID 反倒是合规的。
    NSError *err = nil;
    if (![IMDeviceID checkDeviceID:@"张三的 iPhone" error:&err]) {
        // 码与服务端拒绝时是同一个 1004，宿主不用为「本地拦的」和「服务端拒的」写两遍。
        NSLog(@"[objc] device_id 不合规 code=%ld name=%@ detail=%@",
              (long)err.code, err.userInfo[IMRTCErrorInfo.nameKey], err.localizedDescription);
    }
    // 上限是公开常量：宿主拿它裁自己生成的 id，别把 64 抄进自己代码里。
    NSLog(@"[objc] device_id 上限 %ld 字节", (long)IMDeviceID.maxBytes);
}

- (void)checkAsyncAPI {
    // Swift 的 async 方法在 ObjC 里是 completionHandler 形式。
    [_engine login:@"token" completionHandler:^(NSError * _Nullable error) {
        // 登录失败要能分支：domain 认「是不是我们的错」，code 是协议码（如 1004）。
        if (error != nil) {
            if ([error.domain isEqualToString:IMRTCErrorInfo.domain] && error.code == 1004) {
                NSLog(@"[objc] 入参不对：%@", error.localizedDescription);
            }
            return;
        }
        [self->_engine call:@[@"bob"] mediaType:@"video" isGroup:NO completionHandler:^{}];
        [self->_engine joinRoom:@"r-1" roomToken:@"rt" autoSubscribe:YES completionHandler:^{}];
        [self->_engine leaveRoomWithCompletionHandler:^{}];
        [self->_engine acceptWithCompletionHandler:^{}];
        [self->_engine hangupWithCompletionHandler:^{}];
        [self->_engine forceEnd];
        [self->_engine setMuted:@"mic-1" muted:YES completionHandler:^{}];
        [self->_engine publishMicrophoneWithCompletionHandler:^(NSString *cid, NSError *err) {}];
        [self->_engine startLocalPreviewWithCompletionHandler:^(NSString *cid, NSError *err) {}];
        [self->_engine stopLocalPreview];

        // 按类型的媒体开关（腾讯 TUICallEngine 同名，2026-09-15）：
        // open 没发布就发布、发布过就取消静音；close 只静音不 unpublish，没发布过是空操作。
        [self->_engine openMicrophoneWithCompletionHandler:^(NSError * _Nullable err) {}];
        [self->_engine closeMicrophoneWithCompletionHandler:^{}];
        [self->_engine openCameraWithCompletionHandler:^(NSError * _Nullable err) {}];
        [self->_engine closeCameraWithCompletionHandler:^{}];

        // 终态销毁（2026-09-15）：logout + 撤观察者 + 断 delegate，之后这台 Engine 不能再用。
        [self->_engine destroyWithCompletionHandler:^{}];
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

- (void)callEngine:(IMCallEngine *)engine wasKickedOutFor:(IMKickedOutReason)reason {
    // 两种原因两种处置——ObjC 侧也要能对枚举分支。
    if (reason == IMKickedOutReasonAuthExpired) {
        NSLog(@"[objc] 票不好使，取新票重登");
    } else {
        NSLog(@"[objc] 账号在别处登录或被吊销，回登录页");
    }
}

- (void)callEngine:(IMCallEngine *)engine tokenWillExpireAt:(int64_t)expiresAtMS {
    // 去自家后台换票，再带着新的到期时刻推回来。
    [engine updateToken:@"refreshed-token" expiresAtMS:expiresAtMS + 43200000];
}

- (void)callEngine:(IMCallEngine *)engine didReceiveCall:(NSString *)callID caller:(NSString *)caller
           inviter:(NSString *)inviter calleeIDs:(NSArray<NSString *> *)calleeIDs
         mediaType:(NSString *)mediaType isGroup:(BOOL)isGroup
       chatGroupID:(NSString *)chatGroupID userData:(NSString *)userData {
    NSLog(@"[objc] didReceiveCall %@ from=%@ inviter=%@ group=%@", callID, caller, inviter, chatGroupID);
}

- (void)callEngine:(IMCallEngine *)engine callDidBegin:(NSString *)callID roomID:(NSString *)roomID
         mediaType:(NSString *)mediaType isGroup:(BOOL)isGroup role:(NSString *)role
            caller:(NSString *)caller chatGroupID:(NSString *)chatGroupID userData:(NSString *)userData {
    NSLog(@"[objc] callBegin %@ / %@ caller=%@ group=%@", callID, roomID, caller, chatGroupID);
}

// reason 2026-09-15 从 NSString 改成 IMCallEndReason（四端命名对齐，@objc optional
// 静默失效陷阱：旧签名 `reason:(NSString *)` 不会编译报错，只会收不到这条回调）。
- (void)callEngine:(IMCallEngine *)engine callDidEnd:(NSString *)callID reason:(IMCallEndReason)reason
       durationSec:(NSInteger)durationSec endedBy:(NSString *)endedBy {
    NSLog(@"[objc] callEnd %@ reason=%ld %ld秒", callID, (long)reason, (long)durationSec);
}

- (void)callEngine:(IMCallEngine *)engine user:(NSString *)uid audioAvailable:(BOOL)available {
    NSLog(@"[objc] %@ 麦克风 %d", uid, available);
}

// 元素类型 2026-09-15 从 NSDictionary 改成强类型 IMSpeaker / IMNetworkQuality（同一个陷阱）。
- (void)callEngine:(IMCallEngine *)engine activeSpeakersDidChange:(NSArray<IMSpeaker *> *)speakers {
    NSLog(@"[objc] 主讲人 %lu 位", (unsigned long)speakers.count);
}

- (void)callEngine:(IMCallEngine *)engine networkQualityDidChange:(NSArray<IMNetworkQuality *> *)entries {
    NSLog(@"[objc] 网络质量上报 %lu 条", (unsigned long)entries.count);
}

- (void)callEngine:(IMCallEngine *)engine didFailWithError:(NSError *)error {
    NSLog(@"[objc] error %@ %ld", error.domain, (long)error.code);
}

@end
