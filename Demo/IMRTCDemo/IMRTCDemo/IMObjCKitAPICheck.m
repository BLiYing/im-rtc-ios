//
//  IMObjCKitAPICheck.m
//  IMRTCDemo
//
//  **这个文件存在的唯一目的是「编译即验证」**（CONVENTIONS §4），与
//  `IMObjCAPICheck.m`（验 Engine）分开一个文件——那份验的是无 UI 的信令/媒体门面，
//  这份验的是 IMCallKit：纯 Objective-C 工程不写一行 Swift 也要能把整套 Kit 用起来
//  （HOST_INTEGRATION_DESIGN，首批宿主 IMProgram 是 ObjC 工程）。
//
//  这段代码永远不会被执行，它只需要**编得过**。新增 Kit 的公开 API 之后，
//  在这里补一行调用；编不过就说明那个 API 对 ObjC 宿主还不可用。
//

@import Foundation;
@import UIKit;
@import IMCallEngine;
@import IMCallKit;

// MARK: - IMInviteMemberProvider / IMProfileResolving 的 ObjC 实现

// 证明这两个协议对 ObjC 类型可实现——纯 ObjC 宿主想接「按通话要候选人」/「本机身份解析」
// 不需要借道 Swift。
@interface IMObjCKitAPICheckProvider : NSObject <IMInviteMemberProvider, IMProfileResolving>
@end

@implementation IMObjCKitAPICheckProvider

- (void)inviteCandidatesFor:(IMInviteContext *)context
                       query:(NSString *)query
                      cursor:(nullable NSString *)cursor
                  completion:(void (^)(NSArray<IMInviteCandidate *> *items,
                                       NSString * _Nullable nextCursor,
                                       NSError * _Nullable error))completion {
    completion(@[], nil, nil);
}

- (BOOL)canInviteIn:(IMInviteContext *)context {
    return YES;
}

- (nullable NSString *)displayNameForUID:(NSString *)uid {
    return uid;
}

@end

// MARK: - IMCallControllerStateObserver 的 ObjC 实现

@interface IMObjCKitAPICheck : NSObject <IMCallControllerStateObserver>
@end

@implementation IMObjCKitAPICheck {
    IMCallEngine *_engine;
    IMCallKit *_kit;
    IMObjCKitAPICheckProvider *_provider;
}

- (void)checkKitAPI {
    NSURL *url = [NSURL URLWithString:@"ws://127.0.0.1:8787/v1/ws"];
    _engine = [[IMCallEngine alloc] initWithUrl:url deviceID:@"objc-kit-demo"];

    // 控制器也能不经 IMCallKit、直接由 ObjC 造一个（宿主只想要状态中枢、不要 Kit 那整套界面时）。
    IMCallEngine *standaloneEngine = [[IMCallEngine alloc] initWithUrl:url deviceID:@"objc-controller-demo"];
    IMCallController *standaloneController = [[IMCallController alloc] initWithEngine:standaloneEngine];
    NSLog(@"[objc] 独立控制器 phase=%ld", (long)[standaloneController objcPhase]);

    // 配置：宿主给的候选名单（静态兜底）+ provider（分页/搜索）+ 身份解析器，
    // 都是 ObjC 实例（item 5：核对 IMCallKitConfig / provider / resolver 的 ObjC 可见性）。
    IMCallKitConfig *config = [[IMCallKitConfig alloc] init];
    config.forcesDarkAppearance = YES;
    config.bannerFirst = YES;
    config.floatingWindow = YES;
    config.allowsManualUIDInput = NO;
    _provider = [[IMObjCKitAPICheckProvider alloc] init];
    config.inviteMemberProvider = _provider;
    config.profileResolver = _provider;
    IMInviteCandidate *candidate = [[IMInviteCandidate alloc] initWithUid:@"bob"
                                                                       name:@"Bob"
                                                                  avatarURL:nil
                                                                   subtitle:nil
                                                                 selectable:YES
                                                         unselectableReason:nil];
    config.inviteCandidates = @[candidate];
    config.incomingVibration = NO;

    // 入口：纯 ObjC 造 Kit，拿到控制器。
    _kit = [[IMCallKit alloc] initWithEngine:_engine config:config];
    NSLog(@"[objc] Kit 版本 %@", IMCallKit.kitVersion);

    IMCallController *controller = _kit.controller;
    [controller addStateObserver:self];
    // block 形式：返回 NSUUID 退订凭证，block 被强持有，里面弱捕获 self。
    __weak typeof(self) weakSelf = self;
    NSUUID *stateToken = [controller addStateChangeHandler:^(IMCallController *c) {
        NSLog(@"[objc] block 状态变化：phase=%ld 群=%d %@", (long)c.objcPhase, c.isGroupCall, weakSelf);
    }];
    [controller removeStateChangeHandler:stateToken];

    // 发起（完整形态：isGroup / chatGroupID / userData / timeoutSec）。
    [controller placeCall:@[@"bob", @"carol"]
                 mediaType:@"video"
                   isGroup:YES
               chatGroupID:@"g-42"
                  userData:@"{}"
                timeoutSec:45];

    // 直接进会议房。
    [controller joinMeetingWithRoomID:@"room-1" roomToken:@"rt"];

    // 接听 / 拒接 / 红键结束。
    [controller accept];
    [controller reject];
    [controller end];

    // 麦克风 / 摄像头 / 扬声器 / 前后摄像头切换。
    [controller toggleMic];
    [controller toggleCamera];
    [controller toggleSpeaker];
    [controller switchCamera];
    BOOL usingFront = [controller isUsingFrontCamera];

    // 挂远端画面 / 本端预览。
    [controller attachView:@"bob" to:nil];
    [controller attachLocalPreviewToView:nil];
    BOOL hasCamera = [controller hasLocalCamera];

    // 主动加入正在进行的群通话：controller 与 IMCallKit 门面两个入口都验一遍。
    [controller joinCall:@"call-77a1"];
    [_kit joinCall:@"call-77a1"];

    // 通话中加人、报层。
    [controller inviteMore:@[@"dave"]];
    [controller reportLayer:@"bob" layer:@"h"];

    // 收起 / 展开小窗、交换大小画面、dismiss。
    [controller setMinimized:YES];
    [controller setSwapped:YES];
    [controller dismiss];

    // 加人上下文与权限（HOST_INTEGRATION_DESIGN §3.4）。
    IMInviteContext *ctx = [controller inviteContext];
    BOOL canInvite = [controller canStartInvite];
    NSLog(@"[objc] 邀请上下文 call=%@ group=%@ canInvite=%d",
          ctx.callID, ctx.chatGroupID, canInvite);

    // 只读状态查询（够自画辅助 UI）：阶段、是否群聊、call_id、是否收进小窗、
    // 媒体类型、1v1 对端 uid。
    IMCallKitPhase phase = [controller objcPhase];
    BOOL isGroup = [controller isGroupCall];
    NSString *callID = [controller currentCallID];
    BOOL minimized = [controller isMinimized];
    NSString *mediaType = [controller currentMediaType];
    NSString *peer = [controller peerUID];
    NSLog(@"[objc] phase=%ld group=%d call=%@ minimized=%d media=%@ peer=%@ front=%d cam=%d",
          (long)phase, isGroup, callID, minimized, mediaType, peer, usingFront, hasCamera);

    [controller removeStateObserver:self];

    // 宿主的身份解析回来了，重画；version 常量走门面（全局常量 ObjC 看不见，见 KitEntry.swift）。
    [_kit reloadProfiles:@[@"bob"]];
    [_kit start];
}

#pragma mark - IMCallControllerStateObserver

- (void)callControllerDidUpdateState:(IMCallController *)controller {
    NSLog(@"[objc] Kit 状态变化 phase=%ld", (long)[controller objcPhase]);
}

@end
