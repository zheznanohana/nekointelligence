// GMSetup.m — 首次运行/搬家后的自愈安装
//
// 为什么需要它：XPC 服务的注入路径必须是绝对路径，而 app 可能被拖到任何位置
// （/Applications、桌面、只读的 DMG 卷）。所以启动时做三件事：
//   1. 把 dylib 从 app 内 Resources/AI 复制到 ~/Library/Application Support/AppleIntel/AI
//   2. 把 XPC 服务 Info.plist 的 DYLD_INSERT_LIBRARIES 重写成上面这些绝对路径
//   3. 按 Apple 原始 entitlements 重新签名 XPC 副本，再签整个 app（ad-hoc）
// 只在内容变化时才重签，避免每次启动都动签名。

#import <Cocoa/Cocoa.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/mount.h>

static NSString *SUSupport(void){
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/AppleIntel"];
}
static NSString *SUAI(void){ return [SUSupport() stringByAppendingPathComponent:@"AI"]; }

static void slog(NSString *fmt, ...){
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "SETUP %s\n", s.UTF8String);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
    NSString *p = [SUSupport() stringByAppendingPathComponent:@"setup.log"];
    FILE *f = fopen(p.fileSystemRepresentation, "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
}

static BOOL runTask(NSString *launch, NSArray *args){
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = launch;
    t.arguments = args;
    @try { [t launch]; [t waitUntilExit]; }
    @catch (NSException *e) { slog(@"task %@ failed: %@", launch, e.reason); return NO; }
    return t.terminationStatus == 0;
}

static void copyTree(NSString *src, NSString *dst){
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:NULL];
    for (NSString *name in [fm contentsOfDirectoryAtPath:src error:NULL]) {
        NSString *s = [src stringByAppendingPathComponent:name];
        NSString *d = [dst stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        [fm fileExistsAtPath:s isDirectory:&isDir];
        if (isDir) { copyTree(s, d); continue; }
        NSDictionary *sa = [fm attributesOfItemAtPath:s error:NULL];
        NSDictionary *da = [fm attributesOfItemAtPath:d error:NULL];
        if (da && [da[NSFileSize] isEqual:sa[NSFileSize]]) continue;   // 已有同名同大小文件，跳过
        [fm removeItemAtPath:d error:NULL];
        [fm copyItemAtPath:s toPath:d error:NULL];
    }
}

// 把 XPC 副本的注入路径指向支持目录；返回是否改动了 plist
static BOOL ensureXPCConfig(NSString *appPath, NSArray<NSString*> *dylibs){
    NSString *xpc = [appPath stringByAppendingPathComponent:@"Contents/XPCServices/WritingToolsViewService.xpc"];
    NSString *plistPath = [xpc stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSMutableDictionary *pl = [[NSMutableDictionary alloc] initWithContentsOfFile:plistPath];
    if (!pl) { slog(@"XPC Info.plist 读不到: %@", plistPath); return NO; }
    NSMutableDictionary *svc = [pl[@"XPCService"] mutableCopy];
    if (!svc) svc = [NSMutableDictionary dictionary];
    NSMutableDictionary *env = [svc[@"EnvironmentVariables"] mutableCopy];
    if (!env) env = [NSMutableDictionary dictionary];
    NSString *chain = [dylibs componentsJoinedByString:@":"];
    NSMutableArray *logs = [NSMutableArray array];
    [logs addObject:@"GMAX_LABEL=__none__"];
    [logs addObject:@"GMAX_LOG=/tmp/gmax6.log"];
    [logs addObject:@"VSSTUB_LOG=/tmp/bridge/vsstub.log"];
    [logs addObject:@"VSSTUB_INSTR_FILE=/tmp/bridge/instruction.txt"];
    [logs addObject:@"GMHOOK_LOG=/tmp/gmhook_vs.log"];
    [logs addObject:@"GMVS_LOG=/tmp/gmvs_vs.log"];
    [logs addObject:@"GMPREF_LOG=/tmp/gmpref.log"];
    NSString *want = [NSString stringWithFormat:@"%@\n%@", chain, [logs componentsJoinedByString:@"\n"]];
    NSString *have = [NSString stringWithFormat:@"%@\n%@", env[@"DYLD_INSERT_LIBRARIES"] ?: @"",
                      [@[@"GMAX_LABEL", @"GMAX_LOG", @"VSSTUB_LOG", @"VSSTUB_INSTR_FILE", @"GMHOOK_LOG", @"GMVS_LOG", @"GMPREF_LOG"]
                        componentsJoinedByString:@"\n"]];
    BOOL changed = ![env[@"DYLD_INSERT_LIBRARIES"] isEqual:chain];
    env[@"DYLD_INSERT_LIBRARIES"] = chain;
    env[@"GMAX_LABEL"] = @"__none__";
    env[@"GMAX_LOG"] = @"/tmp/gmax6.log";
    env[@"VSSTUB_LOG"] = @"/tmp/bridge/vsstub.log";
    env[@"VSSTUB_INSTR_FILE"] = @"/tmp/bridge/instruction.txt";
    env[@"GMHOOK_LOG"] = @"/tmp/gmhook_vs.log";
    env[@"GMVS_LOG"] = @"/tmp/gmvs_vs.log";
    env[@"GMPREF_LOG"] = @"/tmp/gmpref.log";
    svc[@"EnvironmentVariables"] = env;
    pl[@"XPCService"] = svc;
    if (!changed) return NO;
    if (![pl writeToFile:plistPath atomically:YES]) { slog(@"写 XPC plist 失败"); return NO; }
    (void)want; (void)have;
    return YES;
}

static void ensureAutostartDefault(void);

void GMSetupEnsure(void){
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *app = [[NSBundle mainBundle] bundlePath];
        NSString *res = [app stringByAppendingPathComponent:@"Contents/Resources"];
        [fm createDirectoryAtPath:SUSupport() withIntermediateDirectories:YES attributes:nil error:NULL];
        [fm createDirectoryAtPath:SUAI() withIntermediateDirectories:YES attributes:nil error:NULL];
        [fm createDirectoryAtPath:@"/tmp/bridge" withIntermediateDirectories:YES attributes:nil error:NULL];

        // 1) 支持文件（脚本/entitlements/说明）复制到固定位置，供自检与重签使用
        NSString *supportSrc = [res stringByAppendingPathComponent:@"support"];
        if ([fm fileExistsAtPath:supportSrc]) copyTree(supportSrc, SUSupport());

        // 2) 注入用 dylib 复制到固定位置（app 将来被移动也不影响）
        NSString *aiSrc = [res stringByAppendingPathComponent:@"AI"];
        if ([fm fileExistsAtPath:aiSrc]) {
            for (NSString *name in [fm contentsOfDirectoryAtPath:aiSrc error:NULL]) {
                if (![name hasSuffix:@".dylib"]) continue;
                NSString *s = [aiSrc stringByAppendingPathComponent:name];
                NSString *d = [SUAI() stringByAppendingPathComponent:name];
                NSDictionary *sa = [fm attributesOfItemAtPath:s error:NULL];
                NSDictionary *da = [fm attributesOfItemAtPath:d error:NULL];
                if (!da || ![da[NSFileSize] isEqual:sa[NSFileSize]]) {
                    [fm removeItemAtPath:d error:NULL];
                    [fm copyItemAtPath:s toPath:d error:NULL];
                    slog(@"更新 dylib %@", name);
                }
            }
        }

        // 3) 保证 XPC 副本签名有效（entitlements 决定它能否连 modelmanagerd / 偏好域）
        NSString *ent = [SUSupport() stringByAppendingPathComponent:@"vs.entitlements"];
        NSArray *dylibs = @[
            [SUAI() stringByAppendingPathComponent:@"gmhook6.dylib"],
            [SUAI() stringByAppendingPathComponent:@"gmpref.dylib"],
            [SUAI() stringByAppendingPathComponent:@"gmax.dylib"],
            [SUAI() stringByAppendingPathComponent:@"gmvs.dylib"],
            [SUAI() stringByAppendingPathComponent:@"gmtype2.dylib"],
            [SUAI() stringByAppendingPathComponent:@"vsstub.dylib"],
        ];
        BOOL changed = ensureXPCConfig(app, dylibs);
        NSString *xpc = [app stringByAppendingPathComponent:@"Contents/XPCServices/WritingToolsViewService.xpc"];
        BOOL needSign = changed;
        if (!needSign) {
            // 内容没变也可能因为 app 被移动/复制而签名失效：用 codesign --verify 快速判断
            NSTask *t = [[NSTask alloc] init];
            t.launchPath = @"/usr/bin/codesign";
            t.arguments = @[@"--verify", @"--deep", @"--strict", xpc];
            t.standardError = [NSFileHandle fileHandleWithNullDevice];
            t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
            @try { [t launch]; [t waitUntilExit]; needSign = (t.terminationStatus != 0); }
            @catch (NSException *e) { needSign = YES; }
        }
        ensureAutostartDefault();
        if (needSign) {
            if ([fm fileExistsAtPath:ent]) {
                runTask(@"/usr/bin/codesign", @[@"--force", @"--sign", @"-", @"--entitlements", ent, xpc]);
                runTask(@"/usr/bin/codesign", @[@"--force", @"--sign", @"-", app]);
                slog(@"已重签 XPC 与 app");
                // ad-hoc 签名的「辅助功能」授权是按签名哈希认的：正在运行的进程还是旧签名，
                // 用户此时去授权会一直显示「未授权」。所以重签后立刻用新签名重开一次（只重开一次）。
                if (!getenv("GG_RELAUNCHED") && ![app hasPrefix:@"/Volumes/"]) {
                    slog(@"签名已更新，自动重新打开");
                    [NSTask launchedTaskWithLaunchPath:@"/usr/bin/open"
                                             arguments:@[@"-n", @"--env", @"GG_RELAUNCHED=1", app]];
                    exit(0);
                }
            } else {
                slog(@"缺少 vs.entitlements，跳过重签（功能会受限）");
            }
        }
    }
}

#pragma mark - 开机自启

static NSString *AULabel(void){ return @"com.local.appleintel.host"; }
static NSString *AUPath(void){
    return [NSHomeDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Library/LaunchAgents/%@.plist", AULabel()]];
}

BOOL GMAutostartEnabled(void){
    return [[NSFileManager defaultManager] fileExistsAtPath:AUPath()];
}

void GMSetupSetAutostart(BOOL on){
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *uid = [NSString stringWithFormat:@"%d", (int)getuid()];
    if (on) {
        NSString *app = [[NSBundle mainBundle] bundlePath];
        NSDictionary *pl = @{
            @"Label": AULabel(),
            @"ProgramArguments": @[@"/usr/bin/open", @"-a", app],
            @"RunAtLoad": @YES,
            @"ProcessType": @"Interactive",
        };
        [fm createDirectoryAtPath:[AUPath() stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:NULL];
        [pl writeToFile:AUPath() atomically:YES];
        chmod(AUPath().fileSystemRepresentation, 0644);
        runTask(@"/bin/launchctl", @[@"bootout", [NSString stringWithFormat:@"gui/%@/%@", uid, AULabel()]]);
        runTask(@"/bin/launchctl", @[@"bootstrap", [NSString stringWithFormat:@"gui/%@", uid], AUPath()]);
        slog(@"已开启开机自启");
    } else {
        runTask(@"/bin/launchctl", @[@"bootout", [NSString stringWithFormat:@"gui/%@/%@", uid, AULabel()]]);
        [fm removeItemAtPath:AUPath() error:NULL];
        slog(@"已关闭开机自启");
    }
}

// 首次运行默认开启；之后尊重用户的选择（有 marker 表示用户已做过选择）
static void ensureAutostartDefault(void){
    NSString *marker = [SUSupport() stringByAppendingPathComponent:@".autostart-inited"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:marker]) return;
    GMSetupSetAutostart(YES);
    [@"" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}


#pragma mark - 安装位置 / 单实例 / 从磁盘映像自安装

static NSString *GMAppName(void){ return [[[NSBundle mainBundle] bundlePath] lastPathComponent]; }

// 记录当前安装位置（doctor.sh / uninstall.sh 读它），并让开机自启指向当前位置
void GMSetupRecordInstallPath(void){
    NSString *app = [[NSBundle mainBundle] bundlePath];
    NSString *rec = [SUSupport() stringByAppendingPathComponent:@"install-path.txt"];
    NSString *prev = [[NSString stringWithContentsOfFile:rec encoding:NSUTF8StringEncoding error:NULL]
                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [[NSFileManager defaultManager] createDirectoryAtPath:SUSupport() withIntermediateDirectories:YES attributes:nil error:NULL];
    [[app stringByAppendingString:@"\n"] writeToFile:rec atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    // 新装到一个位置（从 DMG 安装 / 换了路径）的第一次启动：开机自启默认打开并指向这里。
    // 之后用户在「通用」里关掉就尊重用户（路径没变不会再改回来）。
    if (![prev isEqualToString:app] && ![app hasPrefix:@"/Volumes/"] && ![app containsString:@"/AppTranslocation/"]) {
        GMSetupSetAutostart(YES);
        slog(@"新安装位置 %@：已开启开机自启", app);
        return;
    }
    NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:AUPath()];
    NSArray *args = pl[@"ProgramArguments"];
    if ([args isKindOfClass:[NSArray class]] && args.count >= 3 && ![args.lastObject isEqual:app]) {
        NSMutableDictionary *m = [pl mutableCopy];
        m[@"ProgramArguments"] = @[@"/usr/bin/open", @"-a", app];
        [m writeToFile:AUPath() atomically:YES];      // 下次登录生效，不重新 bootstrap（否则会再拉起一个实例）
        slog(@"开机自启路径已更新为 %@", app);
    }
}

// 同一 bundle id 的其他实例（旧版本、另一个位置的副本）让位给当前进程
void GMSetupTakeOver(void){
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    pid_t me = getpid();
    NSArray *others = [[NSRunningApplication runningApplicationsWithBundleIdentifier:bid]
                       filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSRunningApplication *a, id b){ return a.processIdentifier != me; }]];
    if (!others.count) return;
    for (NSRunningApplication *a in others) { slog(@"接管：结束旧实例 pid=%d %@", a.processIdentifier, a.bundleURL.path); [a terminate]; }
    for (int i = 0; i < 30; i++) {
        BOOL alive = NO;
        for (NSRunningApplication *a in others) if (!a.terminated) alive = YES;
        if (!alive) return;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    for (NSRunningApplication *a in others) if (!a.terminated) [a forceTerminate];
}

static BOOL GMIsReadOnlyLocation(NSString *p){
    if ([p containsString:@"/AppTranslocation/"]) return YES;
    struct statfs sf;
    if (statfs(p.fileSystemRepresentation, &sf) == 0 && (sf.f_flags & MNT_RDONLY)) return YES;
    return [p hasPrefix:@"/Volumes/"];
}

// 从 DMG（只读卷）或被系统「转移」的位置运行时：问一次，复制到「应用程序」并从那里重新打开。
// 返回 YES 表示已经拉起安装后的副本，调用方应立即退出。
BOOL GMSetupInstallIfNeeded(void){
    NSString *app = [[NSBundle mainBundle] bundlePath];
    if (getenv("GG_NOINSTALL") || !GMIsReadOnlyLocation(app)) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];

    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *a = [NSAlert new];
    a.messageText = @"安装到「应用程序」文件夹？";
    a.informativeText = @"写作工具面板不能在磁盘映像里运行。安装后 App 会自动重新打开，并推出磁盘映像。";
    a.icon = [NSApp applicationIconImage];
    [a addButtonWithTitle:@"安装"];
    [a addButtonWithTitle:@"退出"];
    if ([a runModal] != NSAlertFirstButtonReturn) { exit(0); }

    GMSetupTakeOver();
    NSArray *targets = @[ @"/Applications", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"] ];
    NSString *dest = nil;
    for (NSString *dir in targets) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *d = [dir stringByAppendingPathComponent:GMAppName()];
        if ([fm fileExistsAtPath:d]) [fm trashItemAtURL:[NSURL fileURLWithPath:d] resultingItemURL:NULL error:NULL];
        if ([fm fileExistsAtPath:d]) continue;
        NSTask *t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"];
        t.arguments = @[app, d];
        if ([t launchAndReturnError:NULL]) { [t waitUntilExit]; if (t.terminationStatus == 0) { dest = d; break; } }
    }
    if (!dest) {
        NSAlert *e = [NSAlert new];
        e.messageText = @"没能安装";
        e.informativeText = @"请把 App 手动拖到「应用程序」文件夹，再从那里打开。";
        [e runModal];
        exit(1);
    }
    runTask(@"/usr/bin/xattr", @[@"-dr", @"com.apple.quarantine", dest]);
    // 另一处的旧副本（同名、同 bundle id）移到废纸篓，避免启动台里出现两个
    for (NSString *dir in targets) {
        NSString *d = [dir stringByAppendingPathComponent:GMAppName()];
        if ([d isEqualToString:dest] || ![fm fileExistsAtPath:d]) continue;
        NSBundle *b = [NSBundle bundleWithPath:d];
        if ([b.bundleIdentifier isEqualToString:[[NSBundle mainBundle] bundleIdentifier]]) {
            [fm trashItemAtURL:[NSURL fileURLWithPath:d] resultingItemURL:NULL error:NULL];
            slog(@"旧副本已移到废纸篓: %@", d);
        }
    }
    slog(@"已从磁盘映像安装到 %@", dest);
    [NSTask launchedTaskWithLaunchPath:@"/usr/bin/open" arguments:@[@"-n", dest]];
    // 推出磁盘映像（等本进程退出后）
    if ([app hasPrefix:@"/Volumes/"]) {
        NSArray *comps = [app pathComponents];   // / Volumes <name> ...
        if (comps.count > 2) {
            NSString *vol = [NSString pathWithComponents:[comps subarrayWithRange:NSMakeRange(0, 3)]];
            NSTask *t = [NSTask new];
            t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
            t.arguments = @[@"-c", [NSString stringWithFormat:@"sleep 2; /usr/bin/hdiutil detach '%@' -quiet", [vol stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]];
            [t launchAndReturnError:NULL];
        }
    }
    return YES;
}
