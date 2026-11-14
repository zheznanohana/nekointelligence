// gmvs: injected into WritingToolsViewService (our own copy) to force availability.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AppKit/AppKit.h>

static FILE *gF;
static void L(NSString *fmt, ...) {
    if (!gF) return;
    va_list ap; va_start(ap, fmt);
    fprintf(gF, "%s\n", [[[NSString alloc] initWithFormat:fmt arguments:ap] UTF8String]); fflush(gF);
    va_end(ap);
}
static BOOL Y(id s, SEL c) { return YES; }
static BOOL N(id s, SEL c) { return NO; }
static long long Zero(id s, SEL c) { return 0; }
static BOOL Y2(id s, SEL c, id a) { return YES; }
static BOOL Y3(id s, SEL c, id a, id b) { return YES; }
static long long Zero2(id s, SEL c, id a) { return 0; }
static long long Zero3(id s, SEL c, id a, id b) { return 0; }
static long long Zero4(id s, SEL c, id a, id b, id d) { return 0; }
static BOOL StatusYes(id s, SEL c, long long *st) { if (st) *st = 0; return YES; }
static BOOL StatusYes2(id s, SEL c, id a, long long *st) { if (st) *st = 0; return YES; }
static BOOL No12(id s, SEL c, id a, id b) { return NO; }


// ---- self screenshot of the ViewService's own windows ----
static void saveWin(NSWindow *w, NSString *path) {
    NSView *v = [w contentView];
    if (!v) return;
    NSRect r = [v bounds];
    if (r.size.width < 2 || r.size.height < 2) return;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:r];
    if (!rep) return;
    [v cacheDisplayInRect:r toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:path atomically:YES];
    L(@"[gmvs] captured %@ %@ %.0fx%.0f bytes=%lu", path, NSStringFromClass([w class]),
      r.size.width, r.size.height, (unsigned long)png.length);
}
static void captureAll(int tag) {
    int i = 0;
    for (NSWindow *w in [NSApp windows]) {
        L(@"[gmvs] win[%d] %@ vis=%d key=%d frame=%@", i, NSStringFromClass([w class]),
          (int)[w isVisible], (int)[w isKeyWindow], NSStringFromRect([w frame]));
        if ([w isVisible]) {
            saveWin(w, [NSString stringWithFormat:@"/tmp/vs_cap_%d_%d.png", tag, i]);
        }
        i++;
    }
}

static int gPass = 0;
static void hookCls(Class C, const char *sel, IMP imp, const char *tag) {
    if (!C) return;
    Method m = class_getClassMethod(C, sel_registerName(sel));
    if (!m) return;
    method_setImplementation(m, imp);
    if (gPass <= 1) L(@"[gmvs] +[%s %s] -> %s", class_getName(C), sel, tag);
}
static void hookIns(Class C, const char *sel, IMP imp, const char *tag) {
    if (!C) return;
    Method m = class_getInstanceMethod(C, sel_registerName(sel));
    if (!m) return;
    method_setImplementation(m, imp);
    if (gPass <= 1) L(@"[gmvs] -[%s %s] -> %s", class_getName(C), sel, tag);
}

static void doHook(void) {
    gPass++;
    Class W = objc_getClass("GMAvailabilityWrapper");
    Class Opt = objc_getClass("GMSOptIn");
    Class CSFA = objc_getClass("CSFAvailability");
    L(@"[gmvs] pass=%d wrapper=%p optin=%p csfa=%p", gPass, W, Opt, CSFA);
    if (W) {
        hookCls(W, "isDeviceEligible", (IMP)Y, "YES");
        hookCls(W, "isOkayToHaveAsset", (IMP)Y, "YES");
        hookCls(W, "wasEverAvailable", (IMP)Y, "YES");
        hookCls(W, "currentWithUseCaseIdentifiers:", (IMP)Zero2, "0(available)");
        hookCls(W, "currentWithUseCaseIdentifiers:language:", (IMP)Zero3, "0(available)");
        hookCls(W, "enabledWithUseCaseIdentifiers:language:", (IMP)Y3, "YES");
        hookCls(W, "assetIsNotReadyWithUseCaseIdentifiers:language:", (IMP)No12, "NO");
        hookCls(W, "useCasePartnerAllowedInUserLocaleRegionWithUseCaseIdentifiers:language:", (IMP)Y3, "YES");
        hookCls(W, "shouldBeShownInSettingsReturningAvailabilityStatus:", (IMP)StatusYes, "YES/0");
        hookCls(W, "shouldBeShownInSetupAssistantReturningAvailabilityStatus:", (IMP)StatusYes, "YES/0");
        hookCls(W, "desiredUseCaseIdentifiersSettings", (IMP)Zero, "keep");
    }
    if (Opt) {
        hookIns(Opt, "isOptedIn", (IMP)Y, "YES");
    }
    if (CSFA) {
        hookCls(CSFA, "currentAvailability", (IMP)Zero, "skip");
    }
}

__attribute__((constructor)) static void init(void) {
    const char *p = getenv("GMVS_LOG");
    gF = fopen(p ? p : "/tmp/gmvs.log", "a");
    char nm[256] = {0}; extern int proc_name(int,char*,unsigned); proc_name(getpid(), nm, sizeof(nm));
    L(@"[gmvs] loaded pid=%d proc=%s", getpid(), nm);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ doHook(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ doHook(); });
    for (int t = 1; t <= 4; t++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t*1.2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ captureAll(t); });
    }
}
