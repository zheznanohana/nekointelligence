#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#include <sys/mman.h>
#import <Carbon/Carbon.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <poll.h>
#import <string.h>
#import <ApplicationServices/ApplicationServices.h>
#import "GMLang.h"

static NSTextView *gTV; static NSWindow *gWin;
static BOOL gAutoCopy = YES;
static NSTimeInterval gLastProgrammatic = 0;
static NSMutableArray<NSString*> *gUndo = nil;
static NSString *gLastText = nil;

// GMBridge.m / GMShell.m
void GMBridgeStart(void);
void GMManagerShow(void);
NSWindow *GMShellCreate(NSTextView *editor, id controller);
void GMShellShow(NSString *pane);
void GMShellSelect(NSString *pane);
void GMShellSetCompact(BOOL on, NSRect frame);
void GMShellSetStatus(NSString *msg);
void GMShellRunDoctor(void);
void GMShellToggleSidebar(void);
NSArray<NSMenuItem*> *GMShellPaneMenuItems(void);
BOOL AIHGetAutoCopy(void) { return gAutoCopy; }
void AIHSetAutoCopy(BOOL on) { gAutoCopy = on; fprintf(stderr,"AUTOCOPY=%d\n",(int)on); }
void GMSetupEnsure(void);
BOOL GMAutostartEnabled(void);
void GMSetupSetAutostart(BOOL on);
BOOL GMSetupInstallIfNeeded(void);
void GMSetupTakeOver(void);
void GMSetupRecordInstallPath(void);
static void pushUndo(NSString *prev){
  if (!prev.length) return;
  if (!gUndo) gUndo=[NSMutableArray array];
  if (gUndo.count && [gUndo.lastObject isEqualToString:prev]) return;
  [gUndo addObject:prev];
  while (gUndo.count>5) [gUndo removeObjectAtIndex:0];
}
static void markProgrammatic(void){ gLastProgrammatic = [[NSDate date] timeIntervalSince1970]; }
static pid_t gTargetPid;
static AXUIElementRef gTargetElem;
static BOOL gFromOtherApp = NO;
static void writeBackToTarget(NSString *s);
static void openFromClipboard(void);
static void ensureWinVisible(void);
static void setupAutoCopy(void){
    gLastProgrammatic = [[NSDate date] timeIntervalSince1970];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSTextStorageDidProcessEditingNotification
        object:[gTV textStorage] queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
        if (!gAutoCopy) return;
        NSTimeInterval now=[[NSDate date] timeIntervalSince1970];
        if (now - gLastProgrammatic < 2.5) return;
        NSString *s=[gTV string];
        if (!s.length || s.length > 300000) return;
        if (gLastText && ![gLastText isEqualToString:s]) pushUndo(gLastText);
        gLastText = s;
        NSPasteboard *pb=[NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:s forType:NSPasteboardTypeString];
        fprintf(stderr,"AUTOCOPY %lu chars\n",(unsigned long)s.length);
        if (gTargetPid && gTargetPid != getpid()) writeBackToTarget(s);
    }];
}

static uintptr_t imageBase(const char *needle){
  for (uint32_t i=0;i<_dyld_image_count();i++){const char*nm=_dyld_get_image_name(i);
    if(nm&&strstr(nm,needle)) return (uintptr_t)_dyld_get_image_header(i);} return 0;}

static void patchAvailability(void){
  void*h=dlopen("/System/Library/PrivateFrameworks/WritingToolsUI.framework/Versions/A/WritingToolsUI",RTLD_NOW);
  fprintf(stderr,"AIH3 dlopen=%p err=%s\n",h,dlerror());
  uintptr_t base=imageBase("WritingToolsUI.framework/Versions/A/WritingToolsUI");
  if(base){
    vm_protect(mach_task_self(),(vm_address_t)((base+0x2A090)&~0xFFFULL),0x2000,0,
               VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE);
    unsigned char*fn=(unsigned char*)(base+0x2A090); fn[0]=0xb0;fn[1]=0x01;fn[2]=0xc3;
    __builtin___clear_cache((char*)fn,(char*)fn+3);
    fprintf(stderr,"AIH3 patched availability\n");
  }
}

static void setStatus(NSString *msg){
  if (!gWin) return;
  GMShellSetStatus(msg);
  fprintf(stderr,"STATUS %s\n", msg.length ? msg.UTF8String : "(clear)");
  static int seq=0; int my=++seq;
  if (msg.length) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(8.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
      if (seq==my) GMShellSetStatus(nil);
    });
  }
}


// ---- 全局抓取：辅助功能读前台 App 选中文字，并把结果写回 ----
static BOOL axTrusted(void){ return AXIsProcessTrusted(); }
static void axPrompt(void){
    NSDictionary *o = @{(__bridge NSString*)kAXTrustedCheckOptionPrompt: @YES};
    BOOL ok = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)o);
    fprintf(stderr,"AX prompt trusted=%d\n",(int)ok);
    if (!ok) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
static NSString *axString(AXUIElementRef el, CFStringRef attr){
    if (!el) return nil;
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return nil;
    NSString *s = nil;
    if (CFGetTypeID(v) == CFStringGetTypeID()) s = [NSString stringWithString:(__bridge NSString*)v];
    CFRelease(v);
    return s;
}
static BOOL postKey(CGKeyCode code, CGEventFlags flags){
    CGEventRef d = CGEventCreateKeyboardEvent(NULL, code, true);
    CGEventRef u = CGEventCreateKeyboardEvent(NULL, code, false);
    if (!d || !u) { if(d)CFRelease(d); if(u)CFRelease(u); return NO; }
    CGEventSetFlags(d, flags); CGEventSetFlags(u, flags);
    CGEventPost(kCGHIDEventTap, d); CGEventPost(kCGHIDEventTap, u);
    CFRelease(d); CFRelease(u); return YES;
}
static pid_t frontPid(void){ NSRunningApplication *a=[[NSWorkspace sharedWorkspace] frontmostApplication]; return a ? a.processIdentifier : 0; }
static NSString *frontName(void){ NSRunningApplication *a=[[NSWorkspace sharedWorkspace] frontmostApplication]; return a.localizedName ?: GMTr(@"前台 App"); }

static NSString *grabSelection(void){
    if (gTargetElem) { CFRelease(gTargetElem); gTargetElem=NULL; }
    gTargetPid = frontPid();
    gFromOtherApp = (gTargetPid != getpid());
    AXUIElementRef app = AXUIElementCreateApplication(gTargetPid);
    AXUIElementRef foc = NULL;
    if (app) {
        if (AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, (CFTypeRef*)&foc) != kAXErrorSuccess) foc = NULL;
        CFRelease(app);
    }
    NSString *sel = nil;
    if (foc) {
        sel = axString(foc, kAXSelectedTextAttribute);
        if (sel.length) gTargetElem = (AXUIElementRef)CFRetain(foc);
        CFRelease(foc);
    }
    if (!sel.length) {
        NSPasteboard *pb=[NSPasteboard generalPasteboard];
        NSString *bak=[pb stringForType:NSPasteboardTypeString];
        [pb clearContents];
        if (postKey(kVK_ANSI_C, kCGEventFlagMaskCommand)) {
            NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:0.8];
            while ([deadline timeIntervalSinceNow] > 0) {
                NSString *t=[pb stringForType:NSPasteboardTypeString];
                if (t.length) { sel=t; break; }
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            if (!sel.length && bak.length) { [pb clearContents]; [pb setString:bak forType:NSPasteboardTypeString]; }
        }
        fprintf(stderr,"AX copy fallback len=%lu\n",(unsigned long)sel.length);
    }
    fprintf(stderr,"GRAB pid=%d app=%s len=%lu ax=%d\n",(int)gTargetPid, frontName().UTF8String,
            (unsigned long)sel.length, gTargetElem?1:0);
    return sel;
}
static void clearTarget(void){
    if (gTargetElem) { CFRelease(gTargetElem); gTargetElem=NULL; }
    gTargetPid = 0;
}
static void writeBackToTarget(NSString *s){
    if (!s.length || !gTargetPid) return;
    if (gTargetElem) {
        AXError e=AXUIElementSetAttributeValue(gTargetElem, kAXSelectedTextAttribute, (__bridge CFTypeRef)s);
        if (e==kAXErrorSuccess) {
            fprintf(stderr,"WRITEBACK ax ok %lu chars\n",(unsigned long)s.length);
            setStatus(GMTr(@"已写回前台 App")); clearTarget(); return;
        }
        fprintf(stderr,"WRITEBACK ax err=%d -> paste\n",(int)e);
    }
    NSPasteboard *pb=[NSPasteboard generalPasteboard];
    [pb clearContents]; [pb setString:s forType:NSPasteboardTypeString];
    NSRunningApplication *a=[NSRunningApplication runningApplicationWithProcessIdentifier:gTargetPid];
    [a activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.3*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        postKey(kVK_ANSI_V, kCGEventFlagMaskCommand);
        fprintf(stderr,"WRITEBACK paste sent\n");
        setStatus(GMTr(@"已写回前台 App（粘贴）")); clearTarget();
    });
}
static void grabAndOpen(void){
    if (!axTrusted()) { fprintf(stderr,"AX not trusted\n"); setStatus(GMTr(@"需要在系统设置里给本 App 勾选「辅助功能」")); axPrompt(); return; }
    NSString *sel=grabSelection();
    if (!sel.length) { ensureWinVisible(); setStatus(GMTr(@"没读到选中文字：先选中一段再按 ⌘9")); return; }
    NSPasteboard *pb=[NSPasteboard generalPasteboard];
    [pb clearContents]; [pb setString:sel forType:NSPasteboardTypeString];
    setStatus([NSString stringWithFormat:GMTr(@"来自 %@，正在改写…"), frontName()]);
    openFromClipboard();
}

static void showPanel(void){
  GMShellSelect(@"write");
  Class C=NSClassFromString(@"NSWritingToolsCoordinator");
  id coord=((id(*)(id,SEL,id))objc_msgSend)([C alloc],sel_registerName("initWithDelegate:"),gTV);
  [gTV setValue:coord forKey:@"writingToolsCoordinator"];
  [gTV setWritingToolsBehavior:2];
  [gTV setAllowedWritingToolsResultOptions:3];
  NSUInteger len=[[gTV string] length];
  NSRange cur = [gTV selectedRange];
  if (cur.length < 5) [gTV setSelectedRange:NSMakeRange(0, MIN((NSUInteger)160,len))];
  [gWin makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  setStatus(GMTr(@"正在打开面板…"));
  [gTV showWritingTools:nil];
  fprintf(stderr,"AIH3 showWritingTools sent\n");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
      BOOL pop=NO;
      for (NSWindow *w in [NSApp windows]) {
          if (!w.isVisible) continue;
          if ([NSStringFromClass([w class]) containsString:@"Popover"]) { pop=YES; break; }
      }
      if (!pop) {
          fprintf(stderr,"AIH3 panel missing -> retry\n");
          setStatus(GMTr(@"面板没弹出，正在重试…"));
          id c2=((id(*)(id,SEL,id))objc_msgSend)([C alloc],sel_registerName("initWithDelegate:"),gTV);
          [gTV setValue:c2 forKey:@"writingToolsCoordinator"];
          [gTV showWritingTools:nil];
      } else {
          setStatus(nil);
      }
      // 面板诊断
      NSMutableString *ws=[NSMutableString string];
      for (NSWindow *w in [NSApp windows]) {
          if (!w.isVisible) continue;
          [ws appendFormat:@"[%@ %@] ", NSStringFromClass([w class]), NSStringFromRect(w.frame)];
      }
      fprintf(stderr,"PANELDIAG host=%d windows=%s\n", (int)gWin.isVisible, ws.UTF8String);
  });
}

static void ensureWinVisible(void){
    if (!gWin) return;
    if ([NSApp isHidden]) { [NSApp unhide:nil]; fprintf(stderr,"WIN unhide\n"); }
    if ([gWin isMiniaturized]) { [gWin deminiaturize:nil]; fprintf(stderr,"WIN deminiaturize\n"); }
    NSScreen *sc=[NSScreen mainScreen];
    NSRect vis=sc.visibleFrame;
    if (gFromOtherApp) {
        NSPoint m=[NSEvent mouseLocation];
        CGFloat w=460,h=240;
        CGFloat x=MIN(MAX(m.x-40, vis.origin.x), NSMaxX(vis)-w);
        CGFloat y=MIN(MAX(m.y-h-30, vis.origin.y), NSMaxY(vis)-h);
        NSRect nf=NSMakeRect(x,y,w,h);
        GMShellSetCompact(YES, nf);
        fprintf(stderr,"WIN compact-invis %s alpha=%.1f\n", NSStringFromRect(nf).UTF8String, gWin.alphaValue);
    } else {
        GMShellSetCompact(NO, NSZeroRect);
    }
    if (!gWin.isVisible) { [gWin makeKeyAndOrderFront:nil]; fprintf(stderr,"WIN shown\n"); }
}

static void openFromClipboard(void){
    ensureWinVisible();
    NSPasteboard *pb=[NSPasteboard generalPasteboard];
    NSString *s=[pb stringForType:NSPasteboardTypeString];
    if(!s.length){ fprintf(stderr,"CLIP empty\n"); return; }
    NSString *prevTxt=[gTV string];
    if (prevTxt.length && ![prevTxt isEqualToString:s]) pushUndo(prevTxt);
    markProgrammatic(); [gTV setString:s]; gLastText=s; [gTV setSelectedRange:NSMakeRange(0,s.length)];
    [gWin makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    fprintf(stderr,"CLIP %lu chars\n",(unsigned long)s.length);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.3*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ showPanel(); });
}

static EventHandlerRef gHKHandler; static EventHotKeyRef gHKRef; static EventHotKeyRef gHKRef2;
static OSStatus hkCallback(EventHandlerCallRef next, EventRef ev, void *ud){
    (void)next; (void)ud;
    EventHotKeyID hk = {0, 0};
    GetEventParameter(ev, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hk), NULL, &hk);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (hk.id == 2) openFromClipboard();
        else grabAndOpen();
    });
    return noErr;
}
static void installHotkey(void){
    EventTypeSpec t={kEventClassKeyboard,kEventHotKeyPressed};
    InstallEventHandler(GetApplicationEventTarget(), NewEventHandlerUPP(hkCallback), 1, &t, NULL, &gHKHandler);
    EventHotKeyID k1; k1.signature='AIIX'; k1.id=1;
    OSStatus s1=RegisterEventHotKey(kVK_ANSI_9, cmdKey, k1, GetApplicationEventTarget(), 0, &gHKRef);
    EventHotKeyID k2; k2.signature='AIIX'; k2.id=2;
    OSStatus s2=RegisterEventHotKey(kVK_ANSI_W, controlKey|optionKey|cmdKey, k2, GetApplicationEventTarget(), 0, &gHKRef2);
    fprintf(stderr,"hotkey cmd9=%d ref=%p | ctrl-opt-cmdW=%d ref=%p\n",(int)s1,(void*)gHKRef,(int)s2,(void*)gHKRef2);
}


// ---- 同步调用千问代理（供系统服务用，阻塞至多 timeout 秒）----
static NSString *syncAsk(NSString *sys, NSString *user, NSTimeInterval timeout){
    int fd=socket(AF_UNIX,SOCK_STREAM,0); if(fd<0) return nil;
    struct sockaddr_un a; memset(&a,0,sizeof a); a.sun_family=AF_UNIX;
    strncpy(a.sun_path,"/tmp/qwen.sock",sizeof(a.sun_path)-1);
    if(connect(fd,(struct sockaddr*)&a,sizeof a)!=0){ close(fd); return nil; }
    NSDictionary *req=@{@"system":sys?:@"",@"user":user?:@"",@"max_tokens":@((int)(user.length*1.6)+400)};
    NSData *d=[NSJSONSerialization dataWithJSONObject:req options:0 error:NULL];
    NSMutableData *out=[NSMutableData dataWithData:d]; [out appendBytes:"\n" length:1];
    ssize_t wr=write(fd,out.bytes,out.length); (void)wr;
    NSMutableData *buf=[NSMutableData data]; char tmp[8192];
    NSTimeInterval end=[NSDate timeIntervalSinceReferenceDate]+timeout;
    while(1){
        NSTimeInterval left=end-[NSDate timeIntervalSinceReferenceDate];
        if(left<=0.05) break;
        struct pollfd pfd={fd,POLLIN,0};
        int r=poll(&pfd,1,(int)(left*1000));
        if(r<=0) break;
        ssize_t n=read(fd,tmp,sizeof tmp);
        if(n<=0) break;
        [buf appendBytes:tmp length:(NSUInteger)n];
        if(buf.length && ((const char*)buf.bytes)[buf.length-1]=='\n') break;
    }
    close(fd);
    if(!buf.length) return nil;
    id j=[NSJSONSerialization JSONObjectWithData:buf options:0 error:NULL];
    if(![j isKindOfClass:[NSDictionary class]]) return nil;
    if([j[@"ok"] boolValue]) return j[@"text"];
    return nil;
}
static NSString *SvcRewriteSystem(void){ return @"You are a text transformation engine inside the macOS Writing Tools panel. Rewrite the provided text to be clearer and more professional. Preserve the original meaning, tone and language. Keep the length within plus or minus 20 percent. Return ONLY the rewritten text."; }
static NSString *SvcSummarizeSystem(void){ return @"You are a summarisation engine inside the macOS Writing Tools panel. Summarise the provided text in ONE short sentence, at most 30 percent of the original length. Preserve the original language. Return ONLY the summary, no preamble."; }
static NSString *SvcTranslateSystem(void){ return @"You are a translation engine. If the text is mainly Chinese, translate it into natural English; otherwise translate it into natural Simplified Chinese. Preserve line breaks, numbers and formatting. Return ONLY the translation, no preamble."; }
static NSString *SvcProofreadSystem(void){ return @"You are a proofreading engine inside the macOS Writing Tools panel. Fix spelling, grammar and punctuation only; do not change wording, tone or length. Return ONLY the corrected text."; }
@interface AISvc : NSObject
- (void)handleServiceText:(NSPasteboard *)pb userData:(NSString *)ud error:(NSString **)err;
- (void)handleServiceRewriteInPlace:(NSPasteboard *)pb userData:(NSString *)ud error:(NSString **)err;
- (void)handleServiceSummarizeInPlace:(NSPasteboard *)pb userData:(NSString *)ud error:(NSString **)err;
- (void)handleServiceTranslateInPlace:(NSPasteboard *)pb userData:(NSString *)ud error:(NSString **)err;
- (void)handleServiceProofreadInPlace:(NSPasteboard *)pb userData:(NSString *)ud error:(NSString **)err;
- (void)handleServiceRewriteToClipboard:(NSPasteboard *)pb userData:(NSString *)ud error:(NSString **)err;
@end
@implementation AISvc

- (void)svcInPlace:(NSPasteboard *)pb system:(NSString *)sys tag:(const char *)tag error:(NSString **)err {
    NSString *s=[pb stringForType:NSPasteboardTypeString];
    if(!s.length){ if(err)*err=GMTr(@"没有收到文本"); return; }
    NSDate *t0=[NSDate date];
    NSString *r=syncAsk(sys,s,25.0);
    if(!r.length){ if(err)*err=GMTr(@"服务商没有响应，请到「诊断」页运行自检"); fprintf(stderr,"SERVICE_INPLACE %s FAILED\n",tag); return; }
    [pb clearContents];
    [pb setString:r forType:NSPasteboardTypeString];
    fprintf(stderr,"SERVICE_INPLACE %s %lu -> %lu chars in %.2fs\n",tag,(unsigned long)s.length,(unsigned long)r.length,-[t0 timeIntervalSinceNow]);
    { NSString *lp=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/AppleIntel/service.log"];
      NSString *line=[NSString stringWithFormat:@"%@ SERVICE_INPLACE %s %lu -> %lu chars in %.2fs\n",[NSDate date],tag,(unsigned long)s.length,(unsigned long)r.length,-[t0 timeIntervalSinceNow]];
      FILE *f=fopen(lp.fileSystemRepresentation,"a"); if(f){ fputs(line.UTF8String,f); fclose(f);} }
}
- (void)handleServiceRewriteInPlace:(NSPasteboard *)pb userData:(NSString *)ud error:(NSString **)err { [self svcInPlace:pb system:SvcRewriteSystem() tag:"rewrite" error:err]; }
- (void)handleServiceSummarizeInPlace:(NSPasteboard *)pb userData:(NSString *)ud error:(NSString **)err { [self svcInPlace:pb system:SvcSummarizeSystem() tag:"summarize" error:err]; }
- (void)handleServiceTranslateInPlace:(NSPasteboard *)pb userData:(NSString *)ud error:(NSString **)err { [self svcInPlace:pb system:SvcTranslateSystem() tag:"translate" error:err]; }
- (void)handleServiceProofreadInPlace:(NSPasteboard *)pb userData:(NSString *)ud error:(NSString **)err { [self svcInPlace:pb system:SvcProofreadSystem() tag:"proofread" error:err]; }
- (void)handleServiceRewriteToClipboard:(NSPasteboard *)pb userData:(NSString *)ud error:(NSString **)err {
    NSString *s=[pb stringForType:NSPasteboardTypeString];
    if(!s.length){ if(err)*err=GMTr(@"没有收到文本"); return; }
    NSDate *t0=[NSDate date];
    NSString *r=syncAsk(SvcRewriteSystem(),s,25.0);
    if(!r.length){ if(err)*err=GMTr(@"服务商没有响应，请到「诊断」页运行自检"); return; }
    NSPasteboard *g=[NSPasteboard generalPasteboard]; [g clearContents]; [g setString:r forType:NSPasteboardTypeString];
    fprintf(stderr,"SERVICE_COPY rewrite %lu -> %lu chars in %.2fs\n",(unsigned long)s.length,(unsigned long)r.length,-[t0 timeIntervalSinceNow]);
}

- (void)handleServiceText:(NSPasteboard *)pb userData:(NSString *)ud error:(NSString **)err {
    NSString *s = [pb stringForType:NSPasteboardTypeString];
    if (!s.length) { if (err) *err = GMTr(@"没有收到文本"); return; }
    markProgrammatic();
    [gTV setString:s];
    [gTV setSelectedRange:NSMakeRange(0, s.length)];
    [gWin makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    fprintf(stderr, "SERVICE got %lu chars\n", (unsigned long)s.length);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.35*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ showPanel(); });
}
@end
static AISvc *gSvc;

@interface AIHCtl : NSObject
- (void)showWT:(id)s;
- (void)showMain:(id)s;
- (void)openSupport:(id)s;
- (void)runDoctor:(id)s;
- (void)reloadWT:(id)s;
- (void)clipWT:(id)s;
- (void)grabWT:(id)s;
- (void)axAuth:(id)s;
- (void)openManager:(id)s;
- (void)toggleAutoStart:(NSMenuItem *)mi;
- (void)toggleLang:(id)s;
@end
@implementation AIHCtl
- (void)showWT:(id)s { showPanel(); }
- (void)reloadWT:(id)s { [gTV setValue:nil forKey:@"writingToolsCoordinator"]; showPanel(); }
- (void)clipWT:(id)s { openFromClipboard(); }
- (void)grabWT:(id)s { grabAndOpen(); }
- (void)axAuth:(id)s { axPrompt(); }
- (void)openManager:(id)s { GMManagerShow(); }
- (void)toggleLang:(id)s {
    NSString *next = [GMLangCode() isEqualToString:@"en"] ? @"zh" : @"en";
    GMLangSet(next);
    fprintf(stderr,"LANG=%s\n", next.UTF8String);
    setStatus(GMTr(@"语言已切换，正在重启 App…"));
    NSString *appPath = [[NSBundle mainBundle] bundlePath];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        [NSTask launchedTaskWithLaunchPath:@"/usr/bin/open" arguments:@[@"-n", appPath]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [NSApp terminate:nil]; });
    });
}
- (void)toggleAutoStart:(NSMenuItem *)mi {
    BOOL on = !GMAutostartEnabled();
    GMSetupSetAutostart(on);
    fprintf(stderr,"AUTOSTART=%d\n",(int)on);
}
- (void)showMain:(id)s { GMShellShow(nil); }
// 点 Dock / 启动台 / 访达里的图标：窗口关掉了也要重新出现
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag { GMShellShow(nil); return YES; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return NO; }
- (void)showSettings:(id)s { GMShellShow(@"providers"); }
- (void)toggleSidebarCmd:(id)s { GMShellToggleSidebar(); }
- (BOOL)validateMenuItem:(NSMenuItem *)mi {
    if (mi.action == @selector(toggleAutoCopy:)) mi.state = gAutoCopy ? NSControlStateValueOn : NSControlStateValueOff;
    if (mi.action == @selector(toggleAutoStart:)) mi.state = GMAutostartEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    return YES;
}
- (void)openSupport:(id)s { [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[@"~/Library/Application Support/AppleIntel" stringByExpandingTildeInPath]]]; }
- (void)runDoctor:(id)s { GMShellRunDoctor(); }
- (void)runDoctorSync:(id)s {
    fprintf(stderr,"DOCTOR start\n");
    NSTask *t=[NSTask new]; t.launchPath=@"/bin/bash";
    NSString *dr=[@"~/Library/Application Support/AppleIntel/doctor.sh" stringByExpandingTildeInPath];
    t.arguments=@[dr];
    NSPipe *pp=[NSPipe pipe]; t.standardOutput=pp; t.standardError=pp;
    __block NSMutableData *acc=[NSMutableData data];
    pp.fileHandleForReading.readabilityHandler=^(NSFileHandle *h){ NSData *d=[h availableData]; if(d.length){ [acc appendData:d]; fprintf(stderr,"DOCTOR %.*s",(int)d.length,(const char*)d.bytes);} };
    [t launch]; [t waitUntilExit];
    pp.fileHandleForReading.readabilityHandler=nil;
    NSString *out=[[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding] ?: @"";
    NSString *logp=[@"~/Library/Application Support/AppleIntel/doctor-last.log" stringByExpandingTildeInPath];
    [out writeToFile:logp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"通过 ([0-9]+) 项，失败 ([0-9]+) 项" options:0 error:NULL];
    NSTextCheckingResult *m=[re firstMatchInString:out options:0 range:NSMakeRange(0,out.length)];
    if (m) {
        NSInteger okk=[[out substringWithRange:[m rangeAtIndex:1]] integerValue];
        NSInteger bad=[[out substringWithRange:[m rangeAtIndex:2]] integerValue];
        if (bad==0) setStatus([NSString stringWithFormat:GMTr(@"自检 %ld/%ld 项通过"),(long)okk,(long)(okk+bad)]);
        else setStatus([NSString stringWithFormat:GMTr(@"自检发现 %ld 项异常，见 doctor-last.log"),(long)bad]);
    } else setStatus(GMTr(@"自检完成（输出见 doctor-last.log）"));
}
- (void)undoRewrite:(id)s {
    if (!gUndo.count) { fprintf(stderr,"UNDO empty\n"); setStatus(GMTr(@"没有可撤销的改写")); return; }
    NSString *prev=[gUndo lastObject]; [gUndo removeLastObject];
    markProgrammatic(); [gTV setString:prev]; gLastText=prev; [gTV setSelectedRange:NSMakeRange(0,0)];
    fprintf(stderr,"UNDO restored %lu chars (left=%lu)\n",(unsigned long)prev.length,(unsigned long)gUndo.count);
    NSPasteboard *pb=[NSPasteboard generalPasteboard]; [pb clearContents]; [pb setString:prev forType:NSPasteboardTypeString];
    setStatus([NSString stringWithFormat:GMTr(@"已撤销上一次改写（剩 %lu 步）"),(unsigned long)gUndo.count]);
}
- (void)toggleAutoCopy:(NSMenuItem *)mi { AIHSetAutoCopy(!gAutoCopy); }
@end

static AIHCtl *gCtl;
static NSStatusItem *gStatusItem;
static NSMenu *gViewMenu;

static NSMenuItem *mkItem(NSMenu *m, NSString *title, SEL sel, NSString *key, NSEventModifierFlags mods, NSString *sym){
  NSMenuItem *it=[m addItemWithTitle:title action:sel keyEquivalent:key?:@""];
  it.target=gCtl;
  if (key.length) it.keyEquivalentModifierMask=mods;
  if (sym) it.image=[NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil];
  return it;
}

static void createMenuBar(void){
  gStatusItem=[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  NSButton *b=gStatusItem.button;
  NSImage *img=[NSImage imageWithSystemSymbolName:@"apple.intelligence" accessibilityDescription:GMTr(@"Apple 智能（Intel）")]
             ?: [NSImage imageWithSystemSymbolName:@"wand.and.stars" accessibilityDescription:GMTr(@"Apple 智能（Intel）")];
  if (img) { img.template=YES; b.image=img; } else b.title=@"AI";
  b.toolTip=GMTr(@"Apple 智能（Intel）");
  NSMenu *m=[NSMenu new];
  NSEventModifierFlags cmd=NSEventModifierFlagCommand;
  mkItem(m, GMTr(@"改写前台 App 的选中文字"), @selector(grabWT:), @"9", cmd, @"text.cursor");
  mkItem(m, GMTr(@"用剪贴板文字打开写作工具"), @selector(clipWT:), @"w", NSEventModifierFlagControl|NSEventModifierFlagOption|cmd, @"doc.on.clipboard");
  mkItem(m, GMTr(@"撤销上一次改写"), @selector(undoRewrite:), nil, 0, @"arrow.uturn.backward");
  [m addItem:[NSMenuItem separatorItem]];
  mkItem(m, GMTr(@"打开 Apple 智能（Intel）"), @selector(showMain:), nil, 0, nil);
  mkItem(m, GMTr(@"设置…"), @selector(showSettings:), @",", cmd, nil);
  [m addItem:[NSMenuItem separatorItem]];
  [m addItemWithTitle:GMTr(@"退出") action:@selector(terminate:) keyEquivalent:@"q"];
  gStatusItem.menu=m;
  fprintf(stderr,"MENUBAR created items=%ld\n",(long)m.numberOfItems);
}



static void dumpAttrs(NSString *tag) {
    NSTextStorage *ts = [gTV textStorage];
    if (!ts) return;
    printf("ATTRS %s len=%lu str=<<%s>>\n", tag.UTF8String, (unsigned long)ts.length,
           [[ts.string substringToIndex:MIN((NSUInteger)160, ts.length)] UTF8String]);
    __block int shown = 0;
    [ts enumerateAttributesInRange:NSMakeRange(0, ts.length) options:0 usingBlock:^(NSDictionary *attrs, NSRange r, BOOL *stop) {
        NSMutableArray *keys = [NSMutableArray array];
        for (NSString *k in attrs) {
            if ([k containsString:@"Underline"] || [k containsString:@"Checking"] ||
                [k containsString:@"Suggestion"] || [k containsString:@"WritingTools"]) {
                [keys addObject:[NSString stringWithFormat:@"%@=%@", k, attrs[k]]];
            }
        }
        if (keys.count) {
            printf("  run %lu,%lu: %s\n", (unsigned long)r.location, (unsigned long)r.length,
                   [[keys componentsJoinedByString:@" | "] UTF8String]);
            if (++shown > 12) *stop = YES;
        }
    }];
    printf("ATTRS %s runs=%d\n", tag.UTF8String, shown);
    fflush(stdout);
}


static void dumpAX(NSString *tag, id obj, int depth) {
    if (!obj || depth > 12) return;
    NSMutableString *ind = [NSMutableString string];
    for (int i = 0; i < depth; i++) [ind appendString:@"  "];
    NSString *role = nil, *label = nil, *value = nil;
    @try { role = [obj accessibilityRole]; } @catch (NSException *e) {}
    @try { label = [obj accessibilityLabel]; } @catch (NSException *e) {}
    @try { id v = [obj accessibilityValue]; value = [v isKindOfClass:[NSString class]] ? v : nil; } @catch (NSException *e) {}
    if (role || label || value) {
        printf("AX %s%s%s%s%s%s\n", ind.UTF8String,
               role ? role.UTF8String : "?", label ? " | " : "",
               label ? label.UTF8String : "", value ? " = " : "",
               value ? value.UTF8String : "");
    }
    NSArray *kids = nil;
    @try { kids = [obj accessibilityChildren]; } @catch (NSException *e) {}
    for (id k in kids) dumpAX(tag, k, depth + 1);
}

static void captureAll(NSString *tag) {
    int i = 0;
    for (NSWindow *w in [NSApp windows]) {
        if (!w.isVisible) continue;
        NSView *cv = w.contentView; if (!cv) continue;
        NSRect r = cv.bounds;
        if (r.size.width < 20 || r.size.height < 20) continue;
        NSBitmapImageRep *rep = [cv bitmapImageRepForCachingDisplayInRect:r];
        if (!rep) continue;
        [cv cacheDisplayInRect:r toBitmapImageRep:rep];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString *p = [NSString stringWithFormat:@"/tmp/host_%@_%d.png", tag, i++];
        [png writeToFile:p atomically:YES];
        printf("CAPTURE %s %dx%d %lu\n", p.UTF8String, (int)r.size.width, (int)r.size.height, (unsigned long)png.length);
        fflush(stdout);
    }
}

// 原仓库只有声明没有实现（导致链接失败）。校对结果最终也是写进 gTV 的
// textStorage，已由 setupAutoCopy 的监听统一处理，这里保留为空钩子。
static void setupReviewWatch(void) {}
int main(){
  setvbuf(stdout,NULL,_IONBF,0); setvbuf(stderr,NULL,_IONBF,0);
  @autoreleasepool{
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    gCtl=[AIHCtl new];
    [NSApp setDelegate:(id<NSApplicationDelegate>)gCtl];
    if (GMSetupInstallIfNeeded()) exit(0);   // 从 DMG 打开：复制到「应用程序」并从那里重开
    GMSetupTakeOver();                        // 其他位置/旧版本的实例让位
    gSvc=[AISvc new]; [NSApp setServicesProvider:gSvc];
    GMSetupEnsure();
    GMSetupRecordInstallPath();    // 首次运行：安装 dylib、改写 XPC 注入路径、重签
    GMBridgeStart();   // 内置中继：本进程直接提供 /tmp/qwen.sock
    if(getenv("GG_SVCTEST")){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            NSPasteboard *pb=[NSPasteboard pasteboardWithUniqueName];
            [pb clearContents]; [pb setString:@"my team need to fix teh bug quickly and we should ship it asap. The release is scheduled for next week and customers keep asking about it." forType:NSPasteboardTypeString];
            NSString *e=nil;
            if(strcmp(getenv("GG_SVCTEST"),"summarize")==0) [gSvc handleServiceSummarizeInPlace:pb userData:nil error:&e];
            else if(strcmp(getenv("GG_SVCTEST"),"proofread")==0) { NSString *r=syncAsk(SvcProofreadSystem(),[pb stringForType:NSPasteboardTypeString],25.0); [pb clearContents]; [pb setString:r?:@"" forType:NSPasteboardTypeString]; }
            else [gSvc handleServiceRewriteInPlace:pb userData:nil error:&e];
            fprintf(stderr,"SVCTEST err=%s result=%.120s\n", e?e.UTF8String:"(nil)", ([pb stringForType:NSPasteboardTypeString]?:@"").UTF8String);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ exit(0); });
        });
    }
    {
        NSMenu *mb=[NSMenu new]; [NSApp setMainMenu:mb];
        NSEventModifierFlags cmd=NSEventModifierFlagCommand;
        // App 菜单
        NSMenuItem *appItem=[mb addItemWithTitle:@"" action:nil keyEquivalent:@""];
        NSMenu *am=[NSMenu new]; [appItem setSubmenu:am];
        [am addItemWithTitle:GMTr(@"关于 Apple 智能（Intel）") action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
        [am addItem:[NSMenuItem separatorItem]];
        mkItem(am, GMTr(@"设置…"), @selector(showSettings:), @",", cmd, nil);
        [am addItem:[NSMenuItem separatorItem]];
        NSMenuItem *svcItem=[am addItemWithTitle:GMTr(@"服务") action:nil keyEquivalent:@""];
        NSMenu *svcMenu=[NSMenu new]; svcItem.submenu=svcMenu; [NSApp setServicesMenu:svcMenu];
        [am addItem:[NSMenuItem separatorItem]];
        [am addItemWithTitle:GMTr(@"隐藏 Apple 智能（Intel）") action:@selector(hide:) keyEquivalent:@"h"];
        NSMenuItem *ho=[am addItemWithTitle:GMTr(@"隐藏其他") action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
        ho.keyEquivalentModifierMask=cmd|NSEventModifierFlagOption;
        [am addItemWithTitle:GMTr(@"全部显示") action:@selector(unhideAllApplications:) keyEquivalent:@""];
        [am addItem:[NSMenuItem separatorItem]];
        [am addItemWithTitle:GMTr(@"退出 Apple 智能（Intel）") action:@selector(terminate:) keyEquivalent:@"q"];
        // 编辑菜单（系统标准，文本框里的 ⌘C/⌘V/⌘Z 依赖它）
        NSMenuItem *edItem=[mb addItemWithTitle:GMTr(@"编辑") action:nil keyEquivalent:@""];
        NSMenu *em=[[NSMenu alloc] initWithTitle:GMTr(@"编辑")]; edItem.submenu=em;
        [em addItemWithTitle:GMTr(@"撤销") action:@selector(undo:) keyEquivalent:@"z"];
        NSMenuItem *redo=[em addItemWithTitle:GMTr(@"重做") action:@selector(redo:) keyEquivalent:@"z"];
        redo.keyEquivalentModifierMask=cmd|NSEventModifierFlagShift;
        [em addItem:[NSMenuItem separatorItem]];
        [em addItemWithTitle:GMTr(@"剪切") action:@selector(cut:) keyEquivalent:@"x"];
        [em addItemWithTitle:GMTr(@"拷贝") action:@selector(copy:) keyEquivalent:@"c"];
        [em addItemWithTitle:GMTr(@"粘贴") action:@selector(paste:) keyEquivalent:@"v"];
        [em addItemWithTitle:GMTr(@"全选") action:@selector(selectAll:) keyEquivalent:@"a"];
        // 写作菜单：工具栏里的每个动作都在这里
        NSMenuItem *opItem=[mb addItemWithTitle:GMTr(@"写作") action:nil keyEquivalent:@""];
        NSMenu *om=[[NSMenu alloc] initWithTitle:GMTr(@"写作")]; [opItem setSubmenu:om];
        mkItem(om, GMTr(@"显示写作工具"), @selector(showWT:), @"t", cmd|NSEventModifierFlagShift, @"wand.and.stars");
        mkItem(om, GMTr(@"改写前台 App 的选中文字"), @selector(grabWT:), @"9", cmd, nil);
        mkItem(om, GMTr(@"用剪贴板文字打开写作工具"), @selector(clipWT:), @"w", NSEventModifierFlagControl|NSEventModifierFlagOption|cmd, nil);
        mkItem(om, GMTr(@"撤销上一次改写"), @selector(undoRewrite:), @"z", cmd|NSEventModifierFlagOption, nil);
        [om addItem:[NSMenuItem separatorItem]];
        mkItem(om, GMTr(@"重新载入面板"), @selector(reloadWT:), @"r", cmd, nil);
        mkItem(om, GMTr(@"结果自动复制到剪贴板"), @selector(toggleAutoCopy:), nil, 0, nil);
        // 显示菜单（⌘1…⌘5 切换侧边栏项，在窗口建好后填充）
        NSMenuItem *viewItem=[mb addItemWithTitle:GMTr(@"显示") action:nil keyEquivalent:@""];
        gViewMenu=[[NSMenu alloc] initWithTitle:GMTr(@"显示")]; viewItem.submenu=gViewMenu;
        // 窗口菜单
        NSMenuItem *winItem=[mb addItemWithTitle:GMTr(@"窗口") action:nil keyEquivalent:@""];
        NSMenu *wm=[[NSMenu alloc] initWithTitle:GMTr(@"窗口")]; winItem.submenu=wm;
        [wm addItemWithTitle:GMTr(@"最小化") action:@selector(performMiniaturize:) keyEquivalent:@"m"];
        [wm addItemWithTitle:GMTr(@"缩放") action:@selector(performZoom:) keyEquivalent:@""];
        [wm addItemWithTitle:GMTr(@"关闭") action:@selector(performClose:) keyEquivalent:@"w"];
        [NSApp setWindowsMenu:wm];
    }
    installHotkey();
    createMenuBar();

    gTV=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,700,500)];
    setupAutoCopy();
    setupReviewWatch();
    [gTV setString:GMTr(@"Apple 智能的写作工具已经在你的 Intel Mac 上跑起来了。\n\n选中这段文字，点工具栏右上角的「写作工具」，Apple 原生面板就会浮出：校对、改写、友好、专业、简洁、摘要、要点、列表、表格、创作。\n\n在其他 App 里也一样：选中文字，按 ⌘9。\n\nThe quick brown fox jumps over the lazy dog. This sentence should be rewritten professionally.")];
    gLastText=[gTV string];
    [gTV setEditable:YES];[gTV setRichText:NO];
    [gTV setFont:[NSFont systemFontOfSize:15]];
    gWin=GMShellCreate(gTV, gCtl);
    {
        NSMenuItem *ts=[gViewMenu addItemWithTitle:GMTr(@"显示/隐藏侧边栏") action:@selector(toggleSidebarCmd:) keyEquivalent:@"s"];
        ts.keyEquivalentModifierMask=NSEventModifierFlagCommand|NSEventModifierFlagControl; ts.target=gCtl;
        [gViewMenu addItem:[NSMenuItem separatorItem]];
        for (NSMenuItem *mi in GMShellPaneMenuItems()) [gViewMenu addItem:mi];
    }

    patchAvailability();          // dlopen AFTER window creation, BEFORE first availability query
    [gWin makeKeyAndOrderFront:nil];
    [gWin makeFirstResponder:gTV];
    [NSApp activateIgnoringOtherApps:YES];

    if (getenv("GG_GRABNOTES")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
          NSArray *ns=[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.Notes"];
          NSRunningApplication *n=ns.firstObject;
          fprintf(stderr,"GRABNOTES notes=%s pid=%d\n", n?"yes":"no", n?(int)n.processIdentifier:0);
          if (n) { [n activateWithOptions:NSApplicationActivateIgnoringOtherApps]; }
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
              fprintf(stderr,"GRABNOTES grabbing from frontmost\n"); grabAndOpen();
          });
      });
    }
    if (getenv("GG_GRAB")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ fprintf(stderr,"GG_GRAB trigger\n"); grabAndOpen(); });
    }
    if (!axTrusted()) {
      fprintf(stderr,"AX not trusted at launch\n");
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ axPrompt(); });
    }
    if (getenv("GG_AUTOSHOW"))
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ showPanel(); });
    if (getenv("GG_DIAG")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ captureAll(@"t8"); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(12*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ captureAll(@"t12"); dumpAttrs(@"t12"); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(20*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ captureAll(@"t20"); dumpAttrs(@"t20"); for (NSWindow *w in [NSApp windows]) { if (!w.isVisible) continue; printf("AXWIN %s\n", w.title.UTF8String ?: "(untitled)"); dumpAX(@"t20", w.contentView, 0); } });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(28*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ captureAll(@"t28"); dumpAttrs(@"t28"); });
    }
    if (getenv("GG_UNDO_AT")) {
        double when=atof(getenv("GG_UNDO_AT")); if(when<1) when=25;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(when*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            fprintf(stderr,"UNDO_TEST before len=%lu undoDepth=%lu\n",(unsigned long)[[gTV string] length],(unsigned long)gUndo.count);
            [gCtl undoRewrite:nil];
            fprintf(stderr,"UNDO_TEST after len=%lu\n",(unsigned long)[[gTV string] length]);
        });
    }
    if (getenv("GG_MBDIAG")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            fprintf(stderr,"MBDIAG statusItem=%s menu=%ld button=%s\n", gStatusItem?"yes":"nil", (long)gStatusItem.menu.numberOfItems, gStatusItem.button.title.UTF8String);
            NSMutableString *ws=[NSMutableString string];
            for (NSWindow *w in [NSApp windows]) [ws appendFormat:@"[%@ vis=%d]",NSStringFromClass([w class]),w.isVisible];
            fprintf(stderr,"MBDIAG wins=%s\n",ws.UTF8String);
        });
    }
    if (getenv("GG_MBTEST")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            int idx=atoi(getenv("GG_MBTEST")); if(idx<0||idx>=(int)gStatusItem.menu.numberOfItems) idx=0;
            NSMenuItem *it=gStatusItem.menu.itemArray[idx];
            fprintf(stderr,"MBTEST idx=%d invoke %s\n", idx, it.title.UTF8String);
            if(it.target && it.action) [it.target performSelector:it.action withObject:it];
            else fprintf(stderr,"MBTEST no target/action\n");
        });
    }
    if(getenv("GG_CBN")){
      int n=atoi(getenv("GG_CBN")); if(n<1) n=1; if(n>20) n=20;
      int iv=26; if(getenv("GG_CBI")) { iv=atoi(getenv("GG_CBI")); if(iv<5) iv=5; }
      for(int i=0;i<n;i++){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((1.0+(double)iv*i)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
          fprintf(stderr,"CYCLE %d\n",i+1); openFromClipboard();
        });
      }
    } else if(getenv("GG_CB2")){
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ openFromClipboard(); });
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(30.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ fprintf(stderr,"CYCLE2\n"); openFromClipboard(); });
    } else if (getenv("GG_CB")) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ openFromClipboard(); });
    }
    if (getenv("GG_MGR")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            fprintf(stderr,"MGR open\n"); GMManagerShow();
        });
    }
    if (getenv("GG_SERVICE")) {
        NSString *t = @(getenv("GG_SERVICE"));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            [gTV setString:t]; [gTV setSelectedRange:NSMakeRange(0,t.length)];
            fprintf(stderr,"GG_SERVICE %lu chars\n",(unsigned long)t.length); showPanel();
        });
    }
    if (getenv("GG_AUTOCLICK")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.4*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            showPanel();
            printf("AUTOCLICK clicked 写作工具\n"); fflush(stdout);
        });
    }
    if (getenv("GG_MGR")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GMManagerShow();
            const char *sp = getenv("GG_MGRSHOT");
            if (sp) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    for (NSWindow *w in [NSApp windows]) {
                        if (![w isVisible]) continue;
                        if (w != gWin) continue;
                        NSView *v = w.contentView;
                        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
                        [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
                        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                        [png writeToFile:[NSString stringWithUTF8String:sp] atomically:YES];
                        fprintf(stderr,"MGRSHOT %s %ldx%ld\n", sp, (long)v.bounds.size.width, (long)v.bounds.size.height);
                        break;
                    }
                });
            }
        });
    }
    if (getenv("GG_SHOTS")) {
        // 调试：依次切换侧边栏每一项并截图（screencapture -l 窗口号）
        NSString *dir=@(getenv("GG_SHOTS"));
        NSArray *panes=@[@"shortcuts",@"providers",@"general",@"diagnostics",@"write"];
        for (NSUInteger i=0;i<panes.count;i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((1.5+1.6*i)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                GMShellShow(panes[i]);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                    NSString *out=[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.png",panes[i]]];
                    NSView *v=gWin.contentView.superview ?: gWin.contentView;
                    NSBitmapImageRep *rep=[v bitmapImageRepForCachingDisplayInRect:v.bounds];
                    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
                    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:out atomically:YES];
                    fprintf(stderr,"SHOT %s\n",out.UTF8String);
                    if (i==panes.count-1) exit(0);
                });
            });
        }
    }
    [NSApp run];
  }
  return 0;
}
