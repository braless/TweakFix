#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>
#import <objc/message.h>
#include <substrate.h>
#include <objc/message.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <math.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

// 微信插件收纳接口（微信->我->插件）
@interface WCPluginsMgr : NSObject
+ (instancetype)sharedInstance;
- (void)registerControllerWithTitle:(NSString *)title version:(NSString *)version controller:(NSString *)controller;
- (void)registerSwitchWithTitle:(NSString *)title key:(NSString *)key;
@end

static NSString *const kBlockedText = @"请求已被拦截";
static NSString *const kSwitchKey = @"APIBlockerEnabled";
static NSString *const kURLsKey = @"APIBlockerURLs";
static NSString *const kDisabledURLsKey = @"APIBlockerDisabledURLs";
static NSString *const kHideBrowserURLKey = @"APIBlockerHideBrowserURL";
static NSString *const kResponseTypeKey = @"APIBlockerResponseType";
static NSString *const kResponseBodyKey = @"APIBlockerResponseBody";
static NSString *const kResponseTypeEmpty = @"empty";
static NSString *const kOldCardPageKey = @"APIBlockerOldCardPage";
static NSString *const kOldCardPageClassKey = @"APIBlockerOldCardPageClass";
static NSString *const kForceCallKitKey = @"APIBlockerForceCallKit";
static NSString *const kBlockPatKey = @"APIBlockerBlockPat";
static NSString *const kBlockGroupUndoneKey = @"APIBlockerBlockGroupUndone";
static NSString *const kPatOverridesKey = @"APIBlockerPatOverrides";
static NSString *const kGroupUndoneOverridesKey = @"APIBlockerGroupUndoneOverrides";
static NSString *const kLogEnabledKey = @"APIBlockerLogEnabled";
static NSString *const kCallKitHideNameKey = @"APIBlockerCallKitHideName";
static NSString *const kCallKitCustomNameKey = @"APIBlockerCallKitCustomName";
static NSString *const kCallKitHideIconKey = @"APIBlockerCallKitHideIcon";
static NSString *const kShowPayBalanceKey = @"APIBlockerShowPayBalance";
static NSString *const kBlockServiceArticleKey = @"APIBlockerBlockServiceArticle";
static NSString *const kMarkBrandReadKey = @"APIBlockerMarkBrandRead";
static NSString *const kMarkBrandReadTipKey = @"APIBlockerMarkBrandReadTip";
static NSString *const kMarkBrandReadTipTextKey = @"APIBlockerMarkBrandReadTipText";
static NSString *const kAutoMarkBrandReadKey = @"APIBlockerAutoMarkBrandRead";
static NSString *const kAutoMarkBrandReadLastKey = @"APIBlockerAutoMarkBrandReadLast";
static NSString *const kMainReadKey = @"APIBlockerMainRead";
static NSString *const kMainReadSpeedKey = @"APIBlockerMainReadSpeed";
static NSString *const kLiquidTabBarKey = @"APIBlockerLiquidTabBar";
static NSString *const kLiquidScrollHideKey = @"APIBlockerLiquidScrollHide";
static NSString *const kLiquidGlassIntensityKey = @"APIBlockerLiquidGlassIntensity";
static NSString *const kTopLiquidKey = @"APIBlockerTopLiquid";
static NSString *const kTabBarOffsetKey = @"APIBlockerTabBarOffset";
static NSString *const kTabBarOffsetValueKey = @"APIBlockerTabBarOffsetValue";
static NSString *const kPluginVersion = @"1.2.54";

// 插件开关状态：默认开启；用户可在 微信->我->插件 里关闭
static BOOL APIBlockerEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kSwitchKey] == nil) {
        return YES;
    }
    return [defaults boolForKey:kSwitchKey];
}

// 浏览器标题栏隐藏网址：默认开启（恢复旧版样式）
static BOOL BrowserURLHideEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kHideBrowserURLKey] == nil) {
        return YES;
    }
    return [defaults boolForKey:kHideBrowserURLKey];
}

// 恢复旧版卡包页面：默认关闭
static BOOL OldCardPageEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kOldCardPageKey];
}

// 付款页面（收付款码页）在付款方式“零钱”后显示真实余额：默认关闭
static BOOL ShowPayBalanceEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kShowPayBalanceKey];
}

// 屏蔽服务号收纳页的下方文章（只保留上方通知）：默认关闭
static BOOL BlockServiceArticleEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kBlockServiceArticleKey];
}

// 长按公众号列表页顶部“公众号”标题，一键把所有公众号未读标记为已读：默认关闭
static BOOL MarkBrandReadEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kMarkBrandReadKey];
}

// 一键已读完成后提示+震动：默认开启（依赖“长按公众号标题已读”功能）
static BOOL MarkBrandReadTipEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kMarkBrandReadTipKey] == nil) {
        return YES;
    }
    return [defaults boolForKey:kMarkBrandReadTipKey];
}

// 一键已读完成提示文本（可自定义）
static NSString *MarkBrandReadTipText(void) {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:kMarkBrandReadTipTextKey];
    return value.length > 0 ? value : @"已全部标记为已读";
}

// 进入公众号列表页后自动一键已读：默认关闭
static BOOL AutoMarkBrandReadEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kAutoMarkBrandReadKey];
}

// 一键已读完成震动：固定极轻微短反馈（约 0.1s、力度极轻）。
// 不使用 AudioServicesPlaySystemSoundWithVibration（私有 API 在部分设备会崩溃），
// 改用系统公开的 UIImpactFeedbackGenerator light 轻拍，绝对稳定。
static void ABDoVibrate(void) {
    @try {
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [g prepare];
            [g impactOccurred];
        }
    } @catch (NSException *e) {}
}

// 主页消息一键已读（消息列表页底部“微信”tab 向上拖动触发）：默认关闭
static BOOL MainReadEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kMainReadKey];
}

// 上滑触发阈值（绝对值）：向上滑动速度达到该值即触发已读（50~800，越小越灵敏，默认 120）
static CGFloat MainReadSpeedThreshold(void) {
    float v = [[NSUserDefaults standardUserDefaults] floatForKey:kMainReadSpeedKey];
    return (v >= 50 && v <= 800) ? v : 120.0;
}

// 原生液态底栏（iOS26 系统 Liquid Glass）：默认开
static BOOL LiquidTabBarEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kLiquidTabBarKey] == nil) return YES;
    return [d boolForKey:kLiquidTabBarKey];
}
// 滚动收纳胶囊：下滑收纳成胶囊、上滑恢复。默认开
static BOOL LiquidScrollHideEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kLiquidScrollHideKey] == nil) return YES;
    return [d boolForKey:kLiquidScrollHideKey];
}
// 玻璃效果强度：0=系统默认，1~100 手动强度
static NSInteger LiquidGlassIntensity(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kLiquidGlassIntensityKey] == nil) return 0;
    NSInteger v = [d integerForKey:kLiquidGlassIntensityKey];
    return MIN(100, MAX(0, v));
}
// 顶部去液态：隐藏导航栏按钮上的液态玻璃包裹。默认开
static BOOL TopLiquidEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kTopLiquidKey] == nil) return YES;
    return [d boolForKey:kTopLiquidKey];
}
// 底栏下沉：iOS27 隐藏 home bar 后底部留白过多，把底栏整体下移填补。默认关
static BOOL TabBarOffsetEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kTabBarOffsetKey] == nil) return NO;
    return [d boolForKey:kTabBarOffsetKey];
}
// 下沉距离（pt，0~80），默认 20
static NSInteger TabBarOffsetValue(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kTabBarOffsetValueKey] == nil) return 20;
    NSInteger v = [d integerForKey:kTabBarOffsetValueKey];
    return MIN(80, MAX(0, v));
}

// 强制 CallKit 系统来电：默认关闭
static BOOL ForceCallKitEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kForceCallKitKey];
}

// 锁屏来电界面的名称 / 图标处理
static BOOL CallKitHideNameEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kCallKitHideNameKey];
}

static NSString *CallKitCustomName(void) {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:kCallKitCustomNameKey];
    return value.length > 0 ? value : nil;
}

static BOOL CallKitHideIconEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kCallKitHideIconKey];
}

// ============ 拍一拍 / 群待办 显示控制 ============
//
// 全局开关：屏蔽全部聊天的拍一拍 / 群待办（默认关闭）。
// 单聊覆盖：聊天详情页里的开关按会话（群或私聊）单独设置，一旦设置过就优先于全局开关。

static BOOL GlobalBlockPat(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kBlockPatKey];
}

static BOOL GlobalBlockGroupUndone(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kBlockGroupUndoneKey];
}

static NSDictionary *ChatOverrides(NSString *key) {
    id stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:key];
    return [stored isKindOfClass:[NSDictionary class]] ? stored : @{};
}

static BOOL OverrideValue(NSString *key, NSString *chat, BOOL fallback) {
    if (chat.length == 0) {
        return fallback;
    }
    NSNumber *value = ChatOverrides(key)[chat];
    return [value isKindOfClass:[NSNumber class]] ? value.boolValue : fallback;
}

static void SetOverride(NSString *key, NSString *chat, BOOL value) {
    if (chat.length == 0) {
        return;
    }
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:ChatOverrides(key)];
    dict[chat] = @(value);
    [[NSUserDefaults standardUserDefaults] setObject:dict forKey:key];
}

static BOOL IsGroupChatName(NSString *chat) {
    return chat.length > 0 && [chat rangeOfString:@"@chatroom"].location != NSNotFound;
}

// 某会话是否显示拍一拍：全局开关只作用于群聊，私聊（或无法识别的会话）一律显示
static BOOL ShouldShowPatInChat(NSString *chat) {
    if (!IsGroupChatName(chat)) {
        return YES;
    }
    return OverrideValue(kPatOverridesKey, chat, !GlobalBlockPat());
}

// 群待办只存在于群聊；非群聊（或无法识别）一律不隐藏
static BOOL ShouldShowGroupUndoneInChat(NSString *chat) {
    if (!IsGroupChatName(chat)) {
        return YES;
    }
    return OverrideValue(kGroupUndoneOverridesKey, chat, !GlobalBlockGroupUndone());
}

static void SetPatShownInChat(NSString *chat, BOOL show) {
    SetOverride(kPatOverridesKey, chat, show);
}

static void SetGroupUndoneShownInChat(NSString *chat, BOOL show) {
    SetOverride(kGroupUndoneOverridesKey, chat, show);
}

// ============ 日志文件 ============
//
// 之前只能靠 syslog 看日志，比较麻烦，现在同时写一份到微信容器里：
//   <微信容器>/Documents/Tweakfix.log
// 用插件里的「文件管理 → Documents → Tweakfix.log」或设置页的「查看日志」就能直接看。

static NSString *TFLogFilePath(void) {
    static NSString *path;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        path = [documents stringByAppendingPathComponent:@"Tweakfix.log"];
    });
    return path;
}

// 日志记录开关：默认关闭（关闭时既不写文件也不进系统日志，避免额外开销）
static BOOL LogEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kLogEnabledKey];
}

static void TFLog(NSString *format, ...) {
    if (!LogEnabled()) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (message == nil) {
        return;
    }
    NSLog(@"[Tweakfix] %@", message);

    static NSLock *logLock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logLock = [[NSLock alloc] init];
    });
    [logLock lock];
    @try {
        NSFileManager *manager = [NSFileManager defaultManager];
        NSString *path = TFLogFilePath();
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM-dd HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                                                    [formatter stringFromDate:[NSDate date]],
                                                    message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];
        unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
        if (size > 512 * 1024) { // 超过 512KB 直接重建，避免无限增长
            [manager removeItemAtPath:path error:NULL];
            attributes = nil;
        }
        if (![manager fileExistsAtPath:path]) {
            [data writeToFile:path atomically:YES];
        } else {
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        }
    } @catch (NSException *exception) {
    }
    [logLock unlock];
}

// =====================================================================
// 消息转发（Webhook）与本地发送 API
// ---------------------------------------------------------------------
// 1) 收到微信消息后，按“私聊默认转发 / 群聊仅白名单”规则 POST 到外部 Webhook
// 2) 插件内监听一个本地 HTTP 端口，外部可在 Wi-Fi 下用本机 IP 调用 /send
//    让当前微信号把文字/图片/视频发给指定联系人或群
// =====================================================================

static void ABShowToast(NSString *text); // 实现在文件后部

static NSString *const kForwardEnabledKey   = @"APIBlockerForwardEnabled";
static NSString *const kForwardWebhookKey   = @"APIBlockerForwardWebhook";
static NSString *const kForwardPrivateKey   = @"APIBlockerForwardPrivate";
static NSString *const kForwardGroupsKey    = @"APIBlockerForwardGroups";
static NSString *const kLocalAPIEnabledKey  = @"APIBlockerLocalAPIEnabled";
static NSString *const kLocalAPIPortKey     = @"APIBlockerLocalAPIPort";
static NSString *const kLocalAPITokenKey    = @"APIBlockerLocalAPIToken";
static NSString *const kLocalAPIIPKey       = @"APIBlockerLocalAPIIP";
static NSString *const kForwardMaxMinutesKey = @"APIBlockerForwardMaxMinutes";
static NSString *const kKeepAliveKey         = @"APIBlockerKeepAliveEnabled";
static const NSInteger kDefaultLocalAPIPort = 8787;

#pragma mark - 配置读取

static BOOL ForwardEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kForwardEnabledKey] == nil) {
        return YES;
    }
    return [d boolForKey:kForwardEnabledKey];
}

static NSString *ForwardWebhook(void) {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:kForwardWebhookKey];
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

// 私聊消息默认转发
static BOOL ForwardPrivateEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kForwardPrivateKey] == nil) {
        return YES;
    }
    return [d boolForKey:kForwardPrivateKey];
}

// 只转发多少分钟以内的消息；0 = 不限制
static NSInteger ForwardMaxMinutes(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kForwardMaxMinutesKey] == nil) {
        return 10;
    }
    NSInteger minutes = [d integerForKey:kForwardMaxMinutesKey];
    if (minutes < 0) minutes = 0;
    return minutes;
}

// 微信后台常驻
static BOOL KeepAliveEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kKeepAliveKey] == nil) {
        return NO;
    }
    return [d boolForKey:kKeepAliveKey];
}

static NSArray<NSString *> *ForwardGroupWhitelist(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:kForwardGroupsKey];
    if ([value isKindOfClass:[NSArray class]]) {
        return value;
    }
    return @[];
}

static void SetForwardGroupWhitelist(NSArray<NSString *> *groups) {
    [[NSUserDefaults standardUserDefaults] setObject:(groups ?: @[]) forKey:kForwardGroupsKey];
}

static BOOL LocalAPIEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kLocalAPIEnabledKey] == nil) {
        return YES;
    }
    return [d boolForKey:kLocalAPIEnabledKey];
}

static NSInteger LocalAPIPort(void) {
    NSInteger port = [[NSUserDefaults standardUserDefaults] integerForKey:kLocalAPIPortKey];
    if (port < 1024 || port > 65535) {
        return kDefaultLocalAPIPort;
    }
    return port;
}

static NSString *LocalAPIToken(void) {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:kLocalAPITokenKey];
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

// 手动指定的对外 IP（留空=自动探测 Wi-Fi 地址）
static NSString *LocalAPIIPManual(void) {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:kLocalAPIIPKey];
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

#pragma mark - 运行时工具

static id ABGetObject(id object, NSString *selectorName) {
    if (!object) {
        return nil;
    }
    SEL sel = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:sel]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

static void ABSetObject(id object, NSString *selectorName, id value) {
    if (!object) {
        return;
    }
    SEL sel = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:sel]) {
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(object, sel, value);
}

static void ABSetUInt(id object, NSString *selectorName, unsigned int value) {
    if (!object) {
        return;
    }
    SEL sel = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:sel]) {
        return;
    }
    ((void (*)(id, SEL, unsigned int))objc_msgSend)(object, sel, value);
}

static unsigned int ABGetUInt(id object, NSString *selectorName) {
    if (!object) {
        return 0;
    }
    SEL sel = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:sel]) {
        return 0;
    }
    return ((unsigned int (*)(id, SEL))objc_msgSend)(object, sel);
}

static id ABService(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        return nil;
    }
    Class centerCls = NSClassFromString(@"MMServiceCenter");
    if (centerCls) {
        SEL centerSel = NSSelectorFromString(@"defaultCenter");
        if ([centerCls respondsToSelector:centerSel]) {
            id center = ((id (*)(id, SEL))objc_msgSend)(centerCls, centerSel);
            SEL getSel = NSSelectorFromString(@"getService:");
            if (center && [center respondsToSelector:getSel]) {
                return ((id (*)(id, SEL, Class))objc_msgSend)(center, getSel, cls);
            }
        }
    }
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    if ([cls respondsToSelector:sharedSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(cls, sharedSel);
    }
    return nil;
}

// 当前登录账号 wxid
static NSString *ABCurrentWxid(void) {
    Class settingCls = NSClassFromString(@"SettingUtil");
    if (settingCls) {
        SEL curSel = NSSelectorFromString(@"getCurUsrName");
        if ([settingCls respondsToSelector:curSel]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(settingCls, curSel);
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
        SEL localSel = NSSelectorFromString(@"getLocalUsrName:");
        if ([settingCls respondsToSelector:localSel]) {
            id value = ((id (*)(id, SEL, int))objc_msgSend)(settingCls, localSel, 0);
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        }
    }
    return @"";
}

static NSString *ABMsgTypeName(NSInteger code) {
    switch (code) {
        case 1: return @"text";
        case 3: return @"image";
        case 34: return @"voice";
        case 37: return @"friend_request";
        case 42: return @"card";
        case 43: return @"video";
        case 47: return @"sticker";
        case 48: return @"location";
        case 49: return @"app";
        case 50: return @"voip";
        case 10000: return @"system";
        case 10002: return @"sys_notice";
        default: return [NSString stringWithFormat:@"type_%ld", (long)code];
    }
}

#pragma mark - 主动发送消息

// 统一的 CMessageWrap 构造（文字/图片等基础字段）
static id ABMakeMessageWrap(NSInteger msgType, NSString *toUser, NSString *content) {
    Class wrapCls = NSClassFromString(@"CMessageWrap");
    if (!wrapCls) {
        return nil;
    }
    SEL initSel = NSSelectorFromString(@"initWithMsgType:");
    id wrap = nil;
    if ([wrapCls instancesRespondToSelector:initSel]) {
        wrap = ((id (*)(id, SEL, long long))objc_msgSend)([wrapCls alloc], initSel, (long long)msgType);
    } else {
        wrap = [[wrapCls alloc] init];
        ABSetUInt(wrap, @"setM_uiMessageType:", (unsigned int)msgType);
    }
    if (!wrap) {
        return nil;
    }
    NSString *selfId = ABCurrentWxid();
    if (selfId.length > 0) {
        ABSetObject(wrap, @"setM_nsFromUsr:", selfId);
    }
    ABSetObject(wrap, @"setM_nsToUsr:", toUser ?: @"");
    ABSetObject(wrap, @"setM_nsContent:", content ?: @"");
    ABSetUInt(wrap, @"setM_uiCreateTime:", (unsigned int)[[NSDate date] timeIntervalSince1970]);
    // 1 = 发送中/本地已创建，微信会走正常发送队列
    ABSetUInt(wrap, @"setM_uiStatus:", 1);
    return wrap;
}

static BOOL ABAddMessageWrapToSend(id wrap, NSString *toUser) {
    if (!wrap || toUser.length == 0) {
        return NO;
    }
    id mgr = ABService(@"CMessageMgr");
    SEL sel = NSSelectorFromString(@"AddMsg:MsgWrap:");
    if (!mgr || ![mgr respondsToSelector:sel]) {
        TFLog(@"[Forward] CMessageMgr AddMsg:MsgWrap: 不可用");
        return NO;
    }
    ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, sel, toUser, wrap);
    return YES;
}

// 记录最近一次发送过程，供 /status 远程排查
static NSString *gABLastSendDetail = @"(none)";
static NSMutableArray<NSString *> *gABSendTrace = nil;
// 最近一次出现在聊天界面的逻辑控制器（自带会话上下文），用于发送图片时复用
static __weak id gABLastLogicController = nil;
static void ABNoteSend(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *message = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    gABLastSendDetail = message ?: @"";
    TFLog(@"[Forward] %@", gABLastSendDetail);
    if (!gABSendTrace) {
        gABSendTrace = [NSMutableArray array];
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], gABLastSendDetail];
    [gABSendTrace addObject:line];
    while (gABSendTrace.count > 8) {
        [gABSendTrace removeObjectAtIndex:0];
    }
}

// 语音诊断：落盘保存，微信重启/崩溃也不会丢
static void ABVoiceDiag(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *message = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [formatter stringFromDate:[NSDate date]], message];
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *file = [dir stringByAppendingPathComponent:@"Tweakfix_voice.log"];
    NSData *existing = [NSData dataWithContentsOfFile:file] ?: [NSData data];
    NSMutableData *buf = [existing mutableCopy];
    if (buf.length > 16 * 1024) {
        [buf setData:[buf subdataWithRange:NSMakeRange(buf.length - 8 * 1024, 8 * 1024)]];
    }
    [buf appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [buf writeToFile:file atomically:YES];
    ABNoteSend(@"%@", message);
}

// 图片：FormImageMsg 生成消息 → AddMsg + StartUploadImageMsg 走微信上传
// 文字消息：CMessageWrap + AddMsg（微信自身发送队列）
static BOOL ABSendTextMessage(NSString *toUser, NSString *text) {
    if (toUser.length == 0 || text.length == 0) {
        return NO;
    }
    id wrap = ABMakeMessageWrap(1, toUser, text);
    BOOL ok = ABAddMessageWrapToSend(wrap, toUser);
    TFLog(@"[Forward] 发送文字 -> %@ : %@ (%@)", toUser, text, ok ? @"已提交" : @"失败");
    ABNoteSend(@"文字消息%@：%@", ok ? @"已提交" : @"提交失败", text);
    return ok;
}

static BOOL ABSendFileAtPath(NSString *toUser, NSString *path);

static id ABFetchLastImageMsg(NSString *toUser) {
    id m = ABService(@"CMessageMgr");
    SEL sel = NSSelectorFromString(@"GetLastImageMsg:");
    if (!m || ![m respondsToSelector:sel]) {
        return nil;
    }
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(m, sel, toUser);
    } @catch (NSException *e) {
        return nil;
    }
}

static BOOL ABTriggerImageUpload(id wrap) {
    id m = ABService(@"CMessageMgr");
    SEL sel = NSSelectorFromString(@"StartUploadImageMsg:MsgWrap:");
    if (!m || !wrap) {
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(m, sel, nil, wrap);
        return YES;
    } @catch (NSException *e) {
        TFLog(@"[Send] StartUploadImageMsg 异常：%@", e.reason);
        return NO;
    }
}

static BOOL ABSendImageAtPath(NSString *toUser, NSString *path, NSData *data) {
    if (toUser.length == 0 || path.length == 0) {
        ABNoteSend(@"图片发送中止：toUser 或 path 为空");
        return NO;
    }
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (!image) {
        image = [UIImage imageWithData:data];
    }
    if (!image || data.length == 0) {
        ABNoteSend(@"图片解码失败：%@", path.lastPathComponent);
        return ABSendFileAtPath(toUser, path);
    }

    // 参考 wechat-ai-chat-analysis：WeixinContentLogicController 表单 + AddMsg:(收件人, wrap)
    Class wxLogicCls = NSClassFromString(@"WeixinContentLogicController");
    id wxMgr = ABService(@"CMessageMgr");
    if (wxLogicCls && wxMgr) {
        @try {
            id wl = [[wxLogicCls alloc] init];
            SEL fSel = NSSelectorFromString(@"FormImageMsg:withImage:withData:");
            id wWrap = nil;
            if ([wl respondsToSelector:fSel]) {
                wWrap = ((id (*)(id, SEL, id, id, id))objc_msgSend)(wl, fSel, toUser, image, data);
            }
            if (wWrap) {
                id ext = ((id (*)(id, SEL))objc_msgSend)(wWrap, NSSelectorFromString(@"m_extendInfoWithMsgType"));
                SEL imgSel = NSSelectorFromString(@"setImage:withData:isOriginImage:");
                if (ext && [ext respondsToSelector:imgSel]) {
                    ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(ext, imgSel, image, data, YES);
                }
                SEL aSel = NSSelectorFromString(@"AddMsg:MsgWrap:");
                if ([wxMgr respondsToSelector:aSel]) {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(wxMgr, aSel, toUser, wWrap);
                    ABNoteSend(@"参考实现：FormImageMsg + AddMsg(to,wrap)：to=%@", [wWrap valueForKey:@"m_nsToUsr"] ?: @"?");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        id last = ABFetchLastImageMsg(toUser);
                        unsigned lid = last ? (unsigned)ABGetUInt(last, @"m_uiMesLocalID") : 0;
                        NSString *lto = last ? ([last valueForKey:@"m_nsToUsr"] ?: @"") : @"";
                        ABNoteSend(@"参考实现复核：localID=%u to=%@", lid, lto.length ? lto : @"无");
                        if (last && lid != 0 && [lto isEqualToString:toUser]) {
                            if (ABTriggerImageUpload(last)) {
                                ABNoteSend(@"图片已入库并触发上传：localID=%u", lid);
                            }
                        }
                    });
                    return YES;
                }
            } else {
                ABNoteSend(@"参考实现：FormImageMsg 返回 nil，转入原有链路");
            }
        } @catch (NSException *e) {
            ABNoteSend(@"参考实现异常：%@，转入原有链路", e.reason);
        }
    }
    Class logicCls = NSClassFromString(@"BaseMsgContentLogicController");
    if (!logicCls) {
        ABNoteSend(@"BaseMsgContentLogicController 不存在，回退文件消息");
        return ABSendFileAtPath(toUser, path);
    }

    @try {
        // 优先用最近打开过的聊天控制器（自带会话上下文），其次查管理器缓存，最后 alloc/init
        id logic = gABLastLogicController;
        BOOL realLogic __attribute__((unused)) = (logic != nil);
        id contactMgr = ABService(@"CContactMgr");
        SEL contactSel = NSSelectorFromString(@"getContactByName:");
        id contact = (contactMgr && [contactMgr respondsToSelector:contactSel])
            ? ((id (*)(id, SEL, id))objc_msgSend)(contactMgr, contactSel, toUser) : nil;
        if (!contact && contactMgr) {
            SEL fbSel = NSSelectorFromString(@"getContactByNameFromDB:");
            if ([contactMgr respondsToSelector:fbSel]) {
                @try { contact = ((id (*)(id, SEL, id))objc_msgSend)(contactMgr, fbSel, toUser); } @catch (NSException *e) { contact = nil; }
            }
            if (!contact && [contactMgr respondsToSelector:NSSelectorFromString(@"getContactByNameFromCache:")]) {
                @try { contact = ((id (*)(id, SEL, id))objc_msgSend)(contactMgr, NSSelectorFromString(@"getContactByNameFromCache:"), toUser); } @catch (NSException *e) { contact = nil; }
            }
        }
        id logicMgr = ABService(@"MMMsgLogicManager");
        ABNoteSend(@"联系人=%@ 逻辑管理器=%@", contact ? NSStringFromClass([contact class]) : @"无", logicMgr ? @"有" : @"无");
        if (logicMgr && contact) {
            SEL cacheSel = NSSelectorFromString(@"GetLogicControllerFromCacheWithContact:");
            if ([logicMgr respondsToSelector:cacheSel]) {
                logic = ((id (*)(id, SEL, id))objc_msgSend)(logicMgr, cacheSel, contact);
            }
            if (!logic) {
                SEL getSel = NSSelectorFromString(@"GetLogicController:");
                if ([logicMgr respondsToSelector:getSel]) {
                    @try {
                        logic = ((id (*)(id, SEL, id))objc_msgSend)(logicMgr, getSel, contact);
                    } @catch (NSException *e) {
                        logic = nil;
                    }
                }
            }
        }
        if (logic) {
            ABNoteSend(@"复用聊天控制器（%@）", toUser);
        }
        if (!logic && logicMgr && contact) {
            SEL genSel = NSSelectorFromString(@"GenOtherBaseMsgControllerByContact:searchScene:extraInfo:");
            if ([logicMgr respondsToSelector:genSel]) {
                @try {
                    id gen = ((id (*)(id, SEL, id, NSUInteger, id))objc_msgSend)(logicMgr, genSel, contact, (NSUInteger)0, nil);
                    if (gen) {
                        logic = gen;
                        ABNoteSend(@"用 GenOtherBaseMsgController 生成会话控制器（%@）", NSStringFromClass([gen class]));
                    }
                } @catch (NSException *e) {
                    ABNoteSend(@"GenOtherBaseMsgController 异常：%@", e.reason);
                }
            }
        }
        if (!logic) {
            Class useCls = logicCls;
            if (logicMgr && contact) {
                SEL clsSel = NSSelectorFromString(@"GetLogicClassByContact:");
                if ([logicMgr respondsToSelector:clsSel]) {
                    @try {
                        Class c = ((Class (*)(id, SEL, id))objc_msgSend)(logicMgr, clsSel, contact);
                        if (c) {
                            useCls = c;
                        }
                    } @catch (NSException *e) {}
                }
            }
            logic = [[useCls alloc] init];
            ABNoteSend(@"未捕获聊天控制器，改用新建实例（%@）", NSStringFromClass(useCls));
        }
        // 脱离聊天上下文时控制器没有会话名，FormImageMsg 会直接返回 nil
        ABSetObject(logic, @"setM_nsChatName:", toUser);
        ABSetObject(logic, @"setM_nsToUsr:", toUser);
        SEL chatSel = NSSelectorFromString(@"getChatName");
        if ([logic respondsToSelector:chatSel]) {
            id cn = nil;
            @try { cn = ((id (*)(id, SEL))objc_msgSend)(logic, chatSel); } @catch (NSException *e) { cn = nil; }
            ABNoteSend(@"控制器上下文：chatName=%@ toUsr=%@", cn ?: @"nil", [logic valueForKey:@"m_nsToUsr"] ?: @"nil");
        }
        SEL canSel = NSSelectorFromString(@"CanSendImageMsg:");
        if ([logic respondsToSelector:canSel]) {
            BOOL can = NO;
            @try { can = ((BOOL (*)(id, SEL, id))objc_msgSend)(logic, canSel, toUser); } @catch (NSException *e) { can = NO; }
            ABNoteSend(@"CanSendImageMsg(%@)=%d", toUser, can ? 1 : 0);
        }
        SEL formSel = NSSelectorFromString(@"FormImageMsg:withImage:withData:");
        id wrap = nil;
        if ([logic respondsToSelector:formSel]) {
            wrap = ((id (*)(id, SEL, id, id, id))objc_msgSend)(logic, formSel, toUser, image, data);
        }
        if (!wrap) {
            SEL formSel2 = NSSelectorFromString(@"FormImageMsg:withImage:");
            if ([logic respondsToSelector:formSel2]) {
                wrap = ((id (*)(id, SEL, id, id))objc_msgSend)(logic, formSel2, toUser, image);
            }
        }
        if (wrap) {
            SEL adjSel = NSSelectorFromString(@"AdjustMsgFromToUserWithChatName:MsgWrap:");
            if ([logic respondsToSelector:adjSel]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(logic, adjSel, toUser, wrap);
                ABNoteSend(@"wrap 已按会话名修正：to=%@", [wrap valueForKey:@"m_nsToUsr"] ?: @"?");
            }
            SEL simSel = NSSelectorFromString(@"SendImageMessage:withData:ImageInfo:");
            if ([logic respondsToSelector:simSel]) {
                @try {
                    ((void (*)(id, SEL, id, id, id))objc_msgSend)(logic, simSel, image, data, nil);
                    ABNoteSend(@"尝试 SendImageMessage(image,data,nil)：chatName=%@", [logic valueForKey:@"m_nsChatName"] ?: @"?");
                } @catch (NSException *e) {
                    ABNoteSend(@"SendImageMessage 异常：%@", e.reason);
                }
            }
            SEL sendWrapSel = NSSelectorFromString(@"SendMessageWrap:");
            if ([logic respondsToSelector:sendWrapSel]) {
                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(logic, sendWrapSel, wrap);
                    ABNoteSend(@"已用会话控制器发送 wrap：to=%@", [wrap valueForKey:@"m_nsToUsr"] ?: @"?");
                } @catch (NSException *e) {
                    ABNoteSend(@"SendMessageWrap 异常：%@", e.reason);
                }
            } else {
                ABNoteSend(@"控制器缺 SendMessageWrap:，稍后走 AddMsg 兜底");
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                id last = ABFetchLastImageMsg(toUser);
                unsigned lidWrap = (unsigned)ABGetUInt(wrap, @"m_uiMesLocalID");
                unsigned lidLast = last ? (unsigned)ABGetUInt(last, @"m_uiMesLocalID") : 0;
                ABNoteSend(@"图片复核：wrap.localID=%u 会话末条.localID=%u to=%@",
                           lidWrap, lidLast, last ? ([last valueForKey:@"m_nsToUsr"] ?: @"?") : @"无");
                NSString *lastTo = last ? ([last valueForKey:@"m_nsToUsr"] ?: @"") : @"";
                if (last && lidLast != 0 && [lastTo isEqualToString:toUser]) {
                    ABNoteSend(@"图片已入库且收件人正确：localID=%u", lidLast);
                    return;
                }
                if (last && lidLast != 0) {
                    if (ABTriggerImageUpload(last)) {
                        ABNoteSend(@"已触发图片上传（localID=%u）", lidLast);
                    }
                    return;
                }
                id mgr = ABService(@"CMessageMgr");
                SEL addSel = NSSelectorFromString(@"AddMsg:MsgWrap:");
                if (mgr && [mgr respondsToSelector:addSel]) {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, addSel, wrap, nil);
                    ABNoteSend(@"入库尝试A（AddMsg:wrap,nil）");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (ABGetUInt(wrap, @"m_uiMesLocalID") == 0) {
                            ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, addSel, nil, wrap);
                            ABNoteSend(@"入库尝试B（AddMsg:nil,wrap）");
                        }
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            unsigned l2 = (unsigned)ABGetUInt(wrap, @"m_uiMesLocalID");
                            ABNoteSend(@"入库结果：localID=%u to=%@", l2, [wrap valueForKey:@"m_nsToUsr"] ?: @"?");
                            if (ABTriggerImageUpload(wrap)) {
                                ABNoteSend(@"已触发图片上传（wrap）");
                            }
                        });
                    });
                } else {
                    ABNoteSend(@"AddMsg 不可用，图片无法入库");
                }
            });
            return YES;
        }
        if (!wrap) {
            SEL sendSel = NSSelectorFromString(@"SendImageMessage:withData:ImageInfo:");
            if ([logic respondsToSelector:sendSel]) {
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(logic, sendSel, toUser, data, nil);
                ABNoteSend(@"图片改走 SendImageMessage（%@×%@，%lu bytes）",
                           @(image.size.width), @(image.size.height), (unsigned long)data.length);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    id m = ABService(@"CMessageMgr");
                    SEL lastSel = NSSelectorFromString(@"GetLastImageMsg:");
                    if (m && [m respondsToSelector:lastSel]) {
                        id last = ((id (*)(id, SEL, id))objc_msgSend)(m, lastSel, toUser);
                        if (last) {
                            ABNoteSend(@"图片已建档：localID=%u to=%@",
                                       (unsigned)ABGetUInt(last, @"m_uiMesLocalID"),
                                       [last valueForKey:@"m_nsToUsr"] ?: @"?");
                        } else {
                            ABNoteSend(@"图片未建档：GetLastImageMsg 返回 nil");
                        }
                    }
                });
                return YES;
            }
        }
        if (!wrap) {
            ABNoteSend(@"FormImageMsg 返回 nil（%@×%@），回退文件消息", @(image.size.width), @(image.size.height));
            return ABSendFileAtPath(toUser, path);
        }
        ABSetObject(wrap, @"setM_nsToUsr:", toUser);
        SEL adjustSel = NSSelectorFromString(@"AdjustMsgBeforeSendWithChatName:MsgWrap:");
        if ([logic respondsToSelector:adjustSel]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(logic, adjustSel, toUser, wrap);
        }
        BOOL added = ABAddMessageWrapToSend(wrap, toUser);
        id mgr = ABService(@"CMessageMgr");
        SEL uploadSel = NSSelectorFromString(@"StartUploadImageMsg:MsgWrap:");
        if (added && mgr && [mgr respondsToSelector:uploadSel]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, uploadSel, toUser, wrap);
            ABNoteSend(@"图片已提交上传：%@（%lu bytes）", path.lastPathComponent, (unsigned long)data.length);
            return YES;
        }
        ABNoteSend(@"图片链路不可用（added=%@ upload=%@），回退文件消息", added ? @"1" : @"0",
                   (mgr && [mgr respondsToSelector:uploadSel]) ? @"1" : @"0");
    } @catch (NSException *exception) {
        ABNoteSend(@"图片发送异常：%@，回退文件消息", exception.reason);
    }
    return ABSendFileAtPath(toUser, path);
}

// 任意音频 → 16k 单声道 PCM16
static NSData *ABPCM16ForVoice(NSString *path) {
    @try {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        NSError *error = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (!reader) return nil;
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
        if (!track) return nil;
        NSDictionary *settings = @{ AVFormatIDKey: @(kAudioFormatLinearPCM),
                                    AVLinearPCMBitDepthKey: @(16),
                                    AVLinearPCMIsFloatKey: @NO,
                                    AVLinearPCMIsBigEndianKey: @NO,
                                    AVNumberOfChannelsKey: @(1),
                                    AVSampleRateKey: @(16000) };
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output]) return nil;
        [reader addOutput:output];
        [reader startReading];
        NSMutableData *pcm = [NSMutableData data];
        while (reader.status == AVAssetReaderStatusReading) {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (!sample) break;
            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
            if (block) {
                size_t len = CMBlockBufferGetDataLength(block);
                unsigned char *bytes = (unsigned char *)malloc(len);
                if (bytes) {
                    CMBlockBufferCopyDataBytes(block, 0, len, bytes);
                    [pcm appendBytes:bytes length:len];
                    free(bytes);
                }
            }
            CFRelease(sample);
        }
        return (reader.status == AVAssetReaderStatusCompleted) ? pcm : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

// 用微信自带的 MJSilkCodec 把 PCM 编成 SILK（微信语音的原生格式）
static NSData *ABSilkForVoice(NSString *path) {
    NSData *pcm = ABPCM16ForVoice(path);
    if (pcm.length == 0) return nil;
    Class codec = NSClassFromString(@"MJSilkCodec");
    SEL encodeSel = NSSelectorFromString(@"encodeToSilkFromPCMData:");
    if (!codec || ![codec respondsToSelector:encodeSel]) return nil;
    @try {
        id silk = ((id (*)(id, SEL, id))objc_msgSend)(codec, encodeSel, pcm);
        return [silk isKindOfClass:[NSData class]] ? silk : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

// 语音：先转 SILK（微信原生语音格式），再 CMessageWrap(type 34) + RecordUploadCDNMgr 上传
static BOOL ABSendVoiceAtPath(NSString *toUser, NSString *path, NSData *data) {
    if (toUser.length == 0 || data.length == 0) {
        ABNoteSend(@"语音发送中止：数据为空");
        return NO;
    }
    double seconds = 0;
    @try {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        seconds = CMTimeGetSeconds(asset.duration);
    } @catch (NSException *exception) {
        seconds = 0;
    }
    if (!isfinite(seconds) || seconds <= 0) {
        seconds = 1.0;
    }
    NSData *silk = ABSilkForVoice(path);
    if (silk.length > 0) {
        data = silk;
        ABNoteSend(@"语音已转 SILK：%@（%lu bytes）", path.lastPathComponent, (unsigned long)silk.length);
    } else {
        ABNoteSend(@"语音 SILK 转码失败，按原始数据发送：%@", path.lastPathComponent);
    }
    id wrap = ABMakeMessageWrap(34, toUser, @"");
    if (!wrap) {
        ABNoteSend(@"语音消息包装创建失败，回退文件消息");
        return ABSendFileAtPath(toUser, path);
    }
    // 校准自原生语音：voiceformat=4，且 content 必须是 <voicemsg .../> XML
    unsigned int voiceSeconds = (unsigned int)ceil(seconds);
    unsigned int voiceMS = voiceSeconds * 1000;
    Class appUtilCls = NSClassFromString(@"CAppUtil");
    SEL calcTimeSel = NSSelectorFromString(@"calcVoiceTime:VoiceFormat:");
    if (appUtilCls && [appUtilCls respondsToSelector:calcTimeSel] && data.length > 0) {
        @try {
            unsigned int calc = ((unsigned int (*)(id, SEL, id, unsigned int))objc_msgSend)(appUtilCls, calcTimeSel, data, 4);
            if (calc > 0) voiceMS = calc;
        } @catch (NSException *exception) {}
    }
    NSString *voiceXML = [NSString stringWithFormat:@"<msg><voicemsg voicelength=\"%u\" voiceformat=\"4\" forwardflag=\"0\" /></msg>", voiceMS];
    // 语音真实字段存在 CMessageWrap.m_extendInfoWithMsgType（CExtendInfoOfVoiceMsg）
    Class voiceExtCls = NSClassFromString(@"CExtendInfoOfVoiceMsg");
    if (voiceExtCls) {
        @try {
            id ext = [[voiceExtCls alloc] init];
            ABSetUInt(ext, @"setM_uiVoiceFormat:", 4);
            ABSetUInt(ext, @"setM_uiVoiceTime:", voiceSeconds);
            ABSetUInt(ext, @"setM_uiVoiceEndFlag:", 1);
            ABSetUInt(ext, @"setM_uiVoiceCancelFlag:", 0);
            ABSetObject(ext, @"setM_dtVoice:", data);
            [wrap setValue:ext forKey:@"m_extendInfoWithMsgType"];
            ABNoteSend(@"语音 extendInfo 已写入（fmt=%u，time=%u）", ABGetUInt(ext, @"m_uiVoiceFormat"), ABGetUInt(ext, @"m_uiVoiceTime"));
        } @catch (NSException *exception) {
            ABNoteSend(@"语音 extendInfo 写入异常：%@", exception.reason);
        }
    }
    ABSetObject(wrap, @"setM_dtVoice:", data);
    ABSetUInt(wrap, @"setM_uiVoiceTime:", voiceSeconds);
    ABSetUInt(wrap, @"setM_uiVoiceFormat:", 4);
    ABSetUInt(wrap, @"setM_uiVoiceEndFlag:", 1);
    ABSetUInt(wrap, @"setM_uiVoiceCancelFlag:", 0);
    ABSetObject(wrap, @"setM_nsContent:", voiceXML);
    ABNoteSend(@"语音消息已按原生格式构造（fmt=4，voicelength=%u）", voiceMS);
    id msgMgr = ABService(@"CMessageMgr");
    // 原生发送顺序：AudioSender prepareSend → addMessageToDB → AddMsg
    id audioSender = ABService(@"AudioSender");
    if (audioSender) {
        SEL prepSel2 = NSSelectorFromString(@"prepareSend:");
        if ([audioSender respondsToSelector:prepSel2]) {
            @try {
                BOOL prep = ((BOOL (*)(id, SEL, id))objc_msgSend)(audioSender, prepSel2, wrap);
                ABNoteSend(@"语音 prepareSend 返回 %d", (int)prep);
            } @catch (NSException *exception) {
                ABNoteSend(@"语音 prepareSend 异常：%@", exception.reason);
            }
        }
        SEL dbSel2 = NSSelectorFromString(@"addMessageToDB:");
        if ([audioSender respondsToSelector:dbSel2]) {
            @try {
                BOOL dbOK = ((BOOL (*)(id, SEL, id))objc_msgSend)(audioSender, dbSel2, wrap);
                ABNoteSend(@"语音 addMessageToDB 返回 %d", (int)dbOK);
            } @catch (NSException *exception) {
                ABNoteSend(@"语音 addMessageToDB 异常：%@", exception.reason);
            }
        }
    }
    BOOL added = NO;
    // 语音消息优先走微信原生的 AddRecordMsg:MsgWrap:（同时入库并挂上语音上传队列）
    SEL addRecordSel = NSSelectorFromString(@"AddRecordMsg:MsgWrap:");
    if (msgMgr && [msgMgr respondsToSelector:addRecordSel]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(msgMgr, addRecordSel, toUser, wrap);
        added = ABGetUInt(wrap, @"m_uiMesLocalID") > 0;
        ABNoteSend(@"语音已由 AddRecordMsg 创建（localID=%u）", ABGetUInt(wrap, @"m_uiMesLocalID"));
    }
    if (!added) {
        added = ABAddMessageWrapToSend(wrap, toUser);
        ABNoteSend(@"语音已由 AddMsg 创建（localID=%u）", ABGetUInt(wrap, @"m_uiMesLocalID"));
    }
    // 上传管理器按 localID 去微信私有目录取语音文件，把所有候选路径都写一遍
    unsigned int localID = ABGetUInt(wrap, @"m_uiMesLocalID");
    NSString *voiceSelfId = ABCurrentWxid() ?: @"";
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    Class utilCls = NSClassFromString(@"CUtility");
    NSMutableArray<NSString *> *voicePaths = [NSMutableArray array];
    if (utilCls && localID > 0 && docPath.length > 0) {
        NSArray<NSString *> *pathSels = @[ @"GetPathOfOriAudioMesForSend:LocalID:DocPath:",
                                           @"GetPathOfMesAudio:LocalID:DocPath:" ];
        for (NSString *name in pathSels) {
            SEL sel = NSSelectorFromString(name);
            if (![utilCls respondsToSelector:sel]) continue;
            @try {
                NSString *p = ((id (*)(id, SEL, id, unsigned int, id))objc_msgSend)(utilCls, sel, voiceSelfId, localID, docPath);
                if (p.length > 0) [voicePaths addObject:p];
            } @catch (NSException *exception) {}
        }
        SEL dirSel = NSSelectorFromString(@"GetPathOfMesAudioDir:");
        if ([utilCls respondsToSelector:dirSel]) {
            @try {
                NSString *dir = ((id (*)(id, SEL, id))objc_msgSend)(utilCls, dirSel, docPath);
                if (dir.length > 0) {
                    [voicePaths addObject:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%u.silk", localID]]];
                }
            } @catch (NSException *exception) {}
        }
    }
    NSMutableArray<NSString *> *written = [NSMutableArray array];
    for (NSString *p in voicePaths) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
        if ([data writeToFile:p atomically:YES]) [written addObject:p.lastPathComponent];
    }
    if (written.count > 0) {
        ABNoteSend(@"语音已落位：%@（localID=%u）", [written componentsJoinedByString:@" / "], localID);
    } else {
        ABNoteSend(@"语音落位失败（localID=%u）", localID);
    }
    id mgr = nil;
    // m_oRecordUploadCDNMgr 是成员变量，没有 getter，只能走 KVC / ivar 直取
    if (msgMgr) {
        @try {
            mgr = [msgMgr valueForKey:@"m_oRecordUploadCDNMgr"];
        } @catch (NSException *exception) {
            mgr = nil;
        }
        if (!mgr) {
            mgr = ABGetObject(msgMgr, @"recordUploadCDNMgr");
        }
        if (!mgr) {
            mgr = ABGetObject(msgMgr, @"getRecordUploadCDNMgr");
        }
    }
    if (!mgr) {
        mgr = ABService(@"RecordUploadCDNMgr");
    }
    // AudioSender 才是原生发送路径：先按它自己的文件名落盘，再按分片登记上传任务
    BOOL nativePartAdded = NO;
    id audioSnd = ABService(@"AudioSender");
    if (audioSnd && localID > 0) {
        SEL realNameSel = NSSelectorFromString(@"getAudioFileName:");
        if ([audioSnd respondsToSelector:realNameSel]) {
            @try {
                NSString *realPath = ((id (*)(id, SEL, unsigned int))objc_msgSend)(audioSnd, realNameSel, localID);
                if (realPath.length > 0 && [realPath isKindOfClass:[NSString class]]) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:[realPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
                    [data writeToFile:realPath atomically:YES];
                    ABNoteSend(@"语音已写入原生文件名：%@", realPath.lastPathComponent);
                }
            } @catch (NSException *exception) {
                ABNoteSend(@"getAudioFileName 异常：%@", exception.reason);
            }
        }
        id uploader = ABService(@"UploadVoiceCDNMgr");
        if (!uploader) {
            @try {
                uploader = [audioSnd valueForKey:@"m_upload"];
            } @catch (NSException *exception) {
                uploader = nil;
            }
        }
        Class uploaderCls = object_getClass(uploader);
        BOOL uploaderIsClass = class_isMetaClass(uploaderCls);
        SEL addPartSel = NSSelectorFromString(@"AddNewPart:LocalID:n64SvrID:Offset:Len:VoiceTime:CreateTime:EndFlag:CancelFlag:VoiceFormat:ForwardFlag:msgSource:");
        BOOL canAddPart = (uploader && !uploaderIsClass && [uploader respondsToSelector:addPartSel]);
        ABNoteSend(@"语音上传器=%@（类对象=%d，可AddNewPart=%d）",
                   uploader ? NSStringFromClass([uploader class]) : @"nil", (int)uploaderIsClass, (int)canAddPart);
        if (uploader && !uploaderIsClass && !canAddPart) {
            NSMutableArray<NSString *> *hits = [NSMutableArray array];
            Class c = [uploader class];
            for (int depth = 0; c && depth < 4; depth++) {
                unsigned int count = 0;
                Method *methods = class_copyMethodList(c, &count);
                for (unsigned int i = 0; i < count && hits.count < 12; i++) {
                    NSString *name = NSStringFromSelector(method_getName(methods[i]));
                    if ([name rangeOfString:@"Part"].location != NSNotFound ||
                        [name rangeOfString:@"Send"].location != NSNotFound ||
                        [name rangeOfString:@"Voice"].location != NSNotFound) {
                        [hits addObject:name];
                    }
                }
                if (methods) free(methods);
                c = class_getSuperclass(c);
            }
            ABNoteSend(@"上传器方法：%@", [hits componentsJoinedByString:@" | "]);
        }
        if (canAddPart) {
            @try {
                unsigned int now = (unsigned int)[[NSDate date] timeIntervalSince1970];
                ((void (*)(id, SEL, id, unsigned int, long long, unsigned int, unsigned int, unsigned int, unsigned int, unsigned int, unsigned int, unsigned int, unsigned int, id))objc_msgSend)(
                    uploader, addPartSel, wrap, localID, 0LL, 0, (unsigned int)data.length,
                    voiceSeconds * 1000, now, 1, 0, 4, 0, @"");
                nativePartAdded = YES;
                ABNoteSend(@"语音已登记上传分片（AddNewPart：%lu bytes）", (unsigned long)data.length);
                SEL startSendSel = NSSelectorFromString(@"startSend");
                if ([uploader respondsToSelector:startSendSel]) {
                    ((void (*)(id, SEL))objc_msgSend)(uploader, startSendSel);
                    ABNoteSend(@"语音已触发 startSend");
                }
            } @catch (NSException *exception) {
                ABNoteSend(@"AddNewPart/startSend 异常：%@", exception.reason);
            }
        }
    }
    SEL uploadSel = NSSelectorFromString(@"StartUploadRecordMsg:");
    if (!nativePartAdded && added && mgr && [mgr respondsToSelector:uploadSel]) {
        // 让微信把语音消息与本地文件/数据库记录对齐后再上传
        SEL saveSel = NSSelectorFromString(@"SaveMesVoice:MsgWrap:");
        if ([msgMgr respondsToSelector:saveSel]) {
            @try {
                ((BOOL (*)(id, SEL, id, id))objc_msgSend)(msgMgr, saveSel, toUser, wrap);
            } @catch (NSException *exception) {}
        }
        ((void (*)(id, SEL, id))objc_msgSend)(mgr, uploadSel, wrap);
        ABNoteSend(@"语音已提交上传：%@（%.1fs，%lu bytes）", path.lastPathComponent, seconds, (unsigned long)data.length);
        // 显式驱动队列（StartUploadRecordMsg 只是入队/标记）
        SEL checkSel = NSSelectorFromString(@"CheckCDNUploadMsgQueue");
        if ([mgr respondsToSelector:checkSel]) {
            ((void (*)(id, SEL))objc_msgSend)(mgr, checkSel);
            ABNoteSend(@"语音已推动上传队列（CheckCDNUploadMsgQueue）");
        }
        SEL uploadDataSel = NSSelectorFromString(@"UploadRecordData");
        if ([mgr respondsToSelector:uploadDataSel]) {
            ((void (*)(id, SEL))objc_msgSend)(mgr, uploadDataSel);
            ABNoteSend(@"语音已推动上传数据（UploadRecordData）");
        }
        return YES;
    }
    ABNoteSend(@"语音上传链路不可用（added=%@，mgr=%@）", added ? @"1" : @"0", mgr ? @"1" : @"0");
    return ABSendFileAtPath(toUser, path);
}

// 表情（GIF/动图）：CEmoticonMgr 生成表情消息 → CEmoticonUploadMgr 上传
static BOOL ABSendStickerAtPath(NSString *toUser, NSString *path, NSData *data) {
    if (toUser.length == 0 || data.length == 0) {
        ABNoteSend(@"表情发送中止：数据为空");
        return NO;
    }
    Class emoticonCls = NSClassFromString(@"CEmoticonMgr");
    SEL msgSel = NSSelectorFromString(@"emoticonMsgForImageData:errorMsg:");
    if (!emoticonCls || ![emoticonCls respondsToSelector:msgSel]) {
        ABNoteSend(@"CEmoticonMgr 表情入口不可用，回退图片消息");
        return ABSendImageAtPath(toUser, path, data);
    }
    // 先把 GIF 作为自定义表情入库，拿到带 MD5 的表情对象，再生成短 XML 的表情消息
    id emoticonOwner = ABService(@"CEmoticonMgr");
    @try {
        if (!emoticonOwner) { emoticonOwner = [[emoticonCls alloc] init]; }
    } @catch (NSException *e) { emoticonOwner = nil; }
    id addWrap = nil;
    SEL addCustomSel = NSSelectorFromString(@"AddCustomEmoticonWithData:addEmoticonWrap:isSilently:");
    if (emoticonOwner && [emoticonOwner respondsToSelector:addCustomSel]) {
        @try {
            addWrap = ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(emoticonOwner, addCustomSel, data, nil, YES);
        } @catch (NSException *e) {
            ABNoteSend(@"自定义表情入库异常：%@", e.reason);
        }
    }
    NSString *errMsg = nil;
    id wrap = nil;
    SEL genSel = NSSelectorFromString(@"genEmoticonMsgForEmoticonWrap:imageData:");
    if (addWrap && [emoticonCls respondsToSelector:genSel]) {
        @try {
            wrap = ((id (*)(id, SEL, id, id))objc_msgSend)(emoticonCls, genSel, addWrap, data);
        } @catch (NSException *e) { wrap = nil; }
    }
    if (!wrap) {
        wrap = ((id (*)(id, SEL, id, NSString **))objc_msgSend)(emoticonCls, msgSel, data, &errMsg);
    }
    if (!wrap) {
        ABNoteSend(@"表情消息生成失败：%@，回退图片消息", errMsg ?: @"未知原因");
        return ABSendImageAtPath(toUser, path, data);
    }
    NSString *selfId = ABCurrentWxid();
    if (selfId.length > 0) {
        ABSetObject(wrap, @"setM_nsFromUsr:", selfId);
    }
    ABSetObject(wrap, @"setM_nsToUsr:", toUser);
    ABSetUInt(wrap, @"setM_uiCreateTime:", (unsigned int)[[NSDate date] timeIntervalSince1970]);
    ABSetUInt(wrap, @"setM_uiStatus:", 1);

    // 优先：与图片同路径，直接交给 CMessageMgr 入库（微信内部建消息+排队上传）
    id cm = ABService(@"CMessageMgr");
    if (!cm) {
        Class cmCls = NSClassFromString(@"CMessageMgr");
        if ([cmCls respondsToSelector:NSSelectorFromString(@"sharedInstance")]) {
            cm = ((id (*)(id, SEL))objc_msgSend)(cmCls, NSSelectorFromString(@"sharedInstance"));
        }
    }
    SEL addSel = NSSelectorFromString(@"AddMsg:MsgWrap:");
    if (cm && [cm respondsToSelector:addSel]) {
        @try {
            NSString *content = [wrap valueForKey:@"m_nsContent"];
            NSString *src = [wrap valueForKey:@"m_nsMsgSource"];
            ABNoteSend(@"表情 wrap 诊断：contentLen=%lu addWrap=%@ content=%.160@", (unsigned long)content.length, addWrap ? @"1" : @"0", content ?: @"");
            ABNoteSend(@"表情 wrap 副诊断：srcLen=%lu src=%.120@ type=%u", (unsigned long)src.length, src ?: @"", (unsigned)ABGetUInt(wrap, @"m_uiMessageType"));
            ((void (*)(id, SEL, id, id))objc_msgSend)(cm, addSel, toUser, wrap);
            ABNoteSend(@"表情消息已入库：%@（%lu bytes）", path.lastPathComponent, (unsigned long)data.length);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SEL lastSel = NSSelectorFromString(@"GetLastMsgToUsr:");
                if ([cm respondsToSelector:lastSel]) {
                    id last = ((id (*)(id, SEL, id))objc_msgSend)(cm, lastSel, toUser);
                    unsigned lid = last ? (unsigned)ABGetUInt(last, @"m_uiMesLocalID") : 0;
                    unsigned mt = last ? (unsigned)ABGetUInt(last, @"m_uiMessageType") : 0;
                    ABNoteSend(@"表情复核：localID=%u type=%u", lid, mt);
                }
            });
            return YES;
        } @catch (NSException *e) {
            ABNoteSend(@"表情入库异常：%@", e.reason);
        }
    }
    BOOL added = ABAddMessageWrapToSend(wrap, toUser);
    id msgMgr = ABService(@"CMessageMgr");
    id uploadMgr = ABGetObject(msgMgr, @"m_oEmoticonUploadMgr");
    SEL startSel = NSSelectorFromString(@"StartUpload:");
    SEL insertSel = NSSelectorFromString(@"InsertMessageToUploadQueue:");
    SEL checkSel = NSSelectorFromString(@"CheckUpload");
    if (added && uploadMgr && [uploadMgr respondsToSelector:startSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(uploadMgr, startSel, wrap);
        ABNoteSend(@"表情已提交上传：%@（%lu bytes）", path.lastPathComponent, (unsigned long)data.length);
        return YES;
    }
    if (added && uploadMgr && [uploadMgr respondsToSelector:insertSel]) {
        BOOL inserted = ((BOOL (*)(id, SEL, id))objc_msgSend)(uploadMgr, insertSel, wrap);
        if (inserted && [uploadMgr respondsToSelector:checkSel]) {
            ((void (*)(id, SEL))objc_msgSend)(uploadMgr, checkSel);
        }
        ABNoteSend(@"表情已加入上传队列：%@（inserted=%@）", path.lastPathComponent, inserted ? @"1" : @"0");
        return inserted;
    }
    ABNoteSend(@"表情上传管理器不可用，回退图片消息");
    return ABSendImageAtPath(toUser, path, data);
}

static UIImage *ABVideoThumbnail(NSString *path, double *outDuration) {
    UIImage *thumb = nil;
    @try {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        double seconds = CMTimeGetSeconds(asset.duration);
        if (outDuration) {
            *outDuration = isfinite(seconds) ? seconds : 0;
        }
        AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
        gen.appliesPreferredTrackTransform = YES;
        gen.maximumSize = CGSizeMake(640, 640);
        CGImageRef imageRef = [gen copyCGImageAtTime:CMTimeMakeWithSeconds(0.1, 600) actualTime:NULL error:NULL];
        if (imageRef) {
            thumb = [UIImage imageWithCGImage:imageRef];
            CGImageRelease(imageRef);
        }
    } @catch (NSException *exception) {
        if (outDuration) {
            *outDuration = 0;
        }
    }
    return thumb;
}

// 视频：CaptureVideoInfo + CExtendInfoOfVideo 生成原生视频消息 → AddMsg → StartUploadVideo
static NSString *ABPlaceVideoForWrap(id wrap, NSString *selfId, NSString *videoPath, NSData *thumbData) {
    Class wrapCls = NSClassFromString(@"CMessageWrap");
    SEL rawPathSel = NSSelectorFromString(@"GetPathOfRawVideoV2:LocalID:DocPath:");
    unsigned int localID = ABGetUInt(wrap, @"m_uiMesLocalID");
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!wrapCls || ![wrapCls respondsToSelector:rawPathSel] || localID == 0 || docPath.length == 0) {
        return nil;
    }
    NSString *videoDst = nil;
    @try {
        videoDst = ((id (*)(id, SEL, id, unsigned int, id))objc_msgSend)(wrapCls, rawPathSel, selfId ?: @"", localID, docPath);
    } @catch (NSException *exception) {
        return nil;
    }
    if (videoDst.length == 0) {
        return nil;
    }
    if (![videoDst isEqualToString:videoPath]) {
        NSString *dir = [videoDst stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        [[NSFileManager defaultManager] removeItemAtPath:videoDst error:NULL];
        [[NSFileManager defaultManager] copyItemAtPath:videoPath toPath:videoDst error:NULL];
    }
    SEL thumbPathSel = NSSelectorFromString(@"getPathOfVideoMsgImgThumb:");
    NSString *thumbDst = nil;
    if ([wrapCls respondsToSelector:thumbPathSel]) {
        @try {
            thumbDst = ((id (*)(id, SEL, id))objc_msgSend)(wrapCls, thumbPathSel, wrap);
        } @catch (NSException *exception) {
            thumbDst = nil;
        }
    }
    if (thumbDst.length == 0) {
        thumbDst = [[videoDst stringByDeletingPathExtension] stringByAppendingString:@".jpg"];
    }
    if (thumbData.length > 0 && thumbDst.length > 0) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[thumbDst stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
        [thumbData writeToFile:thumbDst atomically:YES];
    }
    return videoDst;
}

static BOOL ABSendVideoAtPath(NSString *toUser, NSString *path, NSData *data) {
    if (toUser.length == 0 || path.length == 0) {
        ABNoteSend(@"视频发送中止：文件为空");
        return NO;
    }
    double duration = 0;
    UIImage *thumb = ABVideoThumbnail(path, &duration);
    if (!thumb) {
        ABNoteSend(@"视频缩略图生成失败，回退文件消息");
        return ABSendFileAtPath(toUser, path);
    }
    NSData *thumbData = UIImageJPEGRepresentation(thumb, 0.84);
    NSMutableString *thumbPath = [path mutableCopy];
    [thumbPath appendString:@"_thumb.jpg"];
    if (thumbData.length > 0) {
        [thumbData writeToFile:thumbPath atomically:YES];
    }

    Class infoCls = NSClassFromString(@"CaptureVideoInfo");
    SEL infoSel = NSSelectorFromString(@"genVideoInfoWithVideoUrl:thumb:");
    id info = nil;
    @try {
        if (infoCls && [infoCls respondsToSelector:infoSel]) {
            info = ((id (*)(id, SEL, id, id))objc_msgSend)(infoCls, infoSel, [NSURL fileURLWithPath:path], thumb);
        }
    } @catch (NSException *exception) {
        info = nil;
    }
    if (!info) {
        ABNoteSend(@"CaptureVideoInfo 生成失败，回退文件消息");
        return ABSendFileAtPath(toUser, path);
    }
    ABSetUInt(info, @"setVideo_time:", (unsigned int)(duration > 0 ? duration : 1));
    ABSetUInt(info, @"setVideo_size:", (unsigned int)data.length);
    if (thumbData.length > 0) {
        ABSetUInt(info, @"setThumb_size:", (unsigned int)thumbData.length);
    }
    ABSetUInt(info, @"setVideo_width:", (unsigned int)thumb.size.width);
    ABSetUInt(info, @"setVideo_height:", (unsigned int)thumb.size.height);

    NSString *selfId = ABCurrentWxid() ?: @"";
    id msgMgr = ABService(@"CMessageMgr");

    // 路线一：微信自身的建视频消息入口（内部负责建 wrap、入库与上传）
    SEL addVideoSel = NSSelectorFromString(@"AddVideoMsg:ToUsr:VideoInfo:");
    id wrap = nil;
    if (msgMgr && [msgMgr respondsToSelector:addVideoSel]) {
        @try {
            wrap = ((id (*)(id, SEL, id, id, id))objc_msgSend)(msgMgr, addVideoSel, selfId, toUser, info);
        } @catch (NSException *exception) {
            wrap = nil;
        }
    }
    if (wrap) {
        NSString *dst = ABPlaceVideoForWrap(wrap, selfId, path, thumbData);
        ABNoteSend(@"视频已由微信创建并落位：%@（localID=%u，%.1fs）", dst.lastPathComponent ?: @"?", ABGetUInt(wrap, @"m_uiMesLocalID"), duration);
        return YES;
    }

    // 路线二：手工建 wrap + AddMsg + StartUploadVideo
    Class videoCls = NSClassFromString(@"CExtendInfoOfVideo");
    SEL genSel = NSSelectorFromString(@"GenVideoMsg:ToUsr:MsgType:VideoInfo:");
    @try {
        if (videoCls && [videoCls respondsToSelector:genSel]) {
            wrap = ((id (*)(id, SEL, id, id, unsigned int, id))objc_msgSend)(videoCls, genSel, selfId, toUser, (unsigned int)43, info);
        }
    } @catch (NSException *exception) {
        wrap = nil;
    }
    if (!wrap) {
        ABNoteSend(@"原生视频消息生成失败，回退文件消息");
        return ABSendFileAtPath(toUser, path);
    }
    if (selfId.length > 0) {
        ABSetObject(wrap, @"setM_nsFromUsr:", selfId);
    }
    ABSetObject(wrap, @"setM_nsToUsr:", toUser);
    BOOL added = ABAddMessageWrapToSend(wrap, toUser);
    NSString *videoDst = ABPlaceVideoForWrap(wrap, selfId, path, thumbData);
    if (videoDst.length > 0) {
        ABNoteSend(@"视频已落位微信私有路径：%@（localID=%u）", videoDst.lastPathComponent, ABGetUInt(wrap, @"m_uiMesLocalID"));
    } else {
        ABNoteSend(@"未能推导视频私有路径（localID=%u）", ABGetUInt(wrap, @"m_uiMesLocalID"));
    }
    SEL uploadSel = NSSelectorFromString(@"StartUploadVideo:MsgWrap:");
    if (added && msgMgr && [msgMgr respondsToSelector:uploadSel]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(msgMgr, uploadSel, toUser, wrap);
        ABNoteSend(@"视频已提交上传：%@（%.1fs，%lu bytes）", path.lastPathComponent, duration, (unsigned long)data.length);
        return YES;
    }
    ABNoteSend(@"视频上传入口不可用，回退文件消息");
    return ABSendFileAtPath(toUser, path);
}

// 文件/视频兜底：genFileAppMsgWithFileName（微信文件消息）
static BOOL ABSendFileAtPath(NSString *toUser, NSString *path) {
    if (toUser.length == 0 || path.length == 0) {
        return NO;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    Class wrapCls = NSClassFromString(@"CMessageWrap");
    SEL genSel = NSSelectorFromString(@"genFileAppMsgWithFileName:filePath:fileData:");
    if (!wrapCls || ![wrapCls respondsToSelector:genSel]) {
        return NO;
    }
    id wrap = ((id (*)(id, SEL, id, id, id))objc_msgSend)(wrapCls, genSel, path.lastPathComponent, path, data ?: [NSData data]);
    if (!wrap) {
        return NO;
    }
    NSString *selfId = ABCurrentWxid();
    if (selfId.length > 0) {
        ABSetObject(wrap, @"setM_nsFromUsr:", selfId);
    }
    ABSetObject(wrap, @"setM_nsToUsr:", toUser);
    BOOL ok = ABAddMessageWrapToSend(wrap, toUser);
    if (ok) {
        id msgMgr = ABService(@"CMessageMgr");
        SEL uploadSel = NSSelectorFromString(@"StartUploadAppMsg:MsgWrap:Scene:");
        if (msgMgr && [msgMgr respondsToSelector:uploadSel]) {
            ((void (*)(id, SEL, id, id, NSInteger))objc_msgSend)(msgMgr, uploadSel, toUser, wrap, 0);
        } else {
            ABNoteSend(@"App 消息上传入口不可用");
        }
    }
    TFLog(@"[Forward] 发送文件 -> %@ : %@ (%@)", toUser, path.lastPathComponent, ok ? @"已提交" : @"失败");
    ABNoteSend(@"文件消息%@：%@", ok ? @"已提交" : @"提交失败", path.lastPathComponent);
    return ok;
}

// 下载远端媒体到本地缓存后再发送
static void ABDownloadAndSendMedia(NSString *toUser, NSInteger msgType, NSString *urlString) {
    // 中文/空格路径必须先转义，否则 NSURL 解析失败会导致请求被静默丢弃
    NSString *encoded = [urlString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:encoded ?: urlString];
    if (!url) {
        TFLog(@"[Forward] 非法媒体地址：%@", urlString);
        ABNoteSend(@"媒体地址无法解析：%@", urlString);
        return;
    }
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
                                                             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data.length == 0 || error) {
            TFLog(@"[Forward] 媒体下载失败：%@ (%@)", urlString, error.localizedDescription);
            ABNoteSend(@"媒体下载失败：%@ (%@)", urlString, error.localizedDescription ?: @"未知错误");
            return;
        }
        NSString *ext = url.pathExtension.lowercaseString;
        if (ext.length == 0) {
            ext = (msgType == 43) ? @"mp4" : @"jpg";
        }
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TweakfixMedia"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *name = [NSString stringWithFormat:@"%lld_%ld.%@",
                                                    (long long)[[NSDate date] timeIntervalSince1970],
                                                    (long)msgType,
                                                    ext];
        NSString *path = [dir stringByAppendingPathComponent:name];
        BOOL written = [data writeToFile:path atomically:YES];
        if (!written) {
            TFLog(@"[Forward] 媒体写入失败：%@", path);
            ABNoteSend(@"媒体写入失败：%@", path);
            return;
        }
        TFLog(@"[Forward] 媒体已缓存：%@ (%lu bytes)", path, (unsigned long)data.length);
        ABNoteSend(@"媒体已缓存：%@（%lu bytes），准备发送", name, (unsigned long)data.length);
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL isGif = [path.pathExtension.lowercaseString isEqualToString:@"gif"];
            if (msgType == 47 || isGif) {
                // 按后缀判断：GIF 动图走表情链路，静态图（jpg/png/webp）走图片链路
                ABSendStickerAtPath(toUser, path, data);
            } else if (msgType == 3) {
                ABSendImageAtPath(toUser, path, data);
            } else if (msgType == 34) {
                ABSendVoiceAtPath(toUser, path, data);
            } else if (msgType == 43) {
                ABSendVideoAtPath(toUser, path, data);
            } else {
                ABSendFileAtPath(toUser, path);
            }
        });
    }];
    [task resume];
}

#pragma mark - 收到消息后转发

// 群消息里取真实发送人（尝试解析 msgSource 中的 fromusername）
static NSString *ABExtractGroupSender(id wrap, NSString *fallback) {
    NSString *source = ABGetObject(wrap, @"m_nsMsgSource");
    if (![source isKindOfClass:[NSString class]] || source.length == 0) {
        return fallback;
    }
    NSArray *patterns = @[
        @"fromusername=\"([^\"]+)\"",
        @"<fromusername>([^<]+)</fromusername>",
        @"username=\"([^\"]+)\""
    ];
    for (NSString *pattern in patterns) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
        NSTextCheckingResult *result = [regex firstMatchInString:source options:0 range:NSMakeRange(0, source.length)];
        if (result && result.numberOfRanges > 1) {
            NSString *value = [source substringWithRange:[result rangeAtIndex:1]];
            if (value.length > 0 && IsGroupChatName(value) == NO) {
                return value;
            }
        }
    }
    return fallback;
}

// 联系人 / 群聊显示名（备注 > 昵称 > 原始 ID）
static NSString *ABDisplayNameForUsr(NSString *usr) {
    if (![usr isKindOfClass:[NSString class]] || usr.length == 0) {
        return @"";
    }
    @try {
        id mgr = ABService(@"CContactMgr");
        SEL sel = NSSelectorFromString(@"getContactByName:");
        if (mgr && [mgr respondsToSelector:sel]) {
            id contact = ((id (*)(id, SEL, id))objc_msgSend)(mgr, sel, usr);
            if (contact) {
                for (NSString *key in @[ @"m_nsRemark", @"m_nsNickName", @"m_nsBrandName" ]) {
                    NSString *name = ABGetObject(contact, key);
                    if ([name isKindOfClass:[NSString class]] && name.length > 0) {
                        return name;
                    }
                }
            }
        }
    } @catch (NSException *exception) {}
    return usr;
}

static void ABForwardPostJSON(NSDictionary *payload) {
    NSString *webhook = ForwardWebhook();
    if (webhook.length == 0) {
        return;
    }
    NSURL *url = [NSURL URLWithString:webhook];
    if (!url) {
        TFLog(@"[Forward] Webhook 地址非法：%@", webhook);
        return;
    }
    NSError *jsonError = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (!body) {
        TFLog(@"[Forward] 组装 JSON 失败：%@", jsonError.localizedDescription);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 15.0;
    [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"Tweakfix/1.0" forHTTPHeaderField:@"User-Agent"];
    request.HTTPBody = body;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error) {
            TFLog(@"[Forward] Webhook 推送失败(%ld)：%@", (long)status, error.localizedDescription);
        } else {
            TFLog(@"[Forward] Webhook 推送成功(%ld)：%@", (long)status, payload[@"chat_id"] ?: @"");
        }
    }];
    [task resume];
}

// 收到一条消息：判定私聊/群聊、白名单、组装字段并 POST
static void ABForwardHandleIncomingMessage(id wrap) {
    if (!wrap || !ForwardEnabled() || ForwardWebhook().length == 0) {
        return;
    }

    NSString *from = ABGetObject(wrap, @"m_nsFromUsr") ?: @"";
    NSString *to = ABGetObject(wrap, @"m_nsToUsr") ?: @"";
    NSString *realChat = ABGetObject(wrap, @"m_nsRealChatUsr") ?: @"";
    if (![from isKindOfClass:[NSString class]]) from = @"";
    if (![to isKindOfClass:[NSString class]]) to = @"";
    if (![realChat isKindOfClass:[NSString class]]) realChat = @"";

    NSString *selfId = ABCurrentWxid();
    if (from.length > 0 && selfId.length > 0 && [from isEqualToString:selfId]) {
        return; // 自己发出的消息不转发，避免回环
    }

    BOOL isGroup = NO;
    NSString *chat = nil;
    NSString *sender = from;

    if (IsGroupChatName(realChat)) {
        isGroup = YES;
        chat = realChat;
        sender = ABExtractGroupSender(wrap, from);
    } else if (IsGroupChatName(from)) {
        isGroup = YES;
        chat = from;
        sender = ABExtractGroupSender(wrap, from);
    } else if (IsGroupChatName(to)) {
        isGroup = YES;
        chat = to;
        sender = from;
    } else {
        isGroup = NO;
        chat = from.length > 0 ? from : to;
        sender = from;
    }

    if (chat.length == 0) {
        return;
    }

    if (isGroup) {
        if (![ForwardGroupWhitelist() containsObject:chat]) {
            return; // 未勾选的群不转发
        }
    } else if (!ForwardPrivateEnabled()) {
        return;
    }

    NSInteger typeCode = (NSInteger)ABGetUInt(wrap, @"m_uiMessageType");
    NSString *content = ABGetObject(wrap, @"m_nsContent") ?: @"";
    if (![content isKindOfClass:[NSString class]]) {
        content = [content description] ?: @"";
    }
    // 系统提示类消息不转发，避免刷屏
    if (typeCode == 10000 || typeCode == 10002) {
        return;
    }

    // 超出时间限制的消息直接丢弃（本地补发/离线堆积的老消息）
    NSInteger maxMinutes = ForwardMaxMinutes();
    if (maxMinutes > 0) {
        unsigned int createTime = ABGetUInt(wrap, @"m_uiCreateTime");
        if (createTime > 0) {
            NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - (NSTimeInterval)createTime;
            if (age > (NSTimeInterval)maxMinutes * 60) {
                TFLog(@"[Forward] 丢弃超时消息：%@（%ld 秒前）", chat, (long)age);
                return;
            }
        }
    }
    // 对齐 WeChatFerry 的 WxMsg 回调字段
    unsigned int msgId = ABGetUInt(wrap, @"m_uiMesLocalID");
    if (msgId == 0) {
        msgId = (unsigned int)ABGetUInt(wrap, @"m_uiMesSvrID");
    }
    BOOL isAt = NO;
    if (isGroup && selfId.length > 0) {
        NSString *src = ABGetObject(wrap, @"m_nsMsgSource");
        if ([src isKindOfClass:[NSString class]]) {
            NSString *atPattern = [NSString stringWithFormat:@"<atusername><!\\[CDATA\\[%@\\]\\]></atusername>", selfId];
            if ([src rangeOfString:atPattern].location != NSNotFound ||
                [src rangeOfString:[NSString stringWithFormat:@"<atusername>%@</atusername>", selfId]].location != NSNotFound) {
                isAt = YES;
            }
        }
    }
    NSString *userName = ABDisplayNameForUsr(sender);
    NSString *chatName = ABDisplayNameForUsr(chat);
    NSDictionary *payload = @{
        @"id"        : @(msgId),
        @"type"      : @(typeCode),
        @"ts"        : @((long long)[[NSDate date] timeIntervalSince1970]),
        @"chat_id"   : (isGroup ? chat : chat),
        @"chat_name" : chatName ?: @"",
        @"user_id"   : sender ?: @"",
        @"user_name" : userName ?: @"",
        @"content"   : content ?: @"",
        @"is_group"  : @(isGroup),
        @"is_self"   : @(NO),
        @"is_at"     : @(isAt)
    };
    TFLog(@"[Forward] 转发 %@ %@ -> %@", isGroup ? @"群聊" : @"私聊", chat, ABMsgTypeName(typeCode));
    ABForwardPostJSON(payload);
}

#pragma mark - 本地 HTTP 服务

static int gABListenFD = -1;
static NSInteger gABListenPort = 0;

// 枚举当前所有 IPv4 接口：name -> ip（同名接口取第一个）
static NSDictionary *ABCurrentIPv4Map(void) {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0) {
        return map;
    }
    for (struct ifaddrs *item = addrs; item != NULL; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        NSString *name = [NSString stringWithUTF8String:item->ifa_name] ?: @"";
        if (name.length == 0 || [name hasPrefix:@"lo"]) {
            continue;
        }
        struct sockaddr_in *addr = (struct sockaddr_in *)item->ifa_addr;
        NSString *ip = [NSString stringWithUTF8String:inet_ntoa(addr->sin_addr)] ?: @"";
        if (ip.length == 0 || [ip hasPrefix:@"127."] || [ip isEqualToString:@"0.0.0.0"]) {
            continue;
        }
        if (!map[name]) {
            map[name] = ip;
        }
    }
    freeifaddrs(addrs);
    return map;
}

static BOOL ABIsPrivateIPv4(NSString *ip) {
    NSArray<NSString *> *parts = [ip componentsSeparatedByString:@"."];
    if (parts.count != 4) {
        return NO;
    }
    NSInteger a = [parts[0] integerValue];
    NSInteger b = [parts[1] integerValue];
    if (a == 10) {
        return YES;
    }
    if (a == 192 && b == 168) {
        return YES;
    }
    if (a == 172 && b >= 16 && b <= 31) {
        return YES;
    }
    return NO;
}

static NSString *ABDetectWiFiIPAddress(void) {
    NSDictionary *map = ABCurrentIPv4Map();
    TFLog(@"[LocalAPI] 接口地址：%@", map);
    // iOS 的 Wi-Fi 通常是 en0；个人热点共享给其他设备时是 bridge100
    for (NSString *name in @[ @"en0", @"en1", @"bridge100" ]) {
        NSString *ip = map[name];
        if (ip.length > 0) {
            return ip;
        }
    }
    // 兜底：只接受私网地址，跳过蜂窝（pdp_ip）与隧道（utun），避免显示成蜂窝地址
    for (NSString *name in map) {
        if ([name hasPrefix:@"pdp_ip"] || [name hasPrefix:@"utun"] || [name hasPrefix:@"ipsec"]) {
            continue;
        }
        NSString *ip = map[name];
        if (ABIsPrivateIPv4(ip)) {
            return ip;
        }
    }
    return nil;
}

static NSString *ABWiFiIPAddress(void) {
    NSString *manual = LocalAPIIPManual();
    if (manual.length > 0) {
        return manual;
    }
    return ABDetectWiFiIPAddress();
}

static NSString *ABLocalAPIAddress(void) {
    NSString *ip = ABWiFiIPAddress();
    if (ip.length == 0) {
        return [NSString stringWithFormat:@"http://未连接Wi-Fi:%ld", (long)LocalAPIPort()];
    }
    return [NSString stringWithFormat:@"http://%@:%ld", ip, (long)LocalAPIPort()];
}

static void ABHTTPWriteJSON(int fd, int statusCode, NSDictionary *json) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:(json ?: @{}) options:0 error:NULL];
    NSString *head = [NSString stringWithFormat:
                      @"HTTP/1.1 %d %@\r\n"
                      @"Content-Type: application/json; charset=utf-8\r\n"
                      @"Content-Length: %lu\r\n"
                      @"Connection: close\r\n"
                      @"Access-Control-Allow-Origin: *\r\n"
                      @"Access-Control-Allow-Headers: *\r\n\r\n",
                      statusCode,
                      statusCode == 200 ? @"OK" : @"Bad Request",
                      (unsigned long)body.length];
    NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
    if (headData.length > 0) {
        write(fd, headData.bytes, headData.length);
    }
    if (body.length > 0) {
        write(fd, body.bytes, body.length);
    }
}

static NSInteger ABTypeCodeFromValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value integerValue];
    }
    NSString *text = [[value description] lowercaseString] ?: @"";
    if ([text isEqualToString:@"text"] || [text isEqualToString:@"1"]) return 1;
    if ([text isEqualToString:@"image"] || [text isEqualToString:@"photo"] || [text isEqualToString:@"3"]) return 3;
    if ([text isEqualToString:@"voice"] || [text isEqualToString:@"audio"] || [text isEqualToString:@"34"]) return 34;
    if ([text isEqualToString:@"video"] || [text isEqualToString:@"43"]) return 43;
    if ([text isEqualToString:@"link"] || [text isEqualToString:@"app"] || [text isEqualToString:@"49"]) return 49;
    return 1;
}

static NSString *ABFirstString(NSDictionary *body, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = body[key];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
        if ([value isKindOfClass:[NSNumber class]]) {
            return [value stringValue];
        }
    }
    return @"";
}

// 处理 /send：解析 to / type / content / url，线程安全地投递到主线程发送
static NSDictionary *ABHandleSendPayload(NSDictionary *body) {
    NSString *toUser = ABFirstString(body, @[ @"to", @"wxid", @"chatId", @"chat", @"toUser", @"userName" ]);
    NSString *content = ABFirstString(body, @[ @"content", @"text", @"message" ]);
    NSString *mediaURL = ABFirstString(body, @[ @"url", @"mediaUrl", @"media", @"imageUrl", @"videoUrl" ]);
    NSInteger typeCode = ABTypeCodeFromValue(body[@"type"] ?: body[@"msgType"] ?: @1);

    // 统一约定：图片/表情/视频/语音的地址也放在 content 里；未单独提供 url 时取 content
    if (mediaURL.length == 0 && ([content hasPrefix:@"http://"] || [content hasPrefix:@"https://"])) {
        mediaURL = content;
    }

    if (toUser.length == 0) {
        return @{ @"ok": @NO, @"error": @"missing to/wxid/chatId" };
    }

    // 图片/表情/视频/语音：先下载缓存再发送（异步）
    if ((typeCode == 3 || typeCode == 43 || typeCode == 34 || typeCode == 47) && mediaURL.length > 0) {
        if (![mediaURL hasPrefix:@"http://"] && ![mediaURL hasPrefix:@"https://"]) {
            return @{ @"ok": @NO, @"error": @"media url must start with http(s)" };
        }
        ABDownloadAndSendMedia(toUser, typeCode, mediaURL);
        return @{ @"ok": @YES, @"queued": @YES, @"to": toUser, @"type": ABMsgTypeName(typeCode) };
    }

    if (content.length == 0 && mediaURL.length == 0) {
        return @{ @"ok": @NO, @"error": @"missing content" };
    }

    NSString *text = content.length > 0 ? content : mediaURL;
    dispatch_async(dispatch_get_main_queue(), ^{
        ABSendTextMessage(toUser, text);
    });
    return @{ @"ok": @YES, @"to": toUser, @"type": @"text" };
}

static NSArray *ABVoiceLogTail(void) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *file = [dir stringByAppendingPathComponent:@"Tweakfix_voice.log"];
    NSString *text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:NULL];
    if (text.length == 0) return @[];
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableArray *tail = [NSMutableArray array];
    NSInteger start = MAX(0, (NSInteger)lines.count - 12);
    for (NSInteger i = start; i < (NSInteger)lines.count; i++) {
        NSString *l = lines[(NSUInteger)i];
        if (l.length > 0) [tail addObject:l];
    }
    return tail;
}

static void ABHTTPHandleClient(int clientFD) {
    struct timeval timeout = { 10, 0 };
    setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    NSMutableData *buffer = [NSMutableData data];
    NSData *headerSeparator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSInteger headerEnd = -1;
    char chunk[2048];

    while (buffer.length < 256 * 1024) {
        ssize_t got = recv(clientFD, chunk, sizeof(chunk), 0);
        if (got <= 0) {
            break;
        }
        [buffer appendBytes:chunk length:(NSUInteger)got];
        NSRange searchRange = NSMakeRange(0, buffer.length);
        NSRange found = [buffer rangeOfData:headerSeparator options:0 range:searchRange];
        if (found.location != NSNotFound) {
            headerEnd = (NSInteger)NSMaxRange(found);
            break;
        }
    }

    if (headerEnd <= 0) {
        ABHTTPWriteJSON(clientFD, 400, @{ @"ok": @NO, @"error": @"bad request" });
        close(clientFD);
        return;
    }

    NSString *headerText = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, (NSUInteger)headerEnd)]
                                                  encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSString *requestLine = lines.count > 0 ? lines[0] : @"";
    NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
    NSString *method = parts.count > 0 ? parts[0] : @"";
    NSString *rawPath = parts.count > 1 ? parts[1] : @"/";

    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        NSString *value = [[line substringFromIndex:NSMaxRange(colon)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (name.length > 0) headers[name] = value;
    }

    NSInteger contentLength = [headers[@"content-length"] integerValue];
    NSMutableData *bodyData = [[buffer subdataWithRange:NSMakeRange((NSUInteger)headerEnd, buffer.length - (NSUInteger)headerEnd)] mutableCopy];
    while ((NSInteger)bodyData.length < contentLength) {
        ssize_t got = recv(clientFD, chunk, sizeof(chunk), 0);
        if (got <= 0) break;
        [bodyData appendBytes:chunk length:(NSUInteger)got];
    }

    NSString *path = rawPath;
    NSString *query = @"";
    NSRange question = [rawPath rangeOfString:@"?"];
    if (question.location != NSNotFound) {
        path = [rawPath substringToIndex:question.location];
        query = [rawPath substringFromIndex:NSMaxRange(question)];
    }

    // 可选 Token 校验：设置后请求需带 ?token=xxx 或 X-Auth-Token / X-Token 头
    NSString *token = LocalAPIToken();
    if (token.length > 0) {
        NSString *provided = headers[@"x-auth-token"] ?: headers[@"x-token"] ?: @"";
        if (provided.length == 0) {
            for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
                if ([pair hasPrefix:@"token="]) {
                    provided = [pair substringFromIndex:6];
                }
            }
        }
        if (![provided isEqualToString:token]) {
            ABHTTPWriteJSON(clientFD, 403, @{ @"ok": @NO, @"error": @"invalid token" });
            close(clientFD);
            return;
        }
    }

    if ([path isEqualToString:@"/status"]) {
        ABHTTPWriteJSON(clientFD, 200, @{
            @"ok": @YES,
            @"version": kPluginVersion ?: @"",
            @"wxid": ABCurrentWxid() ?: @"",
            @"port": @(LocalAPIPort()),
            @"forward": @(ForwardEnabled() && ForwardWebhook().length > 0),
            @"privateForward": @(ForwardPrivateEnabled()),
            @"groups": @(ForwardGroupWhitelist().count),
            @"lastSend": gABLastSendDetail ?: @"",
            @"trace": gABSendTrace ?: @[],
            @"voiceLog": ABVoiceLogTail() ?: @[]
        });
        close(clientFD);
        return;
    }

    if (![path isEqualToString:@"/send"] && ![path isEqualToString:@"/api/send"]) {
        ABHTTPWriteJSON(clientFD, 404, @{ @"ok": @NO, @"error": @"not found" });
        close(clientFD);
        return;
    }

    if (![method isEqualToString:@"POST"]) {
        ABHTTPWriteJSON(clientFD, 405, @{ @"ok": @NO, @"error": @"use POST" });
        close(clientFD);
        return;
    }

    id json = nil;
    if (bodyData.length > 0) {
        json = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:NULL];
    }
    if (![json isKindOfClass:[NSDictionary class]]) {
        ABHTTPWriteJSON(clientFD, 400, @{ @"ok": @NO, @"error": @"body must be JSON object" });
        close(clientFD);
        return;
    }

    NSDictionary *result = ABHandleSendPayload((NSDictionary *)json);
    ABHTTPWriteJSON(clientFD, [result[@"ok"] boolValue] ? 200 : 400, result);
    close(clientFD);
}

static void ABHTTPStopServer(void) {
    if (gABListenFD >= 0) {
        close(gABListenFD);
        gABListenFD = -1;
        gABListenPort = 0;
        TFLog(@"[LocalAPI] 已停止");
    }
}

static BOOL ABHTTPStartServer(NSInteger port) {
    if (gABListenFD >= 0 && gABListenPort == port) {
        return YES;
    }
    ABHTTPStopServer();

    int listenFD = socket(AF_INET, SOCK_STREAM, 0);
    if (listenFD < 0) {
        TFLog(@"[LocalAPI] socket 创建失败：%s", strerror(errno));
        return NO;
    }
    int reuse = 1;
    setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((unsigned short)port);

    if (bind(listenFD, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        TFLog(@"[LocalAPI] 端口 %ld 绑定失败：%s", (long)port, strerror(errno));
        close(listenFD);
        return NO;
    }
    if (listen(listenFD, 16) != 0) {
        TFLog(@"[LocalAPI] listen 失败：%s", strerror(errno));
        close(listenFD);
        return NO;
    }

    gABListenFD = listenFD;
    gABListenPort = port;
    TFLog(@"[LocalAPI] 已启动 %@", ABLocalAPIAddress());

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (gABListenFD >= 0) {
            int clientFD = accept(gABListenFD, NULL, NULL);
            if (clientFD < 0) {
                if (errno == EINTR) continue;
                break;
            }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                @try {
                    ABHTTPHandleClient(clientFD);
                } @catch (NSException *exception) {
                    TFLog(@"[LocalAPI] 处理请求异常：%@", exception.reason);
                    close(clientFD);
                }
            });
        }
    });
    return YES;
}

static void ABHTTPRestartServerIfNeeded(void) {
    if (LocalAPIEnabled()) {
        ABHTTPStartServer(LocalAPIPort());
    } else {
        ABHTTPStopServer();
    }
}

static NSHashTable *g_hiddenURLLabels;

// 判断文本是否像网址/域名
static BOOL IsURLText(NSString *text) {
    if (text.length == 0 || [text containsString:@" "]) {
        return NO;
    }
    if ([text containsString:@"://"]) {
        return YES;
    }
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[a-zA-Z0-9][a-zA-Z0-9-]*(\\.[a-zA-Z0-9-]+)+([/:][^ ]*)?$"
                                                                           options:0
                                                                             error:NULL];
    return [regex numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] > 0;
}

// 递归扫描视图，隐藏/恢复形似网址的 UILabel
static void ScanAndApply(UIView *view, BOOL hide) {
    if (!view) {
        return;
    }
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        if (label.text.length && IsURLText(label.text)) {
            if (hide) {
                if (!label.hidden) {
                    label.hidden = YES;
                    if (![g_hiddenURLLabels containsObject:label]) {
                        [g_hiddenURLLabels addObject:label];
                        TFLog(@"[APIBlocker] hide browser URL label: %@", label.text);
                    }
                }
            } else {
                label.hidden = NO;
                [g_hiddenURLLabels removeObject:label];
            }
        }
        return;
    }
    for (UIView *sub in view.subviews) {
        ScanAndApply(sub, hide);
    }
}

// 只扫描导航栏子树，避免误伤页面内容
static void ScanNavBarsInView(UIView *view, BOOL hide) {
    if (!view) {
        return;
    }
    if ([view isKindOfClass:[UINavigationBar class]]) {
        ScanAndApply(view, hide);
        return;
    }
    for (UIView *sub in view.subviews) {
        ScanNavBarsInView(sub, hide);
    }
}

static void (*orig_UINavigationBarLayoutSubviews)(id, SEL);

static void APIBlockerUINavigationBarLayoutSubviews(id self, SEL _cmd) {
    orig_UINavigationBarLayoutSubviews(self, _cmd);
    if (BrowserURLHideEnabled()) {
        ScanAndApply(self, YES);
    } else {
        for (UILabel *label in g_hiddenURLLabels) {
            label.hidden = NO;
        }
        [g_hiddenURLLabels removeAllObjects];
    }
}

static BOOL g_registered = NO;

static void RegisterAPIBlockerPlugin(WCPluginsMgr *mgr) {
    if (g_registered || !mgr) {
        return;
    }
    g_registered = YES;
    @try {
        [mgr registerControllerWithTitle:@"请求拦截" version:kPluginVersion controller:@"APIBlockerSettingsViewController"];
        TFLog(@"[APIBlocker] registered controller into WCPluginsMgr");
    } @catch (NSException *exception) {
        TFLog(@"[APIBlocker] WCPluginsMgr register failed: %@", exception);
    }
}

static IMP orig_WCPluginsMgrInit;

static id APIBlockerWCPluginsMgrInit(id self, SEL _cmd) {
    self = ((id (*)(id, SEL))orig_WCPluginsMgrInit)(self, _cmd);
    if (self) {
        RegisterAPIBlockerPlugin(self);
    }
    return self;
}

// 默认拦截 URL 列表
static NSArray *DefaultURLs(void) {
    return @[ @"https://wcrefine.iosrxwy.com/api.php" ];
}

// v0.0.8 的旧默认列表（4 条），用于迁移
static BOOL IsLegacyDefaultList(NSArray *list) {
    NSArray *legacy = @[
        @"https://wcrefine.iosrxwy.com/api.php",
        @"https://wcrefine.iosrxwy.com/api",
        @"https://wcrefine.iosxwy.com/api.php",
        @"https://wcrefine.uiosxwy.com/api.php",
    ];
    return [list isEqualToArray:legacy];
}

// 读取配置的拦截 URL 列表（从未设置过时返回默认列表）
static NSArray *ConfiguredURLStrings(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:kURLsKey];
    if (stored == nil) {
        return DefaultURLs();
    }
    if ([stored isKindOfClass:[NSArray class]]) {
        if (IsLegacyDefaultList(stored)) {
            return DefaultURLs();
        }
        return stored;
    }
    return @[];
}

// 被禁用的规则：仍然保留在配置里，但不参与匹配
static NSArray<NSString *> *DisabledURLStrings(void) {
    id stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kDisabledURLsKey];
    return [stored isKindOfClass:[NSArray class]] ? stored : @[];
}

static BOOL IsURLDisabled(NSString *pattern) {
    return pattern.length > 0 && [DisabledURLStrings() containsObject:pattern];
}

static void SetURLDisabled(NSString *pattern, BOOL disabled) {
    if (pattern.length == 0) {
        return;
    }
    NSMutableArray *list = [NSMutableArray arrayWithArray:DisabledURLStrings()];
    if (disabled) {
        if (![list containsObject:pattern]) {
            [list addObject:pattern];
        }
    } else {
        [list removeObject:pattern];
    }
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:kDisabledURLsKey];
}

// ============ 自定义响应配置 ============

// 可选的响应格式（同时决定 Content-Type）
static NSArray<NSString *> *ResponseTypeKeys(void) {
    return @[
        @"text/plain",
        @"text/html",
        @"application/json",
        @"application/xml",
        @"application/javascript",
        kResponseTypeEmpty,
    ];
}

static NSString *ResponseTypeLabel(NSString *key) {
    if ([key isEqualToString:@"text/plain"]) {
        return @"纯文本 text/plain";
    }
    if ([key isEqualToString:@"text/html"]) {
        return @"HTML text/html";
    }
    if ([key isEqualToString:@"application/json"]) {
        return @"JSON application/json";
    }
    if ([key isEqualToString:@"application/xml"]) {
        return @"XML application/xml";
    }
    if ([key isEqualToString:@"application/javascript"]) {
        return @"JS application/javascript";
    }
    if ([key isEqualToString:kResponseTypeEmpty]) {
        return @"空响应（200 无内容）";
    }
    return key;
}

// 当前配置的响应格式 key（默认 text/plain）
static NSString *ConfiguredResponseType(void) {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:kResponseTypeKey];
    if (value.length > 0 && [ResponseTypeKeys() containsObject:value]) {
        return value;
    }
    return @"text/plain";
}

// 当前配置的响应内容（默认“请求已被拦截”）
static NSString *ConfiguredResponseBody(void) {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:kResponseBodyKey];
    return value ?: kBlockedText;
}

// 空响应：返回 200 但不带任何内容
static BOOL ResponseIsEmpty(void) {
    return [ConfiguredResponseType() isEqualToString:kResponseTypeEmpty];
}

// 实际写入 HTTP 头的 Content-Type（空响应返回 nil）
static NSString *ResponseContentTypeHeader(void) {
    if (ResponseIsEmpty()) {
        return nil;
    }
    return [ConfiguredResponseType() stringByAppendingString:@"; charset=utf-8"];
}

// 实际要吐出的 body
static NSData *ResponseBodyData(void) {
    if (ResponseIsEmpty()) {
        return [NSData data];
    }
    NSString *body = ConfiguredResponseBody();
    return [body dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
}

// ============ URL 匹配：前缀匹配 + * 泛匹配 ============

static NSMutableDictionary *g_wildcardRegexCache;
static NSObject *g_wildcardRegexLock;

// 把 https://*.tweak.com 这类模式编译成正则（* 匹配任意字符）
static NSRegularExpression *WildcardRegexForPattern(NSString *pattern) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_wildcardRegexCache = [[NSMutableDictionary alloc] init];
        g_wildcardRegexLock = [[NSObject alloc] init];
    });
    @synchronized (g_wildcardRegexLock) {
        NSRegularExpression *cached = g_wildcardRegexCache[pattern];
        if (cached) {
            return cached;
        }
        static NSString *const regexMetaCharacters = @"\\^$.|?+()[]{}";
        NSMutableString *escaped = [NSMutableString string];
        for (NSUInteger i = 0; i < pattern.length; i++) {
            unichar c = [pattern characterAtIndex:i];
            if (c == '*') {
                [escaped appendString:@".*"];
                continue;
            }
            if ([regexMetaCharacters rangeOfString:[NSString stringWithCharacters:&c length:1]].location != NSNotFound) {
                [escaped appendString:@"\\"];
            }
            [escaped appendFormat:@"%C", c];
        }
        // 以 * 结尾表示后续任意；否则只允许继续拼路径/查询，避免 *.tweak.com 误命中 tweak.com.evil.com
        NSString *suffix = [pattern hasSuffix:@"*"] ? @"" : @"(?:[/?#].*)?$";
        NSString *expression = [NSString stringWithFormat:@"^%@%@", escaped, suffix];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:expression
                                                                              options:NSRegularExpressionCaseInsensitive
                                                                                error:NULL];
        if (regex) {
            g_wildcardRegexCache[pattern] = regex;
        }
        return regex;
    }
}

// 命中规则：不含 * 时按前缀匹配（兼容旧配置）；含 * 时按泛匹配，如 https://*.tweak.com、https://a.baidu.com/api=*
static BOOL URLMatches(NSURL *url) {
    if (!url) {
        return NO;
    }
    NSString *absolute = url.absoluteString.lowercaseString;
    if (absolute.length == 0) {
        return NO;
    }
    for (id entry in ConfiguredURLStrings()) {
        if (![entry isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *pattern = [(NSString *)entry lowercaseString];
        if (pattern.length == 0) {
            continue;
        }
        if (IsURLDisabled((NSString *)entry)) {
            continue; // 该条规则已被禁用
        }
        if ([pattern containsString:@"*"]) {
            NSRegularExpression *regex = WildcardRegexForPattern(pattern);
            if (regex && [regex numberOfMatchesInString:absolute options:0 range:NSMakeRange(0, absolute.length)] > 0) {
                return YES;
            }
        } else if ([absolute hasPrefix:pattern]) {
            return YES;
        }
    }
    return NO;
}

// ============ 恢复旧版卡包页面 ============
//
// 微信把“我 → 卡包”入口热更新成了复杂的商家卡片流（V2 / 服务端驱动），
// 微信自带也没有可复用的简洁四入口页面。现改为自建一个标题为“卡包”的
// 列表页（LegacyCardHomeViewController，见下文），固定优惠券 / 会员卡 /
// 交通卡 / 票证四个入口。旧的“切回 V1 / WCCardPackageViewController”方案
// 因观感差异大已移除。

// 设置里显示的旧卡包实现（兼容历史配置，设置页仍引用）
static NSString *ConfiguredOldCardPageClass(void) {
    NSString *configured = [[NSUserDefaults standardUserDefaults] stringForKey:kOldCardPageClassKey];
    return configured.length > 0 ? configured : @"自动";
}

// ============ 补齐首页缺失的入口（会员卡 / 卡券）============
//
// 首页顶部入口来自服务端下发的 GetMktCardHomePageResponse.cardHomePageTopCellList，
// 热更新后可能少项。这里只在“卡包页自己”的数据里补两条入口：
//   会员卡 -> WCMktMemberCardHomeViewController
//   卡券   -> WCMktCouponHomeViewController（券和礼品卡列表）
// 不 hook 任何全局类（UINavigationController 之类），避免影响面扩大。

static NSString *const kMemberCardJumpMarker = @"apiblocker://membercard";
static NSString *const kCouponJumpMarker = @"apiblocker://coupon";
static BOOL g_legacyInjectionDisabled = NO; // 补位失败过就停用，避免反复踩坑

// 只 hook “类自己实现”的方法：如果方法是从父类继承的，
// MSHookMessageEx 取到的 orig 可能已经是别人装上的 hook，会形成递归。
static BOOL ClassImplementsMethod(Class cls, SEL sel) {
    if (!cls) {
        return NO;
    }
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        return NO;
    }
    Class super = class_getSuperclass(cls);
    if (!super) {
        return YES;
    }
    Method superMethod = class_getInstanceMethod(super, sel);
    return (superMethod == NULL) || (method != superMethod);
}

// 类方法版本（hook 类方法要传元类，同样只挂自己实现的）
static BOOL ClassImplementsClassMethod(Class cls, SEL sel) {
    if (!cls) {
        return NO;
    }
    Method method = class_getClassMethod(cls, sel);
    if (!method) {
        return NO;
    }
    Class super = class_getSuperclass(cls);
    if (!super) {
        return YES;
    }
    Method superMethod = class_getClassMethod(super, sel);
    return (superMethod == NULL) || (method != superMethod);
}

// ===== 本次 PluginsInject 兼容调整已禁用（保留代码，#if 0 不参与编译）=====
#if 0
// ============ PluginsInject 兼容实现（默认启用，无开关）============
//
// 参考 PluginsInject.dylib 的功能：
//  1. 探测当前进程可用的 Keychain access group，注入到 SecItem* 查询
//  2. 通过 LSBundleProxy 私有 API 取 App Group 容器路径
//  3. hook NSFileManager / NSUserDefaults，使 group 容器访问落到同一路径
//  4. 保守补齐 CloudKit entitlement key
// 不含任何偏好开关；每个 wrapper 都保留失败回退（orig 不存在时安全退出）。
static NSString *const kTFSharedKeychainAccount = @"zxPluginsInjectGenericEntry";
static NSString *gTFSharedAccessGroup = nil;
static NSString *gTFSharedAppGroupPath = nil;
static BOOL gTFSharedBridgeInstalled = NO;

static OSStatus (*orig_TFSecItemAdd)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*orig_TFSecItemCopyMatching)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*orig_TFSecItemUpdate)(CFDictionaryRef, CFDictionaryRef) = NULL;
static OSStatus (*orig_TFSecItemDelete)(CFDictionaryRef) = NULL;

static NSString *TFSharedAccessGroup(void) {
    if (gTFSharedAccessGroup.length > 0) {
        return gTFSharedAccessGroup;
    }
    if (gTFSharedBridgeInstalled) {
        return nil; // 安装 hook 后不再探测，避免递归
    }
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    query[(__bridge id)kSecAttrAccount] = kTFSharedKeychainAccount;
    query[(__bridge id)kSecAttrService] = @"";
    query[(__bridge id)kSecReturnAttributes] = @YES;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *add = [NSMutableDictionary dictionary];
        add[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
        add[(__bridge id)kSecAttrAccount] = kTFSharedKeychainAccount;
        add[(__bridge id)kSecAttrService] = @"";
        add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        add[(__bridge id)kSecValueData] = [@"1" dataUsingEncoding:NSUTF8StringEncoding];
        status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        if (status == errSecSuccess || status == errSecDuplicateItem) {
            status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        }
    }
    if (status == errSecSuccess && result) {
        NSDictionary *attrs = (__bridge NSDictionary *)result;
        NSString *group = attrs[(__bridge id)kSecAttrAccessGroup];
        if ([group isKindOfClass:NSString.class] && group.length > 0) {
            gTFSharedAccessGroup = [group copy];
        }
        CFRelease(result);
    }
    return gTFSharedAccessGroup;
}

static CFDictionaryRef TFCopyQueryWithSharedAccessGroup(CFDictionaryRef query) {
    NSString *group = TFSharedAccessGroup();
    if (!query || group.length == 0) {
        return query;
    }
    NSDictionary *origin = (__bridge NSDictionary *)query;
    NSMutableDictionary *merged = [origin mutableCopy] ?: [NSMutableDictionary dictionary];
    [merged removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    merged[(__bridge id)kSecAttrAccessGroup] = group;
    return (CFDictionaryRef)CFRetain((__bridge CFTypeRef)merged);
}

static OSStatus TFSharedSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!orig_TFSecItemAdd) return errSecParam;
    CFDictionaryRef patched = TFCopyQueryWithSharedAccessGroup(attributes);
    OSStatus status = orig_TFSecItemAdd(patched, result);
    if (patched != attributes) CFRelease(patched);
    return status;
}

static OSStatus TFSharedSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!orig_TFSecItemCopyMatching) return errSecParam;
    CFDictionaryRef patched = TFCopyQueryWithSharedAccessGroup(query);
    OSStatus status = orig_TFSecItemCopyMatching(patched, result);
    if (patched != query) CFRelease(patched);
    return status;
}

static OSStatus TFSharedSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (!orig_TFSecItemUpdate) return errSecParam;
    CFDictionaryRef patched = TFCopyQueryWithSharedAccessGroup(query);
    OSStatus status = orig_TFSecItemUpdate(patched, attributesToUpdate);
    if (patched != query) CFRelease(patched);
    return status;
}

static OSStatus TFSharedSecItemDelete(CFDictionaryRef query) {
    if (!orig_TFSecItemDelete) return errSecParam;
    CFDictionaryRef patched = TFCopyQueryWithSharedAccessGroup(query);
    OSStatus status = orig_TFSecItemDelete(patched);
    if (patched != query) CFRelease(patched);
    return status;
}

static NSString *TFSharedAppGroupPath(void) {
    if (gTFSharedAppGroupPath.length > 0) {
        return gTFSharedAppGroupPath;
    }
    Class proxyClass = objc_getClass("LSBundleProxy");
    if (!proxyClass || !ClassImplementsClassMethod(proxyClass, NSSelectorFromString(@"bundleProxyForCurrentProcess"))) {
        return nil;
    }
    id proxy = [proxyClass performSelector:@selector(bundleProxyForCurrentProcess)];
    if (!proxy || ![proxy respondsToSelector:NSSelectorFromString(@"entitlements")]) {
        return nil;
    }
    NSDictionary *entitlements = [proxy performSelector:@selector(entitlements)];
    NSArray *groups = entitlements[@"com.apple.security.application-groups"];
    if (![groups isKindOfClass:NSArray.class] || groups.count == 0) {
        return nil;
    }
    SEL containerURLsSel = NSSelectorFromString(@"groupContainerURLs");
    if (![proxy respondsToSelector:containerURLsSel]) {
        return nil;
    }
    NSDictionary *urls = [proxy performSelector:containerURLsSel];
    for (NSString *groupName in groups) {
        NSURL *url = [urls isKindOfClass:NSDictionary.class] ? urls[groupName] : nil;
        if ([url isKindOfClass:NSURL.class] && url.path.length > 0) {
            gTFSharedAppGroupPath = [url.path copy];
            break;
        }
    }
    return gTFSharedAppGroupPath;
}

static BOOL TFEnsureDirectoryAtPath(NSString *path) {
    if (path.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDir]) {
        return isDir;
    }
    NSError *error = nil;
    return [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
}

static NSURL *(*orig_TFContainerURLForGroup)(id, SEL, NSString *) = NULL;
static NSURL *TFSharedContainerURLForGroup(id self, SEL _cmd, NSString *identifier) {
    if (!orig_TFContainerURLForGroup) return nil;
    NSString *path = TFSharedAppGroupPath();
    if (path.length > 0 && TFEnsureDirectoryAtPath(path)) {
        return [NSURL fileURLWithPath:path isDirectory:YES];
    }
    return orig_TFContainerURLForGroup(self, _cmd, identifier);
}

static id (*orig_TFUserDefaultsInitWithSuite)(id, SEL, NSString *, NSURL *) = NULL;
static id TFSharedUserDefaultsInitWithSuite(id self, SEL _cmd, NSString *suiteName, NSURL *container) {
    if (!orig_TFUserDefaultsInitWithSuite) return nil;
    NSString *path = TFSharedAppGroupPath();
    if ([suiteName hasPrefix:@"group"] && path.length > 0 && TFEnsureDirectoryAtPath(path)) {
        NSURL *sharedURL = [NSURL fileURLWithPath:path isDirectory:YES];
        return orig_TFUserDefaultsInitWithSuite(self, _cmd, suiteName, sharedURL);
    }
    return orig_TFUserDefaultsInitWithSuite(self, _cmd, suiteName, container);
}

static id (*orig_TFCKEntitlementsInit)(id, SEL, NSDictionary *) = NULL;
static id TFSharedCKEntitlementsInit(id self, SEL _cmd, NSDictionary *entitlementsDict) {
    if (!orig_TFCKEntitlementsInit) return nil;
    NSMutableDictionary *merged = [entitlementsDict mutableCopy] ?: [NSMutableDictionary dictionary];
    if (!merged[@"com.apple.developer.icloud-container-environment"]) {
        merged[@"com.apple.developer.icloud-container-environment"] = @"Production";
    }
    if (!merged[@"com.apple.developer.icloud-services"]) {
        merged[@"com.apple.developer.icloud-services"] = @"CloudKit";
    }
    return orig_TFCKEntitlementsInit(self, _cmd, merged);
}

static void TFInstallPluginsInjectCompatHooks(void) {
    if (gTFSharedBridgeInstalled) return;
    // 探测必须在 hook 之前完成，否则 wrapper 内调用会被自己拦住形成递归
    TFSharedAccessGroup();
    TFSharedAppGroupPath();
    gTFSharedBridgeInstalled = YES;

    void *secAdd = MSFindSymbol(NULL, "_SecItemAdd");
    void *secCopy = MSFindSymbol(NULL, "_SecItemCopyMatching");
    void *secUpdate = MSFindSymbol(NULL, "_SecItemUpdate");
    void *secDelete = MSFindSymbol(NULL, "_SecItemDelete");
    if (secAdd)  MSHookFunction(secAdd,  (void *)TFSharedSecItemAdd,         (void **)&orig_TFSecItemAdd);
    if (secCopy) MSHookFunction(secCopy, (void *)TFSharedSecItemCopyMatching,(void **)&orig_TFSecItemCopyMatching);
    if (secUpdate) MSHookFunction(secUpdate, (void *)TFSharedSecItemUpdate,  (void **)&orig_TFSecItemUpdate);
    if (secDelete) MSHookFunction(secDelete, (void *)TFSharedSecItemDelete,  (void **)&orig_TFSecItemDelete);

    SEL containerSel = NSSelectorFromString(@"containerURLForSecurityApplicationGroupIdentifier:");
    if (ClassImplementsMethod([NSFileManager class], containerSel)) {
        MSHookMessageEx([NSFileManager class], containerSel,
                        (IMP)&TFSharedContainerURLForGroup, (IMP *)&orig_TFContainerURLForGroup);
    }
    SEL suiteSel = NSSelectorFromString(@"_initWithSuiteName:container:");
    if (ClassImplementsMethod([NSUserDefaults class], suiteSel)) {
        MSHookMessageEx([NSUserDefaults class], suiteSel,
                        (IMP)&TFSharedUserDefaultsInitWithSuite, (IMP *)&orig_TFUserDefaultsInitWithSuite);
    }
    Class ckEntitlements = objc_getClass("CKEntitlements");
    SEL ckEntSel = NSSelectorFromString(@"initWithEntitlementsDict:");
    if (ckEntitlements && ClassImplementsMethod(ckEntitlements, ckEntSel)) {
        MSHookMessageEx(ckEntitlements, ckEntSel,
                        (IMP)&TFSharedCKEntitlementsInit, (IMP *)&orig_TFCKEntitlementsInit);
    }
}
#endif

// WCMkt 系列二级页面都用 initWithTitle: 构造
static UIViewController *MakeCardSubPage(NSString *className, NSString *title) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        return nil;
    }
    UIViewController *vc = nil;
    SEL initSel = NSSelectorFromString(@"initWithTitle:");
    if ([cls instancesRespondToSelector:initSel]) {
        vc = [[cls alloc] performSelector:initSel withObject:title];
    }
    if (!vc) {
        vc = [[cls alloc] init];
    }
    if (vc) {
        vc.hidesBottomBarWhenPushed = YES;
    }
    return vc;
}

static UIViewController *MemberCardPage(void) {
    return MakeCardSubPage(@"WCMktMemberCardHomeViewController", @"会员卡");
}

static UIViewController *CouponPage(void) {
    UIViewController *vc = MakeCardSubPage(@"WCMktCouponHomeViewController", @"券和礼品卡");
    if (!vc) {
        vc = MakeCardSubPage(@"WCMktCouponHomeViewControllerV2", @"券和礼品卡");
    }
    return vc;
}


static void ApplyPlainBackButton(UIViewController *vc);

static void PresentSubPage(UIViewController *host, UIViewController *page) {
    if (!host || !page) {
        TFLog(@"[APIBlocker] 二级页面创建失败（host=%@）", host ? @"ok" : @"nil");
        return;
    }
    ApplyPlainBackButton(host);
    TFLog(@"[APIBlocker] 打开二级页面：%@（from %@）",
          NSStringFromClass(page.class),
          NSStringFromClass(host.class));
    if (host.navigationController) {
        [host.navigationController pushViewController:page animated:YES];
        ApplyPlainBackButton(page);
    } else {
        [host presentViewController:page animated:YES completion:nil];
    }
}

// 返回按钮只保留箭头（不显示文字），配色用 labelColor（不是蓝色）
static void ApplyPlainBackButton(UIViewController *vc) {
    if (!vc) {
        return;
    }
    @try {
        UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithTitle:@""
                                                                style:UIBarButtonItemStylePlain
                                                               target:nil
                                                               action:nil];
        vc.navigationItem.backBarButtonItem = back;
        UINavigationController *nav = vc.navigationController;
        if (nav) {
            nav.navigationBar.tintColor = UIColor.labelColor;
        }
    } @catch (NSException *exception) {
        TFLog(@"[APIBlocker] 设置返回按钮失败：%@", exception.reason);
    }
}

// 构造合成入口：优先克隆已有项（对象结构最完整），失败再新建
static id MakeTopCell(NSMutableArray *cells, NSString *title, NSString *jumpMarker) {
    Class cellClass = NSClassFromString(@"CardHomePageTopCell");
    if (!cellClass) {
        return nil;
    }
    id sample = cells.count > 0 ? cells.firstObject : nil;
    id cell = nil;
    if (sample && [sample respondsToSelector:NSSelectorFromString(@"copy")]) {
        @try {
            cell = [sample performSelector:NSSelectorFromString(@"copy")];
        } @catch (NSException *exception) {
            cell = nil;
        }
    }
    if (!cell || ![cell isKindOfClass:cellClass]) {
        cell = [[cellClass alloc] init];
    }
    [cell setValue:title forKey:@"cardTopCellTitle"];
    [cell setValue:@"" forKey:@"cardTopCellWording"];
    [cell setValue:jumpMarker forKey:@"cardTopCellJumpUrl"];
    [cell setValue:@0 forKey:@"cardTopCellOpType"];
    [cell setValue:@0 forKey:@"isShowRedDot"];
    [cell setValue:@0 forKey:@"isShowNew"];
    if (sample) {
        NSString *icon = [sample valueForKey:@"cardTopCellIcon"];
        if ([icon isKindOfClass:[NSString class]] && icon.length > 0) {
            [cell setValue:icon forKey:@"cardTopCellIcon"];
        }
    }
    return cell;
}

// 补入口 + 让内嵌的“卡券”区块默认折叠
static void InjectLegacyTopCells(id response) {
    if (!OldCardPageEnabled() || !response || g_legacyInjectionDisabled) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            InjectLegacyTopCells(response);
        });
        return;
    }
    @try {
        id topCellList = [response valueForKey:@"cardHomePageTopCellList"];
        NSMutableArray *cells = topCellList ? [topCellList valueForKey:@"cardHomePageTopCell"] : nil;
        if (![cells isKindOfClass:[NSMutableArray class]]) {
            Class listClass = NSClassFromString(@"CardHomePageTopCellList");
            if (!listClass) {
                g_legacyInjectionDisabled = YES;
                return;
            }
            topCellList = [[listClass alloc] init];
            cells = [NSMutableArray array];
            [topCellList setValue:cells forKey:@"cardHomePageTopCell"];
            [response setValue:topCellList forKey:@"cardHomePageTopCellList"];
        }

        NSArray<NSArray<NSString *> *> *wanted = @[
            @[ @"会员卡", kMemberCardJumpMarker ],
            @[ @"卡券", kCouponJumpMarker ],
        ];
        for (NSArray<NSString *> *item in wanted) {
            NSString *title = item[0];
            NSString *marker = item[1];
            BOOL exists = NO;
            for (id existing in cells) {
                NSString *cellTitle = [existing valueForKey:@"cardTopCellTitle"];
                NSString *cellWording = [existing valueForKey:@"cardTopCellWording"];
                NSString *cellJump = [existing valueForKey:@"cardTopCellJumpUrl"];
                if ([cellJump isEqualToString:marker] ||
                    (cellTitle.length > 0 && [cellTitle containsString:title]) ||
                    (cellWording.length > 0 && [cellWording containsString:title])) {
                    exists = YES;
                    break;
                }
            }
            if (exists) {
                TFLog(@"[APIBlocker] 服务端已下发“%@”入口，无需补", title);
                continue;
            }
            id cell = MakeTopCell(cells, title, marker);
            if (cell) {
                [cells addObject:cell];
                TFLog(@"[APIBlocker] 已补回入口：%@（首页入口共 %lu 项）", title, (unsigned long)cells.count);
            }
        }

        // 首页底部那块内嵌的“卡券（暂无卡券）”是 cardHomePageStoreList 渲染出来的，
        // 现在卡券已经是独立入口了，这里把数据清掉，让那一块不再出现。
        @try {
            id storeList = [response valueForKey:@"cardHomePageStoreList"];
            if (storeList) {
                [response setValue:nil forKey:@"cardHomePageStoreList"];
                TFLog(@"[APIBlocker] 已移除首页多余的卡券区块");
            }
        } @catch (NSException *exception) {
            TFLog(@"[APIBlocker] 移除卡券区块失败：%@", exception.reason);
        }
    } @catch (NSException *exception) {
        g_legacyInjectionDisabled = YES;
        TFLog(@"[APIBlocker] 补入口失败，已停用自动补位：%@", exception.reason);
    }
}

// ============ 文件管理：浏览当前 App 数据目录 ============

static NSString *FileSizeString(unsigned long long size) {
    if (size >= 1024ULL * 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f GB", size / 1024.0 / 1024 / 1024];
    }
    if (size >= 1024ULL * 1024) {
        return [NSString stringWithFormat:@"%.1f MB", size / 1024.0 / 1024];
    }
    if (size >= 1024ULL) {
        return [NSString stringWithFormat:@"%.1f KB", size / 1024.0];
    }
    return [NSString stringWithFormat:@"%llu B", size];
}

@interface APIBlockerPlistEditorViewController : UIViewController
- (instancetype)initWithPath:(NSString *)path;
- (instancetype)initWithPath:(NSString *)path plainText:(BOOL)plainText;
@end

@interface APIBlockerFileBrowserViewController : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
@end

@implementation APIBlockerFileBrowserViewController {
    NSString *_path;
    NSMutableArray<NSString *> *_entries; // 目录在前，文件在后
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _path = [path copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _path.lastPathComponent.length > 0 ? _path.lastPathComponent : @"文件管理";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(reloadFiles)];
    [self reloadFiles];
}

- (void)reloadFiles {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:_path error:NULL];
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (NSString *name in names) {
        BOOL isDir = NO;
        [fm fileExistsAtPath:[_path stringByAppendingPathComponent:name] isDirectory:&isDir];
        if (isDir) {
            [dirs addObject:name];
        } else {
            [files addObject:name];
        }
    }
    [dirs sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [files sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    _entries = [[dirs arrayByAddingObjectsFromArray:files] mutableCopy];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _entries.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"当前目录：%@", _path];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"filecell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"filecell"];
    }
    NSString *name = _entries[indexPath.row];
    NSString *full = [_path stringByAppendingPathComponent:name];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    [fm fileExistsAtPath:full isDirectory:&isDir];
    cell.textLabel.text = name;
    if (isDir) {
        cell.detailTextLabel.text = @"文件夹";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:NULL];
        NSDate *date = attrs[NSFileModificationDate];
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm";
        NSString *dateStr = date ? [fmt stringFromDate:date] : @"";
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        BOOL isPlist = [name.pathExtension.lowercaseString isEqualToString:@"plist"];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@%@",
                                                              FileSizeString(size),
                                                              dateStr,
                                                              isPlist ? @" · plist" : @""];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.navigationController.topViewController != self) {
        return; // 防止快速连点导致重复 push
    }
    NSString *name = _entries[indexPath.row];
    NSString *full = [_path stringByAppendingPathComponent:name];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    [fm fileExistsAtPath:full isDirectory:&isDir];
    if (isDir) {
        APIBlockerFileBrowserViewController *sub = [[APIBlockerFileBrowserViewController alloc] initWithPath:full];
        [self.navigationController pushViewController:sub animated:YES];
        return;
    }
    if ([name.pathExtension.lowercaseString isEqualToString:@"plist"]) {
        APIBlockerPlistEditorViewController *editor = [[APIBlockerPlistEditorViewController alloc] initWithPath:full];
        [self.navigationController pushViewController:editor animated:YES];
        return;
    }
    // 文本类文件直接用文本编辑器打开（日志、json、txt 等）
    NSString *ext = name.pathExtension.lowercaseString;
    NSArray<NSString *> *textExtensions = @[ @"log", @"txt", @"json", @"xml", @"strings", @"md", @"conf", @"cfg", @"ini", @"html", @"js", @"css" ];
    if ([textExtensions containsObject:ext]) {
        APIBlockerPlistEditorViewController *editor = [[APIBlockerPlistEditorViewController alloc] initWithPath:full plainText:YES];
        [self.navigationController pushViewController:editor animated:YES];
        return;
    }
    // 非 plist 文件：显示基本信息
    NSDictionary *attrs = [fm attributesOfItemAtPath:full error:NULL];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *msg = [NSString stringWithFormat:@"名称：%@\n大小：%@\n修改时间：%@",
                                                name,
                                                FileSizeString([attrs[NSFileSize] unsignedLongLongValue]),
                                                attrs[NSFileModificationDate] ? [fmt stringFromDate:attrs[NSFileModificationDate]] : @"未知"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"文件信息"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

// ============ plist 编辑器：文本模式（支持搜索/替换/保存） ============

@implementation APIBlockerPlistEditorViewController {
    NSString *_path;
    UITextView *_textView;
    UITextField *_searchField;
    UITextField *_replaceField;
    NSRange _lastFoundRange;
    BOOL _exactMatchEnabled;
    UIBarButtonItem *_counterItem;
    BOOL _plainText;
}

- (instancetype)initWithPath:(NSString *)path {
    return [self initWithPath:path plainText:NO];
}

- (instancetype)initWithPath:(NSString *)path plainText:(BOOL)plainText {
    self = [super init];
    if (self) {
        _path = [path copy];
        _plainText = plainText;
        _lastFoundRange = NSMakeRange(NSNotFound, 0);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _plainText ? [NSString stringWithFormat:@"%@ · 文本", _path.lastPathComponent]
                            : _path.lastPathComponent;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.edgesForExtendedLayout = UIRectEdgeNone;

    _textView = [[UITextView alloc] initWithFrame:CGRectZero];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.font = [UIFont fontWithName:@"Menlo" size:13] ?: [UIFont systemFontOfSize:13];
    _textView.editable = YES;
    _textView.alwaysBounceVertical = YES;
    _textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _textView.text = [self plistTextForFile];
    [self.view addSubview:_textView];

    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectZero];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [self setupToolbarItems:toolbar];
    [self.view addSubview:toolbar];

    [NSLayoutConstraint activateConstraints:@[
        [toolbar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [toolbar.heightAnchor constraintEqualToConstant:44],
        [_textView.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor],
        [_textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    UIBarButtonItem *saveItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                                                 style:UIBarButtonItemStyleDone
                                                                target:self
                                                                action:@selector(savePressed)];

    UISwitch *exactSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    exactSwitch.on = NO;
    [exactSwitch addTarget:self action:@selector(exactMatchToggled:) forControlEvents:UIControlEventValueChanged];
    UILabel *exactLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    exactLabel.text = @"精确匹配";
    exactLabel.font = [UIFont systemFontOfSize:14];
    exactLabel.textColor = UIColor.labelColor;
    [exactLabel sizeToFit];
    CGFloat switchW = exactSwitch.frame.size.width;
    CGFloat labelW = exactLabel.frame.size.width;
    UIView *exactContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, labelW + 8 + switchW, 32)];
    exactLabel.frame = CGRectMake(0, (32 - exactLabel.frame.size.height) / 2.0, labelW, exactLabel.frame.size.height);
    exactSwitch.frame = CGRectMake(labelW + 8, (32 - exactSwitch.frame.size.height) / 2.0, switchW, exactSwitch.frame.size.height);
    [exactContainer addSubview:exactLabel];
    [exactContainer addSubview:exactSwitch];
    UIBarButtonItem *exactItem = [[UIBarButtonItem alloc] initWithCustomView:exactContainer];

    _counterItem = [[UIBarButtonItem alloc] initWithTitle:@"0 / 0"
                                                    style:UIBarButtonItemStylePlain
                                                   target:nil
                                                   action:nil];

    self.navigationItem.rightBarButtonItems = @[saveItem, _counterItem, exactItem];
}

- (NSString *)plistTextForFile {
    NSData *data = [NSData dataWithContentsOfFile:_path];
    if (!data) {
        return @"";
    }
    if (_plainText) {
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        return raw ?: @"";
    }
    NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:0
                                                          format:&format
                                                           error:NULL];
    if (plist && format == NSPropertyListBinaryFormat_v1_0) {
        NSData *xml = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                 format:NSPropertyListXMLFormat_v1_0
                                                                options:0
                                                                  error:NULL];
        if (xml) {
            return [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding];
        }
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

- (void)setupToolbarItems:(UIToolbar *)toolbar {
    _searchField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 110, 32)];
    _searchField.borderStyle = UITextBorderStyleRoundedRect;
    _searchField.font = [UIFont systemFontOfSize:13];
    _searchField.placeholder = @"搜索";
    _searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    [_searchField addTarget:self action:@selector(searchFieldChanged) forControlEvents:UIControlEventEditingChanged];

    _replaceField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 110, 32)];
    _replaceField.borderStyle = UITextBorderStyleRoundedRect;
    _replaceField.font = [UIFont systemFontOfSize:13];
    _replaceField.placeholder = @"替换为";
    _replaceField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _replaceField.autocorrectionType = UITextAutocorrectionTypeNo;

    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                          target:nil
                                                                          action:nil];
    toolbar.items = @[
        [[UIBarButtonItem alloc] initWithCustomView:_searchField],
        flex,
        [[UIBarButtonItem alloc] initWithCustomView:_replaceField],
        flex,
        [[UIBarButtonItem alloc] initWithTitle:@"查找" style:UIBarButtonItemStylePlain target:self action:@selector(findNext)],
        [[UIBarButtonItem alloc] initWithTitle:@"替换" style:UIBarButtonItemStylePlain target:self action:@selector(replaceCurrent)],
    ];
}

// 高亮所有匹配项（黄色半透明背景，深浅色模式均可见）。
// 必须显式设置前景色为 labelColor，否则设置 attributedText 后夜间模式文字会变成黑色。
- (void)applyHighlights {
    NSString *needle = _searchField.text;
    UIFont *font = _textView.font ?: [UIFont systemFontOfSize:13];
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:_textView.text
                                                                                   attributes:@{
                                                                                       NSFontAttributeName: font,
                                                                                       NSForegroundColorAttributeName: UIColor.labelColor,
                                                                                   }];
    if (needle.length > 0) {
        UIColor *highlight = [UIColor.systemYellowColor colorWithAlphaComponent:0.35];
        for (NSValue *value in [self allMatchRangesForNeedle:needle inString:attributed.string]) {
            [attributed addAttribute:NSBackgroundColorAttributeName value:highlight range:value.rangeValue];
        }
    }
    _textView.attributedText = attributed;
    [self updateMatchCounter];
}

// 按当前模式（模糊 / 精确）收集所有匹配区间。
- (NSArray<NSValue *> *)allMatchRangesForNeedle:(NSString *)needle inString:(NSString *)text {
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    if (needle.length == 0 || text.length == 0) {
        return ranges;
    }
    NSRange searchRange = NSMakeRange(0, text.length);
    while (searchRange.length > 0) {
        NSRange found = [self rangeOfNeedle:needle inString:text range:searchRange];
        if (found.location == NSNotFound) {
            break;
        }
        [ranges addObject:[NSValue valueWithRange:found]];
        NSUInteger next = NSMaxRange(found);
        if (next >= text.length) {
            break;
        }
        searchRange = NSMakeRange(next, text.length - next);
    }
    return ranges;
}

// 导航栏统计：当前选中的是第几个 / 总匹配数。
- (void)updateMatchCounter {
    NSArray<NSValue *> *ranges = [self allMatchRangesForNeedle:_searchField.text inString:_textView.text];
    NSUInteger total = ranges.count;
    NSUInteger current = 0;
    if (total > 0) {
        NSRange sel = _textView.selectedRange;
        if (sel.length > 0) {
            for (NSUInteger i = 0; i < ranges.count; i++) {
                if (NSEqualRanges([ranges[i] rangeValue], sel)) {
                    current = i + 1;
                    break;
                }
            }
        }
        if (current == 0 && _lastFoundRange.location != NSNotFound) {
            for (NSUInteger i = 0; i < ranges.count; i++) {
                if (NSEqualRanges([ranges[i] rangeValue], _lastFoundRange)) {
                    current = i + 1;
                    break;
                }
            }
        }
    }
    _counterItem.title = [NSString stringWithFormat:@"%lu / %lu", (unsigned long)current, (unsigned long)total];
}

- (void)searchFieldChanged {
    _lastFoundRange = NSMakeRange(NSNotFound, 0);
    [self applyHighlights];
}

- (void)exactMatchToggled:(UISwitch *)sender {
    _exactMatchEnabled = sender.isOn;
    _lastFoundRange = NSMakeRange(NSNotFound, 0);
    [self applyHighlights];
}

// 按当前模式查找：默认模糊（子串）匹配；开启“精确匹配”后只匹配完整关键字（整词）。
- (NSRange)rangeOfNeedle:(NSString *)needle inString:(NSString *)haystack range:(NSRange)searchRange {
    if (!_exactMatchEnabled) {
        return [haystack rangeOfString:needle options:NSCaseInsensitiveSearch range:searchRange];
    }
    while (searchRange.length > 0) {
        NSRange found = [haystack rangeOfString:needle options:NSCaseInsensitiveSearch range:searchRange];
        if (found.location == NSNotFound) {
            break;
        }
        if ([self isWholeWordMatch:found inString:haystack]) {
            return found;
        }
        NSUInteger next = NSMaxRange(found);
        if (next >= haystack.length) {
            break;
        }
        searchRange = NSMakeRange(next, haystack.length - next);
    }
    return NSMakeRange(NSNotFound, 0);
}

- (BOOL)isWholeWordMatch:(NSRange)range inString:(NSString *)string {
    NSMutableCharacterSet *wordChars = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [wordChars addCharactersInString:@"_"];
    if (range.location > 0) {
        unichar c = [string characterAtIndex:range.location - 1];
        if ([wordChars characterIsMember:c]) {
            return NO;
        }
    }
    if (NSMaxRange(range) < string.length) {
        unichar c = [string characterAtIndex:NSMaxRange(range)];
        if ([wordChars characterIsMember:c]) {
            return NO;
        }
    }
    return YES;
}

- (void)findNext {
    NSString *needle = _searchField.text;
    NSString *haystack = _textView.text;
    NSArray<NSValue *> *ranges = [self allMatchRangesForNeedle:needle inString:haystack];
    if (ranges.count == 0) {
        _lastFoundRange = NSMakeRange(NSNotFound, 0);
        [self applyHighlights];
        return;
    }
    NSUInteger currentIndex = 0;
    if (_lastFoundRange.location != NSNotFound) {
        for (NSUInteger i = 0; i < ranges.count; i++) {
            if (NSEqualRanges([ranges[i] rangeValue], _lastFoundRange)) {
                currentIndex = i;
                break;
            }
        }
    }
    NSUInteger nextIndex = (currentIndex + 1) % ranges.count;
    NSRange found = [ranges[nextIndex] rangeValue];
    _lastFoundRange = found;
    [self applyHighlights];
    _textView.selectedRange = found;
    [_textView scrollRangeToVisible:found];
    [self updateMatchCounter];
}

- (void)replaceCurrent {
    NSString *replacement = _replaceField.text ?: @"";
    NSRange sel = _lastFoundRange;
    if (sel.location == NSNotFound || sel.length == 0) {
        sel = _textView.selectedRange;
    }
    if (sel.location == NSNotFound || sel.length == 0) {
        [self findNext];
        sel = _lastFoundRange;
        if (sel.location == NSNotFound || sel.length == 0) {
            return;
        }
    }
    NSString *newText = [_textView.text stringByReplacingCharactersInRange:sel withString:replacement];
    _textView.text = newText;
    _lastFoundRange = NSMakeRange(NSNotFound, 0);
    // 替换后必须重建 attributed 文本，否则旧的高亮背景会残留（严重时整片发黄）。
    [self applyHighlights];
}

- (void)savePressed {
    NSString *text = _textView.text;
    if (_plainText) {
        [self writeText:text];
        return;
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSError *parseError = nil;
    id parsed = [NSPropertyListSerialization propertyListWithData:data
                                                          options:0
                                                           format:NULL
                                                            error:&parseError];
    if (!parsed) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"内容不是合法 plist"
                                                                       message:[NSString stringWithFormat:@"%@\n仍然写入文件吗？", parseError.localizedDescription]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"仍要保存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self writeText:text];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self writeText:text];
}

- (void)writeText:(NSString *)text {
    NSError *error = nil;
    BOOL ok = [text writeToFile:_path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    NSString *msg = ok ? @"保存成功" : [NSString stringWithFormat:@"写入失败：%@", error.localizedDescription];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存结果"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

// ============ 响应内容编辑页 ============

@interface APIBlockerResponseBodyViewController : UIViewController
@end

@implementation APIBlockerResponseBodyViewController {
    UITextView *_textView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"响应内容";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.edgesForExtendedLayout = UIRectEdgeNone;

    _textView = [[UITextView alloc] initWithFrame:CGRectZero];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.font = [UIFont fontWithName:@"Menlo" size:13] ?: [UIFont systemFontOfSize:13];
    _textView.textColor = UIColor.labelColor;
    _textView.backgroundColor = UIColor.systemBackgroundColor;
    _textView.alwaysBounceVertical = YES;
    _textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _textView.autocorrectionType = UITextAutocorrectionTypeNo;
    _textView.text = ConfiguredResponseBody();
    [self.view addSubview:_textView];

    [NSLayoutConstraint activateConstraints:@[
        [_textView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(savePressed)];
}

- (void)savePressed {
    [[NSUserDefaults standardUserDefaults] setObject:_textView.text ?: @"" forKey:kResponseBodyKey];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

// 群聊白名单选择器：列出当前账号所有群聊（会话 + 通讯录），勾选后只转发这些群
@interface APIBlockerGroupPickerViewController : UITableViewController <UISearchBarDelegate>
@end

static NSString *ABPickerGroupIdFromObject(id info) {
    if ([info isKindOfClass:[NSString class]]) {
        NSString *value = (NSString *)info;
        return IsGroupChatName(value) ? value : nil;
    }
    if (![info isKindOfClass:[NSObject class]]) {
        return nil;
    }
    // MMSessionInfo 的真实字段是 m_nsUserName（sessionId 是旧版本猜的名字）
    NSString *value = ABGetObject(info, @"m_nsUserName");
    if (![value isKindOfClass:[NSString class]] || value.length == 0) {
        value = ABGetObject(info, @"sessionId");
    }
    if (![value isKindOfClass:[NSString class]] || value.length == 0) {
        value = ABGetObject(info, @"userName");
    }
    if (![value isKindOfClass:[NSString class]] || value.length == 0) {
        id contact = ABGetObject(info, @"m_contact");
        value = ABGetObject(contact, @"m_nsUsrName");
    }
    if (![value isKindOfClass:[NSString class]] || !IsGroupChatName(value)) {
        return nil;
    }
    return value;
}

@implementation APIBlockerGroupPickerViewController {
    NSMutableArray<NSDictionary *> *_groups;
    NSMutableArray<NSDictionary *> *_filtered;
    NSMutableSet<NSString *> *_selected;
    UISearchBar *_searchBar;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStylePlain];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"群聊白名单";
    _groups = [NSMutableArray array];
    _filtered = [NSMutableArray array];
    _selected = [NSMutableSet setWithArray:ForwardGroupWhitelist()];

    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 44)];
    _searchBar.placeholder = @"搜索群名称或群号";
    _searchBar.delegate = self;
    _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.tableView.tableHeaderView = _searchBar;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self
                                                                                          action:@selector(donePressed)];
    [self loadGroups];
    [self.tableView reloadData];
}

- (void)donePressed {
    SetForwardGroupWhitelist(_selected.allObjects);
    TFLog(@"[Forward] 群白名单已保存：%lu 个", (unsigned long)_selected.count);
    [self.navigationController popViewControllerAnimated:YES];
}

// 会话列表 + 通讯录群聊，两路取并集，避免只显示最近打开过的群
- (void)loadGroups {
    NSMutableSet<NSString *> *chatIds = [NSMutableSet set];

    id sessionMgr = ABService(@"MMNewSessionMgr");
    if (sessionMgr) {
        SEL listSel = NSSelectorFromString(@"GetSessionInfoList");
        if ([sessionMgr respondsToSelector:listSel]) {
            id list = ((id (*)(id, SEL))objc_msgSend)(sessionMgr, listSel);
            if ([list isKindOfClass:[NSArray class]]) {
                for (id info in (NSArray *)list) {
                    NSString *chatId = ABPickerGroupIdFromObject(info);
                    if (chatId) {
                        [chatIds addObject:chatId];
                    }
                }
            }
        }
        SEL countSel = NSSelectorFromString(@"GetSessionCount");
        if ([sessionMgr respondsToSelector:countSel]) {
            unsigned int count = ((unsigned int (*)(id, SEL))objc_msgSend)(sessionMgr, countSel);
            SEL indexSel = NSSelectorFromString(@"GetSessionAtIndex:");
            SEL nameSel = NSSelectorFromString(@"GetSessionUserNameAtIndex:");
            if (count > 5000) {
                count = 5000;
            }
            for (unsigned int i = 0; i < count; i++) {
                NSString *chatId = nil;
                if ([sessionMgr respondsToSelector:indexSel]) {
                    id info = ((id (*)(id, SEL, unsigned int))objc_msgSend)(sessionMgr, indexSel, i);
                    chatId = ABPickerGroupIdFromObject(info);
                }
                if (!chatId && [sessionMgr respondsToSelector:nameSel]) {
                    id name = ((id (*)(id, SEL, unsigned int))objc_msgSend)(sessionMgr, nameSel, i);
                    chatId = ABPickerGroupIdFromObject(name);
                }
                if (chatId) {
                    [chatIds addObject:chatId];
                }
            }
        }
    }

    // 通讯录里的全部群（含从没打开过会话的群）
    id contactMgr = ABService(@"CContactMgr");
    if (contactMgr) {
        for (NSString *selName in @[ @"getAllContactUserName", @"getAllContactUserNameFromCache" ]) {
            SEL sel = NSSelectorFromString(selName);
            if ([contactMgr respondsToSelector:sel]) {
                id list = ((id (*)(id, SEL))objc_msgSend)(contactMgr, sel);
                if ([list isKindOfClass:[NSArray class]]) {
                    for (id item in (NSArray *)list) {
                        NSString *chatId = ABPickerGroupIdFromObject(item);
                        if (chatId) {
                            [chatIds addObject:chatId];
                        }
                    }
                }
            }
        }
    }

    SEL contactSel = NSSelectorFromString(@"getContactByName:");
    for (NSString *chatId in chatIds) {
        NSString *name = nil;
        if (contactMgr && [contactMgr respondsToSelector:contactSel]) {
            id contact = ((id (*)(id, SEL, id))objc_msgSend)(contactMgr, contactSel, chatId);
            name = ABGetObject(contact, @"m_nsRemark");
            if (![name isKindOfClass:[NSString class]] || name.length == 0) {
                name = ABGetObject(contact, @"m_nsNickName");
            }
            if ((![name isKindOfClass:[NSString class]] || name.length == 0)) {
                name = ABGetObject(contact, @"chatRoomTopic");
            }
        }
        if (![name isKindOfClass:[NSString class]] || name.length == 0) {
            name = chatId;
        }
        [_groups addObject:@{ @"id": chatId, @"name": name }];
    }

    [_groups sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCompare:b[@"name"]];
    }];
    _filtered = [_groups mutableCopy];
    TFLog(@"[Forward] 群列表：%lu 个（会话+通讯录）", (unsigned long)_groups.count);
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    NSString *keyword = [searchText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (keyword.length == 0) {
        _filtered = [_groups mutableCopy];
    } else {
        _filtered = [NSMutableArray array];
        for (NSDictionary *group in _groups) {
            if ([group[@"name"] rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [group[@"id"] rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [_filtered addObject:group];
            }
        }
    }
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _filtered.count > 0 ? _filtered.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (_groups.count == 0) {
        return nil;
    }
    return [NSString stringWithFormat:@"勾选需要转发的群（共 %lu 个，已选 %lu 个）",
            (unsigned long)_groups.count, (unsigned long)_selected.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return _groups.count > 0 ? @"私聊消息不受此列表影响，可在上一页单独开关。" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"groupCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"groupCell"];
    }
    if (_filtered.count == 0) {
        cell.textLabel.text = _groups.count == 0 ? @"暂无群聊" : @"没有匹配的群";
        cell.detailTextLabel.text = _groups.count == 0 ? @"请先在微信中登录并同步群聊" : @"换一个关键词试试";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *group = _filtered[indexPath.row];
    cell.textLabel.text = group[@"name"];
    cell.detailTextLabel.text = group[@"id"];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.accessoryType = [_selected containsObject:group[@"id"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_filtered.count == 0) {
        return;
    }
    NSString *chatId = _filtered[indexPath.row][@"id"];
    if ([_selected containsObject:chatId]) {
        [_selected removeObject:chatId];
    } else {
        [_selected addObject:chatId];
    }
    [self.tableView reloadData];
}

@end

// 设置页分区
typedef NS_ENUM(NSInteger, APIBlockerSection) {
    APIBlockerSectionMaster      = 0, // 总开关
    APIBlockerSectionInterface   = 1, // 界面（恢复旧版卡包）
    APIBlockerSectionCallKit     = 2, // 语音来电（强制 CallKit）
    APIBlockerSectionChat        = 3, // 聊天显示（屏蔽拍一拍 / 群待办）
    APIBlockerSectionResponse    = 4, // 拦截响应
    APIBlockerSectionBrowser     = 5, // 浏览器
    APIBlockerSectionFileManager = 6, // 文件管理
    APIBlockerSectionForward     = 7, // 消息转发 / 本地发送 API
    APIBlockerSectionURLs        = 8, // 拦截 URL
    APIBlockerSectionCount       = 9,
};

// 二级菜单标题（一级菜单的分类名）
%group ABLogicCapture
%hook BaseMsgContentLogicController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    gABLastLogicController = self;
}
%end

%hook BypMsgContentLogicController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    gABLastLogicController = self;
}
%end
%end

static NSString *ABForwardSectionTitle(NSInteger section) {
    switch (section) {
        case APIBlockerSectionInterface:   return @"界面";
        case APIBlockerSectionCallKit:     return @"语音来电";
        case APIBlockerSectionChat:        return @"聊天显示";
        case APIBlockerSectionResponse:    return @"拦截响应";
        case APIBlockerSectionBrowser:     return @"浏览器";
        case APIBlockerSectionFileManager: return @"文件管理";
        case APIBlockerSectionForward:     return @"消息转发 / 本地 API";
        case APIBlockerSectionURLs:        return @"拦截 URL";
        default:                           return @"请求拦截";
    }
}

// 设置页：微信->我->插件->请求拦截
@interface APIBlockerSettingsViewController : UITableViewController
- (instancetype)initWithDisplaySection:(NSInteger)section;
@end

@implementation APIBlockerSettingsViewController {
    NSMutableArray *_urls;
    NSInteger _displaySection; // <0 表示一级菜单；>=0 只显示该分区
}
static char kABNavTranslucentKey;
static UIColor *ABCardColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:28.0/255.0 alpha:1.0];
        }
        return [UIColor whiteColor];
    }];
}

static void ABApplyCardStyle(UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath) {
    if (!cell || !indexPath) return;

    NSInteger rowCount = [tableView numberOfRowsInSection:indexPath.section];
    BOOL isFirst = (indexPath.row == 0);
    BOOL isLast = (indexPath.row == rowCount - 1);
    CGFloat radius = 12.0;
    CGFloat inset = 16.0;

    CACornerMask mask = 0;
    if (isFirst) mask |= kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    if (isLast)  mask |= kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;

    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = ABCardColor();
    cell.contentView.layer.cornerRadius = radius;
    if (@available(iOS 11.0, *)) {
        cell.contentView.layer.maskedCorners = mask;
        cell.contentView.layer.cornerCurve = kCACornerCurveContinuous;
    }
    cell.contentView.layer.masksToBounds = YES;

    UIView *selected = [[UIView alloc] initWithFrame:cell.contentView.bounds];
    selected.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    selected.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.12];
    selected.layer.cornerRadius = radius;
    if (@available(iOS 11.0, *)) {
        selected.layer.maskedCorners = mask;
        selected.layer.cornerCurve = kCACornerCurveContinuous;
    }
    selected.layer.masksToBounds = YES;
    cell.selectedBackgroundView = selected;

    cell.separatorInset = UIEdgeInsetsMake(0, inset, 0, inset);
    cell.preservesSuperviewLayoutMargins = NO;
    cell.layoutMargins = UIEdgeInsetsMake(0, 28, 0, 28);
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        _displaySection = -1;
    }
    return self;
}

- (instancetype)initWithDisplaySection:(NSInteger)section {
    self = [self init];
    if (self) {
        _displaySection = section;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _displaySection >= 0 ? ABForwardSectionTitle(_displaySection) : @"请求拦截";
    // 右上角“圆圈感叹号”：点击弹出全部设置说明
    UIImage *infoIcon = [UIImage systemImageNamed:@"info.circle"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:infoIcon style:UIBarButtonItemStylePlain target:self action:@selector(ABShowHelp)];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:kURLsKey];
    if (stored == nil) {
        _urls = [DefaultURLs() mutableCopy];
        [defaults setObject:_urls forKey:kURLsKey];
    } else if ([stored isKindOfClass:[NSArray class]]) {
        _urls = [stored mutableCopy];
        if (IsLegacyDefaultList(_urls)) {
            _urls = [DefaultURLs() mutableCopy];
            [defaults setObject:_urls forKey:kURLsKey];
        }
    } else {
        _urls = [NSMutableArray array];
    }
    [self.tableView reloadData];

    // 顶部内容跟随系统安全区：滚动时列表内容被导航栏遮挡、不穿透状态栏，
    // 首屏也从导航栏下方开始（总开关不会跑到最上面）
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;

    // 尽早应用导航栏与页面配色（push 动画一开始就生效，避免进入时顶部先闪默认色再变）
    [self ABApplyNavStyle];
    // 页面背景动态色（日间 238,238,238 / 夜间 24,24,24，参照参考图），顶部区域先铺好
    self.tableView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:24.0/255.0 green:24.0/255.0 blue:24.0/255.0 alpha:1.0];
        }
        return [UIColor colorWithRed:238.0/255.0 green:238.0/255.0 blue:238.0/255.0 alpha:1.0];
    }];
    self.view.backgroundColor = self.tableView.backgroundColor;
}

// 应用导航栏配色（不透明遮挡滚动内容；日间 238 / 夜间 17，参照参考图），push 动画与 appear 都调用
// 用 UINavigationBarAppearance 而非改 translucent，避免在 push 转场动画中触发导航栏大幅重绘（顶部错位黑条）
- (void)ABApplyNavStyle {
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (!bar) return;
    UIColor *navBg = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:17.0/255.0 green:17.0/255.0 blue:17.0/255.0 alpha:1.0]; // (17,17,17)
        }
        return [UIColor colorWithRed:238.0/255.0 green:238.0/255.0 blue:238.0/255.0 alpha:1.0]; // (238,238,238)
    }];
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *app = [[UINavigationBarAppearance alloc] init];
        [app configureWithOpaqueBackground];
        app.backgroundColor = navBg;
        app.shadowColor = [UIColor clearColor];
        bar.standardAppearance = app;
        bar.scrollEdgeAppearance = app;
        if (bar.compactAppearance) bar.compactAppearance = app;
        // 兼容低版本设置 barTintColor（部分微信容器仍读取 barTintColor）
        bar.barTintColor = navBg;
    } else {
        if (!objc_getAssociatedObject(self, &kABNavTranslucentKey)) {
            objc_setAssociatedObject(self, &kABNavTranslucentKey, @(bar.translucent), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        bar.translucent = NO;
        bar.barTintColor = navBg;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self ABApplyNavStyle];
    [self.tableView reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    // 还原导航栏，避免影响微信其它页面
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (bar) {
        NSNumber *orig = objc_getAssociatedObject(self, &kABNavTranslucentKey);
        if (orig) bar.translucent = orig.boolValue;
        if (@available(iOS 13.0, *)) {
            // 还原为默认透明外观（微信自身的导航栏会再覆盖），避免我们的配色残留
            UINavigationBarAppearance *def = [[UINavigationBarAppearance alloc] init];
            [def configureWithTransparentBackground];
            bar.standardAppearance = def;
            bar.scrollEdgeAppearance = def;
        }
        bar.barTintColor = nil;
    }
    [super viewWillDisappear:animated];
}

- (NSArray<NSArray<NSNumber *> *> *)ab_groups {
    NSMutableArray *groups = [NSMutableArray array];
    if (_displaySection < 0) {
        // 一级菜单：仿 WCPulse 的分组组织方式，只做 UI 分组，逻辑行号保持不变
        [groups addObject:@[@0]];                 // 总开关
        [groups addObject:@[@1, @2, @3, @4]];      // 功能
        [groups addObject:@[@5, @6]];              // 工具
        [groups addObject:@[@7, @8]];              // 数据与规则
        return groups;
    }
    switch (_displaySection) {
        case APIBlockerSectionMaster:
            return @[@[@0]];
        case APIBlockerSectionInterface:
            return @[
                @[@0, @1],               // 卡包
                @[@2, @3],               // 支付与订阅号
                @[@4, @5, @6, @7, @8, @9], // 已读
                @[@10, @11, @12, @13, @14, @15], // 底栏与界面
            ];
        case APIBlockerSectionCallKit:
            return @[@[@0, @1, @2, @3]];  // 系统来电
        case APIBlockerSectionChat:
            return @[@[@0, @1]];          // 群聊显示
        case APIBlockerSectionResponse:
            return @[@[@0, @1]];          // 拦截响应
        case APIBlockerSectionBrowser:
            return @[@[@0]];              // 浏览器
        case APIBlockerSectionFileManager:
            return @[@[@0, @1, @2]];      // 文件与日志
        case APIBlockerSectionForward:
            return @[
                @[@0, @1, @2, @3],        // 消息转发
                @[@4, @5, @6, @7, @8, @9], // 本地 API
                @[@10],                   // 后台
            ];
        case APIBlockerSectionURLs: {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSInteger i = 0; i <= _urls.count; i++) {
                [rows addObject:@(i)];
            }
            return @[rows];
        }
        default:
            return @[@[]];
    }
}

- (NSArray<NSString *> *)ab_groupTitles {
    if (_displaySection < 0) {
        return @[@"总开关", @"功能", @"工具", @"数据与规则"];
    }
    switch (_displaySection) {
        case APIBlockerSectionMaster:      return @[@"总开关"];
        case APIBlockerSectionInterface:   return @[@"卡包", @"支付与订阅号", @"已读", @"底栏与界面"];
        case APIBlockerSectionCallKit:     return @[@"系统来电"];
        case APIBlockerSectionChat:        return @[@"群聊显示"];
        case APIBlockerSectionResponse:    return @[@"拦截响应"];
        case APIBlockerSectionBrowser:     return @[@"浏览器"];
        case APIBlockerSectionFileManager: return @[@"文件与日志"];
        case APIBlockerSectionForward:     return @[@"消息转发", @"本地 API", @"后台"];
        case APIBlockerSectionURLs:        return @[@"规则列表"];
        default:                           return @[@""];
    }
}

- (NSInteger)ab_logicalRowForIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSArray<NSNumber *> *> *groups = [self ab_groups];
    if (indexPath.section < 0 || indexPath.section >= (NSInteger)groups.count) {
        return 0;
    }
    NSArray<NSNumber *> *rows = groups[indexPath.section];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)rows.count) {
        return 0;
    }
    return rows[indexPath.row].integerValue;
}

- (NSIndexPath *)ab_visibleIndexPathForLogicalRow:(NSInteger)logicalRow {
    NSArray<NSArray<NSNumber *> *> *groups = [self ab_groups];
    for (NSInteger section = 0; section < (NSInteger)groups.count; section++) {
        NSArray<NSNumber *> *rows = groups[section];
        for (NSInteger row = 0; row < (NSInteger)rows.count; row++) {
            if (rows[row].integerValue == logicalRow) {
                return [NSIndexPath indexPathForRow:row inSection:section];
            }
        }
    }
    return nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return [self ab_groups].count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray<NSArray<NSNumber *> *> *groups = [self ab_groups];
    if (section < 0 || section >= (NSInteger)groups.count) {
        return 0;
    }
    return groups[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSArray<NSString *> *titles = [self ab_groupTitles];
    if (section < 0 || section >= (NSInteger)titles.count) {
        return nil;
    }
    return titles[section];
}

// 全部设置说明（原来显示在各分区 footer，现集中到右上角感叹号弹出）
static NSString *ABPluginHelpText(void) {
    return @"【总开关】\n关闭后插件不再拦截任何请求\n\n"
    @"【界面】\n"
    @"· 旧版卡包：微信把“卡包”热更新成了“小店与卡包”，开启后点击卡包回到旧版卡包首页（优惠券/会员卡/交通卡/票证）。\n"
    @"· 卡包页面实现：旧版卡包首页各入口实际跳转的页面类。\n"
    @"· 付款页余额：收付款码页在“零钱”后显示真实剩余金额。\n"
    @"· 屏蔽服务号文章：订阅号消息流下方资讯文章（该页为 Flutter 渲染，原生屏蔽可能不生效）。\n"
    @"· 长按标题已读：公众号列表页长按/双击标题，一键把全部公众号未读标记为已读。\n"
    @"· 已读提示：一键已读完成后弹出提示并轻微震动（公众号与主页共用）。\n"
    @"· 提示文本：自定义已读完成提示的文字。\n"
    @"· 进入自动已读：进入公众号列表页自动一键已读；2 小时内重复进入不再自动已读，手动长按/双击不受限。\n"
    @"· 主页一键已读：消息列表页底部“微信”tab 向上拖动，已读全部会话并清除所有数字（底部气泡与各消息行气泡同步爆炸）。\n"
    @"· 上滑灵敏度：触发主页一键已读所需的上滑速度阈值，50~800，越小越灵敏。\n\n"
    @"【语音来电】\n"
    @"微信在部分设备上用 LiveCommunicationKit（App 内顶部浮窗）接来电。开启“强制系统来电”后，语音/视频来电在系统电话界面显示。“微信音频/微信视频”那行来自 CXProviderConfiguration.localizedName，图标来自 iconTemplateImageData。\n\n"
    @"【聊天显示】\n"
    @"全局屏蔽只对群聊生效：群里的拍一拍/群待办不再显示，私聊不受影响。单群可用“聊天信息 → 插件”里的“显示拍一拍/显示群待办”单独放开，单群设置优先于全局。\n\n"
    @"【拦截响应】\n"
    @"对所有命中的请求生效：选择响应格式即决定 Content-Type；“空响应”返回 200 且不发送任何内容。\n\n"
    @"【浏览器】\n"
    @"开启后内置浏览器标题下不再显示网址（恢复旧版样式）。\n\n"
    @"【文件管理】\n"
    @"浏览当前 App 数据目录，支持编辑 plist 文件。\n\n"
    @"【消息转发 / 本地 API】\n"
    @"· Webhook 地址：收到的消息会以 JSON POST 到该地址；未填写时不转发。\n"
    @"· 转发私聊消息：默认开启。群聊消息只在“群聊白名单”勾选的群里转发。\n"
    @"· 群聊白名单：从当前账号已有群聊（会话 + 通讯录）中勾选，未勾选的群不转发；列表太长可用搜索。\n"
    @"· 本地 API：在 Wi-Fi 下监听本机 IP，外部 POST /send 即可用当前微信号发消息；支持可选密钥校验。\n"
    @"· 本机 IP：默认自动取 Wi-Fi 地址（en0）；若显示不对或关闭 Wi-Fi 后想改地址，可在“本机 IP”一行手动指定。\n"
    @"· 请求体：{\"to\":\"wxid_xxx 或 123@chatroom\",\"type\":\"text/image/video/voice/sticker\",\"content\":\"文字\",\"url\":\"媒体地址\"}。\n"
    @"  媒体会先下载缓存到 Documents/TweakfixMedia；按后缀分流：.gif 走表情（动图），其余静态图走图片消息；语音走语音消息；视频以 mp4 文件消息发送（可在微信内点开播放）。\n\n"
    @"【拦截 URL】\n"
    @"不含 * 时按前缀匹配（请求地址以该 URL 开头）；含 * 时按泛匹配，例如 https://*.tweak.com 或 https://a.baidu.com/api=*。左滑单条规则可禁用/启用/删除，禁用的规则保留但不参与拦截。\n\n"
    @"";
}

- (void)ABShowHelp {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"设置说明"
                                                                message:ABPluginHelpText()
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return nil; // 详细说明已移动到右上角“感叹号”按钮
}

// 响应内容预览（换行压平 + 截断）
- (NSString *)previewForResponseBody:(NSString *)body {
    NSString *flat = [body stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    flat = [flat stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
    if (flat.length > 60) {
        flat = [[flat substringToIndex:60] stringByAppendingString:@"…"];
    }
    return flat.length > 0 ? flat : @"（空）";
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    ABApplyCardStyle(tableView, cell, indexPath);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger row = [self ab_logicalRowForIndexPath:indexPath];
    if (_displaySection < 0 && row >= 1) {
        // 一级菜单：分类入口（与总开关同级）
        UITableViewCell *nav = [tableView dequeueReusableCellWithIdentifier:@"abMenuCell"];
        if (!nav) {
            nav = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"abMenuCell"];
        }
        nav.preservesSuperviewLayoutMargins = NO;
        nav.layoutMargins = UIEdgeInsetsMake(0, 28, 0, 28);
        static NSString *const names[8] = { @"界面", @"语音来电", @"聊天显示", @"拦截响应",
                                            @"浏览器", @"文件管理", @"消息转发 / 本地 API", @"拦截 URL" };
        static NSString *const subs[8]  = { @"卡包 / 已读 / 底栏", @"强制系统来电", @"拍一拍 / 群待办", @"响应格式与内容",
                                            @"隐藏内置浏览器网址", @"目录浏览与日志", @"Webhook、白名单、/send", @"前缀 / 泛匹配规则" };
        NSInteger idx = MIN(MAX(row - 1, 0), 7);
        nav.textLabel.text = names[idx];
        nav.detailTextLabel.text = subs[idx];
        nav.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        nav.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        nav.selectionStyle = UITableViewCellSelectionStyleDefault;
        nav.accessoryView = nil;
        return nav;
    }
    NSInteger sec = _displaySection >= 0 ? _displaySection : (_displaySection < 0 ? row : indexPath.section);
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }
    // 内容左右向中间缩进（参照参考图：cell 内容左起点约 30pt）
    cell.preservesSuperviewLayoutMargins = NO;
    cell.layoutMargins = UIEdgeInsetsMake(0, 28, 0, 28);
    if (sec == APIBlockerSectionMaster) {
        cell.textLabel.text = @"总开关";
        cell.detailTextLabel.text = nil;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = APIBlockerEnabled();
        [sw addTarget:self action:@selector(masterSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (sec == APIBlockerSectionInterface) {
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (row == 0) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"旧版卡包";
            cell.detailTextLabel.text = @"恢复 优惠券/会员卡/交通卡/票证 首页";
            cell.textLabel.textColor = UIColor.labelColor;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = OldCardPageEnabled();
            [sw addTarget:self action:@selector(oldCardPageSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 1) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"卡包页面实现";
            cell.textLabel.textColor = UIColor.labelColor;
            cell.detailTextLabel.text = ConfiguredOldCardPageClass();
        } else if (row == 2) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"付款页余额";
            cell.detailTextLabel.text = @"收付款码页显示 剩余X元（零钱）";
            cell.textLabel.textColor = UIColor.labelColor;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = ShowPayBalanceEnabled();
            [sw addTarget:self action:@selector(payBalanceSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 3) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"屏蔽服务号文章";
            cell.detailTextLabel.text = @"服务号收纳页只留通知";
            cell.textLabel.textColor = UIColor.labelColor;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = BlockServiceArticleEnabled();
            [sw addTarget:self action:@selector(blockServiceArticleSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 4) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"长按标题已读";
            cell.detailTextLabel.text = @"公众号列表页长按/双击标题，一键标记全部未读";
            cell.textLabel.textColor = UIColor.labelColor;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = MarkBrandReadEnabled();
            [sw addTarget:self action:@selector(markBrandReadSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 5) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"已读提示";
            cell.detailTextLabel.text = @"一键已读后提示+轻微震动";
            cell.textLabel.textColor = UIColor.labelColor;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = MarkBrandReadTipEnabled();
            [sw addTarget:self action:@selector(markBrandReadTipSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 6) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"提示文本";
            cell.textLabel.textColor = UIColor.labelColor;
            cell.detailTextLabel.text = MarkBrandReadTipText();
        } else if (row == 7) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"进入自动已读";
            cell.detailTextLabel.text = @"进入公众号列表页自动标记全部未读（2小时内不重复）";
            cell.textLabel.textColor = UIColor.labelColor;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = AutoMarkBrandReadEnabled();
            [sw addTarget:self action:@selector(autoMarkBrandReadSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 8) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"主页一键已读";
            cell.detailTextLabel.text = @"“微信”tab 上滑，已读全部并清除数字";
            cell.textLabel.textColor = UIColor.labelColor;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = MainReadEnabled();
            [sw addTarget:self action:@selector(mainReadSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 9) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"上滑灵敏度";
            cell.textLabel.textColor = UIColor.labelColor;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f（50~800，越小越灵敏）", MainReadSpeedThreshold()];
        } else if (row == 10) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"原生液态底栏（iOS26）";
            cell.detailTextLabel.text = @"底栏回归系统液态玻璃（需重启生效）";
            cell.textLabel.textColor = UIColor.labelColor;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = LiquidTabBarEnabled();
            [sw addTarget:self action:@selector(liquidTabBarSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 11) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"玻璃效果强度";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld（0=系统默认，越大越模糊）", (long)LiquidGlassIntensity()];
            cell.textLabel.textColor = UIColor.labelColor;
            UISlider *sl = [[UISlider alloc] init];
            sl.maximumValue = 100;
            sl.minimumValue = 0;
            sl.value = LiquidGlassIntensity();
            [sl addTarget:self action:@selector(liquidGlassIntensityChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sl;
        } else if (row == 12) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"滚动收纳胶囊";
            cell.detailTextLabel.text = @"下滑时底栏收纳成胶囊，上滑恢复";
            cell.textLabel.textColor = UIColor.labelColor;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = LiquidScrollHideEnabled();
            [sw addTarget:self action:@selector(liquidScrollHideSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 13) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"顶部去液态";
            cell.detailTextLabel.text = @"去掉顶部按钮的液态玻璃包裹（需重启生效）";
            cell.textLabel.textColor = UIColor.labelColor;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = TopLiquidEnabled();
            [sw addTarget:self action:@selector(topLiquidSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 14) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"底栏下沉";
            cell.detailTextLabel.text = @"iOS27 隐藏 home bar 后下移底栏，填补底部留白";
            cell.textLabel.textColor = UIColor.labelColor;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = TabBarOffsetEnabled();
            [sw addTarget:self action:@selector(tabBarOffsetSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 15) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"下沉距离";
            cell.textLabel.textColor = UIColor.labelColor;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld pt（0~80）", (long)TabBarOffsetValue()];
        }
    } else if (sec == APIBlockerSectionCallKit) {
        cell.textLabel.textColor = UIColor.labelColor;
        cell.accessoryView = nil;
        if (row == 0) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"强制系统来电（CallKit）";
            cell.detailTextLabel.text = @"来电显示在系统电话界面";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = ForceCallKitEnabled();
            [sw addTarget:self action:@selector(forceCallKitSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 1) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"隐藏来电名称";
            cell.detailTextLabel.text = @"隐藏“微信音频 / 微信视频”那行";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = CallKitHideNameEnabled();
            [sw addTarget:self action:@selector(callKitHideNameSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 2) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"自定义来电名称";
            cell.detailTextLabel.text = CallKitCustomName() ?: @"未设置（点击修改，留空即取消）";
        } else {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"隐藏来电图标";
            cell.detailTextLabel.text = @"隐藏锁屏来电上的微信图标";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = CallKitHideIconEnabled();
            [sw addTarget:self action:@selector(callKitHideIconSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
    } else if (sec == APIBlockerSectionChat) {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.textLabel.textColor = UIColor.labelColor;
        UISwitch *sw = [[UISwitch alloc] init];
        if (row == 0) {
            cell.textLabel.text = @"全局屏蔽拍一拍";
            cell.detailTextLabel.text = @"只对所有群聊生效，私聊不受影响";
            sw.on = GlobalBlockPat();
            [sw addTarget:self action:@selector(blockPatSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        } else {
            cell.textLabel.text = @"全局屏蔽群待办";
            cell.detailTextLabel.text = @"所有群聊都不显示群待办";
            sw.on = GlobalBlockGroupUndone();
            [sw addTarget:self action:@selector(blockGroupUndoneSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        }
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (sec == APIBlockerSectionResponse) {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.textColor = UIColor.labelColor;
        if (row == 0) {
            cell.textLabel.text = @"响应格式";
            cell.detailTextLabel.text = ResponseTypeLabel(ConfiguredResponseType());
        } else {
            cell.textLabel.text = @"响应内容";
            cell.detailTextLabel.text = ResponseIsEmpty() ? @"空响应：不发送任何内容"
                                                          : [self previewForResponseBody:ConfiguredResponseBody()];
        }
    } else if (sec == APIBlockerSectionBrowser) {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.textLabel.text = @"隐藏网址";
        cell.detailTextLabel.text = @"标题下不显示网址（恢复旧版）";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = BrowserURLHideEnabled();
        [sw addTarget:self action:@selector(browserURLSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (sec == APIBlockerSectionFileManager) {
        if (row == 0) {
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.textColor = UIColor.labelColor;
            cell.textLabel.text = @"文件管理";
            cell.detailTextLabel.text = @"浏览数据目录 / 编辑 plist / 查看文本";
        } else if (row == 1) {
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.textColor = UIColor.labelColor;
            cell.textLabel.text = @"记录日志";
            cell.detailTextLabel.text = @"排查问题用，默认关闭";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = LogEnabled();
            [sw addTarget:self action:@selector(logSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.textColor = UIColor.labelColor;
            cell.textLabel.text = @"查看日志";
            cell.detailTextLabel.text = @"Documents/Tweakfix.log";
        }
    } else if (sec == APIBlockerSectionForward) {
        cell.accessoryView = nil;
        cell.textLabel.textColor = UIColor.labelColor;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (row == 0) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"消息转发";
            cell.detailTextLabel.text = @"收到消息后 POST 到外部 Webhook";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = ForwardEnabled();
            [sw addTarget:self action:@selector(forwardSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 1) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"Webhook 地址";
            NSString *url = ForwardWebhook();
            cell.detailTextLabel.text = url.length > 0 ? url : @"未设置（点击填写）";
        } else if (row == 2) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"转发私聊消息";
            cell.detailTextLabel.text = @"默认开启；群聊仅转发白名单";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = ForwardPrivateEnabled();
            [sw addTarget:self action:@selector(forwardPrivateSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 3) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"群聊白名单";
            NSUInteger count = ForwardGroupWhitelist().count;
            cell.detailTextLabel.text = count > 0 ? [NSString stringWithFormat:@"已选 %lu 个群", (unsigned long)count] : @"未选择（点击勾选）";
        } else if (row == 4) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"本地 API 服务";
            cell.detailTextLabel.text = @"Wi-Fi 下用本机 IP 访问（POST /send）";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = LocalAPIEnabled();
            [sw addTarget:self action:@selector(localAPISwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else if (row == 5) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"API 端口";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)LocalAPIPort()];
        } else if (row == 6) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"API 密钥";
            cell.detailTextLabel.text = LocalAPIToken().length > 0 ? @"已设置（请求需带 token）" : @"未设置（局域网均可访问）";
        } else if (row == 7) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"API 地址";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@/send（点击复制）", ABLocalAPIAddress()];
        } else if (row == 8) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"本机 IP";
            NSString *manualIP = LocalAPIIPManual();
            NSString *autoIP = ABDetectWiFiIPAddress();
            if (manualIP.length > 0) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"手动：%@", manualIP];
            } else if (autoIP.length > 0) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"自动：%@", autoIP];
            } else {
                cell.detailTextLabel.text = @"未检测到 Wi-Fi，点击手动指定";
            }
        } else if (row == 9) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"消息时间限制";
            NSInteger minutes = ForwardMaxMinutes();
            cell.detailTextLabel.text = minutes > 0 ? [NSString stringWithFormat:@"只转发 %ld 分钟内的消息", (long)minutes] : @"不限制时间";
        } else {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"微信后台常驻";
            cell.detailTextLabel.text = @"开启后尽量保持后台不被系统挂起";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = KeepAliveEnabled();
            [sw addTarget:self action:@selector(keepAliveSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        if (row < _urls.count) {
            NSString *pattern = _urls[row];
            BOOL disabled = IsURLDisabled(pattern);
            cell.textLabel.text = pattern;
            cell.textLabel.textColor = disabled ? UIColor.secondaryLabelColor : UIColor.labelColor;
            cell.detailTextLabel.text = disabled ? @"已禁用（左滑可启用）" : @"点击修改（左滑可禁用/删除）";
        } else {
            cell.textLabel.text = @"＋ 添加 URL";
            cell.detailTextLabel.text = nil;
            cell.textLabel.textColor = UIColor.systemBlueColor;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.navigationController.topViewController != self) {
        return; // 防止快速连点导致重复 push
    }
    NSInteger row = [self ab_logicalRowForIndexPath:indexPath];
    if (_displaySection < 0 && row >= 1) {
        APIBlockerSettingsViewController *subVC = [[APIBlockerSettingsViewController alloc] initWithDisplaySection:row];
        [self.navigationController pushViewController:subVC animated:YES];
        return;
    }
    NSInteger sec = _displaySection >= 0 ? _displaySection : (_displaySection < 0 ? row : indexPath.section);
    if (sec == APIBlockerSectionResponse) {
        if (row == 0) {
            [self chooseResponseType];
        } else {
            APIBlockerResponseBodyViewController *editor = [[APIBlockerResponseBodyViewController alloc] init];
            [self.navigationController pushViewController:editor animated:YES];
        }
        return;
    }
    if (sec == APIBlockerSectionInterface && row == 1) {
        [self chooseOldCardPageClass];
        return;
    }
    if (sec == APIBlockerSectionInterface && row == 6) {
        [self editMarkBrandReadTipText];
        return;
    }
    if (sec == APIBlockerSectionInterface && row == 9) {
        [self editMainReadSpeed];
        return;
    }
    if (sec == APIBlockerSectionInterface && row == 15) {
        [self editTabBarOffset];
        return;
    }
    if (sec == APIBlockerSectionCallKit && row == 2) {
        [self editCallKitCustomName];
        return;
    }
    if (sec == APIBlockerSectionFileManager) {
        if (row == 0) {
            APIBlockerFileBrowserViewController *browser = [[APIBlockerFileBrowserViewController alloc] initWithPath:NSHomeDirectory()];
            [self.navigationController pushViewController:browser animated:YES];
        } else if (row == 2) {
            NSString *logPath = TFLogFilePath();
            if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
                [[NSString stringWithFormat:@"[启动] 日志文件尚未生成，运行一次相关功能后就有了\n"] writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }
            APIBlockerPlistEditorViewController *viewer = [[APIBlockerPlistEditorViewController alloc] initWithPath:logPath plainText:YES];
            [self.navigationController pushViewController:viewer animated:YES];
        }
        return;
    }
    if (sec == APIBlockerSectionForward) {
        if (row == 1) {
            [self editForwardWebhook];
        } else if (row == 3) {
            APIBlockerGroupPickerViewController *picker = [[APIBlockerGroupPickerViewController alloc] init];
            [self.navigationController pushViewController:picker animated:YES];
        } else if (row == 5) {
            [self editLocalAPIPort];
        } else if (row == 6) {
            [self editLocalAPIToken];
        } else if (row == 7) {
            UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
            NSString *address = ABLocalAPIAddress();
            if ([address containsString:@"未连接Wi-Fi"]) {
                [self editLocalAPIIP];
            } else {
                pasteboard.string = address;
                ABShowToast(@"API 地址已复制");
            }
        } else if (row == 8) {
            [self editLocalAPIIP];
        } else if (row == 9) {
            [self editForwardMaxMinutes];
        }
        return;
    }
    if (sec != APIBlockerSectionURLs) {
        return;
    }
    BOOL isAdd = (row >= _urls.count);
    NSString *current = isAdd ? @"" : _urls[row];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:isAdd ? @"添加拦截 URL" : @"修改拦截 URL"
                                                                  message:@"不含 * 时按前缀匹配；用 * 可泛匹配，例如 https://*.tweak.com 或 https://a.baidu.com/api=*"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = current;
        textField.keyboardType = UIKeyboardTypeURL;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length == 0) {
            return;
        }
        if (isAdd) {
            [_urls addObject:text];
        } else {
            NSString *oldPattern = _urls[row];
            BOOL wasDisabled = IsURLDisabled(oldPattern);
            _urls[row] = text;
            if (![oldPattern isEqualToString:text]) {
                SetURLDisabled(oldPattern, NO);
                if (wasDisabled) {
                    SetURLDisabled(text, YES);
                }
            }
        }
        [[NSUserDefaults standardUserDefaults] setObject:_urls forKey:kURLsKey];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger row = [self ab_logicalRowForIndexPath:indexPath];
    NSInteger sec = _displaySection >= 0 ? _displaySection : (_displaySection < 0 ? row : indexPath.section);
    return sec == APIBlockerSectionURLs && row < _urls.count;
}

// 左滑：禁用/启用 + 删除
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger row = [self ab_logicalRowForIndexPath:indexPath];
    NSInteger sec = _displaySection >= 0 ? _displaySection : (_displaySection < 0 ? row : indexPath.section);
    if (sec != APIBlockerSectionURLs || row >= _urls.count) {
        return nil;
    }
    NSString *pattern = _urls[row];
    BOOL disabled = IsURLDisabled(pattern);

    UIContextualAction *toggle = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                        title:(disabled ? @"启用" : @"禁用")
                                                                      handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        SetURLDisabled(pattern, !disabled);
        TFLog(@"[APIBlocker] 规则“%@”%@", pattern, disabled ? @"已启用" : @"已禁用");
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        completionHandler(YES);
    }];
    toggle.backgroundColor = disabled ? UIColor.systemGreenColor : UIColor.systemGrayColor;

    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                        title:@"删除"
                                                                      handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        SetURLDisabled(pattern, NO);
        if (row < _urls.count) {
            [_urls removeObjectAtIndex:row];
        }
        [[NSUserDefaults standardUserDefaults] setObject:_urls forKey:kURLsKey];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        completionHandler(YES);
    }];

    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[remove, toggle]];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger row = [self ab_logicalRowForIndexPath:indexPath];
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        if (row < _urls.count) {
            SetURLDisabled(_urls[row], NO);
        }
        [_urls removeObjectAtIndex:row];
        [[NSUserDefaults standardUserDefaults] setObject:_urls forKey:kURLsKey];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

- (void)chooseOldCardPageClass {
    NSString *current = ConfiguredOldCardPageClass();
    NSArray<NSArray<NSString *> *> *options = @[
        @[ @"自动", @"自动（卡包首页 → 兼容页）" ],
        @[ @"WCMktCardHomeViewController", @"卡包首页 WCMktCardHome" ],
        @[ @"WCCardPackageViewController", @"兼容页 WCCardPackage" ],
    ];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"旧版页面实现"
                                                                   message:@"自动模式进的不是“优惠券/会员卡/交通卡/票证”首页时，换另一个试试"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray<NSString *> *option in options) {
        NSString *value = option[0];
        NSString *label = option[1];
        if ([value isEqualToString:current]) {
            label = [label stringByAppendingString:@"   ✓"];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            if ([value isEqualToString:@"自动"]) {
                [defaults removeObjectForKey:kOldCardPageClassKey];
            } else {
                [defaults setObject:value forKey:kOldCardPageClassKey];
            }
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    NSIndexPath *anchorPath = [self ab_visibleIndexPathForLogicalRow:1] ?: [NSIndexPath indexPathForRow:0 inSection:0];
    UITableViewCell *anchor = [self.tableView cellForRowAtIndexPath:anchorPath];
    sheet.popoverPresentationController.sourceView = anchor ?: self.view;
    sheet.popoverPresentationController.sourceRect = anchor ? anchor.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)chooseResponseType {
    NSString *current = ConfiguredResponseType();
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"响应格式"
                                                                   message:@"该格式同时作为 Content-Type 返回"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *key in ResponseTypeKeys()) {
        NSString *label = ResponseTypeLabel(key);
        if ([key isEqualToString:current]) {
            label = [label stringByAppendingString:@"   ✓"];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [[NSUserDefaults standardUserDefaults] setObject:key forKey:kResponseTypeKey];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    NSIndexPath *anchorPath = [self ab_visibleIndexPathForLogicalRow:0] ?: [NSIndexPath indexPathForRow:0 inSection:0];
    UITableViewCell *anchor = [self.tableView cellForRowAtIndexPath:anchorPath];
    sheet.popoverPresentationController.sourceView = anchor ?: self.view;
    sheet.popoverPresentationController.sourceRect = anchor ? anchor.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)masterSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kSwitchKey];
}

- (void)browserURLSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kHideBrowserURLKey];
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        ScanNavBarsInView(window, sender.on);
    }
}

- (void)oldCardPageSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kOldCardPageKey];
    TFLog(@"[APIBlocker] 恢复旧版卡包：%@", sender.on ? @"开启" : @"关闭");
}

- (void)payBalanceSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kShowPayBalanceKey];
    TFLog(@"[APIBlocker] 付款页显示余额：%@", sender.on ? @"开启" : @"关闭");
}

- (void)blockServiceArticleSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kBlockServiceArticleKey];
    TFLog(@"[APIBlocker] 屏蔽服务号文章：%@", sender.on ? @"开启" : @"关闭");
}

- (void)markBrandReadSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kMarkBrandReadKey];
    TFLog(@"[APIBlocker] 长按公众号标题已读：%@", sender.on ? @"开启" : @"关闭");
}

- (void)markBrandReadTipSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kMarkBrandReadTipKey];
    TFLog(@"[APIBlocker] 已读完成提示：%@", sender.on ? @"开启" : @"关闭");
}

- (void)autoMarkBrandReadSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kAutoMarkBrandReadKey];
    TFLog(@"[APIBlocker] 进入页面自动已读：%@", sender.on ? @"开启" : @"关闭");
}

- (void)mainReadSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kMainReadKey];
    TFLog(@"[APIBlocker] 主页消息一键已读：%@", sender.on ? @"开启" : @"关闭");
}

- (void)editMarkBrandReadTipText {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"自定义提示文本"
                                                                   message:@"一键已读完成后弹出的提示内容（留空恢复默认）"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = MarkBrandReadTipText();
        textField.placeholder = @"已全部标记为已读";
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (text.length > 0) {
            [defaults setObject:text forKey:kMarkBrandReadTipTextKey];
        } else {
            [defaults removeObjectForKey:kMarkBrandReadTipTextKey];
        }
        TFLog(@"[APIBlocker] 自定义提示文本：%@", text.length > 0 ? text : @"（已清空）");
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editMainReadSpeed {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"上滑触发阈值"
        message:@"向上滑动的速度达到该值即触发已读（50~800，越小越灵敏，默认 120）"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = [NSString stringWithFormat:@"%.0f", MainReadSpeedThreshold()];
        textField.placeholder = @"默认 120";
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        float v = [alert.textFields.firstObject.text floatValue];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (v >= 50 && v <= 800) {
            [defaults setFloat:v forKey:kMainReadSpeedKey];
        } else {
            [defaults removeObjectForKey:kMainReadSpeedKey];
        }
        TFLog(@"[APIBlocker] 上滑触发阈值：%.0f", MainReadSpeedThreshold());
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)liquidTabBarSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kLiquidTabBarKey];
    TFLog(@"[APIBlocker] 原生液态底栏（iOS26）：%@", sender.on ? @"开启" : @"关闭");
}

- (void)liquidScrollHideSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kLiquidScrollHideKey];
    TFLog(@"[APIBlocker] 滚动收纳胶囊：%@", sender.on ? @"开启" : @"关闭");
}

- (void)liquidGlassIntensityChanged:(UISlider *)sender {
    NSInteger v = (NSInteger)lround(sender.value);
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:kLiquidGlassIntensityKey];
    TFLog(@"[APIBlocker] 玻璃效果强度：%ld", (long)v);
    [self.tableView reloadData];
}

- (void)topLiquidSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kTopLiquidKey];
    TFLog(@"[APIBlocker] 顶部去液态：%@", sender.on ? @"开启" : @"关闭");
}

- (void)tabBarOffsetSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kTabBarOffsetKey];
    TFLog(@"[APIBlocker] 底栏下沉：%@", sender.on ? @"开启" : @"关闭");
}

- (void)editTabBarOffset {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下沉距离"
                                                                   message:@"输入底栏下移的 pt 数（0~80）"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.placeholder = [NSString stringWithFormat:@"当前 %ld", (long)TabBarOffsetValue()];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        float v = [alert.textFields.firstObject.text floatValue];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (v >= 0 && v <= 80) {
            [defaults setInteger:(NSInteger)lround(v) forKey:kTabBarOffsetValueKey];
            TFLog(@"[APIBlocker] 下沉距离：%ld pt", (long)TabBarOffsetValue());
        }
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)forceCallKitSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kForceCallKitKey];
    TFLog(@"[APIBlocker] 强制系统来电（CallKit）：%@", sender.on ? @"开启" : @"关闭");
}

- (void)blockPatSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kBlockPatKey];
    TFLog(@"[APIBlocker] 全局屏蔽拍一拍：%@", sender.on ? @"开启" : @"关闭");
}

- (void)blockGroupUndoneSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kBlockGroupUndoneKey];
    TFLog(@"[APIBlocker] 全局屏蔽群待办：%@", sender.on ? @"开启" : @"关闭");
}

- (void)logSwitchChanged:(UISwitch *)sender {
    if (sender.on) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kLogEnabledKey];
        TFLog(@"[APIBlocker] 日志记录已开启，文件：%@", TFLogFilePath());
    } else {
        TFLog(@"[APIBlocker] 日志记录已关闭");
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kLogEnabledKey];
    }
}

- (void)callKitHideNameSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kCallKitHideNameKey];
    TFLog(@"[APIBlocker] 隐藏来电名称：%@", sender.on ? @"开启" : @"关闭");
}

- (void)callKitHideIconSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kCallKitHideIconKey];
    TFLog(@"[APIBlocker] 隐藏来电图标：%@", sender.on ? @"开启" : @"关闭");
}

- (void)editCallKitCustomName {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"自定义来电名称"
                                                                   message:@"显示在锁屏来电界面上（留空表示不修改，用“隐藏来电名称”可整行隐藏）"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = [[NSUserDefaults standardUserDefaults] stringForKey:kCallKitCustomNameKey];
        textField.placeholder = @"例如：语音通话";
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (text.length > 0) {
            [defaults setObject:text forKey:kCallKitCustomNameKey];
        } else {
            [defaults removeObjectForKey:kCallKitCustomNameKey];
        }
        TFLog(@"[APIBlocker] 自定义来电名称：%@", text.length > 0 ? text : @"（已清空）");
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 消息转发 / 本地 API 设置

- (void)forwardSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kForwardEnabledKey];
    TFLog(@"[Forward] 消息转发：%@", sender.on ? @"开启" : @"关闭");
}

- (void)forwardPrivateSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kForwardPrivateKey];
    TFLog(@"[Forward] 私聊转发：%@", sender.on ? @"开启" : @"关闭");
}

- (void)keepAliveSwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kKeepAliveKey];
    TFLog(@"[KeepAlive] 微信后台常驻：%@", sender.on ? @"开启" : @"关闭");
    if (sender.on) {
        extern void ABKeepAliveTick(void);
        extern void ABKeepAliveAudioStart(void);
        extern void ABKeepAliveAudioStop(void);
        if (sender.on) {
            ABKeepAliveTick();
            ABKeepAliveAudioStart();
        } else {
            ABKeepAliveAudioStop();
        }
    }
}

- (void)editForwardMaxMinutes {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"消息时间限制"
                                                                   message:@"只转发该分钟数以内的消息，更早的丢弃；填 0 表示不限制"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = [NSString stringWithFormat:@"%ld", (long)ForwardMaxMinutes()];
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSInteger minutes = text.integerValue;
        if (minutes < 0) minutes = 0;
        [[NSUserDefaults standardUserDefaults] setInteger:minutes forKey:kForwardMaxMinutesKey];
        TFLog(@"[Forward] 时间限制：%ld 分钟", (long)minutes);
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)localAPISwitchChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kLocalAPIEnabledKey];
    ABHTTPRestartServerIfNeeded();
    [self.tableView reloadData];
    ABShowToast(sender.on ? @"本地 API 已启动" : @"本地 API 已关闭");
}

- (void)editForwardWebhook {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Webhook 地址"
                                                                   message:@"收到的消息会以 JSON POST 到这里，例如 http://192.168.1.10:8080/wechat"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = ForwardWebhook();
        textField.placeholder = @"https://example.com/webhook";
        textField.keyboardType = UIKeyboardTypeURL;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (text.length > 0) {
            [defaults setObject:text forKey:kForwardWebhookKey];
        } else {
            [defaults removeObjectForKey:kForwardWebhookKey];
        }
        TFLog(@"[Forward] Webhook：%@", text.length > 0 ? text : @"（已清空）");
        [self.tableView reloadData];
        if (text.length > 0 && ![text hasPrefix:@"http://"] && ![text hasPrefix:@"https://"]) {
            ABShowToast(@"Webhook 需以 http:// 或 https:// 开头");
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editLocalAPIPort {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"API 端口"
                                                                   message:@"1024~65535，修改后立即重启本地服务"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = [NSString stringWithFormat:@"%ld", (long)LocalAPIPort()];
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSInteger port = [alert.textFields.firstObject.text integerValue];
        if (port < 1024 || port > 65535) {
            ABShowToast(@"端口需在 1024~65535 之间");
            return;
        }
        [[NSUserDefaults standardUserDefaults] setInteger:port forKey:kLocalAPIPortKey];
        ABHTTPRestartServerIfNeeded();
        [self.tableView reloadData];
        ABShowToast([NSString stringWithFormat:@"端口已改为 %ld", (long)port]);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editLocalAPIToken {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"API 密钥"
                                                                   message:@"可选。设置后请求需带 X-Auth-Token 头或 ?token=；留空表示不校验（同一局域网内均可调用）"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = LocalAPIToken();
        textField.placeholder = @"留空表示不校验";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (text.length > 0) {
            [defaults setObject:text forKey:kLocalAPITokenKey];
        } else {
            [defaults removeObjectForKey:kLocalAPITokenKey];
        }
        [self.tableView reloadData];
        ABShowToast(text.length > 0 ? @"已设置 API 密钥" : @"已关闭密钥校验");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editLocalAPIIP {
    NSString *detected = ABDetectWiFiIPAddress();
    NSString *message = detected.length > 0
        ? [NSString stringWithFormat:@"留空=自动使用 Wi-Fi 地址（当前 %@）", detected]
        : @"留空=自动探测；当前未检测到 Wi-Fi，可手动填写手机在 Wi-Fi 中的 IP";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"本机 IP"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = LocalAPIIPManual();
        textField.placeholder = detected.length > 0 ? detected : @"例如 192.168.1.8";
        textField.keyboardType = UIKeyboardTypeDecimalPad;
        textField.textAlignment = NSTextAlignmentCenter;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (text.length > 0) {
            [defaults setObject:text forKey:kLocalAPIIPKey];
        } else {
            [defaults removeObjectForKey:kLocalAPIIPKey];
        }
        [self.tableView reloadData];
        ABShowToast(text.length > 0 ? [NSString stringWithFormat:@"已使用 %@", text] : @"已恢复自动探测");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
// 数据源：微信“零钱”余额（单位：分）由 WCPayLogicMgr -getLocalBalanceInfo 返回的
// WCPayBalanceInfo.m_uiAvailableBalance 提供。微信在“切换付款方式”弹层里已对
// 零钱 / 经营账户 / 零钱通 展示余额，这里在付款码页主界面当前付款方式文字右侧直接补一行“剩余 X 元”。

// ============ 付款页面（收付款码页）显示真实余额 ============
// 微信服务 / 余额类接口（仅本功能使用）
@interface MMServiceCenter : NSObject
+ (instancetype)defaultCenter;
- (id)getService:(Class)cls;
@end

@interface WCPayLogicMgr : NSObject
- (id)getLocalBalanceInfo;
@end

@interface WCPayBalanceInfo : NSObject
- (unsigned long long)m_uiAvailableBalance;
@end

// 取零钱可用余额（单位：分）
static uint64_t ABZeroBalanceFen(void) {
    Class centerClass = NSClassFromString(@"MMServiceCenter");
    Class mgrClass = NSClassFromString(@"WCPayLogicMgr");
    if (!centerClass || !mgrClass) return 0;
    id center = [centerClass defaultCenter];
    if (!center) return 0;
    id mgr = [center getService:mgrClass];
    if (!mgr) return 0;
    id bal = [mgr getLocalBalanceInfo];
    if (!bal) return 0;
    return (uint64_t)[bal m_uiAvailableBalance];
}

// 递归查找指定文本的 UILabel（在付款码页视图树里找“零钱”付款方式）
static UILabel *ABFindLabelWithText(UIView *view, NSString *text) {
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        if (label.text && [label.text isEqualToString:text]) {
            return label;
        }
    }
    for (UIView *sub in view.subviews) {
        UILabel *found = ABFindLabelWithText(sub, text);
        if (found) return found;
    }
    return nil;
}

// 在付款方式 label 右侧注入“剩余 X 元”
static void ABInjectPayBalance(id vc) {
    UIView *root = [vc view];
    if (!root) return;
    // 每个付款页实例只注入一次
    static char kKey;
    if (objc_getAssociatedObject(vc, &kKey) != nil) return;

    UILabel *target = ABFindLabelWithText(root, @"零钱");
    if (!target) return;
    UIView *superView = target.superview;
    if (!superView) return;

    uint64_t fen = ABZeroBalanceFen();
    NSString *text = [NSString stringWithFormat:@"剩余 %.2f 元", fen / 100.0];

    CGRect tf = target.frame;
    CGFloat baseFont = target.font ? target.font.pointSize : 13.0;
    UILabel *bal = [[UILabel alloc] initWithFrame:CGRectMake(CGRectGetMaxX(tf) + 6, tf.origin.y, 160, tf.size.height)];
    bal.text = text;
    bal.font = [UIFont systemFontOfSize:baseFont];
    bal.textColor = [UIColor colorWithRed:0.55 green:0.55 blue:0.55 alpha:1.0];
    [superView addSubview:bal];
    objc_setAssociatedObject(vc, &kKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// hook 收付款码页 viewDidAppear:，布局完成后注入余额
static void (*orig_PayOfflineViewDidAppear)(id, SEL, BOOL);
static void APIBlockerPayOfflineViewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_PayOfflineViewDidAppear(self, _cmd, animated);
    if (!ShowPayBalanceEnabled()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ABInjectPayBalance(self);
    });
}

// ============ 屏蔽服务号收纳页的下方文章 ============
// 目标页（老原生版）：BrandFansMsgSessionViewController。该页上方是通知，下方是文章列表。
// 注意：新版订阅号消息流是 Flutter（BSTimelineFlutterViewController），UIKit 屏蔽对其无效；
// 曾尝试拦截 FlutterMethodChannel/SafeMethodChannel 数据通道（探针），实测会崩溃，已废弃，
// 不再 hook。保留下方老原生版屏蔽，仅在微信回退原生版时生效。

// 老原生服务号收纳页的屏蔽（保留，若微信回退原生版仍生效）
static id (*orig_FansVcCellForRow)(id, SEL, id, id);
static id APIBlockerFansVcCellForRow(id self, SEL _cmd, id tableView, id indexPath) {
    UITableViewCell *cell = orig_FansVcCellForRow(self, _cmd, tableView, indexPath);
    if (!BlockServiceArticleEnabled()) return cell;
    Class articleClass = NSClassFromString(@"BrandFansMsgSessionCell");
    if (!articleClass) return cell;
    if (![cell isKindOfClass:articleClass]) return cell;
    // 文章 cell → 空白 cell（隐藏内容，行高由微信保留）
    static NSString *const rid = @"APIBlockerEmptyServiceCell";
    UITableViewCell *empty = [(UITableView *)tableView dequeueReusableCellWithIdentifier:rid];
    if (!empty) {
        empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
        empty.backgroundColor = [UIColor clearColor];
        empty.contentView.backgroundColor = [UIColor clearColor];
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return empty;
}

// ============ 长按公众号列表页标题，一键把所有公众号未读标记为已读 ============
// 目标页：BrandSessionViewController（“公众号”列表页，每个条目一个公众号 + 未读角标）。
// 机制：BrandSessionMgr / BrandNewSessionMgr 拿全部公众号 username，
//       批量 clearReadCountForBrandSet: 清除未读，触发 onBrandSessionsChanged 刷新列表，
//       完成后按开关弹提示 + 震动。
// 手势 action 用动态添加的方法（class_addMethod），避开编译期无微信类 interface 的问题。

// 轻量 toast 提示（黑底圆角胶囊，自动淡出）
static void ABShowToast(NSString *text) {
    @try {
        UIWindow *window = [UIApplication sharedApplication].windows.firstObject;
        if (!window) return;
        UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        NSDictionary *attr = @{NSFontAttributeName: font};
        CGFloat maxW = window.bounds.size.width - 80;
        CGSize size = [text boundingRectWithSize:CGSizeMake(maxW, 120)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:attr context:nil].size;
        CGFloat padH = 28, padV = 14;
        CGFloat tw = ceil(size.width) + padH;
        CGFloat th = ceil(size.height) + padV;
        UIView *toast = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tw, th)];
        toast.center = CGPointMake(window.bounds.size.width / 2.0, window.bounds.size.height * 0.72);
        toast.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.88];
        toast.layer.cornerRadius = th / 2.0;
        toast.clipsToBounds = YES;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(padH / 2.0, padV / 2.0, ceil(size.width), ceil(size.height))];
        label.text = text;
        label.font = font;
        label.textColor = [UIColor whiteColor];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        [toast addSubview:label];
        toast.alpha = 0;
        [window addSubview:toast];
        [UIView animateWithDuration:0.25 animations:^{
            toast.alpha = 1.0;
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                toast.alpha = 0;
            } completion:^(BOOL finished) {
                [toast removeFromSuperview];
            }];
        });
    } @catch (NSException *e) {}
}

// 一键已读核心逻辑（长按 / 进入页面自动已读共用）
static void ABMarkAllBrandReadDo(id vc) {
    @try {
        Class centerClass = NSClassFromString(@"MMServiceCenter");
        if (!centerClass) {
            TFLog(@"[APIBlocker] 一键已读：未找到服务类");
            return;
        }
        id center = [centerClass defaultCenter];
        if (!center) {
            TFLog(@"[APIBlocker] 一键已读：MMServiceCenter 为空");
            return;
        }
        // 收集所有公众号 username —— 这是能否真正清零的关键。
        // 旧实现只依赖 BrandSessionMgr.getAllUserNamesOnSessionStorgae（微信源码错拼的方法名），
        // 这版微信若该方法名不匹配/返回空，一个用户都拿不到 → 清理只刷了 UI、DB 未清，
        // 新文章进来微信从 DB 读到历史累计未读，就显示成几十上百条。
        // 公众号会话 username 以 "gh_" 开头，直接用主会话层遍历筛选，最稳。
        NSMutableArray *usersAll = [NSMutableArray array];
        @try {
            id sessionMgr0 = [center getService:NSClassFromString(@"MMNewSessionMgr")];
            if (sessionMgr0 && [sessionMgr0 respondsToSelector:@selector(GetSessionCount)]) {
                unsigned cnt = ((unsigned(*)(id, SEL))objc_msgSend)(sessionMgr0, @selector(GetSessionCount));
                for (unsigned i = 0; i < cnt; i++) {
                    id uname = nil;
                    if ([sessionMgr0 respondsToSelector:@selector(GetSessionUserNameAtIndex:)]) {
                        uname = ((id(*)(id, SEL, unsigned))objc_msgSend)(sessionMgr0, @selector(GetSessionUserNameAtIndex:), i);
                    }
                    if ([uname isKindOfClass:[NSString class]] && [uname hasPrefix:@"gh_"]) {
                        [usersAll addObject:uname];
                    }
                }
            }
        } @catch (NSException *e) {
            TFLog(@"[APIBlocker] 公众号枚举失败：%@", e.reason);
        }
        // 兜底：品牌 mgr 的名称枚举补漏
        for (NSString *mgName in @[@"BrandSessionMgr", @"BrandNewSessionMgr"]) {
            id mgr = [center getService:NSClassFromString(mgName)];
            if (!mgr || ![mgr respondsToSelector:@selector(getAllUserNamesOnSessionStorgae)]) continue;
            @try {
                NSArray *u = [mgr performSelector:@selector(getAllUserNamesOnSessionStorgae)];
                if ([u isKindOfClass:[NSArray class]]) {
                    for (id x in u) {
                        if ([x isKindOfClass:[NSString class]] && ![usersAll containsObject:x]) {
                            [usersAll addObject:x];
                        }
                    }
                }
            } @catch (NSException *e) {}
        }
        // 关键：对每个公众号 username 从主会话层「写库」清零（主页一键已读就用这套，持久生效）
        @try {
            id sessionMgr = [center getService:NSClassFromString(@"MMNewSessionMgr")];
            if (sessionMgr && [sessionMgr respondsToSelector:@selector(ChangeSessionUnReadCount:to:)]) {
                for (id u in usersAll) {
                    if (![u isKindOfClass:[NSString class]]) continue;
                    ((void(*)(id, SEL, id, unsigned))objc_msgSend)(sessionMgr, @selector(ChangeSessionUnReadCount:to:), u, 0);
                }
            }
            if (sessionMgr && [sessionMgr respondsToSelector:@selector(recountUnReadCountAndFireExtension)]) {
                ((void(*)(id, SEL))objc_msgSend)(sessionMgr, @selector(recountUnReadCountAndFireExtension));
            }
        } @catch (NSException *e) {
            TFLog(@"[APIBlocker] 公众号已读写库失败：%@", e.reason);
        }
        // 补充：品牌 mgr 清品牌内存计数
        for (NSString *mgName in @[@"BrandSessionMgr", @"BrandNewSessionMgr"]) {
            id mgr = [center getService:NSClassFromString(mgName)];
            if (!mgr) continue;
            SEL clearSetSel = @selector(clearReadCountForBrandSet:);
            SEL clearSel = @selector(clearReadCountForBrand:);
            if ([mgr respondsToSelector:clearSetSel]) {
                @try { [mgr performSelector:clearSetSel withObject:usersAll]; } @catch (NSException *e) {}
            } else if ([mgr respondsToSelector:clearSel]) {
                for (id u in usersAll) {
                    if (![u isKindOfClass:[NSString class]]) continue;
                    @try { [mgr performSelector:clearSel withObject:u]; } @catch (NSException *e) {}
                }
            }
        }
        // 刷新当前列表，让角标消失：触发微信自己的刷新回调 + reloadData
        @try {
            SEL changedSel = @selector(onBrandSessionsChanged);
            if ([(id)vc respondsToSelector:changedSel]) {
                [(id)vc performSelector:changedSel];
            }
        } @catch (NSException *e) {}
        id table = [(id)vc valueForKey:@"m_tableView"];
        if (table && [table respondsToSelector:@selector(reloadData)]) {
            [table reloadData];
        }
        NSUInteger total = usersAll ? usersAll.count : 0;
        TFLog(@"[APIBlocker] 一键已读：共 %lu 个公众号，处理完毕", (unsigned long)total);
        // 完成提示 + 短暂震动
        if (MarkBrandReadTipEnabled()) {
            ABShowToast(MarkBrandReadTipText());
            ABDoVibrate();
        }
    } @catch (NSException *e) {
        TFLog(@"[APIBlocker] 一键已读异常：%@", e.reason);
    }
}

// 长按手势 action（动态方法），位置过滤后执行核心逻辑
static void ABMarkAllBrandReadIMP(id self, SEL _cmd, UILongPressGestureRecognizer *g) {
    if (g.state != UIGestureRecognizerStateBegan) return;
    // 位置过滤放宽：只排除导航栏最左/最右的按钮区，标题区（中央大范围）都可触发
    UINavigationBar *bar = (id)[(id)self navigationController].navigationBar;
    if (bar) {
        CGPoint p = [g locationInView:bar];
        CGFloat w = bar.bounds.size.width;
        if (w > 0 && (p.x < w * 0.12 || p.x > w * 0.88)) return;
    }
    ABMarkAllBrandReadDo(self);
}

// 双击标题 action（动态方法），双击成功（Recognized）后执行核心逻辑
static void ABMarkAllBrandReadDblIMP(id self, SEL _cmd, UITapGestureRecognizer *g) {
    if (g.state != UIGestureRecognizerStateRecognized) return;
    UINavigationBar *bar = (id)[(id)self navigationController].navigationBar;
    if (bar) {
        CGPoint p = [g locationInView:bar];
        CGFloat w = bar.bounds.size.width;
        if (w > 0 && (p.x < w * 0.12 || p.x > w * 0.88)) return;
    }
    ABMarkAllBrandReadDo(self);
}

// 给公众号列表页挂手势（统一挂到 navigationBar）：长按 + 双击，关联对象去重
static char kBrandLPKey;
static void ABInstallBrandLongPress(id vc) {
    if (objc_getAssociatedObject(vc, &kBrandLPKey)) return;
    UINavigationBar *bar = [(id)vc navigationController].navigationBar;
    if (!bar) return;
    Class cls = object_getClass(vc);
    // 长按
    SEL actSel = @selector(ABMarkAllBrandRead:);
    if (cls && !class_getInstanceMethod(cls, actSel)) {
        class_addMethod(cls, actSel, (IMP)ABMarkAllBrandReadIMP, "v@:@");
    }
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:vc action:actSel];
    lp.minimumPressDuration = 0.5;
    [bar addGestureRecognizer:lp];
    // 双击
    SEL dblSel = @selector(ABMarkAllBrandReadDouble:);
    if (cls && !class_getInstanceMethod(cls, dblSel)) {
        class_addMethod(cls, dblSel, (IMP)ABMarkAllBrandReadDblIMP, "v@:@");
    }
    UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:vc action:dblSel];
    dbl.numberOfTapsRequired = 2;
    [bar addGestureRecognizer:dbl];
    objc_setAssociatedObject(vc, &kBrandLPKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TFLog(@"[APIBlocker] 公众号列表页已挂 长按/双击 已读手势到 navigationBar");
}

// hook 公众号列表页 viewDidLoad / viewDidAppear：挂长按手势 + 进入自动已读（2 小时内重复进入不再自动已读）
static void (*orig_BrandSessionViewDidLoad)(id, SEL);
static void APIBlockerBrandSessionViewDidLoad(id self, SEL _cmd) {
    orig_BrandSessionViewDidLoad(self, _cmd);
    if (!MarkBrandReadEnabled()) return;
    @try {
        ABInstallBrandLongPress(self);
    } @catch (NSException *e) {
        TFLog(@"[APIBlocker] 长按手势挂载失败(viewDidLoad)：%@", e.reason);
    }
}

static void (*orig_BrandSessionViewDidAppear)(id, SEL, BOOL);
static void APIBlockerBrandSessionViewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_BrandSessionViewDidAppear(self, _cmd, animated);
    @try {
        if (AutoMarkBrandReadEnabled()) {
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            NSTimeInterval last = [[NSUserDefaults standardUserDefaults] doubleForKey:kAutoMarkBrandReadLastKey];
            if (last <= 0 || now - last >= 7200) {
                // 首次进入，或距上次自动已读已满 2 小时 → 自动一键已读并记录时间
                [[NSUserDefaults standardUserDefaults] setDouble:now forKey:kAutoMarkBrandReadLastKey];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    ABMarkAllBrandReadDo(self);
                });
            }
            // 2 小时内重复进入：不再自动已读（双击/长按手动已读不受此限制）
        }
        if (MarkBrandReadEnabled()) {
            ABInstallBrandLongPress(self);
        }
    } @catch (NSException *e) {
        TFLog(@"[APIBlocker] 公众号页 viewDidAppear 处理失败：%@", e.reason);
    }
}

// ============ 主页消息一键已读（消息列表页底部“微信”tab 向上拖动）===========
// 目标页：NewMainFrameViewController（主消息列表）。机制：MMNewSessionMgr 遍历全部会话
// 把 unreadCount 清零 → recountUnReadCountAndFireExtension 重算总未读并触发 UI 刷新 →
// MainSessionMgr.updateMainSessionListNotify: 刷新列表。底部 tab 上加向上拖手势，
// 拖动时红色气泡跟随“拉扯”，松手向上快拖 → 气泡破碎消失 + 执行一键已读。

// 一键已读核心：清空所有主会话未读
// 前向声明：遍历消息行未读气泡并爆炸（定义在本文件后方）
static void ABBreakRowBubblesInView(UIView *view, UIWindow *win);
static void ABMarkMainUnreadDo(id vc) {
    @try {
        Class centerClass = NSClassFromString(@"MMServiceCenter");
        if (!centerClass) {
            TFLog(@"[APIBlocker] 主页一键已读：未找到服务类");
            return;
        }
        id center = [centerClass defaultCenter];
        if (!center) return;
        id mgr = [center getService:NSClassFromString(@"MMNewSessionMgr")];
        if (!mgr) {
            TFLog(@"[APIBlocker] 主页一键已读：MMNewSessionMgr 为空");
            return;
        }
        NSInteger total = 0;
        // 用已加载的会话数组遍历（mainSessionEnumerator 可能是空枚举器）
        if ([mgr respondsToSelector:@selector(GetSessionCount)]) {
            unsigned count = ((unsigned(*)(id, SEL))objc_msgSend)(mgr, @selector(GetSessionCount));
            for (unsigned i = 0; i < count; i++) {
                id session = nil;
                if ([mgr respondsToSelector:@selector(GetSessionAtIndex:)]) {
                    session = ((id(*)(id, SEL, unsigned))objc_msgSend)(mgr, @selector(GetSessionAtIndex:), i);
                }
                // 内存置 0
                if (session && [session respondsToSelector:@selector(setUnreadCount:)]) {
                    ((void(*)(id, SEL, unsigned))objc_msgSend)(session, @selector(setUnreadCount:), 0);
                }
                // 用 username 走正规清零（含 DB + 通知）
                id uname = nil;
                if ([mgr respondsToSelector:@selector(GetSessionUserNameAtIndex:)]) {
                    uname = ((id(*)(id, SEL, unsigned))objc_msgSend)(mgr, @selector(GetSessionUserNameAtIndex:), i);
                }
                if (uname && [uname isKindOfClass:[NSString class]] && [mgr respondsToSelector:@selector(ChangeSessionUnReadCount:to:)]) {
                    ((void(*)(id, SEL, id, unsigned))objc_msgSend)(mgr, @selector(ChangeSessionUnReadCount:to:), uname, 0);
                }
                total++;
            }
        }
        // 重算总未读 + 触发未读变化广播（更新底部气泡 / 顶部标题数字 / 列表条目）
        // 同步：先让消息行上各会话的红色未读气泡爆炸消失（赶在刷新移除前）
        // 从整个 window 扫描所有表格，覆盖消息列表（可能位于子控制器视图树中）
        UIWindow *win = [(id)vc view].window ?: [UIApplication sharedApplication].windows.firstObject;
        if (win) {
            ABBreakRowBubblesInView(win, win);
        }
        if ([mgr respondsToSelector:@selector(recountUnReadCountAndFireExtension)]) {
            ((void(*)(id, SEL))objc_msgSend)(mgr, @selector(recountUnReadCountAndFireExtension));
        }
        id mainMgr = [center getService:NSClassFromString(@"MainSessionMgr")];
        if (mainMgr && [mainMgr respondsToSelector:@selector(updateMainSessionListNotify:)]) {
            ((void(*)(id, SEL, BOOL))objc_msgSend)(mainMgr, @selector(updateMainSessionListNotify:), YES);
        }
        @try {
            id table = [(id)vc valueForKey:@"m_tableView"];
            if (table && [table respondsToSelector:@selector(reloadData)]) {
                [table reloadData];
            }
        } @catch (NSException *e) {}
        TFLog(@"[APIBlocker] 主页一键已读：处理 %ld 个会话", (long)total);
        // 完成轻微震动（受“已读完成提示”开关控制）
        if (MarkBrandReadTipEnabled()) {
            ABDoVibrate();
        }
    } @catch (NSException *e) {
        TFLog(@"[APIBlocker] 主页一键已读异常：%@", e.reason);
    }
}

// 找底部 tab 栏（微信自定义 MMTabBar 或系统 UITabBar）
static UIView *ABFindMainTabBar(id vc) {
    id tabVC = [(id)vc tabBarController];
    UIView *tb = tabVC ? [tabVC tabBar] : nil;
    if (tb) return tb;
    UIView *scan = [(id)vc view];
    while (scan.superview) {
        scan = scan.superview;
        if ([scan isKindOfClass:NSClassFromString(@"MMTabBar")]) return scan;
        if ([scan isKindOfClass:[UITabBar class]]) return scan;
    }
    return nil;
}

// “微信”tab 判定区域：tab 栏左 1/4 全高（微信是第一个 tab，固定在此范围）
static CGRect ABFindWeChatTabRect(UIView *tabbar) {
    return CGRectMake(0, 0, tabbar.bounds.size.width / 4.0, tabbar.bounds.size.height);
}

// 判断是否为红色
static BOOL ABIsRedColor(UIColor *c) {
    if (!c) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([c getRed:&r green:&g blue:&b alpha:&a]) {
        return (r > 0.7 && g < 0.45 && b < 0.45);
    }
    return NO;
}

// 递归找微信“微信”tab 上的红色气泡（红底带数字的 UILabel）位置，换算到 window 坐标
static CGPoint ABFindWeChatBubbleCenter(id vc, UIView *tabbar, UIWindow *win) {
    __block UIView *found = nil;
    __block void (^scan)(UIView *) = nil;
    scan = ^(UIView *v) {
        if (found) return;
        for (UIView *sv in v.subviews) {
            if (found) return;
            if ([sv isKindOfClass:[UILabel class]]) {
                UILabel *l = (UILabel *)sv;
                if (l.text.length > 0 && ABIsRedColor(l.backgroundColor)) {
                    found = sv;
                    return;
                }
            }
            scan(sv);
        }
    };
    scan(tabbar);
    if (found) {
        return [found convertPoint:CGPointMake(found.bounds.size.width / 2.0, found.bounds.size.height / 2.0) toView:win];
    }
    // 兜底估算：微信 tab 在 tabbar 左 1/4，气泡在其图标右上
    CGRect tb = tabbar.bounds;
    return [tabbar convertPoint:CGPointMake(tb.size.width * 0.125 + 16, 12) toView:win];
}

// 红色气泡（白色未读数字）
static UIView *ABMakeMainBubble(NSInteger count, CGPoint center, UIWindow *win) {
    CGFloat d = 24.0;
    UIView *b = [[UIView alloc] initWithFrame:CGRectMake(0, 0, d, d)];
    b.center = center;
    b.backgroundColor = [UIColor colorWithRed:0.94 green:0.21 blue:0.17 alpha:1.0];
    b.layer.cornerRadius = d / 2.0;
    b.clipsToBounds = YES;
    UILabel *l = [[UILabel alloc] initWithFrame:b.bounds];
    l.text = count > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)count];
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    l.textColor = [UIColor whiteColor];
    l.textAlignment = NSTextAlignmentCenter;
    [b addSubview:l];
    [win addSubview:b];
    return b;
}

// 气泡破碎消失：从气泡中心拆成多个小红点四散 + 淡出 + 缩小
static void ABBreakMainBubble(UIView *bubble, UIWindow *win) {
    CGPoint c = bubble.center;
    UIColor *col = bubble.backgroundColor;
    [bubble removeFromSuperview];
    for (int i = 0; i < 10; i++) {
        UIView *f = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 5, 5)];
        f.backgroundColor = col;
        f.layer.cornerRadius = 2.5;
        f.center = c;
        [win addSubview:f];
        double ang = (double)(i % 10) / 10.0 * 2.0 * M_PI + ((double)rand() / RAND_MAX) * 0.6;
        double dist = 26 + ((double)rand() / RAND_MAX) * 48;
        CGPoint end = CGPointMake(c.x + cos(ang) * dist, c.y + sin(ang) * dist);
        [UIView animateWithDuration:0.5 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            f.center = end;
            f.alpha = 0;
            f.transform = CGAffineTransformMakeScale(0.2, 0.2);
        } completion:^(BOOL done) {
            [f removeFromSuperview];
        }];
    }
}

// 在一个 cell 里找红色未读气泡：优先红底 UILabel，也兼容“红底小容器 + 内部数字”的结构
static UIView *ABFindRowBubbleInCell(UIView *cell) {
    __block UIView *bub = nil;
    __block void (^find)(UIView *) = nil;
    find = ^(UIView *v) {
        if (bub) return;
        for (UIView *sv in v.subviews) {
            if (bub) return;
            if (ABIsRedColor(sv.backgroundColor) && sv.frame.size.width < 30 && sv.frame.size.height < 30) {
                NSString *txt = nil;
                if ([sv isKindOfClass:[UILabel class]]) {
                    txt = [(UILabel *)sv text];
                } else {
                    for (UIView *c in sv.subviews) {
                        if ([c isKindOfClass:[UILabel class]]) { txt = [(UILabel *)c text]; break; }
                    }
                }
                if (txt.length > 0) { bub = sv; return; }
            }
            find(sv);
        }
    };
    find(cell);
    return bub;
}

// 递归遍历视图树：找出所有 UITableView 可见 cell 上的红色未读气泡，逐个爆炸消失
static void ABBreakRowBubblesInView(UIView *view, UIWindow *win) {
    if (!view) return;
    if ([view isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)view;
        for (UITableViewCell *c in [tv visibleCells]) {
            UIView *bub = ABFindRowBubbleInCell(c);
            if (bub) ABBreakMainBubble(bub, win);
        }
        return;
    }
    for (UIView *sv in view.subviews) ABBreakRowBubblesInView(sv, win);
}

// pan 手势 action（动态方法）：气泡从 tab 原气泡处跟随手指并稍放大，松手向上快拖 → 破碎 + 一键已读
static void ABMainTabPanIMP(id self, SEL _cmd, UIPanGestureRecognizer *p) {
    static UIView *sBubble = nil;
    static UIWindow *sWin = nil;
    switch (p.state) {
        case UIGestureRecognizerStateBegan: {
            sWin = [(id)self view].window ?: [UIApplication sharedApplication].windows.firstObject;
            if (!sWin) return;
            // 只在“微信”tab 按钮区域生效，其余 tab（通讯录/发现/我）不响应
            UIView *tabbar = ABFindMainTabBar(self);
            if (tabbar) {
                CGPoint loc = [p locationInView:tabbar];
                if (!CGRectContainsPoint(ABFindWeChatTabRect(tabbar), loc)) {
                    sBubble = nil;
                    return;
                }
            }
            NSInteger total = 0;
            Class centerClass = NSClassFromString(@"MMServiceCenter");
            if (centerClass) {
                id center = [centerClass defaultCenter];
                id mgr = center ? [center getService:NSClassFromString(@"MMNewSessionMgr")] : nil;
                if (mgr && [mgr respondsToSelector:@selector(GetTotalUnreadCount)]) {
                    total = ((NSInteger(*)(id, SEL))objc_msgSend)(mgr, @selector(GetTotalUnreadCount));
                }
            }
            // 气泡从微信 tab 上原有气泡位置开始（不是手指位置），像被“拉扯”起来
            CGPoint start = CGPointMake(sWin.bounds.size.width * 0.5, sWin.bounds.size.height * 0.9);
            if (tabbar) start = ABFindWeChatBubbleCenter(self, tabbar, sWin);
            sBubble = ABMakeMainBubble(total, start, sWin);
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (sBubble && sWin) {
                sBubble.center = [p locationInView:sWin];
                // 向上拖动越多，气泡拉扯得越大
                CGPoint tr = [p translationInView:p.view];
                CGFloat frac = MIN(0.8, MAX(0.0, -tr.y / 120.0));
                CGFloat scale = 1.0 + frac * 0.6;
                sBubble.transform = CGAffineTransformMakeScale(scale, scale);
            }
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (sBubble && sWin) {
                CGPoint vel = [p velocityInView:p.view];
                if (vel.y < -MainReadSpeedThreshold()) {
                    ABBreakMainBubble(sBubble, sWin);
                    ABMarkMainUnreadDo(self);
                } else {
                    [sBubble removeFromSuperview];
                }
            }
            sBubble = nil;
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [sBubble removeFromSuperview];
            sBubble = nil;
            break;
        default:
            break;
    }
}

static char kMainTabPanKey;
static void ABInstallMainTabPan(id vc) {
    if (objc_getAssociatedObject(vc, &kMainTabPanKey)) return;
    UIView *tabbar = ABFindMainTabBar(vc);
    if (!tabbar) return;
    Class cls = object_getClass(vc);
    SEL panSel = @selector(ABMainTabPan:);
    if (cls && !class_getInstanceMethod(cls, panSel)) {
        class_addMethod(cls, panSel, (IMP)ABMainTabPanIMP, "v@:@");
    }
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:vc action:panSel];
    [tabbar addGestureRecognizer:pan];
    objc_setAssociatedObject(vc, &kMainTabPanKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TFLog(@"[APIBlocker] 主页消息一键已读：已挂 tab 上拖手势");
}

// hook 主消息列表页 viewDidAppear，开启时挂底部 tab 上拖手势
static void (*orig_NewMainFrameViewDidAppear)(id, SEL, BOOL);
static void APIBlockerNewMainFrameViewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_NewMainFrameViewDidAppear(self, _cmd, animated);
    if (!MainReadEnabled()) return;
    @try {
        ABInstallMainTabPan(self);
    } @catch (NSException *e) {
        TFLog(@"[APIBlocker] 主页消息上拖挂载失败：%@", e.reason);
    }
}

@interface APIBlockerURLProtocol : NSURLProtocol
@end

@implementation APIBlockerURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSURL *url = request.URL;
    TFLog(@"[APIBlocker] canInitWithRequest: %@", url.absoluteString);
    if (!APIBlockerEnabled()) {
        return NO;
    }
    if (![url.scheme.lowercaseString isEqualToString:@"http"] &&
        ![url.scheme.lowercaseString isEqualToString:@"https"]) {
        return NO;
    }
    return URLMatches(url);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSData *body = ResponseBodyData();
    NSString *contentType = ResponseContentTypeHeader();
    TFLog(@"[APIBlocker] BLOCKED %@ -> %@ (%lu bytes)",
          self.request.URL.absoluteString,
          contentType ?: @"空响应",
          (unsigned long)body.length);
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)body.length];
    headers[@"Connection"] = @"close";
    if (contentType.length > 0) {
        headers[@"Content-Type"] = contentType;
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                             statusCode:200
                                                            HTTPVersion:@"HTTP/1.1"
                                                           headerFields:headers];
    id<NSURLProtocolClient> client = self.client;
    [client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (body.length > 0) {
        [client URLProtocol:self didLoadData:body];
    }
    [client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
    // 无实际网络连接，无需处理
}

@end

// ============ 自建旧版卡包首页（四入口） ============
//
// 微信把“我 → 卡包”热更新成了复杂的商家卡片流（V2 / 服务端驱动），
// 且本地没有可供直接复用的简洁四入口页面。这里自建一个标题为“卡包”的
// 列表页，固定四个入口：优惠券 / 会员卡 / 交通卡 / 票证，
// 各自跳到微信对应的原生二级页面，观感与微信列表一致。

@interface LegacyCardHomeViewController : UITableViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation LegacyCardHomeViewController

// 背景色：跟随系统深浅色，暗色用微信暗色 #111111，亮色用微信亮色 #EDEDED
static UIColor *CardPageBackgroundColor(void) {
    if (@available(iOS 13.0, *)) {
        if (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0x11/255.0 green:0x11/255.0 blue:0x11/255.0 alpha:1.0];
        }
    }
    return [UIColor colorWithRed:0xED/255.0 green:0xED/255.0 blue:0xED/255.0 alpha:1.0];
}

// 通栏卡片背景：深色 #191919 / 亮色 #FFFFFF（与微信卡包一致）
static UIColor *CardCellBackgroundColor(void) {
    if (@available(iOS 13.0, *)) {
        if (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0x19/255.0 green:0x19/255.0 blue:0x19/255.0 alpha:1.0];
        }
    }
    return [UIColor whiteColor];
}

// 卡片按下高亮色：深色略亮 / 亮色浅灰（只作用于卡片区域，不超出条目宽度）
static UIColor *CardCellSelectedColor(void) {
    if (@available(iOS 13.0, *)) {
        if (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0x27/255.0 green:0x27/255.0 blue:0x27/255.0 alpha:1.0];
        }
    }
    return [UIColor colorWithWhite:0.91 alpha:1.0];
}

// 图标描边加粗：把原图在周围小偏移反复绘制，使线条/轮廓变粗（轻微）
static UIImage *ABThickenImage(UIImage *img, CGFloat px) {
    if (!img) return nil;
    CGSize size = img.size;
    CGFloat scale = img.scale;
    if (size.width <= 0 || size.height <= 0) return img;
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetShouldAntialias(ctx, true);
    CGFloat step = px > 0 ? px / 2.0 : 1.0;
    for (CGFloat dx = -px; dx <= px; dx += step) {
        for (CGFloat dy = -px; dy <= px; dy += step) {
            if (sqrt(dx * dx + dy * dy) > px + 0.01) continue;
            [img drawAtPoint:CGPointMake(dx, dy)];
        }
    }
    [img drawAtPoint:CGPointZero];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result ?: img;
}

// 四个入口的彩色小图标（PNG 内嵌，深色/亮色背景均适用），显示时轻微描边加粗
static UIImage *CardPageIcon(NSString *b64) {
    if (b64.length == 0) {
        return nil;
    }
    NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    UIImage *img = data ? [UIImage imageWithData:data] : nil;
    if (!img) return nil;
    return ABThickenImage(img, 0.5);
}

// 入口配置：标题 + 内嵌彩色图标(PNG base64) + 跳转类（带兜底类）
static NSArray *LegacyCardHomeEntries(void) {
    // 优惠券：橙色票券；会员卡：黄色VIP；交通卡：绿色公交；票证：蓝色框
    static NSString *const kIconCoupon  = @"iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAFMklEQVR4nO3bXYhVVRTA8bXvufOBlkoPjTNzHWccAzMGCnuwmkqhjJA+RQqSIIeEfLEvKMcse5BAIsvorY+HQEgmIsgegh4EE59ECcHQUjPTRJIyzI+5Z8XeZ587Zwavog+yjv1/OHfmnrPvcd+917lnn3X3FgEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANeaE6PWDHbqC7e2yNRqRcRVsqqq3xMe4lNffRe2+MfwZlx8S079v1A8e5mGbVo8jnPi4k+2JSvsVEV9+Ubz+DLxZX5TOG5Wj8bxQlH/Oifi0nAM71Rd5KO9F2TDjqMm29pkpZYOdOiWh1vl9OmKbD+edWqhjSX1fxVqnu9zvoPVxUDIi2SdmsZteSCFDq7khZz4EPPb/Kuzzo8BFP+fuCeLL83q4/vaP/hjhy2NoImRJyr3djiZOiURt+EXk21t0vqFnVpfPVOfGuiIp3u5pa/36vqF3Sbfiw98c0ZTX7FEvvjxj+virHGpSD2/dBljMgDCdTW/ll8PXBxfGGQyAPA/D4BssGfzjLk6LhtQGmQyAPzoetToR+bV8O/F6rsxGQBtSSLVFieHn5+hL87vstp2lzU82KXHVvRotS2RtorJpraZB/DW3lfTp2clMrdWla/31eXxkUOXrOuHD3XrDZXsDsKbGDX583CXfrGQchP/iIViIilPFlUrTk6cr8jq7w9fsj7fLO3RxXNaZdehuowcPCfvbP/dZFubrFTR+gU1HR5sk6/2pfLkyMGm9dXXblG54O+3suzgWBKv2NuFLGBjs4tZwfGJonjUeKz8t4gkTk6dq8hNm/Y1rcvIEzVdMtAub287J+u2HTHfxuZtfKCm+tZsHbrT/uXg2dtvVl3bqxsfrJmva6kcXdmre5+bab5Rdy3r1mMre8zXM2dzZHIRXx44L3M77Ff3jo6qjBwYlbKw36LRnpOpaBlq2+Jk18m6lEUZmjSo+6F7HOFbps5/O1iecV9pAuC2aU5c3f6l1dWdzJmWSFmUJgCWzG6V/X+KeftP1mXJrFYpi6qUwPBgp/Z1VeWl7842LaPD/RpyyOEnZnsm3vP7ZE5xlocbP4MoG2QU8gDhGPFJ2KWhxepnE6m++9NFP+f97J/3F02SVfO79YOdNmcBFZmv4NC86frxonbZ8ZvIPZ83zwaumNep7YkfK/gOHLtUZBPFxs/uKX7T7PJyYdZRPv3HzywqlskSRX5OUDVROfGvyuY9x5vW5YdlvXp3T1We+faMbN5tMwNYClseq6mu6dc9y/vtX/wn2L28L9R986MkhK7Ymwu6VId7VV/u088WlyepMtEni2eovtKn+ka/rrvf5pQwk2OAFqfhji95r3nuvwyGth5xQ1tF6qt7tS0x2f827wJGUyeVpDy3UpdTERWrqSGTATD2zdx1Qv1UczHJZABkiy1MVu0qxbUKBpls5aaTNkpKCYArE5ZrVepideR8JV69a7q6xM8JNHmumf1kkr9XzdIbJzs5/49KmsbkTliLFWVrtMK5lS3NksKSrFAgWw7o8o+5LFE4tsCvUSxL/OSJwuJ0spBEdOMnCxXqkCWUsqRRGo/bSBrFfW2TRM6cdTJ5088m29pkpXKfPtKjUxIRTWPfF78NLPRUcRln/nzsie9CjWPx8a+TfLFozBSGpYKFtZ6NbHJeJj6GwIqb80OlcV1hVjwLhKQi8teovx381XQ7AwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJBr5D927LjaTI0GRwAAAABJRU5ErkJggg==";
    static NSString *const kIconMember = @"iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAJiElEQVR4nO2cC4xVRxnH/3PO2Xv3ybIFRaTYdQGttQZaTNoiagklLQQXLIVU4jvWhtiWhBgEjSWaWmPSBzU21RRJsEJ51DYIiAFpoaA1ErChvKS8CjbY8NoFdpe9957zmZlzzn3t3b27lMpk/f/ay717Zs7MOfN9830z38w5ACGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQggh5NqgYBmPfKtJhjQoSABA8i9Riq7WJJp0/V+YLoA44U/zlcsTZgn/NsWoXGHZo1F67qg+prKl6GMqLy3+KyxK162Phd/Zepwwr3IUTrcKnl7ytlVtbtXFbF9+s4yfkgRatPR040etayQQaURWcLqh9Uf/dsI70VLX+cx5kcJI0Tlhxiivio7rsiMlyko7+iFupBj6E0Rl5ZUTK5cpQ3/p63VyZZifOr8DNABvbuvELdP/aVW7W8HUicNF3hsjj81tyu+G/YoFD4wQOX2bzJ5mzz16sIS6agU4Ye+ZcXej1FQpBEHYTrFljoxptndnTX/kKrT5DTu7Cju+SZXsOfGx0FXEtjvuzbHpzisnymNKMMmh0ZdSriIuo+B4ZAQcoP2ywNf3I4K6GliDNQrQehHY+48Mvt5cje96HgLRYotMr/k/bDylJeNGJjbrAkIzHIvCEClI1k/HLgN+LpeKfbl2OaGqZP28FrYZVjjhEa2cseLovJEyFFQYIYFOi1yR9gqi4CiFTt/H3l2XceZc5C5IIZPvHG6NafygmDR+WL+/xyti5hQ9Bvis3De5sd820F2fu17k32Pl2zPtGQPEw9Vrju8HQMaH56LforT7CrRrsEb+9iiAmAGYE333TyQas9gjfosUIH+m3q9RsAprZgG95f7mRvnUyArAD9DeqfCLXx8u26Q/nDNCEp6O6bj4yeJD2fwP3v9xGTpEIVAufrq4a4Ru7jeapKFeIfDDUbwxTqJDPgqtlwLsO5zGlh3v9FmkeUHIa449ChDOucp2kK81D8CUGS5wJgCuS+DChZHy3IrulWDBg03ys8fqgfMBUFuJff9qkpc2HjX5n11YC7fOAQZWYPigT8sDP96XLefOOz4mixfV6zldFI3UHz1A0dPBaBqXAv6+f6A8+nQLNvdaEeyycda4gLhdyvWOZ5a1Iv0u0HFO4J9OY+ak6h7z3zshCf8/aWTagb1/60AsfM2FCz7SZzPInPbhZ3R8IMfWN04ov8VH5myA9NkAaNcTeg/w9UBOAZkAQXsat49WWLfkQ5g6sZezl3i9wBKssQBm8BdF/npi0/Z31O49A+S2sQ78SwHGjanoMf+tN1VA2gN4gzy8svVCQZrjCDxXQblxBLEQ19WeRuDVelixLoV1W8+jrtqF4zqY/PkqTJvoInXOR3Kgj8XzB2H9luPl79GyYYA9FkBjonHllWDZ+nYTDcykBcl6wePzbix50hPzR4lbE0YPO88HePSXOf8f1qfChZtuzY4OHwuQcLB7fworNxxXz685on6z8m01/Xt71LK1nUhc5yB1PsCIJhfT7y43v88PG9uBXQpQHE7vhudWHFGnjgsSVQroCDBjQlXJfM1fSADtArfWweu7OktWqOI6S9YbCSpQqK7s2lQvbrgEZFwTJhZXoXFobwxqpFSWYI0CxIs4ve0da169DFXrItUW4BOjHEybdENBqzZPHC6jRrjItOu1Aw8rN2kn3hWJl5hKVWsEpQd9qqR3yq4vROcWDSNK3KNdvd8qBejrHGnu4wdV+pIYPw7Px32TCpfY7p1YZUY4btLBeycDLH3pWImCJdv1S3fK3CnpTNfUqV+sAir8cJtCWuHwiVJWpri+wKppoD0KULwRoxds25mGV6cQXPRxzx3JgrR7xlVA2gKoGgfrd1wu43Iku2rYJYvWjCCDoYML059ceKPMmVVt/H+i3sVbB9L487aep4K53UT2YI8CRPSleV7Y0GH8byYlGPxRhYe+OsKc/p1ZjTJkmIKfFkha4Q9b2rotQ2WXi0v6ADMTkIsZPDwrgc5do6Vz1xiRPbfIvG9WIuj0kahzkc5U4PtPnen9vdEClJREt2Lojt+9clQdPwJU6FBAxsfMu8KYwJcnJMwOLa/Kw76DPjZuO9FNsU7kcnoaferpKeBWKjPiTzS4QI0DOB68hhocOpnAjIdOYdPrvQgExbEOi4yAPXGALj96x+q/dGL+nEoELT7G3uRh6oQb5PabXUibgqp38fKrl8rUqnL7C7ugdxYJkPTw5n5g37E0EhV6pxJwvg3Y+VYLlq4uH4rOKy6slQrQkzz61jo/eOKgeuQrt0pS+ahJ+Hhm/gAMrPFNY19uESz6VdHcv6A+iVSg+1iAHygTCPr9n1rx5NIeyuoDFsnftjFAwaauXvPazhRUrUI65aNpWGAWb/Tgb8fuVM8nqty2sx60xKzhV+uYw9XAsuVuuxTACKTvLN/YZhrWbArv1Pv7tI9OYNWmjjJnOkVbu4uJtqKbMLW6el3fIhNgjQJke+IVtPPytcfU8aMCVDpI695v5v4+lqzJLfyUQiDI+A78wIGjN30WoTdz6jTfbEaV/92K1/+jAoQLJVceKVu1OQ33wzVI1nlwh1Th5dfKBWWARLIKXkMF3HrPKE4xTl0Vkg0e3AFJMxZ43xjBOzbJ355ZQMiVL5UueOqAOnRypLgqQKAUfrvqSNlmnr3wLD4yWId5Bc+v7GotZs87jbpqvfLbiqWre7YmvSEXCLLHB3j9YRAYs3RNH6ZkANZu7lmoL/6xVPj4fWAMnF2bAq1xATEWWccPhviZRUuwSAHKReT6EWLPPVqjAPET1vox6v6K0k8km48992iNAuhpmCgHqbQ9veNqs2n7CRU4LpR+WtQSrLmS9pR+iYLgS+MLl3X7Ez+fN1KcpIP2DnssgD1XAuCvL4yWcVM8BKcCZFI6she/HCL/MW4UPOFrAkix/zC+1YE4bt4OnHw996PtWPFOH4R5skUHkOjlDuGDw/rvuP6ovmgHUBg8jkPJeW8jiUO9ceDIPEcQzv0rrnew940MPtO8y5p2t+ZCYhY9/ElpHKbg+PGmzWijqBFU9gH/6Ge+MPOe+Q/fD5OL8GcDcEHuse5St65yr3fJHsr+m/9+gfiVMwXF584vXtTSSuUqvHs2wI+eOGBdmxNCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQgghhBBCCCGEEEIIIYQQQnAN+C+fhn0Gn7QGBAAAAABJRU5ErkJggg==";
    static NSString *const kIconTraffic = @"iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAIn0lEQVR4nO3ce2wcxR0H8O/s7j18MSaPNgK1jTHY50vi14VEcexARJVW/aMSUQOoalHVCKqCSosQpKpQeYhSiCD1H1WTpkJENEkToohIIJRWStWqlNLSkoY864S83KgRUuI6sc+58+3t/KqZ3buz3QB9xPaM+X0Sn897e7uzu7+dmZ2dWYAxxhhjjDHGGGOMMcYYY4wxxhhjjDHGGGOMMcYYY4wxxhhjjDHGGGOMMcYYY4wxxphBBKaZhq/NJ2+WB1HnQtR6cFMxOAkBxByImAO4AtIDSIQbL4QAgSBIQBDBkQBKAAIB8gOgSJD5AJQLEAyWUPqnj1J/EWdePTYt9p21G3HT3RlKdc+Gqw52ghBIQI4EkHkJORwgyAWgQQmZK+kDGBTUwQTO7jr+kdtcf0eakBBwkx5EyoOnAqnWg1PrwtFB5cJJuoAHyCBAcN7H8BsDOLn1iHX707oEK9kXu0nMiePS3vM4ueHwlG9D43faaOYX54L+4WPfmt9NeXqmteymZdSxcRnBQIt33ErtPWambdpYuuc2o3fw0l+vNDp94zmwSObbrZT/2zBMVjhbQMOdGWuCwKoAQK2D0qAPk9FQCe5MD7YwPqWNaxZQqnMmigM+EnM9XH53CCYLLvpIZa9B87NZ8uriOPKtt7lS+P/I/qxaqVrwVActeCKr/66/Mz3h2exn7mi64jrmfSlN81aPXb++dFRpfP5manqkpfJZ26j0m8joHCD9zRYa/P1AdYIr4MRcNH+vg8Q1DtKtYTBAv1L5fzhJqJYeglD/SP0mqDYeRU1TryTUF6L5aPQn4WQIgUzbzdHSy/OEBaeaszmbJZAEqUYkV6Dphjb1FvCqJ30pV4TJjA4Atz4BRySqf9e5yL+Tw4mf9xqbrTY91ELOJ6q71f1UNf0mMrYSOP/xRZTomomapbORXtsRnnsJV59tRpNh87Ky+Jefpdi1NVjy2ueMLQaMzQFoloMgH8CREqiJ4tRzIfPG7kuNCgThhukNVPGQJ7gxF6YyNwAk6TKaHIBUQ78qkmMCp3eZm/0rVJCgmH4b1hzcQNclTGVsAKhsVO23cv1OM/dEqpAjVKkEqldXVz/NzbWMrQM4EHCkgJBRjVzt0FG1a1NRUUI4YTodIlUOwGTmBgAJxGbGEJut7rlGV3sW5ABndh8XIh7uVpFy4c2Jwa0xN+HGFgGHH/6zyDyaJSklTqw7oE8pg4vSMZxUGAD9m84hnk5h5GgOpjI2AJTeZ/aPPeQqS7WBEyb71E7zew0ZWwRciZB2JNeFPezYoxHT24DKbCmqrAuA6vWgHUWADawKAH1ZZQFy7EindQHAPu4BYEklQNiRTBsDYKoTMP3YFQBRi6DxhD1ZgNENQeNd7Zsqjfe1EJICFFA0REy1NVW7FalePrhEOPnSfzv4xJ4AsEr7y8uvehZQv7rxQ5fZcP9CaunppPTX2/7jdXfsvvrpZCoAXpm6Hdvy0y7K7l5Bjfd9eCA0rE6TTQFgVREgagWa1y8i3VdApTxQPbAIUnfgpEqnTv1OhNWbMFuXYaYcHRY9rZzFI8yuCYH+tjN6KarzpyoRCoT8+UGM5OKIZWvQtncFwQeKh4dB5ZHGqvGnEOg0ioQ9jcF2BUDShTxXwns9B6e8kG1+ejH5fSM49cKhMWmZ/2yWuCVwgpR6i3A8gZb1U9/X/tj33xHjD37rTzrJP1uE/77ZXcGtzQFUE+ux58K+AZnHlpA7QxUFns7FpSoMgvKVQlirD28fh/0JSXUt0tPKx0x1OasWGfqsjcYP6Pkrvx0QBXpRItCjDPT6hBpLUAo7qQifIHMBDj3wJ73w9h3dUx6g0zQAykM7gN4f/GXKi4EPYsktC/sagsLzdazr19xI193bMCW7/Lp7Guj6e/593cZGpvU5wLi/Wzd0UleiFUkvgTc636X99745afu+fdMyuiW2CIEr8WbnATr0jbeElRFgk4WbOysx0PBkC/1w8+NEuYtEpWHaumsjZX4UjuObaE3PtdOGLeuJ/DxRoUA929bRjevaqwNCd3RZUwjYVQSMOrOkEFiZ7gZmxCDdy/h8+y2oCSojMiZUPEjgC9nbIL0ikAiwsrlb9/+3kVUBoMYKlLnk4RdH96Dw/iCcXAxb334Vw7H8pKRjxA2wY9/rEJeA4oUCth99TY9ALlOPnLOFVXUAxKtvTz25X7z+lKS+nX1IukkcLPTi+NrwEnGinfjuPrFtHdGBl46gKHz0Dp/C8Uer6xZxewLAKq2/WU7Nz4wt5294KEPz1k78wyKuZN7DGap/pLmy7vovZyj94yXU/qsV1tQBrArVti1dNLSnH6mWOjgzXPiq+aco9Sgip0b9uPoJn2o8WfW2rhpkWn5bbQTSjfwinCSp3Hik2v9F2Oijv64uPMPGIfWqFhLOIsIxgPnofkHS1Y1KwQUfl98bwqxVn8TBu/5gxb61qghQLXGnXzZ/sMWcVXOtyQE8W6usd93eTRuf/wqCIR8yALy6JLbvfAsPPrFlwgNkc8/9dPuqJfAvFuCoNMUEvvrAC9j7279GtxaNj1E7A8C9tnqZN1zwcfrMAOTlEZ3dx4eS6B+YnCeIXRjI4UxfP/yhAhz1DAOXkB+p3gDyUpNzOfqxk912K2Uem5zGnv9V24vLaeHTS41O42j25FWR7K4VpPLd0rlCJfVB9DQwBw4kqbt+4ZapziK6rkdRJS6q/IUdRkhX9srdSNS1e3VAR2VqeFeQyncOo891r5Hwc718SZCBRPzTCfh/L+LQg3+0Zr9ak9DxGu7OkHoYgzpAqhavD4bamph6zn/0SJny5qkACAeYV76vD6aIavrlnkKjuw3pu77RIY9q/+rJH3qeQIdWGFLRdDVP3/aPfhQ9Y4wxxhhjjDHGGGOMMcYYY4wxxhhjjDHGGGOMMcYYY4wxxhhjjDHGGGOMMcYYY4wxxhg+wL8AHjEX6s4PERcAAAAASUVORK5CYII=";
    static NSString *const kIconTicket  = @"iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAF8ElEQVR4nO3cW2gcVRgH8P+Znbgmbmob0ku8YBRfFGxVUB8UrPgmKIIXBKHFt760fbP6YAUf+qB4qVTUpyIF2xd9EUEpQaEWq75oQeiL19hGba1pQ2g3ZuaTc5mZjbuZdYem+yX8f73sZjIzO3vON2fO+c7sAkRERERERERERERERERERERERERERERERERERERERERERERERERERERERERERNQfBoqNPrhDTDwIQCB2gRj3bMFBG7vMs48mfyL+MVvbCIzYrSO7Sctys3BjsdsJxJjwo7hVRIzfZxvT8n9+BGHdCJE08eenr6ktZ7UHtu7Z45KM3wZcBCTyZevqKtRBy1Nf7GGBD5TF351dz/3z8eRk22T1m1dz2N/CgCtevDUcIvOf+g/bp3UgOnMKp1+4Vm1ZqzN67zMyuk9kZPPOTqfcsrLmrqdk9ZsiIw/tVvle7LmljtQGgTnB2c/3Lvuz5u9vDhkzexESD0EjlQEASUKbujKk9oIgKTRSGQDGGJ0HVpHtSNp/GiktZ52FVVnW21RIZQDYk0Vng1mN3uoHYmiUjc1XCHEtms5WTWcAuEF5+RrvPTcmV9ddDysffxc5nWzjtEjRGOD8PxG27jnZh+gy7o9GSgOg3Fvb18uWxwWYApDYq1jIwriRQwSYUPHZtdclb1JgfYI19TF55MUpc7k7tQY6qQwAm5ErK7Cheor56RgDD/dWkTMfbJBVV3buXVzz5C0SDUSQ+dQP29xf49LHNqbyrKH70f5G8mX258n3vy85liJdrY3KALB5+LI0QCr2wHs/p2zldtrsum0bZfjte5DMXEBqK1YEqTsAg1roKaeR/Y1vYWyA1IxBbNdLBbVGA+ObRuTnXUc6HlTb/IUiKgOg+xlTrTiNmyBq3/a3d46bG28YlnmTInUJG19lfs6omOzJlmWPUTYfcEWEyV1fLHpQYSpLJaUBYM/C0l9XiwE3G9jZT88fXbKTNLIzitBJZR7AKT1pWqbuet1nP05GyaYQ9dEZAH5KvoTt4Vfd9eWvCOOGqAyAHnS5anYbJiy21y6V8Ojt62SpGgCtcwEq+wBLV1Sdz/+dD4zJG08PArMpIOM+uvIbP8Lz/Miy4LPjwcjnmhoD2PfRBWz/cLIkwhgAl7Ieu10jOjM2SdS+eO9nU+bODdeLSyy6UUCRQCpSOD548ld1eabEPw4k5ZWvtPlX2wK4QWDZueTa1Cr7DUPBDrYeLDt7LwWdQaCzE/h/SNXOZZ8qwkAlpQFgurSa1YZVOq/C/RWrHQWU3BDgm/EqAWADS+mp2CdKA6BLJRlxOftK++1wCXhs0xOy5/5XMdOc9T1718G0j0XH33/EIEwt29/nfQlBoz6MV756Cfu/frfjgetNAykNAFf+JSVWi2qIGgmOvjwmZ2eBOAqp47xzmH/Kw62fiOCqOrBqbYrol4G2/U03p/HDuR/RnJ9zE03Z9K0fuxcfHvAvkc1T2A+a2BZFMDTXwLnm+UWP193hyDxAb8pa6kNHBPfdOoA7xhMXwcWHQfJpGhjXRhSfArFBcPL3CPsnkrb9TZw4bCZOHF6698I7gnossNbcSwefHPvD3HwMy4a4vofO/rbOo1J8zazCX56gks4AsNfbFXRbsBggVRrROgOg+mSfSsbdQ6TzHakMAJ1FVR2Hgb0WmI2AFXQJiCVRe1uYzhagFkNqOgusClOLgKg9/6CB0q4JMPq6iPz1K6JT3wKxnagtkjJ+tB+SP9mXPYSGdsEXP4RckE3suG1CMiZLB4ubdEzyzF/2CvaZ30cYwYdvDLE7a/kUQniRcPtK6zdThHGsJE3I6nHUbtoIHNiC018eUFfe6g4os3bzDpG7t0HiRki9tn6dh/H3aWQ1nN1DllV0ftEtul6+/vJ7fYt7/8UutzeCZK/ss3vZldtWbn4biUnzIPJrFKlld8UyPnjs9u72crfiHOLvDuLMx7vVljURERERERERERERERERERERERERERERERERERERERERERERERERERERERERERGhD/4FUgH4N1a+GtwAAAAASUVORK5CYII=";
    return @[
        @{ @"title": @"优惠券", @"iconData": kIconCoupon,  @"class": @"WCMktCouponHomeViewControllerV2",  @"fallback": @"WCMktCouponHomeViewController" },
        @{ @"title": @"会员卡", @"iconData": kIconMember,  @"class": @"WCMktMemberCardHomeViewController", @"fallback": @"" },
        @{ @"title": @"交通卡", @"iconData": kIconTraffic, @"placeholder": @YES },
        @{ @"title": @"票证",   @"iconData": kIconTicket,  @"class": @"WCMktTicketListViewControler",     @"fallback": @"" },
    ];
}

- (instancetype)init {
    // 用 Plain 样式，避免 Grouped 顶部/分区自带的留白，列表紧贴标题栏
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        self.title = @"卡包";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 页面背景：深色 #111111 / 亮色 #EDEDED
    self.tableView.backgroundColor = CardPageBackgroundColor();
    // 通栏卡片列表：无分隔线、无左右边距、无圆角
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    self.tableView.estimatedRowHeight = 0;
    self.tableView.rowHeight = 64.0; // 56pt 卡片 + 上下各 4pt 间距
    self.tableView.contentInset = UIEdgeInsetsZero;
    // 细返回箭头：替代微信导航栏默认的粗箭头
    @try {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithWeight:UIImageSymbolWeightLight];
        UIImage *arrow = [[UIImage systemImageNamed:@"chevron.backward" withConfiguration:cfg]
                          imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:arrow
                                                                                 style:UIBarButtonItemStylePlain
                                                                                target:self
                                                                                action:@selector(ABBackTapped:)];
    } @catch (NSException *exception) {
        TFLog(@"[APIBlocker] 卡包细返回箭头设置失败：%@", exception.reason);
    }
}

- (void)ABBackTapped:(id)sender {
    [self.navigationController popViewControllerAnimated:YES];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)LegacyCardHomeEntries().count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 64.0; // 56pt 卡片 + 上下各 4pt 间距
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const kCellID = @"LegacyCardHomeCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kCellID];
        cell.backgroundColor = [UIColor clearColor];   // 透出页面背景
        cell.contentView.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.separatorInset = UIEdgeInsetsZero;
        // 通栏卡片条（56pt 高，上下各留 4pt 形成 8pt 行间距）
        CGFloat W = tableView.bounds.size.width;
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 4, W, 56)];
        card.backgroundColor = CardCellBackgroundColor();
        card.tag = 9001;
        // 按下高亮背景：与卡片同尺寸（0,4,W,56），不超出条目宽度
        UIView *selBg = [[UIView alloc] initWithFrame:CGRectMake(0, 4, W, 56)];
        selBg.backgroundColor = CardCellSelectedColor();
        selBg.tag = 9010;
        cell.selectedBackgroundView = selBg;
        // 彩色图标（45pt 居中）
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(16, (56 - 45) / 2.0, 45, 45)];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.tag = 9002;
        [card addSubview:iv];
        // 标题（浅灰白文字）
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(58, 0, W - 58 - 40, 56)];
        lab.font = [UIFont systemFontOfSize:16];
        // 文字颜色：亮色=黑，暗色=浅灰（与截图一致）
        lab.textColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
            return (t.userInterfaceStyle == UIUserInterfaceStyleDark) ? [UIColor colorWithWhite:0.85 alpha:1.0] : [UIColor blackColor];
        }];
        lab.tag = 9003;
        [card addSubview:lab];
        // 右侧灰色箭头
        UIImage *chev = [[UIImage systemImageNamed:@"chevron.right"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        UIImageView *arrow = [[UIImageView alloc] initWithImage:chev];
        arrow.tintColor = [UIColor colorWithWhite:94/255.0 alpha:1.0];
        arrow.frame = CGRectMake(W - 22, (56 - 14) / 2.0, 9, 14);
        arrow.tag = 9004;
        [card addSubview:arrow];
        [cell.contentView addSubview:card];
    }
    NSDictionary *entry = LegacyCardHomeEntries()[(NSUInteger)indexPath.row];
    UIView *cardV = [cell.contentView viewWithTag:9001];
    UIImageView *iv = (UIImageView *)[cardV viewWithTag:9002];
    iv.image = CardPageIcon(entry[@"iconData"]);
    UILabel *lab = (UILabel *)[cardV viewWithTag:9003];
    lab.text = entry[@"title"];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *entry = LegacyCardHomeEntries()[(NSUInteger)indexPath.row];
    // 交通卡：微信里是服务端下发的 H5 入口，本地无法复现，点击仅提示
    if ([entry[@"placeholder"] boolValue]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"交通卡"
                                                                       message:@"请在微信「我 - 钱包 - 交通卡」中管理"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIViewController *page = MakeCardSubPage(entry[@"class"], entry[@"title"]);
    if (!page && [entry[@"fallback"] length] > 0) {
        page = MakeCardSubPage(entry[@"fallback"], entry[@"title"]);
    }
    if (!page) {
        TFLog(@"[APIBlocker] 卡包二级页创建失败：%@", entry[@"title"]);
        return;
    }
    ApplyPlainBackButton(self);
    ApplyPlainBackButton(page);
    if (self.navigationController) {
        TFLog(@"[APIBlocker] 卡包入口 -> push %@", entry[@"title"]);
        [self.navigationController pushViewController:page animated:YES];
    } else {
        TFLog(@"[APIBlocker] 卡包入口 -> present %@", entry[@"title"]);
        [self presentViewController:page animated:YES completion:nil];
    }
}

@end

// 恢复旧版卡包：拦截“我 → 卡包”点击，直接进自建的四入口卡包页
static void (*orig_MoreViewControllerOnCardsEntryClicked)(id, SEL);

static void APIBlockerOnCardsEntryClicked(id self, SEL _cmd) {
    @try {
        if (OldCardPageEnabled()) {
            UIViewController *host = (UIViewController *)self;
            LegacyCardHomeViewController *home = [[LegacyCardHomeViewController alloc] init];
            UINavigationController *nav = host.navigationController;
            if (nav) {
                ApplyPlainBackButton(host);
                ApplyPlainBackButton(home);
                TFLog(@"[APIBlocker] 卡包入口 -> push 自建旧版卡包页");
                [nav pushViewController:home animated:YES];
            } else {
                TFLog(@"[APIBlocker] 卡包入口 -> present 自建旧版卡包页");
                [host presentViewController:home animated:YES completion:nil];
            }
            return;
        }
    } @catch (NSException *exception) {
        TFLog(@"[APIBlocker] 卡包入口处理异常，回退原生行为：%@", exception.reason);
    }
    if (orig_MoreViewControllerOnCardsEntryClicked) {
        orig_MoreViewControllerOnCardsEntryClicked(self, _cmd);
    }
}

// 卡包首页数据落地前补齐入口（只 hook 目标类自己实现的方法）
static void (*orig_SetMktCardHomePageResponse)(id, SEL, id);

static void APIBlockerSetMktCardHomePageResponse(id self, SEL _cmd, id response) {
    @try {
        InjectLegacyTopCells(response);
    } @catch (NSException *exception) {
        TFLog(@"[APIBlocker] 补入口异常：%@", exception.reason);
    }
    orig_SetMktCardHomePageResponse(self, _cmd, response);
}

// 点击合成入口时，打开对应二级页面
static void (*orig_HandleHomePageTopCellClick)(id, SEL, id);

static void APIBlockerHandleHomePageTopCellClick(id self, SEL _cmd, id indexPath) {
    @try {
        if (OldCardPageEnabled()) {
            SEL elemSel = NSSelectorFromString(@"getHomePageTopCellElemWithIndexPath:");
            if ([self respondsToSelector:elemSel]) {
                id elem = [self performSelector:elemSel withObject:indexPath];
                NSString *jump = [elem valueForKey:@"cardTopCellJumpUrl"];
                if ([jump isEqualToString:kMemberCardJumpMarker]) {
                    PresentSubPage([self valueForKey:@"delegate"], MemberCardPage());
                    return;
                }
                if ([jump isEqualToString:kCouponJumpMarker]) {
                    PresentSubPage([self valueForKey:@"delegate"], CouponPage());
                    return;
                }
            }
        }
    } @catch (NSException *exception) {
        TFLog(@"[APIBlocker] 入口跳转异常：%@", exception.reason);
    }
    orig_HandleHomePageTopCellClick(self, _cmd, indexPath);
}


// 首页底部那块内嵌“卡券（暂无卡券）”的数据源，开关打开时返回空
static id (*orig_GetHomePageStoreListData)(id, SEL);

static id APIBlockerGetHomePageStoreListData(id self, SEL _cmd) {
    if (OldCardPageEnabled()) {
        return nil;
    }
    return orig_GetHomePageStoreListData(self, _cmd);
}

// ============ 强制 CallKit 系统来电 ============
//
// 微信内部有两条来电通道：
//   1) CallKit（CXProvider / CXCallController）—— 系统级来电，可在系统电话界面接听；
//   2) LCK（LiveCommunicationKit）—— App 内顶部浮窗样式。
// 分流判断集中在 VoIPPushKitNotifyService：LCK 侧是 +isVoIPLCKAvailable / -useVoIPLCK /
// -setUseVoIPLCK:，CallKit 侧是 +isCallkitAvailable / +isDeviceCallkitAvailable /
// +getCallkitSwitchFromService / +getIfCanUseCX:isMultiTalk:。
// 开关打开时：LCK 一律不可用，CallKit 一律可用。开关关闭时完全走原生逻辑。

static BOOL (*orig_isVoIPLCKAvailable)(id, SEL);
static BOOL (*orig_useVoIPLCK)(id, SEL);
static void (*orig_setUseVoIPLCK)(id, SEL, BOOL);
static BOOL (*orig_isCallkitAvailable)(id, SEL);
static BOOL (*orig_isDeviceCallkitAvailable)(id, SEL);
static BOOL (*orig_getCallkitSwitchFromService)(id, SEL);
static BOOL (*orig_getIfCanUseCX)(id, SEL, BOOL, BOOL);

static BOOL APIBlockerIsVoIPLCKAvailable(id self, SEL _cmd) {
    if (ForceCallKitEnabled()) {
        TFLog(@"[APIBlocker] LCK 可用性查询 -> NO（强制 CallKit）");
        return NO;
    }
    return orig_isVoIPLCKAvailable ? orig_isVoIPLCKAvailable(self, _cmd) : YES;
}

static BOOL APIBlockerUseVoIPLCK(id self, SEL _cmd) {
    if (ForceCallKitEnabled()) {
        TFLog(@"[APIBlocker] useVoIPLCK -> NO（强制 CallKit）");
        return NO;
    }
    return orig_useVoIPLCK ? orig_useVoIPLCK(self, _cmd) : NO;
}

static void APIBlockerSetUseVoIPLCK(id self, SEL _cmd, BOOL value) {
    if (ForceCallKitEnabled()) {
        TFLog(@"[APIBlocker] setUseVoIPLCK:%d -> 忽略，保持关闭", value);
        return;
    }
    if (orig_setUseVoIPLCK) {
        orig_setUseVoIPLCK(self, _cmd, value);
    }
}

static BOOL APIBlockerIsCallkitAvailable(id self, SEL _cmd) {
    if (ForceCallKitEnabled()) {
        TFLog(@"[APIBlocker] isCallkitAvailable -> YES（强制 CallKit）");
        return YES;
    }
    return orig_isCallkitAvailable ? orig_isCallkitAvailable(self, _cmd) : NO;
}

static BOOL APIBlockerIsDeviceCallkitAvailable(id self, SEL _cmd) {
    if (ForceCallKitEnabled()) {
        return YES;
    }
    return orig_isDeviceCallkitAvailable ? orig_isDeviceCallkitAvailable(self, _cmd) : NO;
}

static BOOL APIBlockerGetCallkitSwitchFromService(id self, SEL _cmd) {
    if (ForceCallKitEnabled()) {
        TFLog(@"[APIBlocker] getCallkitSwitchFromService -> YES（强制 CallKit）");
        return YES;
    }
    return orig_getCallkitSwitchFromService ? orig_getCallkitSwitchFromService(self, _cmd) : NO;
}

static BOOL APIBlockerGetIfCanUseCX(id self, SEL _cmd, BOOL isMultiTalk, BOOL arg2) {
    if (ForceCallKitEnabled()) {
        TFLog(@"[APIBlocker] getIfCanUseCX:isMultiTalk: -> YES（强制 CallKit）");
        return YES;
    }
    return orig_getIfCanUseCX ? orig_getIfCanUseCX(self, _cmd, isMultiTalk, arg2) : NO;
}

// ============ 拍一拍 / 群待办 过滤 ============

// ============ 锁屏来电界面的名称 / 图标 ============
//
// CallKit 锁屏来电界面上那行“微信视频 / 微信音频”来自
// CXProviderConfiguration.localizedName，图标来自 iconTemplateImageData。
// 这两个 setter 只有使用 CallKit 的 App（这里就是微信）会调用，所以只影响来电界面本身。

static void (*orig_SetProviderLocalizedName)(id, SEL, id);
static void (*orig_SetProviderIconTemplate)(id, SEL, id);

// 全透明的 1x1 PNG：返回 nil 时 CallKit 会回退去画 App 图标，
// 给一张空图才能让来电界面上的图标真的“没有内容”。
// 直接写死字节，避免用 UIKit 画图（配置对象可能在子线程创建）。
static NSData *TransparentIconData(void) {
    static NSData *data;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        static const unsigned char bytes[] = {
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG 头
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        };
        data = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    });
    return data;
}

static void APIBlockerSetProviderLocalizedName(id self, SEL _cmd, id name) {
    @try {
        NSString *custom = CallKitCustomName();
        if (custom.length > 0) {
            TFLog(@"[APIBlocker] 来电名称改为自定义：%@", custom);
            orig_SetProviderLocalizedName(self, _cmd, custom);
            return;
        }
        if (CallKitHideNameEnabled()) {
            TFLog(@"[APIBlocker] 来电名称已隐藏（原值：%@）", name);
            orig_SetProviderLocalizedName(self, _cmd, @"");
            return;
        }
    } @catch (NSException *exception) {
        TFLog(@"[APIBlocker] 来电名称处理异常：%@", exception.reason);
    }
    orig_SetProviderLocalizedName(self, _cmd, name);
}

static void APIBlockerSetProviderIconTemplate(id self, SEL _cmd, id data) {
    if (CallKitHideIconEnabled()) {
        TFLog(@"[APIBlocker] 来电图标已替换为透明图");
        orig_SetProviderIconTemplate(self, _cmd, TransparentIconData());
        return;
    }
    TFLog(@"[APIBlocker] 来电图标设置（%lu 字节）", (unsigned long)[data length]);
    orig_SetProviderIconTemplate(self, _cmd, data);
}

// 直接改 getter：不管谁在什么时候读配置，都返回我们的值（provider 已创建也有效）
static id (*orig_GetProviderLocalizedName)(id, SEL);
static id (*orig_GetProviderIconTemplate)(id, SEL);

// 把当前设置应用到配置对象上（名称 + 图标）
static void ApplyCallKitConfigToProviderConfiguration(id configuration) {
    if (!configuration) {
        return;
    }
    @try {
        NSString *custom = CallKitCustomName();
        NSString *targetName = nil;
        if (custom.length > 0) {
            targetName = custom;
        } else if (CallKitHideNameEnabled()) {
            targetName = @"";
        }
        if (targetName && orig_SetProviderLocalizedName) {
            orig_SetProviderLocalizedName(configuration, NSSelectorFromString(@"setLocalizedName:"), targetName);
        }
        if (CallKitHideIconEnabled() && orig_SetProviderIconTemplate) {
            orig_SetProviderIconTemplate(configuration, NSSelectorFromString(@"setIconTemplateImageData:"), TransparentIconData());
        }
        NSString *currentName = nil;
        @try {
            currentName = [configuration valueForKey:@"localizedName"];
        } @catch (NSException *exception) {
        }
        TFLog(@"[APIBlocker] 新建 CallKit 配置：localizedName=%@，custom=%@，hideName=%@，hideIcon=%@",
              currentName.length > 0 ? currentName : @"（空）",
              custom ?: @"无",
              CallKitHideNameEnabled() ? @"开" : @"关",
              CallKitHideIconEnabled() ? @"开" : @"关");
    } @catch (NSException *exception) {
        TFLog(@"[APIBlocker] 应用 CallKit 配置失败：%@", exception.reason);
    }
}

static id APIBlockerGetProviderLocalizedName(id self, SEL _cmd) {
    NSString *custom = CallKitCustomName();
    if (custom.length > 0) {
        TFLog(@"[APIBlocker] 读取来电名称 -> 自定义：%@", custom);
        return custom;
    }
    if (CallKitHideNameEnabled()) {
        TFLog(@"[APIBlocker] 读取来电名称 -> 空");
        return @"";
    }
    id value = orig_GetProviderLocalizedName ? orig_GetProviderLocalizedName(self, _cmd) : nil;
    TFLog(@"[APIBlocker] 读取来电名称 -> 原值：%@", value);
    return value;
}

static id APIBlockerGetProviderIconTemplate(id self, SEL _cmd) {
    if (CallKitHideIconEnabled()) {
        TFLog(@"[APIBlocker] 读取来电图标 -> 透明图");
        return TransparentIconData();
    }
    return orig_GetProviderIconTemplate ? orig_GetProviderIconTemplate(self, _cmd) : nil;
}

// 记录 CallKit 的来电人名，方便对照锁屏上显示的内容
static void (*orig_SetLocalizedCallerName)(id, SEL, id);

static void APIBlockerSetLocalizedCallerName(id self, SEL _cmd, id name) {
    TFLog(@"[APIBlocker] CallKit 来电人名：%@", name);
    orig_SetLocalizedCallerName(self, _cmd, name);
}

// 微信不会调用 setLocalizedName:，那行“微信音频 / 微信视频”是按空值由系统渲染的，
// 所以这里在创建 CXProvider 时直接改配置对象（在调用原始 init 之前）。
static id (*orig_ProviderInitWithConfiguration)(id, SEL, id);

static id APIBlockerProviderInitWithConfiguration(id self, SEL _cmd, id configuration) {
    @try {
        ApplyCallKitConfigToProviderConfiguration(configuration);
    } @catch (NSException *exception) {
        TFLog(@"[APIBlocker] provider 配置处理异常：%@", exception.reason);
    }
    return orig_ProviderInitWithConfiguration(self, _cmd, configuration);
}

// 拍一拍消息的 view model 是 AppPatMessageViewModel；不加入显示列表即等同于不显示
static void (*orig_AddChatViewModel)(id, SEL, id, BOOL);

static void APIBlockerAddChatViewModel(id self, SEL _cmd, id viewModel, BOOL addMoreMsg) {
    @try {
        Class patViewModelClass = NSClassFromString(@"AppPatMessageViewModel");
        NSString *vmName = NSStringFromClass([viewModel class]);
        if ([vmName rangeOfString:@"Pat"].location != NSNotFound) {
            TFLog(@"[APIBlocker] 消息 view model：%@（addChatViewModel）", vmName);
        }
        if (patViewModelClass && [viewModel isKindOfClass:patViewModelClass]) {
            NSString *chat = nil;
            SEL chatSel = NSSelectorFromString(@"getCurrentChatName");
            if ([self respondsToSelector:chatSel]) {
                chat = [self performSelector:chatSel];
            }
            if (!ShouldShowPatInChat(chat)) {
                TFLog(@"[APIBlocker] 已隐藏拍一拍（%@）", chat.length > 0 ? chat : @"未知会话");
                return;
            }
        }
    } @catch (NSException *exception) {
        TFLog(@"[APIBlocker] 拍一拍过滤异常：%@", exception.reason);
    }
    orig_AddChatViewModel(self, _cmd, viewModel, addMoreMsg);
}

// 从消息里取会话名（群聊优先用 @chatroom 那一侧）
static NSString *ChatNameFromMessageWrap(id wrap) {
    if (!wrap) {
        return nil;
    }
    @try {
        NSString *from = [wrap valueForKey:@"m_nsFromUsr"];
        NSString *to = [wrap valueForKey:@"m_nsToUsr"];
        if ([from rangeOfString:@"@chatroom"].location != NSNotFound) {
            return from;
        }
        if ([to rangeOfString:@"@chatroom"].location != NSNotFound) {
            return to;
        }
        return from.length > 0 ? from : to;
    } @catch (NSException *exception) {
    }
    return nil;
}

static BOOL ShouldHidePatForWrap(id wrap) {
    return !ShouldShowPatInChat(ChatNameFromMessageWrap(wrap));
}

// 拍一拍行高置 0：视觉上直接消失，不动消息数据，也不动列表结构
static double (*orig_ChatViewModelRowHeight)(id, SEL);

static double APIBlockerChatViewModelRowHeight(id self, SEL _cmd) {
    @try {
        Class patViewModelClass = NSClassFromString(@"AppPatMessageViewModel");
        if (patViewModelClass && [self isKindOfClass:patViewModelClass]) {
            id wrap = [self valueForKey:@"messageWrap"];
            if (ShouldHidePatForWrap(wrap)) {
                TFLog(@"[APIBlocker] 拍一拍行高置 0（%@）", ChatNameFromMessageWrap(wrap) ?: @"未知会话");
                return 0.0;
            }
        }
    } @catch (NSException *exception) {
        TFLog(@"[APIBlocker] 拍一拍行高处理异常：%@", exception.reason);
    }
    return orig_ChatViewModelRowHeight(self, _cmd);
}

// 双保险：拍一拍 cell 的内容全部隐藏
static void (*orig_PatCellLayoutContentView)(id, SEL);

static void APIBlockerPatCellLayoutContentView(id self, SEL _cmd) {
    orig_PatCellLayoutContentView(self, _cmd);
    @try {
        id viewModel = [self valueForKey:@"viewModel"];
        id wrap = [viewModel valueForKey:@"messageWrap"];
        if (ShouldHidePatForWrap(wrap)) {
            for (UIView *subview in ((UIView *)self).subviews) {
                subview.hidden = YES;
            }
            ((UIView *)self).backgroundColor = [UIColor clearColor];
        }
    } @catch (NSException *exception) {
    }
}

// 群待办顶部列表由 WCGroupUndoneMgr 提供，返回空数组即不显示
static id (*orig_GetUndoneListOfGroup)(id, SEL, id);

static id APIBlockerGetUndoneListOfGroup(id self, SEL _cmd, id group) {
    @try {
        NSString *chat = [group isKindOfClass:[NSString class]] ? group : nil;
        if (chat.length == 0 && group) {
            @try {
                chat = [group valueForKey:@"m_nsUsrName"];
            } @catch (NSException *exception) {
            }
        }
        if (!ShouldShowGroupUndoneInChat(chat)) {
            TFLog(@"[APIBlocker] 已隐藏群待办列表（%@）", chat.length > 0 ? chat : @"未知群");
            return @[];
        }
    } @catch (NSException *exception) {
        TFLog(@"[APIBlocker] 群待办过滤异常：%@", exception.reason);
    }
    return orig_GetUndoneListOfGroup(self, _cmd, group);
}

// ============ 聊天详情页注入单聊开关 ============


static NSMutableArray *g_chatSwitchHandlers; // 保活 target，避免开关回调时 target 已释放

@interface APIBlockerChatSwitchHandler : NSObject
@property (nonatomic, copy) NSString *chat;
@property (nonatomic, copy) NSString *kind; // pat / undone
- (void)switchChanged:(id)sender;
- (void)noopCellTap:(id)sender;
@end

@implementation APIBlockerChatSwitchHandler

- (BOOL)switchStateFromSender:(id)sender {
    if ([sender isKindOfClass:[UISwitch class]]) {
        return [(UISwitch *)sender isOn];
    }
    for (NSString *key in @[@"accessoryView", @"switchView", @"m_switch", @"switchControl", @"m_switchView", @"valueView"]) {
        @try {
            id value = [sender valueForKey:key];
            if ([value isKindOfClass:[UISwitch class]]) {
                return [(UISwitch *)value isOn];
            }
        } @catch (NSException *exception) {
        }
    }
    BOOL current = [self.kind isEqualToString:@"pat"] ? ShouldShowPatInChat(self.chat) : ShouldShowGroupUndoneInChat(self.chat);
    return !current;
}

- (void)switchChanged:(id)sender {
    BOOL on = [self switchStateFromSender:sender];
    BOOL isPat = [self.kind isEqualToString:@"pat"];
    if (isPat) {
        SetPatShownInChat(self.chat, on);
    } else {
        SetGroupUndoneShownInChat(self.chat, on);
    }
    TFLog(@"[APIBlocker] %@：%@ -> %@", self.chat, isPat ? @"显示拍一拍" : @"显示群待办", on ? @"开" : @"关");
}

- (void)noopCellTap:(id)sender {
}

@end

static NSString *ChatNameFromInfoVC(UIViewController *vc) {
    for (NSString *key in @[@"m_chatRoomContact", @"m_contact", @"m_chatContact", @"m_oContactInfoAssist"]) {
        @try {
            id value = [vc valueForKey:key];
            if (!value) {
                continue;
            }
            NSString *name = [value valueForKey:@"m_nsUsrName"];
            if (name.length > 0) {
                return name;
            }
            id contact = [value valueForKey:@"m_contact"];
            name = [contact valueForKey:@"m_nsUsrName"];
            if (name.length > 0) {
                return name;
            }
        } @catch (NSException *exception) {
        }
    }
    return nil;
}

static id FindTableManager(UIViewController *vc) {
    Class managerClass = NSClassFromString(@"WCTableViewManager");
    if (!managerClass) {
        return nil;
    }
    for (NSString *key in @[@"m_tableViewInfo", @"m_tableViewManager", @"m_oContactInfoAssist", @"m_tableView"]) {
        @try {
            id value = [vc valueForKey:key];
            if (!value) {
                continue;
            }
            if ([value isKindOfClass:managerClass]) {
                return value;
            }
            for (NSString *subKey in @[@"m_tableViewInfo", @"m_tableViewManager"]) {
                @try {
                    id inner = [value valueForKey:subKey];
                    if ([inner isKindOfClass:managerClass]) {
                        return inner;
                    }
                } @catch (NSException *exception) {
                }
            }
        } @catch (NSException *exception) {
        }
    }
    return nil;
}

// ============ 群聊详情页：在“查找聊天内容”下面插入开关 ============
//
// 只在对应全局开关打开时才显示对应行：
//   全局屏蔽拍一拍 → “显示拍一拍”
//   全局屏蔽群待办 → “显示群待办”
// 不加分组标题，直接插到“查找聊天内容”这一行下面，
// 不新增分组，避免改变微信内部缓存的 section 索引。

static NSString *const kPatSwitchTitle = @"显示拍一拍";
static NSString *const kUndoneSwitchTitle = @"显示群待办";
static NSArray *SectionCells(id section) {
    @try {
        SEL sel = NSSelectorFromString(@"getAllCells");
        if ([section respondsToSelector:sel]) {
            id cells = [section performSelector:sel];
            if ([cells isKindOfClass:[NSArray class]]) {
                return cells;
            }
        }
    } @catch (NSException *exception) {
    }
    return @[];
}

static NSString *CellTitle(id cellManager) {
    @try {
        id config = [cellManager performSelector:NSSelectorFromString(@"cellConfig")];
        if (!config) {
            return nil;
        }
        for (NSString *key in @[@"title", @"titleAttributed", @"hintText"]) {
            @try {
                id value = [config valueForKey:key];
                if ([value isKindOfClass:[NSString class]]) {
                    return value;
                }
                if ([value isKindOfClass:[NSAttributedString class]]) {
                    return [(NSAttributedString *)value string];
                }
            } @catch (NSException *exception) {
            }
        }
    } @catch (NSException *exception) {
    }
    return nil;
}

static id MakeChatSwitchCell(Class cellClass, NSString *chat, NSString *kind, NSString *title) {
    if (g_chatSwitchHandlers == nil) {
        g_chatSwitchHandlers = [NSMutableArray array];
    }
    APIBlockerChatSwitchHandler *handler = [[APIBlockerChatSwitchHandler alloc] init];
    handler.chat = chat;
    handler.kind = kind;
    [g_chatSwitchHandlers addObject:handler];
    BOOL on = [kind isEqualToString:@"pat"] ? ShouldShowPatInChat(chat) : ShouldShowGroupUndoneInChat(chat);
    return ((id (*)(id, SEL, SEL, id, id, BOOL))objc_msgSend)(cellClass,
                NSSelectorFromString(@"switchCellForSel:target:title:on:"),
                NSSelectorFromString(@"switchChanged:"), handler, title, on);
}

// 每次群聊详情页出现时同步一次：全局开关开了才显示对应行


// ============ 群聊详情页：末尾新增“插件”分组 ============
//
// 只做一件事：在群聊详情页的表格末尾追加一个“插件”分组，
// 里面按全局开关显示“显示拍一拍 / 显示群待办”。
// 绝不改动微信自己的分组和单元格——之前用 removeCellAt:/insertCell:At:
// 去改微信已有分组，会导致进聊天信息就闪退。

static NSString *const kChatSectionHeader = @"插件";

static NSArray *TableSections(id tableManager) {
    @try {
        SEL sectionsSel = NSSelectorFromString(@"getAllSections");
        if ([tableManager respondsToSelector:sectionsSel]) {
            id sections = [tableManager performSelector:sectionsSel];
            if ([sections isKindOfClass:[NSArray class]]) {
                return sections;
            }
        }
    } @catch (NSException *exception) {
    }
    return @[];
}

// 我们自己加的分组（表头是“插件”）
static NSInteger PluginSectionIndex(id tableManager) {
    NSArray *sections = TableSections(tableManager);
    for (NSInteger i = (NSInteger)sections.count - 1; i >= 0; i--) {
        @try {
            id header = [sections[(NSUInteger)i] performSelector:NSSelectorFromString(@"getHeaderView")];
            NSString *text = nil;
            if ([header isKindOfClass:[NSString class]]) {
                text = header;
            } else if (header) {
                text = [header valueForKey:@"text"];
            }
            if ([text isEqualToString:kChatSectionHeader]) {
                return i;
            }
        } @catch (NSException *exception) {
        }
    }
    return -1;
}

static void LogGroupInfoRowTitles(id tableManager, NSString *chat) {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (id section in TableSections(tableManager)) {
        for (id cell in SectionCells(section)) {
            NSString *title = CellTitle(cell);
            if (title.length > 0) {
                [titles addObject:title];
            }
            if (titles.count >= 60) {
                break;
            }
        }
        if (titles.count >= 60) {
            break;
        }
    }
    TFLog(@"[APIBlocker] 群聊详情（%@）现有行：%@", chat, [titles componentsJoinedByString:@" | "]);
}

static NSArray<NSArray<NSString *> *> *WantedChatSwitchRows(void) {
    NSMutableArray<NSArray<NSString *> *> *wanted = [NSMutableArray array];
    if (GlobalBlockPat()) {
        [wanted addObject:@[ @"pat", kPatSwitchTitle ]];
    }
    if (GlobalBlockGroupUndone()) {
        [wanted addObject:@[ @"undone", kUndoneSwitchTitle ]];
    }
    return wanted;
}

// 每次进入群聊详情页同步一次：只操作我们自己那个“插件”分组
static void SyncGroupChatSwitchRows(UIViewController *vc) {
    @try {
        NSString *chat = ChatNameFromInfoVC(vc);
        if (chat.length == 0) {
            return;
        }
        id tableManager = FindTableManager(vc);
        if (!tableManager) {
            TFLog(@"[APIBlocker] 群聊详情（%@）：没找到表格管理器", chat);
            return;
        }
        Class sectionClass = NSClassFromString(@"WCTableViewSectionManager");
        Class cellClass = NSClassFromString(@"WCTableViewCellManager");
        if (!sectionClass || !cellClass) {
            return;
        }

        NSArray<NSArray<NSString *> *> *wanted = WantedChatSwitchRows();
        NSInteger existing = PluginSectionIndex(tableManager);

        // 已经是我们想要的状态就不要再动表格（减少改动次数，降低出问题概率）
        if (existing >= 0) {
            NSArray *cells = SectionCells(TableSections(tableManager)[(NSUInteger)existing]);
            BOOL same = (cells.count == wanted.count);
            for (NSUInteger i = 0; same && i < wanted.count; i++) {
                same = [CellTitle(cells[i]) isEqualToString:wanted[i][1]];
            }
            if (same) {
                return;
            }
            ((void (*)(id, SEL, unsigned int))objc_msgSend)(tableManager,
                NSSelectorFromString(@"removeSectionAt:"), (unsigned int)existing);
        }

        if (wanted.count == 0) {
            if (existing >= 0) {
                ((void (*)(id, SEL))objc_msgSend)(tableManager, NSSelectorFromString(@"reloadTableView"));
            }
            return;
        }

        id section = ((id (*)(id, SEL, id))objc_msgSend)(sectionClass,
                                                         NSSelectorFromString(@"sectionWithHeader:"),
                                                         kChatSectionHeader);
        if (!section) {
            return;
        }
        BOOL added = NO;
        for (NSArray<NSString *> *item in wanted) {
            id cell = MakeChatSwitchCell(cellClass, chat, item[0], item[1]);
            if (!cell) {
                continue;
            }
            ((void (*)(id, SEL, id))objc_msgSend)(section, NSSelectorFromString(@"addCell:"), cell);
            added = YES;
        }
        if (!added) {
            TFLog(@"[APIBlocker] 群聊详情（%@）：开关行创建失败", chat);
            LogGroupInfoRowTitles(tableManager, chat);
            return;
        }
        // 插在最后一个分组（“退出群聊”）之前，而不是加到最末尾
        NSArray *sections = TableSections(tableManager);
        NSInteger insertIndex = (NSInteger)sections.count - 1;
        if (insertIndex < 0) {
            insertIndex = 0;
        }
        ((void (*)(id, SEL, id, unsigned int))objc_msgSend)(tableManager,
            NSSelectorFromString(@"insertSection:At:"), section, (unsigned int)insertIndex);
        ((void (*)(id, SEL))objc_msgSend)(tableManager, NSSelectorFromString(@"reloadTableView"));
        TFLog(@"[APIBlocker] 群聊详情（%@）已在“退出群聊”前插入“%@”分组（第 %ld 组），共 %lu 行",
              chat, kChatSectionHeader, (long)insertIndex, (unsigned long)wanted.count);
    } @catch (NSException *exception) {
        TFLog(@"[APIBlocker] 群聊详情页同步开关失败：%@", exception.reason);
    }
}

static void (*orig_ChatRoomInfoViewDidAppear)(id, SEL, BOOL);

static void APIBlockerChatRoomInfoViewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_ChatRoomInfoViewDidAppear(self, _cmd, animated);
    UIViewController *vc = (UIViewController *)self;
    // 等这次出现转场跑完再改表格，避免在动画/刷新过程中动分组
    dispatch_async(dispatch_get_main_queue(), ^{
        if (vc.viewIfLoaded.window) {
            SyncGroupChatSwitchRows(vc);
        }
    });
}

// 语音上传失败诊断：把微信内部错误码写进 trace
static void APIBlockerVoiceUploadTaskFail(id self, SEL _cmd, id task) {
    ABNoteSend(@"语音上传任务失败：%@", task);
}

static void APIBlockerVoiceSendError(id self, SEL _cmd, id wrap, unsigned int errNo) {
    ABNoteSend(@"语音发送错误码：%u", errNo);
}

static void APIBlockerVoiceSendFail(id self, SEL _cmd) {
    NSArray *stack = [NSThread callStackSymbols];
    NSUInteger limit = MIN(stack.count, (NSUInteger)10);
    NSMutableString *frames = [NSMutableString string];
    for (NSUInteger i = 1; i < limit; i++) {
        [frames appendFormat:@" | %@", stack[i]];
    }
    ABVoiceDiag(@"语音消息被标记发送失败，调用栈：%@", frames);
}

static void APIBlockerVoiceProgress(id self, SEL _cmd, id wrap, id progress, id total) {
    ABVoiceDiag(@"语音上传进度 progress=%@ total=%@", progress, total);
}

static void APIBlockerVoiceTaskFinish(id self, SEL _cmd, id task, id uploadTask) {
    ABVoiceDiag(@"语音上传完成：%@ / %@", task, uploadTask);
}

static IMP orig_VoiceProgress = NULL;
static IMP orig_VoiceTaskFinish = NULL;

static IMP orig_VoiceUploadTaskFail = NULL;
static IMP orig_VoiceSendError = NULL;
static IMP orig_VoiceSendFail = NULL;

// 原生语音校准：用户手动发一条语音时，把 wrap 的真实字段打出来
static void ABLogVoiceWrap(NSString *tag, id wrap) {
    if (!wrap) return;
    @try {
        unsigned int msgType = ABGetUInt(wrap, @"m_uiMessageType");
        unsigned int localID = ABGetUInt(wrap, @"m_uiMesLocalID");
        unsigned int voiceTime = ABGetUInt(wrap, @"m_uiVoiceTime");
        unsigned int voiceFormat = ABGetUInt(wrap, @"m_uiVoiceFormat");
        unsigned int endFlag = ABGetUInt(wrap, @"m_uiVoiceEndFlag");
        unsigned int cancelFlag = ABGetUInt(wrap, @"m_uiVoiceCancelFlag");
        NSData *voiceData = ABGetObject(wrap, @"m_dtVoice");
        NSString *content = ABGetObject(wrap, @"m_nsContent");
        ABVoiceDiag(@"%@ type=%u localID=%u time=%u fmt=%u end=%u cancel=%u dt=%lu content=%@",
                    tag, msgType, localID, voiceTime, voiceFormat, endFlag, cancelFlag,
                    (unsigned long)voiceData.length,
                    content.length > 80 ? [content substringToIndex:80] : (content ?: @""));
    } @catch (NSException *exception) {
        ABVoiceDiag(@"%@ 读取 wrap 字段异常", tag);
    }
}

static BOOL (*orig_SaveMesVoice)(id, SEL, id, id) = NULL;
static BOOL APIBlockerSaveMesVoice(id self, SEL _cmd, id usr, id wrap) {
    ABLogVoiceWrap(@"原生语音保存", wrap);
    return orig_SaveMesVoice ? orig_SaveMesVoice(self, _cmd, usr, wrap) : YES;
}

static void (*orig_AddMsgVoice)(id, SEL, id, id) = NULL;
static void APIBlockerAddMsgVoice(id self, SEL _cmd, id usr, id wrap) {
    @try {
        if (ABGetUInt(wrap, @"m_uiMessageType") == 34) {
            ABLogVoiceWrap(@"AddMsg语音", wrap);
        }
    } @catch (NSException *exception) {}
    if (orig_AddMsgVoice) orig_AddMsgVoice(self, _cmd, usr, wrap);
}

static BOOL (*orig_PrepareSend)(id, SEL, id) = NULL;
static BOOL APIBlockerPrepareSend(id self, SEL _cmd, id wrap) {
    @try { ABLogVoiceWrap(@"prepareSend", wrap); } @catch (NSException *exception) {}
    return orig_PrepareSend ? orig_PrepareSend(self, _cmd, wrap) : YES;
}

static BOOL (*orig_AudioAddMessageToDB)(id, SEL, id) = NULL;
static BOOL APIBlockerAudioAddMessageToDB(id self, SEL _cmd, id wrap) {
    @try { ABLogVoiceWrap(@"音频入库", wrap); } @catch (NSException *exception) {}
    return orig_AudioAddMessageToDB ? orig_AudioAddMessageToDB(self, _cmd, wrap) : YES;
}

static void (*orig_AddRecordMsg)(id, SEL, id, id) = NULL;
static void APIBlockerAddRecordMsg(id self, SEL _cmd, id usr, id wrap) {
    ABLogVoiceWrap(@"原生语音创建", wrap);
    if (orig_AddRecordMsg) orig_AddRecordMsg(self, _cmd, usr, wrap);
}

%ctor {
    TFLog(@"[APIBlocker] loaded into %@", NSProcessInfo.processInfo.processName);
    TFLog(@"[APIBlocker] 日志文件：%@", TFLogFilePath());
    // 全局注册：覆盖 NSURLConnection 与默认 NSURLSession
    [NSURLProtocol registerClass:[APIBlockerURLProtocol class]];

    // 语音上传/发送失败诊断
    Class recUploadCls = NSClassFromString(@"RecordUploadCDNMgr");
    if (recUploadCls) {
        SEL failTaskSel = NSSelectorFromString(@"OnRecordUploadTaskFail:");
        if (ClassImplementsMethod(recUploadCls, failTaskSel)) {
            MSHookMessageEx(recUploadCls, failTaskSel, (IMP)&APIBlockerVoiceUploadTaskFail, (IMP *)&orig_VoiceUploadTaskFail);
        }
        SEL sendFailSel = NSSelectorFromString(@"SendMsgFail");
        if (ClassImplementsMethod(recUploadCls, sendFailSel)) {
            MSHookMessageEx(recUploadCls, sendFailSel, (IMP)&APIBlockerVoiceSendFail, (IMP *)&orig_VoiceSendFail);
        }
        SEL progressSel = NSSelectorFromString(@"OnRecordUploadTask:progressChange:total:");
        if (ClassImplementsMethod(recUploadCls, progressSel)) {
            MSHookMessageEx(recUploadCls, progressSel, (IMP)&APIBlockerVoiceProgress, (IMP *)&orig_VoiceProgress);
        }
        SEL finishSel = NSSelectorFromString(@"OnRecordUploadTaskFinish:uploadTask:");
        if (ClassImplementsMethod(recUploadCls, finishSel)) {
            MSHookMessageEx(recUploadCls, finishSel, (IMP)&APIBlockerVoiceTaskFinish, (IMP *)&orig_VoiceTaskFinish);
        }
    }
    Class chatMgrCls = NSClassFromString(@"CMessageMgr");
    if (chatMgrCls) {
        SEL voiceErrSel = NSSelectorFromString(@"AsyncOnSendVoiceError:MsgWrap:ErroNO:");
        if (ClassImplementsMethod(chatMgrCls, voiceErrSel)) {
            MSHookMessageEx(chatMgrCls, voiceErrSel, (IMP)&APIBlockerVoiceSendError, (IMP *)&orig_VoiceSendError);
        }
        SEL saveVoiceSel = NSSelectorFromString(@"SaveMesVoice:MsgWrap:");
        if (ClassImplementsMethod(chatMgrCls, saveVoiceSel)) {
            MSHookMessageEx(chatMgrCls, saveVoiceSel, (IMP)&APIBlockerSaveMesVoice, (IMP *)&orig_SaveMesVoice);
        }
        SEL addRecordSel2 = NSSelectorFromString(@"AddRecordMsg:MsgWrap:");
        if (ClassImplementsMethod(chatMgrCls, addRecordSel2)) {
            MSHookMessageEx(chatMgrCls, addRecordSel2, (IMP)&APIBlockerAddRecordMsg, (IMP *)&orig_AddRecordMsg);
        }
        SEL addMsgSel = NSSelectorFromString(@"AddMsg:MsgWrap:");
        if (ClassImplementsMethod(chatMgrCls, addMsgSel)) {
            MSHookMessageEx(chatMgrCls, addMsgSel, (IMP)&APIBlockerAddMsgVoice, (IMP *)&orig_AddMsgVoice);
        }
    }
    Class audioSenderCls = NSClassFromString(@"AudioSender");
    if (audioSenderCls) {
        SEL prepSel = NSSelectorFromString(@"prepareSend:");
        if (ClassImplementsMethod(audioSenderCls, prepSel)) {
            MSHookMessageEx(audioSenderCls, prepSel, (IMP)&APIBlockerPrepareSend, (IMP *)&orig_PrepareSend);
        }
        SEL dbSel = NSSelectorFromString(@"addMessageToDB:");
        if (ClassImplementsMethod(audioSenderCls, dbSel)) {
            MSHookMessageEx(audioSenderCls, dbSel, (IMP)&APIBlockerAudioAddMessageToDB, (IMP *)&orig_AudioAddMessageToDB);
        }
    }
    ABVoiceDiag(@"插件加载 v%@", kPluginVersion);

    // 微信内置浏览器标题栏：隐藏网址（恢复旧版样式）
    g_hiddenURLLabels = [NSHashTable weakObjectsHashTable];
    Class navBarClass = NSClassFromString(@"UINavigationBar");
    if (navBarClass) {
        MSHookMessageEx(navBarClass, @selector(layoutSubviews), (IMP)&APIBlockerUINavigationBarLayoutSubviews, (IMP *)&orig_UINavigationBarLayoutSubviews);
    }

    // 微信插件收纳：注册到 微信->我->插件 页面
    Class mgrClass = NSClassFromString(@"WCPluginsMgr");
    if (mgrClass) {
        MSHookMessageEx(mgrClass, @selector(init), (IMP)&APIBlockerWCPluginsMgrInit, (IMP *)&orig_WCPluginsMgrInit);
    }

    // 拍一拍 / 群待办 过滤
    Class msgVCClass = NSClassFromString(@"BaseMsgContentViewController");
    SEL addViewModelSel = NSSelectorFromString(@"addChatViewModel:addMoreMsg:");
    if (msgVCClass && ClassImplementsMethod(msgVCClass, addViewModelSel)) {
        MSHookMessageEx(msgVCClass, addViewModelSel, (IMP)&APIBlockerAddChatViewModel, (IMP *)&orig_AddChatViewModel);
    } else {
        TFLog(@"[APIBlocker] 未找到 addChatViewModel:addMoreMsg:，拍一拍过滤未启用");
    }
    Class undoneMgrClass = NSClassFromString(@"WCGroupUndoneMgr");
    SEL undoneListSel = NSSelectorFromString(@"getUndoneListOfGroup:");
    if (undoneMgrClass && ClassImplementsMethod(undoneMgrClass, undoneListSel)) {
        MSHookMessageEx(undoneMgrClass, undoneListSel, (IMP)&APIBlockerGetUndoneListOfGroup, (IMP *)&orig_GetUndoneListOfGroup);
    } else {
        TFLog(@"[APIBlocker] 未找到 getUndoneListOfGroup:，群待办过滤未启用");
    }

    // 拍一拍隐藏：行高置 0 + cell 内容隐藏（不动消息数据，也不动列表结构）
    // 锁屏来电界面：名称 / 图标
    Class providerConfigClass = NSClassFromString(@"CXProviderConfiguration");
    if (providerConfigClass) {
        SEL providerNameSel = NSSelectorFromString(@"setLocalizedName:");
        if (ClassImplementsMethod(providerConfigClass, providerNameSel)) {
            MSHookMessageEx(providerConfigClass, providerNameSel, (IMP)&APIBlockerSetProviderLocalizedName, (IMP *)&orig_SetProviderLocalizedName);
        }
        SEL providerIconSel = NSSelectorFromString(@"setIconTemplateImageData:");
        if (ClassImplementsMethod(providerConfigClass, providerIconSel)) {
            MSHookMessageEx(providerConfigClass, providerIconSel, (IMP)&APIBlockerSetProviderIconTemplate, (IMP *)&orig_SetProviderIconTemplate);
        }
        SEL providerNameGetSel = NSSelectorFromString(@"localizedName");
        if (ClassImplementsMethod(providerConfigClass, providerNameGetSel)) {
            MSHookMessageEx(providerConfigClass, providerNameGetSel, (IMP)&APIBlockerGetProviderLocalizedName, (IMP *)&orig_GetProviderLocalizedName);
        }
        SEL providerIconGetSel = NSSelectorFromString(@"iconTemplateImageData");
        if (ClassImplementsMethod(providerConfigClass, providerIconGetSel)) {
            MSHookMessageEx(providerConfigClass, providerIconGetSel, (IMP)&APIBlockerGetProviderIconTemplate, (IMP *)&orig_GetProviderIconTemplate);
        }
        Class providerClass = NSClassFromString(@"CXProvider");
        SEL providerInitSel = NSSelectorFromString(@"initWithConfiguration:");
        if (providerClass && ClassImplementsMethod(providerClass, providerInitSel)) {
            MSHookMessageEx(providerClass, providerInitSel, (IMP)&APIBlockerProviderInitWithConfiguration, (IMP *)&orig_ProviderInitWithConfiguration);
            TFLog(@"[APIBlocker] 已挂 CXProvider initWithConfiguration:");
        } else {
            TFLog(@"[APIBlocker] 未找到 CXProvider initWithConfiguration:");
        }
        Class callUpdateClass = NSClassFromString(@"CXCallUpdate");
        SEL callerNameSel = NSSelectorFromString(@"setLocalizedCallerName:");
        if (callUpdateClass && ClassImplementsMethod(callUpdateClass, callerNameSel)) {
            MSHookMessageEx(callUpdateClass, callerNameSel, (IMP)&APIBlockerSetLocalizedCallerName, (IMP *)&orig_SetLocalizedCallerName);
        }
    } else {
        TFLog(@"[APIBlocker] 未找到 CXProviderConfiguration");
    }

    Class chatViewModelClass = NSClassFromString(@"BaseChatViewModel");
    SEL rowHeightSel = NSSelectorFromString(@"rowHeight");
    if (chatViewModelClass && ClassImplementsMethod(chatViewModelClass, rowHeightSel)) {
        MSHookMessageEx(chatViewModelClass, rowHeightSel, (IMP)&APIBlockerChatViewModelRowHeight, (IMP *)&orig_ChatViewModelRowHeight);
        TFLog(@"[APIBlocker] 拍一拍隐藏：已挂 rowHeight");
    } else {
        TFLog(@"[APIBlocker] 未找到 rowHeight，拍一拍行高处理未启用");
    }
    Class patCellClass = NSClassFromString(@"AppPatMessageCellView");
    SEL layoutContentSel = NSSelectorFromString(@"layoutContentView");
    if (patCellClass && ClassImplementsMethod(patCellClass, layoutContentSel)) {
        MSHookMessageEx(patCellClass, layoutContentSel, (IMP)&APIBlockerPatCellLayoutContentView, (IMP *)&orig_PatCellLayoutContentView);
        TFLog(@"[APIBlocker] 拍一拍隐藏：已挂 AppPatMessageCellView.layoutContentView");
    } else {
        TFLog(@"[APIBlocker] 未找到 AppPatMessageCellView.layoutContentView");
    }

    // 聊天详情页（群 / 私聊）注入“显示拍一拍 / 显示群待办”开关
    Class roomInfoClass = NSClassFromString(@"ChatRoomInfoViewController");
    if (roomInfoClass && ClassImplementsMethod(roomInfoClass, @selector(viewDidAppear:))) {
        MSHookMessageEx(roomInfoClass, @selector(viewDidAppear:), (IMP)&APIBlockerChatRoomInfoViewDidAppear, (IMP *)&orig_ChatRoomInfoViewDidAppear);
    }

    // 恢复旧版卡包：只替换“我 → 卡包”入口的跳转目标
    Class moreVCClass = NSClassFromString(@"MoreViewController");
    if (moreVCClass) {
        MSHookMessageEx(moreVCClass, @selector(onCardsEntryClicked), (IMP)&APIBlockerOnCardsEntryClicked, (IMP *)&orig_MoreViewControllerOnCardsEntryClicked);
    } else {
        TFLog(@"[APIBlocker] 未找到 MoreViewController，卡包入口 hook 未安装");
    }

    // 付款页面显示余额：收付款码页 viewDidAppear: 后注入“剩余 X 元”
    Class payVcClass = NSClassFromString(@"WCPayOfflinePayViewController");
    if (payVcClass && ClassImplementsMethod(payVcClass, @selector(viewDidAppear:))) {
        MSHookMessageEx(payVcClass, @selector(viewDidAppear:), (IMP)&APIBlockerPayOfflineViewDidAppear, (IMP *)&orig_PayOfflineViewDidAppear);
        TFLog(@"[APIBlocker] 付款页余额显示：已挂 WCPayOfflinePayViewController");
    } else {
        TFLog(@"[APIBlocker] 未找到 WCPayOfflinePayViewController，付款页余额显示未启用");
    }

    // 屏蔽服务号收纳页的下方文章（BrandFansMsgSessionViewController）
    Class fansVcClass = NSClassFromString(@"BrandFansMsgSessionViewController");
    if (fansVcClass && ClassImplementsMethod(fansVcClass, @selector(tableView:cellForRowAtIndexPath:))) {
        MSHookMessageEx(fansVcClass, @selector(tableView:cellForRowAtIndexPath:), (IMP)&APIBlockerFansVcCellForRow, (IMP *)&orig_FansVcCellForRow);
        TFLog(@"[APIBlocker] 屏蔽服务号文章：已挂 BrandFansMsgSessionViewController");
    } else {
        TFLog(@"[APIBlocker] 未找到 BrandFansMsgSessionViewController，屏蔽服务号文章未启用");
    }

    // 长按公众号列表页标题，一键把所有公众号未读标记为已读
    Class brandSessionClass = NSClassFromString(@"BrandSessionViewController");
    if (brandSessionClass && ClassImplementsMethod(brandSessionClass, @selector(viewDidLoad))) {
        MSHookMessageEx(brandSessionClass, @selector(viewDidLoad), (IMP)&APIBlockerBrandSessionViewDidLoad, (IMP *)&orig_BrandSessionViewDidLoad);
        MSHookMessageEx(brandSessionClass, @selector(viewDidAppear:), (IMP)&APIBlockerBrandSessionViewDidAppear, (IMP *)&orig_BrandSessionViewDidAppear);
        TFLog(@"[APIBlocker] 一键已读：已挂 BrandSessionViewController");
    } else {
        TFLog(@"[APIBlocker] 未找到 BrandSessionViewController，一键已读未启用");
    }

    // 主页消息一键已读：主消息列表页（NewMainFrameViewController）底部“微信”tab 向上拖动
    Class newMainClass = NSClassFromString(@"NewMainFrameViewController");
    if (newMainClass && ClassImplementsMethod(newMainClass, @selector(viewDidAppear:))) {
        MSHookMessageEx(newMainClass, @selector(viewDidAppear:), (IMP)&APIBlockerNewMainFrameViewDidAppear, (IMP *)&orig_NewMainFrameViewDidAppear);
        TFLog(@"[APIBlocker] 主页消息一键已读：已挂 NewMainFrameViewController");
    } else {
        TFLog(@"[APIBlocker] 未找到 NewMainFrameViewController，主页消息一键已读未启用");
    }

    // 屏蔽服务号下方文章：订阅号消息流页是 Flutter（BSTimelineFlutterViewController），
    // UIKit 屏蔽对其无效；曾尝试 hook FlutterMethodChannel/SafeMethodChannel 数据通道
    // （探针），实测会导致点击服务号崩溃，已废弃，此处不再 hook，仅保留老原生版屏蔽。

    // 强制 CallKit：LCK 关掉 + CallKit 门槛打开（只在开关打开时改变行为）
    Class voipPushClass = NSClassFromString(@"VoIPPushKitNotifyService");
    if (voipPushClass) {
        Class voipPushMeta = object_getClass(voipPushClass);
        struct { const char *name; IMP hook; void *orig; } classHooks[] = {
            { "isVoIPLCKAvailable",          (IMP)&APIBlockerIsVoIPLCKAvailable,          &orig_isVoIPLCKAvailable },
            { "isCallkitAvailable",          (IMP)&APIBlockerIsCallkitAvailable,          &orig_isCallkitAvailable },
            { "isDeviceCallkitAvailable",    (IMP)&APIBlockerIsDeviceCallkitAvailable,    &orig_isDeviceCallkitAvailable },
            { "getCallkitSwitchFromService", (IMP)&APIBlockerGetCallkitSwitchFromService, &orig_getCallkitSwitchFromService },
            { "getIfCanUseCX:isMultiTalk:",  (IMP)&APIBlockerGetIfCanUseCX,               &orig_getIfCanUseCX },
        };
        for (size_t i = 0; i < sizeof(classHooks) / sizeof(classHooks[0]); i++) {
            SEL sel = sel_registerName(classHooks[i].name);
            if (!ClassImplementsClassMethod(voipPushClass, sel)) {
                continue;
            }
            MSHookMessageEx(voipPushMeta, sel, classHooks[i].hook, (IMP *)classHooks[i].orig);
        }

        SEL useLCKSel = NSSelectorFromString(@"useVoIPLCK");
        if (ClassImplementsMethod(voipPushClass, useLCKSel)) {
            MSHookMessageEx(voipPushClass, useLCKSel, (IMP)&APIBlockerUseVoIPLCK, (IMP *)&orig_useVoIPLCK);
        }
        SEL setUseLCKSel = NSSelectorFromString(@"setUseVoIPLCK:");
        if (ClassImplementsMethod(voipPushClass, setUseLCKSel)) {
            MSHookMessageEx(voipPushClass, setUseLCKSel, (IMP)&APIBlockerSetUseVoIPLCK, (IMP *)&orig_setUseVoIPLCK);
        }
        TFLog(@"[APIBlocker] CallKit 强制开关已安装（VoIPPushKitNotifyService）");
    } else {
        TFLog(@"[APIBlocker] 未找到 VoIPPushKitNotifyService，CallKit 开关未安装");
    }

    // 首页入口补位：只 hook WCMktCardHomeLogicController 自己实现的方法
    Class cardHomeLogicClass = NSClassFromString(@"WCMktCardHomeLogicController");
    if (cardHomeLogicClass) {
        SEL setterSel = NSSelectorFromString(@"setMktCardHomePageResponse:");
        if (ClassImplementsMethod(cardHomeLogicClass, setterSel)) {
            MSHookMessageEx(cardHomeLogicClass,
                            setterSel,
                            (IMP)&APIBlockerSetMktCardHomePageResponse,
                            (IMP *)&orig_SetMktCardHomePageResponse);
        }
        SEL clickSel = NSSelectorFromString(@"handleHomePageTopCellClickWithIndexPath:");
        if (ClassImplementsMethod(cardHomeLogicClass, clickSel)) {
            MSHookMessageEx(cardHomeLogicClass,
                            clickSel,
                            (IMP)&APIBlockerHandleHomePageTopCellClick,
                            (IMP *)&orig_HandleHomePageTopCellClick);
        }
        SEL storeSel = NSSelectorFromString(@"getHomePageStoreListData");
        if (ClassImplementsMethod(cardHomeLogicClass, storeSel)) {
            MSHookMessageEx(cardHomeLogicClass,
                            storeSel,
                            (IMP)&APIBlockerGetHomePageStoreListData,
                            (IMP *)&orig_GetHomePageStoreListData);
        }
    } else {
        TFLog(@"[APIBlocker] 未找到 WCMktCardHomeLogicController，入口补位未启用");
    }


    // PluginsInject 兼容能力：本次调整已禁用
#if 0
    TFInstallPluginsInjectCompatHooks();
#endif

    // 兜底：WCPluginsMgr 类延迟加载时，稍后主动注册一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!g_registered) {
            id cls = NSClassFromString(@"WCPluginsMgr");
            if (cls) {
                RegisterAPIBlockerPlugin([cls sharedInstance]);
            }
        }
    });
}

// 部分 App 使用自定义 NSURLSessionConfiguration，这里确保协议类也注入进去
%group ABBase

%hook NSURLSessionConfiguration

- (NSArray *)protocolClasses {
    NSArray *classes = %orig;
    for (Class cls in classes) {
        if (cls == [APIBlockerURLProtocol class]) {
            return classes;
        }
    }
    NSMutableArray *mutableClasses = [classes mutableCopy];
    [mutableClasses insertObject:[APIBlockerURLProtocol class] atIndex:0];
    return [mutableClasses copy];
}

%end

// 微信/支付宝等 App 的内置浏览器是 WKWebView，
// 其网络请求在独立进程发出，NSURLProtocol 拦不到，必须在这里拦截
%hook WKWebView

- (id)loadRequest:(NSURLRequest *)request {
    NSURL *url = request.URL;
    if (URLMatches(url) && APIBlockerEnabled()) {
        NSData *body = ResponseBodyData();
        TFLog(@"[APIBlocker] WKWebView loadRequest BLOCKED %@ -> %@ (%lu bytes)",
              url.absoluteString,
              ConfiguredResponseType(),
              (unsigned long)body.length);
        if (body.length == 0) {
            return [self loadHTMLString:@"" baseURL:url];
        }
        return [self loadData:body
                     MIMEType:ConfiguredResponseType()
         characterEncodingName:@"utf-8"
                      baseURL:url];
    }
    return %orig;
}

%end

%end // ABBase


// ============================================================
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <QuartzCore/QuartzCore.h>

// ---------- 日志 ----------
// WCLGLog 始终输出（只用在「出问题了」的地方）；WCLGDebug 要把 WCLG_DEBUG 改成 1 才输出。
// 同时写一份到微信沙盒的 Documents/wctabbar.log，方便用 Filza 直接取。
// 文件写入 dispatch 到主队列 —— %ctor 在 dylib 加载阶段跑，那里做文件 I/O 会让宿主闪退。
#define WCLG_DEBUG 0

static void WCLGLogImpl(NSString *fmt, ...) {
	va_list ap; va_start(ap, fmt);
	NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);

	NSLog(@"[wctabbar] %@", msg);

	dispatch_async(dispatch_get_main_queue(), ^{
		static NSString *path;
		static dispatch_once_t once;
		dispatch_once(&once, ^{
			path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/wctabbar.log"];
		});
		NSString *line = [msg stringByAppendingString:@"\n"];
		NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
		if (!fh) {
			[line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
		} else {
			[fh seekToEndOfFile];
			[fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
			[fh closeFile];
		}
	});
}
#define WCLGLog(fmt, ...) WCLGLogImpl(fmt, ##__VA_ARGS__)

#if WCLG_DEBUG
#define WCLGDebug(fmt, ...) WCLGLog(fmt, ##__VA_ARGS__)
#else
#define WCLGDebug(...) do {} while (0)
#endif

// ---------- 微信真实类 / 系统私有类 ----------
// 如实声明继承关系，编译器才知道它们是系统类的子类
@interface MMTabBar : UITabBar
@end

@interface MMTabBarController : UITabBarController
- (void)relayoutButtons:(BOOL)animated;
// iOS 26 的 UITabBarController 属性。本工程 SDK 是 16.5，没有这个枚举，
// 所以这里用 NSInteger 占位，值在下面用宏定义。
- (void)setTabBarMinimizeBehavior:(NSInteger)behavior;
@end

// Swift 类 UIKit.ScrollEdgeEffectView 在 ObjC 里没有合法标识符，
// 这里只是给 Logos 一个占位名，真正的 Class 在 %ctor 里通过 %init 注入。
@interface ScrollEdgeEffectView : UIView
@end

// 同理：Swift 类 UIKit._UITabBarItemPlatterView，占位名给 Logos 用，
// 真正的 Class 在 %ctor 里通过 %init 注入。
@interface UITabBarItemPlatterView : UIView
@end

// ---------- 常量 / 开关 ----------
static NSString *const kWCLGEnabledKey = @"wclg_native_tabbar_enabled";
static NSString *const kWCLGDesignKey  = @"UIDesignRequiresCompatibility";

// 全局液态总开关：优先读插件的「原生液态底栏」设置项；未设置时读底层 wclg key（默认开）
static BOOL WCLGEnabled(void) {
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	if ([d objectForKey:kLiquidTabBarKey] != nil) return [d boolForKey:kLiquidTabBarKey];
	return ([d objectForKey:kWCLGEnabledKey] == nil) ? YES : [d boolForKey:kWCLGEnabledKey];
}

// 滚动收纳开关：插件「滚动收纳胶囊」设置项（默认开）。开=OnScrollDown(2)，关=Never(1)
static NSInteger WCLGMinimizeBehaviorValue(void) {
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	BOOL scrollHide = YES;
	if ([d objectForKey:kLiquidScrollHideKey] != nil) scrollHide = [d boolForKey:kLiquidScrollHideKey];
	return scrollHide ? 2 /* OnScrollDown */ : 1 /* Never */;
}

// ============================================================
//  视图分类（带缓存）
//
//  layoutSubviews 会被反复触发，每次对每个 subview 做字符串匹配太浪费。
//  类名到类型的映射是固定的，按 Class 缓存一次即可。
//  只在主线程使用（UIKit 布局本来就在主线程）。
//
//    Platter   —— 系统的浮动胶囊，不能动
//    Item      —— 微信的 MMTabBarItemView，要对齐
//    Protected —— 系统的按钮/容器/透镜等，绝不能摘
//    Removable —— 候选的「微信背景容器」：纯 UIView、UIVisualEffectView、
//                 或主 bundle 里的自家类。系统私有的 _UI* 类一律不在此列。
//    Other     —— 不认识的，不碰
// ============================================================
typedef NS_ENUM(NSUInteger, WCLGViewKind) {
	WCLGViewKindOther = 0,
	WCLGViewKindPlatter,
	WCLGViewKindItem,
	WCLGViewKindProtected,
	WCLGViewKindRemovable,
};

static WCLGViewKind WCLGClassifyClass(Class cls) {
	static NSMapTable<Class, NSNumber *> *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		cache = [NSMapTable strongToStrongObjectsMapTable];
	});

	NSNumber *hit = [cache objectForKey:cls];
	if (hit) return (WCLGViewKind)hit.unsignedIntegerValue;

	NSString *name = NSStringFromClass(cls);
	WCLGViewKind kind;
	if ([name containsString:@"MMTabBarItemView"]) {
		kind = WCLGViewKindItem;
	} else if ([name containsString:@"Platter"]) {
		kind = WCLGViewKindPlatter;
	} else if ([name containsString:@"LiquidLens"] ||
			   [name containsString:@"TabBarButton"] ||
			   [name containsString:@"ItemView"] ||
			   [name containsString:@"Container"] ||
			   [name containsString:@"_UITabButton"]) {
		kind = WCLGViewKindProtected;
	} else if (cls == [UIView class] ||
			   cls == [UIVisualEffectView class] ||
			   [NSBundle bundleForClass:cls] == [NSBundle mainBundle]) {
		kind = WCLGViewKindRemovable;
	} else {
		kind = WCLGViewKindOther;
	}

	[cache setObject:@(kind) forKey:cls];
	WCLGDebug(@"classify %@ -> %lu", name, (unsigned long)kind);
	return kind;
}

static inline WCLGViewKind WCLGKindOfView(UIView *v) {
	return WCLGClassifyClass([v class]);
}

// ============================================================
//  擦掉微信画在底栏上的东西
//
//    · WCLGResetBarChrome        —— 底栏自身的底色，窗口/外观变化时做
//    · WCLGRemoveChromeContainer —— 微信塞的全尺寸背景容器，摘掉
//
//  容器检查必须放在 layoutSubviews 里：微信是「先 addSubview、再由自己的
//  layout 设尺寸」，didAddSubview: 那一刻子视图的 frame 还是 0，
//  满尺寸判定必然过不了。
// ============================================================
static void WCLGResetBarChrome(UITabBar *bar) {
	if (!bar || ![bar isKindOfClass:[UITabBar class]]) return;

	// 已经是干净状态就别写 —— 多余的写入会让 UIKit 标记重新布局
	BOOL colorDirty =
		(bar.backgroundColor && CGColorGetAlpha(bar.backgroundColor.CGColor) > 0.01) ||
		(bar.layer.backgroundColor && CGColorGetAlpha(bar.layer.backgroundColor) > 0.01);
	if (bar.translucent && !bar.opaque && !colorDirty) return;

	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	bar.translucent = YES;
	bar.opaque = NO;
	bar.backgroundColor = [UIColor clearColor];
	bar.layer.backgroundColor = [UIColor clearColor].CGColor;
	[CATransaction commit];
}

// 判断 sub 是不是微信的背景容器；是就摘掉并返回 YES
static BOOL WCLGRemoveChromeContainer(UITabBar *bar, UIView *sub) {
	if (!bar || !sub) return NO;
	if (WCLGKindOfView(sub) != WCLGViewKindRemovable) return NO;

	// 跟底栏一样大的容器 = 微信的底。frame 也必须是满的 ——
	// bounds 满尺寸但 frame 为 0×0 的是 portal 源视图（挂在屏幕外给
	// _UIPortalView 采样用），摘了会毁掉玻璃折射。
	CGFloat bw = CGRectGetWidth(bar.bounds), bh = CGRectGetHeight(bar.bounds);
	BOOL fullSize = CGRectGetWidth(sub.bounds) >= bw - 1.0 &&
					CGRectGetHeight(sub.bounds) >= bh - 1.0 &&
					CGRectGetWidth(sub.frame) > 1.0 &&
					CGRectGetHeight(sub.frame) > 1.0;
	if (!fullSize) return NO;

	WCLGDebug(@"remove chrome container %@", NSStringFromClass([sub class]));

	// 从视图树里摘掉，而不是 hidden=YES —— 藏的话微信还能改回可见，
	// 摘掉就一劳永逸。整个子树一起走，所以不必再逐个清它子视图的底色。
	[sub removeFromSuperview];
	return YES;
}

// 扫一遍底栏的直接子视图，摘掉微信的背景容器。
// 摘掉后微信不重加的话，后续扫描就是遍历 ~7 个 subview，开销可忽略。
static BOOL WCLGStripChromeContainers(UITabBar *bar) {
	if (!bar) return NO;
	BOOL removed = NO;
	// 遍历中会 removeFromSuperview 改变数组，必须先 copy
	for (UIView *sub in [bar.subviews copy]) {
		if (WCLGRemoveChromeContainer(bar, sub)) removed = YES;
	}
	return removed;
}

// ============================================================
//  收起状态的恢复轮询
//
//  为什么需要：展开只改胶囊、不改底栏自身的 bounds，所以
//  MMTabBar.layoutSubviews 不会触发；胶囊自己的 layoutSubviews 在展开时
//  也可能不触发、或触发时读到的还是动画中的中间值。结果就是「收起能进去、
//  展开回不来」—— 图标一直 hidden、三条杠停在收起时的位置。
//
//  做法：收起期间用 CADisplayLink 轮询，一旦判定已展开就自动停掉，
//  平时（展开态）没有任何开销。
// ============================================================
static void WCLGAlignTabBarItems(UITabBar *bar);

@interface WCLGRecoveryPoller : NSObject
+ (instancetype)shared;
- (void)setActive:(BOOL)on bar:(UITabBar *)bar;
@end

@implementation WCLGRecoveryPoller {
	CADisplayLink *_link;
	__weak UITabBar *_bar;
}

+ (instancetype)shared {
	static WCLGRecoveryPoller *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [WCLGRecoveryPoller new]; });
	return s;
}

- (void)setActive:(BOOL)on bar:(UITabBar *)bar {
	if (!on) {
		[_link invalidate];
		_link = nil;
		return;
	}
	_bar = bar;
	if (_link) return;
	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
	_link.preferredFramesPerSecond = 30;
	[_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)tick:(CADisplayLink *)link {
	UITabBar *bar = _bar;
	if (!bar || !bar.window) {
		[self setActive:NO bar:nil];
		return;
	}
	WCLGAlignTabBarItems(bar);
}

@end


// ============================================================
//  对齐图标
//
//  系统的浮动胶囊是内缩的（如 {21,7},{378,62}），而微信的 MMTabBarItemView
//  是按全宽均分的（0/105/210/315）。这里拿 platter 的 frame 当基准，
//  把 item 视图重新摆到胶囊的网格上，并让内容垂直居中到胶囊。
// ============================================================
// 玻璃效果强度：把底栏系统玻璃（UIVisualEffectView / _UIVisualEffectBackdropView）
// 的模糊半径调到用户设定值。intensity==0 时不干预，保持系统默认。已应用过同值就跳过。
static void WCLGApplyGlassIntensity(UITabBar *bar) {
	if (!bar) return;
	NSInteger intensity = LiquidGlassIntensity();
	if (intensity <= 0) return;
	static NSInteger sApplied = -1;
	if (sApplied == intensity) return;
	CGFloat radius = intensity * 0.4f;

	for (UIView *sub in bar.subviews) {
		// 1) UIVisualEffectView + UIBlurEffect：替换成指定半径（运行时 selector，避免 SDK 缺失声明）
		if ([sub isKindOfClass:[UIVisualEffectView class]]) {
			UIVisualEffectView *vev = (UIVisualEffectView *)sub;
			if ([vev.effect isKindOfClass:[UIBlurEffect class]]) {
				SEL bs = NSSelectorFromString(@"effectWithBlurRadius:");
				if ([UIBlurEffect respondsToSelector:bs]) {
					id newEffect = ((id (*)(id, SEL, CGFloat))objc_msgSend)((id)[UIBlurEffect class], bs, radius);
					if (newEffect) {
						vev.effect = newEffect;
						sApplied = intensity;
						return;
					}
				}
			}
		}
		// 2) _UIVisualEffectBackdropView：走私有 setBlurRadius:/_setBlurRadius:
		NSString *nm = NSStringFromClass([sub class]);
		if ([nm containsString:@"Backdrop"]) {
			if ([sub respondsToSelector:@selector(setBlurRadius:)]) {
				((void(*)(id, SEL, CGFloat))objc_msgSend)(sub, @selector(setBlurRadius:), radius);
				sApplied = intensity;
				return;
			}
			SEL bs = NSSelectorFromString(@"_setBlurRadius:");
			if ([sub respondsToSelector:bs]) {
				((void(*)(id, SEL, CGFloat))objc_msgSend)(sub, bs, radius);
				sApplied = intensity;
				return;
			}
		}
	}
}

// 微信底栏四个 tab 本身没设图标（只有文字），液态胶囊里是空的。
// 这里按顺序给 UITabBarItem 注入自绘图标（SF Symbols，随系统液态玻璃 tint），只注入一次。
static NSArray<NSString *> *kWCLGIconNames(void) {
    return @[@"message.fill", @"person.2.fill", @"safari.fill", @"person.fill"]; // 微信 / 通讯录 / 发现 / 我
}
static void WCLGInstallIcons(UITabBar *bar) {
    if (!bar) return;
    NSArray *items = bar.items;
    if (items.count == 0) return;
    static BOOL sInstalled = NO;
    if (sInstalled) return;
    NSArray<NSString *> *names = kWCLGIconNames();
    for (NSUInteger i = 0; i < items.count; i++) {
        if (i >= names.count) break;
        UITabBarItem *item = items[i];
        if (item.image) continue; // 已有图标就不覆盖
        UIImage *img = [UIImage systemImageNamed:names[i]];
        if (img) {
            item.image = img;
            item.selectedImage = img;
        }
    }
    sInstalled = YES;
}

static void WCLGAlignTabBarItems(UITabBar *bar) {
	if (!bar) return;

	// 玻璃效果强度：0=不干预（系统默认），>0 设到系统玻璃 backdrop 上
	WCLGApplyGlassIntensity(bar);

	// 底栏没图标的 tab 注入自绘图标（微信/通讯录/发现/我）
	WCLGInstallIcons(bar);

	// 一次遍历同时找胶囊和微信的 item 视图
	UIView *platter = nil;
	NSMutableArray<UIView *> *items = [NSMutableArray array];
	for (UIView *sub in bar.subviews) {
		switch (WCLGKindOfView(sub)) {
			case WCLGViewKindPlatter:
				if (!platter) platter = sub;
				break;
			case WCLGViewKindItem:
				[items addObject:sub];
				break;
			default:
				break;
		}
	}
	if (!platter || items.count == 0) return;

	// 胶囊还没布局（frame 为空）就别动，否则所有 item 会塌到 x=0
	CGRect pf = platter.frame;
	if (CGRectIsEmpty(pf) || CGRectIsNull(pf)) return;

	// 按 x 排序，保证顺序和 tab 一致
	[items sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
		if (a.frame.origin.x < b.frame.origin.x) return NSOrderedAscending;
		if (a.frame.origin.x > b.frame.origin.x) return NSOrderedDescending;
		return NSOrderedSame;
	}];

	NSUInteger count = items.count;

	// ---- 收纳状态 ----
	// 底栏收起时胶囊会缩成一个小圆。这时按胶囊网格摆 4 个 item 会全部叠在一起，
	// 而系统自己的 _UITabButton 又没有图标（微信没给 MMtabbarItem 设 image），
	// 所以收起时把 4 个 item 全藏掉，换成一个居中的「三条杠」图标。
	// 只看宽度：收起时胶囊缩成一个小圆，宽度必然明显变小。
	// 高度不能用来判断 —— 展开态 62/90≈0.69 只比 0.6 高一点，
	// 底栏一变高（换机型/横屏/微信改版）就会把展开误判成收起。
	CGFloat bw = CGRectGetWidth(bar.bounds);
	CGFloat bh = CGRectGetHeight(bar.bounds);
	// 收纳判定用「宽高双条件」：展开态胶囊宽≈0.9倍、高≈0.69倍底栏，都不会同时 < 0.6；
	// 收起小圆宽和高都明显小于底栏。双条件避免单看宽度在部分机型/横屏下误判。
	BOOL minimized = (bw > 1.0 && CGRectGetWidth(pf) < bw * 0.6 && CGRectGetHeight(pf) < bh * 0.6);

	// 常驻轮询：收纳期间靠它跟动画，展开后靠它把图标恢复回来（原版只在收纳时激活，
	// 展开后 tick 一旦判展开就停，若停止前那次没执行到恢复逻辑，图标会一直 hidden）。
	// align 内部对「位置/可见性没变」都不写，常驻开销可忽略。
	[[WCLGRecoveryPoller shared] setActive:YES bar:bar];

	// 只在状态翻转时打日志，方便定位「展开后不恢复」的问题
	static BOOL sLoggedMin = NO;
	static BOOL sLoggedFirst = NO;
	if (!sLoggedFirst) {
		sLoggedFirst = YES;
		WCLGLog(@"align first call: bar=%@ platter=%@", NSStringFromCGRect(bar.bounds), NSStringFromCGRect(pf));
	}
	if (minimized != sLoggedMin) {
		sLoggedMin = minimized;
		WCLGLog(@"minimize=%d bar=%@ platter=%@", minimized, NSStringFromCGRect(bar.bounds), NSStringFromCGRect(pf));
	}

	[CATransaction begin];
	[CATransaction setDisableActions:YES];

	if (minimized) {
		// 收纳态：不要三条杠。只显示当前选中 tab 的 item（自绘图标 + 名称），其余隐藏，
		// 并把选中的摆到胶囊中心。
		UITabBarItem *selected = bar.selectedItem;
		UIView *selectedView = nil;
		for (UIView *iv in items) {
			BOOL isSel = NO;
			if ([(id)iv respondsToSelector:@selector(tabBarItem)]) {
				isSel = ([(id)iv tabBarItem] == selected);
			}
			if (iv.hidden == isSel) iv.hidden = !isSel; // 选中显示、其余隐藏
			if (isSel) selectedView = iv;
		}
		if (selectedView) {
			CGPoint c = CGPointMake(CGRectGetMidX(pf), CGRectGetMidY(pf));
			if (fabs(selectedView.center.x - c.x) > 0.5 || fabs(selectedView.center.y - c.y) > 0.5) {
				selectedView.center = c;
			}
		}
	} else {
		// 展开态：全部显示 + 摆到胶囊网格
		for (UIView *iv in items) {
			if (iv.hidden) iv.hidden = NO;
		}
		for (NSUInteger i = 0; i < count; i++) {
			UIView *iv = items[i];
			CGPoint c = iv.center;

			// 摆到胶囊的网格上
			c.x = pf.origin.x + pf.size.width * ((CGFloat)i + 0.5) / (CGFloat)count;

			// 垂直：让 item 内容的中心落在胶囊中心
			CGRect content = CGRectNull;
			for (UIView *g in iv.subviews) {
				if (g.hidden) continue;
				content = CGRectUnion(content, g.frame);
			}
			if (!CGRectIsNull(content)) {
				CGFloat contentMidYInBar = iv.frame.origin.y + CGRectGetMidY(content);
				c.y += CGRectGetMidY(pf) - contentMidYInBar;
			}

			// 位置已经对了就别写 —— 无条件写 frame 会让 UIKit 标记重新布局，
			// 反过来又触发 layoutSubviews，白白多跑一轮
			if (fabs(iv.center.x - c.x) < 0.5 && fabs(iv.center.y - c.y) < 0.5) continue;
			iv.center = c;
		}
	}
	[CATransaction commit];
}

// ============================================================
//  胶囊布局钩子
//
//  底栏收纳/展开是系统动画，动画结束后 MMTabBar 的 layoutSubviews 不一定
//  再触发，最后一帧的对齐就漏掉了（展开后图标挤在一边、收起后没恢复）。
//  直接钩胶囊自己的 layoutSubviews：它一动就对一次，跟着动画走。
// ============================================================
%group WCLGPlatter

%hook UITabBarItemPlatterView

- (void)layoutSubviews {
	%orig;
	UIView *sv = ((UIView *)self).superview;
	static BOOL sLogged = NO;
	if (!sLogged) {
		sLogged = YES;
		WCLGLog(@"platter layout fired, superview=%@", NSStringFromClass([sv class]));
	}
	if ([sv isKindOfClass:[UITabBar class]]) {
		WCLGAlignTabBarItems((UITabBar *)sv);
	}
}

%end

%end // WCLGPlatter

// 摘容器 + 重置底色 + 对齐，layoutSubviews 和 relayoutButtons: 共用
static void WCLGApplyFixes(UITabBar *bar) {
	if (!bar) return;
	if (WCLGStripChromeContainers(bar)) {
		WCLGResetBarChrome(bar);
	}
	WCLGAlignTabBarItems(bar);
}

// ============================================================
//  底栏随滚动收纳 / 展开
//
//  iOS 26 的系统能力：UITabBarController.tabBarMinimizeBehavior
//    Automatic = 0, Never = 1, OnScrollDown = 2, OnScrollUp = 3
//
//  注意它是**按滚动方向**触发的：OnScrollDown = 下滑收起、往回上滑展开；
//  系统没有「停止滚动就展开」这个档位。
//
//  本工程 SDK 是 16.5，没有这个枚举，所以全程运行时 + 版本把关
//  （%ctor 已经保证系统 >= iOS 26）。
// ============================================================
#define WCLG_MINIMIZE_ON_SCROLL_DOWN 2

static void WCLGSetMinimizeBehavior(id vc) {
	if (!vc) return;
	SEL sel = NSSelectorFromString(@"setTabBarMinimizeBehavior:");
	if (![vc respondsToSelector:sel]) return;
	((void (*)(id, SEL, NSInteger))objc_msgSend)(vc, sel, WCLGMinimizeBehaviorValue());
	WCLGDebug(@"minimize behavior set on %@", NSStringFromClass([vc class]));
}

// ============================================================
//  关键：让 UIKit 认为微信没申请旧版设计
//
//  微信 Info.plist 里有 UIDesignRequiresCompatibility = true，这是它底栏是
//  「全宽不透明」而不是 iOS 26 浮动玻璃的根本原因（它用 iphoneos26.1 SDK 构建，
//  却主动退回了旧设计系统）。UIKit 走 NSBundle 读这个 key，这里把它屏蔽掉。
//
//  两个入口统一返回 @NO。infoDictionary 调用很频繁，处理后的字典按源字典缓存。
// ============================================================
static BOOL WCLGIsMainBundle(NSBundle *b) {
	return b == [NSBundle mainBundle];
}

static NSDictionary *WCLGPatchedInfoDictionary(NSDictionary *src) {
	static NSDictionary *cachedSrc = nil;
	static NSDictionary *cachedPatched = nil;
	static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;

	os_unfair_lock_lock(&lock);
	if (cachedSrc != src) {
		NSMutableDictionary *m = [src mutableCopy];
		m[kWCLGDesignKey] = @NO;
		cachedPatched = [m copy];
		cachedSrc = src;
	}
	NSDictionary *result = cachedPatched;
	os_unfair_lock_unlock(&lock);
	return result;
}

%group WCLGBundle

%hook NSBundle

- (id)objectForInfoDictionaryKey:(NSString *)key {
	if ([key isEqualToString:kWCLGDesignKey] && WCLGIsMainBundle(self)) {
		return @NO;
	}
	return %orig;
}

- (NSDictionary *)infoDictionary {
	NSDictionary *d = %orig;
	if (d[kWCLGDesignKey] != nil && WCLGIsMainBundle(self)) {
		return WCLGPatchedInfoDictionary(d);
	}
	return d;
}

%end

%end // WCLGBundle

// ============================================================
//  关掉底栏附近和顶部的滚动边缘效果
//
//  UIKit.ScrollEdgeEffectView 是系统给可滚动内容边缘加的模糊/渐隐，让内容滚到
//  浮动栏底下时柔化过渡。底栏一透明，下边缘那个就露出来了（实测位于
//  {0,782},{420,130}，正好压在底栏 y=822..912 下面）。
//
//  处理两类实例，都在窗口坐标下判断：
//    · 底部：frame 与 MMTabBar 的 frame 相交（看和底栏的关系而不是屏幕位置，
//            所以没有底栏的页面，比如推入的聊天页，底部不受影响）
//    · 顶部：frame 的上沿落在 状态栏 + 导航栏 的区域内
//  其余位置的边缘效果（页面中间的小滚动区域等）保持系统原生观感。
//
//  · 底栏引用：MMTabBar 在布局/上屏时登记（弱引用）。
//  · 边缘视图登记在弱表里，底栏出现、隐藏、重新布局时统一刷新，
//    所以不依赖两者谁先布局。
//  · 记下 UIKit 自己想要的 hidden 值，底栏离开后能还原，而不是永远藏着。
// ============================================================
static __weak UITabBar *sWCLGTabBar;
static BOOL sWCLGApplyingEdgeHidden = NO; // 只在主线程使用
static const void *kWCLGEdgeIntendedKey = &kWCLGEdgeIntendedKey;

static NSHashTable<UIView *> *WCLGEdgeViews(void) {
	static NSHashTable<UIView *> *table;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		table = [NSHashTable weakObjectsHashTable];
	});
	return table;
}

// 导航栏高度（不含状态栏）。微信自绘的导航栏更高的话改这里。
static const CGFloat kWCLGNavBarHeight = 44.0;

// 顶部：边缘视图的上沿落在 状态栏 + 导航栏 区域内（1pt 容差）
static BOOL WCLGIsTopEdgeView(UIView *v, UIWindow *w) {
	CGRect viewRect = [v convertRect:v.bounds toView:w];
	if (CGRectIsEmpty(viewRect)) return NO; // 还没布局
	CGFloat bandBottom = w.safeAreaInsets.top + kWCLGNavBarHeight;
	return CGRectGetMinY(viewRect) <= bandBottom + 1.0 &&
		   CGRectGetMaxY(viewRect) > 1.0;
}

// 底部：边缘视图和当前底栏重叠
static BOOL WCLGOverlapsTabBar(UIView *v, UIWindow *w) {
	UITabBar *bar = sWCLGTabBar;
	if (!bar || bar.window != w || bar.hidden) return NO;

	CGRect barRect = [bar convertRect:bar.bounds toView:w];
	CGRect viewRect = [v convertRect:v.bounds toView:w];
	CGRect inter = CGRectIntersection(barRect, viewRect);
	return !CGRectIsNull(inter) &&
		   CGRectGetWidth(inter) > 1.0 &&
		   CGRectGetHeight(inter) > 1.0;
}

static BOOL WCLGShouldHideEdgeView(UIView *v) {
	UIWindow *w = v.window;
	if (!w) return NO; // 还没上屏，等 layoutSubviews / didMoveToWindow 再判断
	return WCLGIsTopEdgeView(v, w) || WCLGOverlapsTabBar(v, w);
}

// 目标状态 = UIKit 想要的 hidden || 位于底栏或顶部区域。只在不一致时才写。
static void WCLGApplyEdgeHidden(UIView *v) {
	NSNumber *intended = objc_getAssociatedObject(v, kWCLGEdgeIntendedKey);
	BOOL want = intended.boolValue || WCLGShouldHideEdgeView(v);
	if (v.hidden == want) return;

	sWCLGApplyingEdgeHidden = YES;
	v.hidden = want;
	sWCLGApplyingEdgeHidden = NO;
}

static void WCLGRefreshEdgeViews(void) {
	for (UIView *v in WCLGEdgeViews().allObjects) {
		WCLGApplyEdgeHidden(v);
	}
}

// MMTabBar 上屏/布局时调用：登记自己并刷新所有边缘视图
static void WCLGTrackTabBar(UITabBar *bar) {
	if (bar.window) {
		sWCLGTabBar = bar;
	} else if (sWCLGTabBar == bar) {
		sWCLGTabBar = nil;
	}
	WCLGRefreshEdgeViews();
}

%group WCLGScrollEdge

%hook ScrollEdgeEffectView

// UIKit 自己怎么设都无效：和底栏重叠就强制 hidden。
// 同时记下 UIKit 想要的值（我们自己写入时不记），底栏离开后好还原。
- (void)setHidden:(BOOL)hidden {
	if (!sWCLGApplyingEdgeHidden) {
		objc_setAssociatedObject(self, kWCLGEdgeIntendedKey, @(hidden),
								 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	%orig(hidden || WCLGShouldHideEdgeView(self));
}

// 上屏/布局时登记并按当前位置校正一次
- (void)layoutSubviews {
	%orig;
	[WCLGEdgeViews() addObject:self];
	WCLGApplyEdgeHidden(self);
}

- (void)didMoveToWindow {
	%orig;
	[WCLGEdgeViews() addObject:self];
	WCLGApplyEdgeHidden(self);
}

%end

%end // WCLGScrollEdge

// ============================================================
//  底栏下沉（iOS27 隐藏 home bar 后，把底栏整体下移填补底部留白）
//
//  独立于「原生液态底栏」开关，始终生效：hook MMTabBar setFrame: 拿到系统每次
//  摆底的原始 y，再整体下移 offset pt。sABOffsetting 防止在 setter 内改 self.frame
//  递归累加；关闭开关时 offset=0，回到系统原始位置。
// ============================================================
static BOOL sABOffsetting = NO;

// 识别微信主底栏：全宽 + 位于屏幕底部（适配 8.0.64 等任意 tabbar 类名，不依赖 MMTabBar）
static BOOL ABIsMainTabBar(UITabBar *bar) {
	if (!bar) return NO;
	CGRect swb = [UIScreen mainScreen].bounds;
	CGRect f = bar.frame;
	if (f.size.width < swb.size.width * 0.85) return NO;
	if (f.origin.y < swb.size.height * 0.35) return NO;
	if (f.size.height < 1) return NO;
	return YES;
}

%group ABTabBarOffset
%hook UITabBar
- (void)setFrame:(CGRect)rect {
	if (sABOffsetting) {
		%orig(rect);
		return;
	}
	%orig(rect);
	if (!ABIsMainTabBar(self)) return;
	sABOffsetting = YES;
	CGFloat offset = TabBarOffsetEnabled() ? (CGFloat)TabBarOffsetValue() : 0.0;
	if (offset > 0.5) {
		CGRect f = self.frame;
		CGFloat target = rect.origin.y + offset;
		if (fabs(f.origin.y - target) > 0.5) {
			f.origin.y = target;
			self.frame = f;
		}
	}
	sABOffsetting = NO;
}
%end
%end // ABTabBarOffset

// ============================================================
//  底栏 Hook
//
//  这个组只在开关打开、系统 >= iOS 26 时才会 %init，
//  所以里面不需要再逐个检查开关。
// ============================================================
%group WCLGTabBar

%hook MMTabBar

// --- 吞掉微信的 appearance 覆盖，保留系统默认（浮动玻璃的来源）---
- (void)setStandardAppearance:(UITabBarAppearance *)appearance {
	return;
}

- (void)setScrollEdgeAppearance:(UITabBarAppearance *)appearance {
	return;
}

- (void)setBackgroundImage:(UIImage *)image {
	return;
}

- (void)setShadowImage:(UIImage *)image {
	return;
}

- (void)setBarTintColor:(UIColor *)color {
	return;
}

// 背景色：只挡不透明的
- (void)setBackgroundColor:(UIColor *)color {
	if (color && CGColorGetAlpha(color.CGColor) > 0.01) return;
	%orig;
}

// --- 布局后：摘背景容器 + 对齐图标 ---
- (void)layoutSubviews {
	%orig;
	WCLGApplyFixes(self);
	WCLGTrackTabBar(self);
}

- (void)didMoveToWindow {
	%orig;
	WCLGResetBarChrome(self);
	WCLGTrackTabBar(self);
}

// 底栏显示/隐藏时，重叠关系变了，刷新边缘视图
- (void)setHidden:(BOOL)hidden {
	%orig;
	WCLGRefreshEdgeViews();
}

- (void)didMoveToSuperview {
	%orig;
	WCLGResetBarChrome(self);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
	%orig;
	WCLGResetBarChrome(self);
}

%end

// MMTabBarController 是 UITabBarController，别干预它的原生行为。
// 只挂钩微信自己的按钮重排：重排后 item 可能回到全宽网格，
// 这里立刻重新摘容器、确认底色、对齐，不必等下一轮 bar 布局。
%hook MMTabBarController

- (void)relayoutButtons:(BOOL)animated {
	%orig;
	UITabBar *bar = self.tabBar;
	WCLGResetBarChrome(bar);
	WCLGApplyFixes(bar);
}

// --- 随滚动收纳 ---
// 微信自己也可能设这个属性（它的二进制里有 setTabBarMinimizeBehavior:），
// 所以直接在 setter 上强制成我们要的值，谁设都一样。
- (void)setTabBarMinimizeBehavior:(NSInteger)behavior {
	%orig(WCLGMinimizeBehaviorValue());
}

- (void)viewDidLoad {
	%orig;
	WCLGSetMinimizeBehavior(self);
}

- (void)viewWillAppear:(BOOL)animated {
	%orig;
	WCLGSetMinimizeBehavior(self);
}

%end

%end // WCLGTabBar

// ============================================================
//  入口
//
//  统一在这里把关：系统太旧或开关关闭就什么都不装，微信保持原样。
//  NSBundle 的 hook 要尽早装，赶在 UIKit 读取 Info.plist 之前。
// ============================================================
%ctor {
	if ([NSProcessInfo processInfo].operatingSystemVersion.majorVersion < 26) return;
	if (!WCLGEnabled()) return;

	%init(WCLGBundle);
	%init(WCLGTabBar);

	// 收纳动画期间要靠胶囊自己的 layout 来驱动对齐
	Class platterCls = NSClassFromString(@"UIKit._UITabBarItemPlatterView");
	if (!platterCls) platterCls = objc_getClass("_TtC5UIKit24_UITabBarItemPlatterView");
	if (platterCls) {
		WCLGLog(@"platter class resolved: %@", NSStringFromClass(platterCls));
		%init(WCLGPlatter, UITabBarItemPlatterView = platterCls);
	} else {
		WCLGLog(@"platter class NOT found — minimize tracking disabled");
	}

	// 首选 ObjC 名（实测能解析到）。备选的 mangled 名是从内部类
	// _TtCC5UIKit20...BackdropView 推导的，**从未验证过**，
	// 留着是防将来 ObjC 名解析方式变了，成本为零。
	Class edgeCls = NSClassFromString(@"UIKit.ScrollEdgeEffectView");
	if (!edgeCls) edgeCls = objc_getClass("_TtC5UIKit20ScrollEdgeEffectView");
	if (edgeCls) {
		%init(WCLGScrollEdge, ScrollEdgeEffectView = edgeCls);
	} else {
		// 微信或系统升级后类名变了，在这里留痕，别静默失败
		WCLGLog(@"ScrollEdgeEffectView not found, edge effect stays on");
	}
}
%group ABTop

// 禁用顶部导航栏按钮的液态玻璃包裹（屏蔽 UIDesignRequiresCompatibility 的副作用）。
// 只隐藏「液态玻璃层」（类名含 Liquid/Glass/Platter/BackgroundEffect 且非按钮宿主），
// 保留按钮本身与点击；全程防御性，找不到就不动。附带探针日志定位真实类名。
static char kABTopPrintedSetKey;

static void ABTopClassify(UIView *v, NSMutableSet *printed) {
    if (!v) return;
    NSString *name = NSStringFromClass([v class]);
    if (name.length == 0) return;
    if (![printed containsObject:name]) {
        [printed addObject:name];
        TFLog(@"[APIBlocker] nav subview: %@", name);
    }
    // 液态玻璃层特征名
    BOOL glass = [name rangeOfString:@"Liquid"].location != NSNotFound ||
                 [name rangeOfString:@"Glass"].location != NSNotFound ||
                 [name rangeOfString:@"Platter"].location != NSNotFound ||
                 [name rangeOfString:@"LiquidLens"].location != NSNotFound;
    // 宿主/背景容器绝不能碰（隐藏会破坏点击或让导航栏背景消失）
    BOOL host = [name rangeOfString:@"BarButton"].location != NSNotFound ||
                [name rangeOfString:@"Button"].location != NSNotFound ||
                [name rangeOfString:@"ItemView"].location != NSNotFound ||
                [name rangeOfString:@"ContentView"].location != NSNotFound ||
                [name rangeOfString:@"BackgroundView"].location != NSNotFound ||
                [name rangeOfString:@"UIBarBackground"].location != NSNotFound ||
                [name rangeOfString:@"BarBackground"].location != NSNotFound;
    // 图标/文字内容层绝不动（上一版把官方图标一起剥没了，就是误命中了图标层）
    BOOL content = [name rangeOfString:@"Image"].location != NSNotFound ||
                   [name rangeOfString:@"Icon"].location != NSNotFound ||
                   [name rangeOfString:@"Symbol"].location != NSNotFound ||
                   [name rangeOfString:@"Label"].location != NSNotFound ||
                   [name rangeOfString:@"Title"].location != NSNotFound;
    if (glass && !host && !content) {
        // 若该视图直接承载可见图标（含 UIImageView 子视图），视为内容层，不隐藏
        BOOL carriesIcon = NO;
        for (UIView *g in v.subviews) {
            if ([g isKindOfClass:[UIImageView class]]) { carriesIcon = YES; break; }
        }
        if (!carriesIcon) {
            if (!v.hidden) v.hidden = YES;
        }
    }
    // 递归：液态玻璃可能包在按钮内部的更深层（不止前两层）
    for (UIView *g in [v.subviews copy]) {
        ABTopClassify(g, printed);
    }
}

static void ABTopDeGlaze(UINavigationBar *bar) {
    if (!bar || !TopLiquidEnabled()) return;
    NSMutableSet *printed = objc_getAssociatedObject(bar, &kABTopPrintedSetKey);
    if (!printed) {
        printed = [NSMutableSet set];
        objc_setAssociatedObject(bar, &kABTopPrintedSetKey, printed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (UIView *sv in [bar.subviews copy]) {
        ABTopClassify(sv, printed); // classify 内部递归整棵子树
    }
}

%hook UINavigationBar

- (void)layoutSubviews {
    %orig;
    @try { ABTopDeGlaze(self); }
    @catch (NSException *e) { TFLog(@"[APIBlocker] nav deglaze err: %@", e.reason); }
}

%end

%end // ABTop


// 收消息 hook：微信收到新消息时转发到外部 Webhook
%group ABForwardHook
%hook CMessageMgr

- (void)AsyncOnAddMsg:(id)msg MsgWrap:(id)wrap {
    %orig;
    @try {
        ABForwardHandleIncomingMessage(wrap);
    } @catch (NSException *exception) {
        TFLog(@"[Forward] 转发异常：%@", exception.reason);
    }
}

// 诊断：抓真实表情消息（type 47）的原始 wrap 字段，用于对齐发送格式
- (void)AddMsg:(id)usr MsgWrap:(id)wrap {
    %orig;
    @try {
        unsigned t = (unsigned)ABGetUInt(wrap, @"m_uiMessageType");
        if (t == 47) {
            NSString *c = [wrap valueForKey:@"m_nsContent"];
            NSString *src = [wrap valueForKey:@"m_nsMsgSource"];
            ABNoteSend(@"原生表情消息：to=%@ len=%lu content=%.200@", [wrap valueForKey:@"m_nsToUsr"] ?: @"?", (unsigned long)c.length, c ?: @"");
            ABNoteSend(@"原生表情副：srcLen=%lu src=%.160@", (unsigned long)src.length, src ?: @"");
        }
    } @catch (NSException *exception) {
        TFLog(@"[Probe] AddMsg 诊断异常：%@", exception.reason);
    }
}

%end
%end // ABForwardHook


// 安装基础 hook 组（NSURLSessionConfiguration / WKWebView + 顶部去液态）——group 定义在文件中部，故在此末尾 ctor 统一 init
#pragma mark - 微信后台常驻

static NSUInteger gABBackgroundTask = UIBackgroundTaskInvalid;

static AVAudioPlayer *gABSilencePlayer = nil;
static NSTimer *gABKeepAliveTimer = nil;

// 生成 2 秒静音 WAV（22050Hz / 单声道 / 16bit），用于后台保活
static NSURL *ABSilentAudioURL(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TweakfixMedia"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"silence_keepalive.wav"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return [NSURL fileURLWithPath:path];
    }
    int rate = 22050, channels = 1, bits = 16;
    int frames = rate * 2;
    int dataBytes = frames * channels * bits / 8;
    NSMutableData *d = [NSMutableData dataWithCapacity:44 + dataBytes];
    uint32_t u32; uint16_t u16;
    [d appendBytes:"RIFF" length:4];
    u32 = 36 + dataBytes; [d appendBytes:&u32 length:4];
    [d appendBytes:"WAVEfmt " length:8];
    u32 = 16; [d appendBytes:&u32 length:4];
    u16 = 1; [d appendBytes:&u16 length:2];
    u16 = channels; [d appendBytes:&u16 length:2];
    u32 = rate; [d appendBytes:&u32 length:4];
    u32 = rate * channels * bits / 8; [d appendBytes:&u32 length:4];
    u16 = channels * bits / 8; [d appendBytes:&u16 length:2];
    u16 = bits; [d appendBytes:&u16 length:2];
    [d appendBytes:"data" length:4];
    u32 = dataBytes; [d appendBytes:&u32 length:4];
    [d appendData:[NSMutableData dataWithLength:dataBytes]];
    [d writeToFile:path atomically:YES];
    return [NSURL fileURLWithPath:path];
}

void ABKeepAliveAudioStart(void) {
    if (!KeepAliveEnabled()) {
        return;
    }
    @try {
        if (gABSilencePlayer && gABSilencePlayer.isPlaying) {
            return;
        }
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:nil];
        [session setActive:YES error:nil];
        if (!gABSilencePlayer) {
            NSError *err = nil;
            gABSilencePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:ABSilentAudioURL() error:&err];
            if (err) {
                TFLog(@"[KeepAlive] 静音音频加载失败：%@", err.localizedDescription);
            }
            gABSilencePlayer.numberOfLoops = -1;
            gABSilencePlayer.volume = 0.0;
            [gABSilencePlayer prepareToPlay];
        }
        BOOL ok = [gABSilencePlayer play];
        TFLog(@"[KeepAlive] 静音音频启动 play=%d playing=%d", ok ? 1 : 0, gABSilencePlayer.isPlaying ? 1 : 0);
    } @catch (NSException *e) {
        TFLog(@"[KeepAlive] 静音音频异常：%@", e.reason);
    }
}

void ABKeepAliveAudioStop(void) {
    @try {
        if (gABSilencePlayer) {
            [gABSilencePlayer stop];
        }
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    } @catch (NSException *e) {
        TFLog(@"[KeepAlive] 停止静音音频异常：%@", e.reason);
    }
    TFLog(@"[KeepAlive] 静音音频已停止");
}

static void ABKeepAliveAudioEnsure(void) {
    if (!KeepAliveEnabled()) {
        return;
    }
    if (!gABSilencePlayer || !gABSilencePlayer.isPlaying) {
        ABKeepAliveAudioStart();
    }
}

void ABKeepAliveTick(void) {
    if (!KeepAliveEnabled()) {
        return;
    }
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) {
        return;
    }
    if (gABBackgroundTask != UIBackgroundTaskInvalid) {
        [app endBackgroundTask:gABBackgroundTask];
        gABBackgroundTask = UIBackgroundTaskInvalid;
    }
    ABKeepAliveAudioEnsure();
    __block BOOL handlerRan = NO;
    gABBackgroundTask = [app beginBackgroundTaskWithExpirationHandler:^{
        handlerRan = YES;
        if (gABBackgroundTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:gABBackgroundTask];
            gABBackgroundTask = UIBackgroundTaskInvalid;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ABKeepAliveTick();
        });
    }];
    TFLog(@"[KeepAlive] 申请后台任务：%lu", (unsigned long)gABBackgroundTask);
    // 后台任务通常约 180 秒到期，提前续一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!handlerRan && KeepAliveEnabled()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ABKeepAliveTick();
            });
        }
    });
}

static void ABSetupKeepAlive(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        if (KeepAliveEnabled()) {
            ABKeepAliveTick();
            ABKeepAliveAudioStart();
        }
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
        if (type.integerValue == AVAudioSessionInterruptionTypeEnded) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ABKeepAliveAudioEnsure();
            });
        }
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        gABSilencePlayer = nil;
        ABKeepAliveAudioEnsure();
    }];
    if (!gABKeepAliveTimer) {
        gABKeepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:20.0 repeats:YES block:^(NSTimer *t) {
            if (KeepAliveEnabled() && [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
                ABKeepAliveAudioEnsure();
            }
        }];
    }
    if (KeepAliveEnabled()) {
        ABKeepAliveAudioStart();
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        if (gABBackgroundTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:gABBackgroundTask];
            gABBackgroundTask = UIBackgroundTaskInvalid;
        }
    }];
}

%ctor {
    %init(ABBase);
    %init(ABTop);
    %init(ABTabBarOffset); // 底栏下沉：独立于液态开关，始终生效
    %init(ABForwardHook);
    %init(ABLogicCapture); // 捕获最近打开的聊天控制器，用于图片按会话名定位

    // 本地发送 API：跟随配置启停（默认开启，端口 8787）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ABHTTPRestartServerIfNeeded();
        ABSetupKeepAlive();
    });
}
