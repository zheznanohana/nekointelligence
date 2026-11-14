#import <Cocoa/Cocoa.h>
#include <sys/stat.h>
#import <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
static FILE *gF;
static void L(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt); NSString *s=[[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    fprintf(stderr,"[gmt2] %s\n", s.UTF8String);
    if (gF){ fprintf(gF,"[gmt2] %s\n", s.UTF8String); fflush(gF); }
}

static void writeInstr(NSString *s) {
    if (!s.length) return;
    NSString *path = getenv("VSSTUB_INSTR_FILE") ? @(getenv("VSSTUB_INSTR_FILE")) : @"/tmp/bridge/instruction.txt";
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
    [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static NSMutableString *gBuf;

static id findAny(id v, NSString *needle, int d) {
    if (!v || d > 16) return nil;
    NSString *lab = nil;
    @try { lab = [v accessibilityLabel]; } @catch (NSException *e) {}
    if (!lab) @try { lab = [v accessibilityTitle]; } @catch (NSException *e) {}
    if (lab && [lab isKindOfClass:[NSString class]] && [lab localizedCaseInsensitiveContainsString:needle]) return v;
    id kids = nil;
    @try { kids = [v accessibilityChildren]; } @catch (NSException *e) {}
    if ([kids isKindOfClass:[NSArray class]]) {
        for (id k in kids) { id r = findAny(k, needle, d+1); if (r) return r; }
    }
    if ([v isKindOfClass:[NSView class]]) {
        for (id k in [(NSView *)v subviews]) { id r = findAny(k, needle, d+1); if (r) return r; }
    }
    return nil;
}

static void dumpLabels(NSView *v, int d) {
    if (!v || d > 7) return;
    NSString *lab = nil, *role = nil;
    @try { lab = [v accessibilityLabel]; } @catch (NSException *e) {}
    @try { role = [v accessibilityRole]; } @catch (NSException *e) {}
    if (lab.length) L(@"AXLABEL[%d] role=%@ label=%@ cls=%@", d, role, lab, NSStringFromClass([v class]));
    id kids = nil;
    @try { kids = [v accessibilityChildren]; } @catch (NSException *e) {}
    if ([kids isKindOfClass:[NSArray class]]) { for (id k in kids) dumpLabels(k, d+1); }
    if ([v isKindOfClass:[NSView class]]) for (id k in [(NSView *)v subviews]) dumpLabels(k, d+1);
}
static void dumpAll(void) {
    for (NSWindow *w in [NSApp windows]) {
        if (!w.isVisible) continue;
        L(@"AXDUMP window %@ %@ children=%lu", NSStringFromClass([w class]), NSStringFromRect(w.frame), (unsigned long)[[w.contentView accessibilityChildren] count]);
        dumpLabels(w.contentView, 0);
    }
}


static void viewPress(NSString *label);
static void dumpAll(void);
// ---- row emulation: click a preset row -> convert to instruction -> press Rewrite ----
static NSDictionary *gRowMap;
static void rowInit(void) {
    if (gRowMap) return;
    gRowMap = @{
        @"friendly":      @"Rewrite the text in a friendly, warm tone.",
        @"professional":  @"Rewrite the text in a professional, business tone.",
        @"concise":       @"Rewrite the text to be more concise.",
        @"summary":       @"Summarize the text in one short paragraph.",
        @"key points":    @"Extract the key points from the text as a short bullet list.",
        @"list":          @"Reformat the text as a bulleted list.",
        @"table":         @"Convert the information in the text into a table.",
        @"compose":       @"Write new text following the user's instruction; keep it short and natural."
    };
}
static id hitNode(id v, NSPoint p, int d, NSString **outLabel) {
    if (!v || d > 18) return nil;
    NSString *role=nil,*lab=nil;
    @try { role=[v accessibilityRole]; } @catch(NSException *e){}
    @try { lab=[v accessibilityLabel]; } @catch(NSException *e){}
    NSRect fr = NSZeroRect; BOOL haveFr=NO;
    @try { fr=[v accessibilityFrame]; haveFr=YES; } @catch(NSException *e){}
    if (haveFr && [role isEqualToString:@"AXButton"] && lab.length && NSPointInRect(p, fr)) {
        if (outLabel) *outLabel = lab;
        return v;
    }
    id kids=nil; @try { kids=[v accessibilityChildren]; } @catch(NSException *e){}
    if ([kids isKindOfClass:[NSArray class]]) for (id k in kids) { id r=hitNode(k,p,d+1,outLabel); if (r) return r; }
    if ([v isKindOfClass:[NSView class]]) for (id k in [(NSView*)v subviews]) { id r=hitNode(k,p,d+1,outLabel); if (r) return r; }
    return nil;
}
static BOOL rowHandle(NSString *label) {
    if (getenv("GMT2_NOROW")) return NO;
    rowInit();
    NSString *key = [label lowercaseString];
    NSString *instr = gRowMap[key];
    if (!instr) return NO;
    NSString *pending = [NSString stringWithContentsOfFile:@"/tmp/bridge/instruction.txt" encoding:NSUTF8StringEncoding error:NULL];
    if (pending.length) instr = [NSString stringWithFormat:@"%@ Then: %@", instr, pending];
    writeInstr(instr);
    L(@"ROW %@ -> instruction (%lu chars)", label, (unsigned long)instr.length);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.35*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ viewPress(@"Rewrite"); });
    return YES;
}

static void viewPress(NSString *label) {
    for (NSWindow *w in [NSApp windows]) {
        if (!w.isVisible || w.frame.size.width < 200) continue;
        id v = findAny(w.contentView, label, 0);
        if (!v) continue;
        BOOL ok = NO;
        @try { ok = [v accessibilityPerformPress]; } @catch (NSException *e) { L(@"press threw %@", e.reason); }
        L(@"viewPress %@ on %@ -> %d", label, NSStringFromClass([v class]), (int)ok);
        return;
    }
    L(@"viewPress %@ not found", label);
}

static void axPress(NSString *label) {
    AXUIElementRef app = AXUIElementCreateApplication(getpid());
    CFTypeRef wins = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &wins) != kAXErrorSuccess || !wins) { L(@"no windows"); return; }
    for (CFIndex i = 0; i < CFArrayGetCount(wins); i++) {
        AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(wins, i);
        CFTypeRef kids = NULL;
        if (AXUIElementCopyAttributeValue(w, kAXChildrenAttribute, &kids) != kAXErrorSuccess || !kids) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:(__bridge id)w];
        while (stack.count) {
            AXUIElementRef e = (__bridge AXUIElementRef)[stack lastObject]; [stack removeLastObject];
            CFTypeRef t=NULL, ch=NULL;
            NSString *title=nil;
            if (AXUIElementCopyAttributeValue(e, kAXTitleAttribute, &t)==kAXErrorSuccess && t) { title=(__bridge NSString*)t; CFRelease(t); }
            if (!title) { if (AXUIElementCopyAttributeValue(e, kAXDescriptionAttribute, &t)==kAXErrorSuccess && t) { title=(__bridge NSString*)t; CFRelease(t);} }
            if (title && [title containsString:label]) {
                AXError er = AXUIElementPerformAction(e, kAXPressAction);
                L(@"AXpress %@ on '%@' -> %d", label, title, (int)er);
                if (ch) CFRelease(ch);
                if (kids) CFRelease(kids);
                if (wins) CFRelease(wins);
                CFRelease(app);
                return;
            }
            if (AXUIElementCopyAttributeValue(e, kAXChildrenAttribute, &ch)==kAXErrorSuccess && ch) {
                for (CFIndex j=0;j<CFArrayGetCount(ch);j++) [stack addObject:(__bridge id)CFArrayGetValueAtIndex(ch,j)];
                CFRelease(ch);
            }
        }
        if (kids) CFRelease(kids);
    }
    CFRelease(wins); CFRelease(app);
    L(@"AXpress %@ not found", label);
}

static void postClickLabel(NSString *label) {
    for (NSWindow *w in [NSApp windows]) {
        if (!w.isVisible) continue;
        id node = findAny(w.contentView, label, 0);
        if (!node) continue;
        NSRect fr = NSZeroRect;
        @try { fr = [node accessibilityFrame]; } @catch (NSException *e) { continue; }
        if (NSIsEmptyRect(fr)) continue;
        NSPoint screen = NSMakePoint(NSMidX(fr), NSMidY(fr));
        NSPoint wp = [w convertPointFromScreen:screen];
        L(@"TESTCLICK %@ frame=%@ winpt=%.0f,%.0f", label, NSStringFromRect(fr), wp.x, wp.y);
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:wp modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:w.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1.0];
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:wp modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime]+0.05 windowNumber:w.windowNumber context:nil eventNumber:2 clickCount:1 pressure:0.0];
        [NSApp postEvent:down atStart:NO];
        [NSApp postEvent:up atStart:NO];
        return;
    }
    L(@"TESTCLICK %@ not found", label);
}

static void ensureDir(void){ mkdir("/tmp/bridge",0777); }
__attribute__((constructor)) static void gmt2Init(void) {
    ensureDir();
    const char *lp=getenv("GMT2_LOG"); if(lp) gF=fopen(lp,"a");
    gBuf=[NSMutableString new];
    L(@"loaded pid=%d", getpid());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *e) {
            @try {
                NSWindow *w = e.window; if (!w) return e;
                NSPoint sp = [w convertPointToScreen:[e locationInWindow]];
                NSString *lab = nil;
                id node = hitNode(w.contentView, sp, 0, &lab);
                if (node && lab.length) { L(@"CLICK row=%@ at %.0f,%.0f", lab, sp.x, sp.y); rowHandle(lab); }
            } @catch (NSException *ex) { L(@"click monitor exception %@", ex.reason); }
            return e;
        }];
        L(@"click monitor installed");
        {
            const char *ds = getenv("GMT2_DUMPTIMES");
            if (ds) {
                NSArray *parts = [@(ds) componentsSeparatedByString:@","];
                for (NSString *ps in parts) {
                    double t = ps.doubleValue;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(t*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        L(@"=== AXDUMP t=%.1f ===", t); dumpAll();
                    });
                }
            }
        }
        {
            const char *cr = getenv("GMT2_CLICKROW");
            if (cr) {
                NSString *lab = @(cr);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.6*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ postClickLabel(lab); });
            }
            const char *cs = getenv("GMT2_CLICKS");
            if (cs) {
                for (NSString *spec in [@(cs) componentsSeparatedByString:@","]) {
                    NSArray *pp = [spec componentsSeparatedByString:@"@"];
                    if (pp.count != 2) continue;
                    NSString *lab = pp[0]; double t = [pp[1] doubleValue];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(t*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ postClickLabel(lab); });
                }
            }
        }
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
            NSResponder *fr = [[e window] firstResponder];
            NSString *fc = fr?NSStringFromClass([fr class]):@"";
            BOOL inPrompt = [fc containsString:@"IntelligenceUI"];
            if (!inPrompt) return e;
            unsigned short kc = e.keyCode;
            NSString *ch = e.characters;
            if (kc == 51) { if (gBuf.length) [gBuf deleteCharactersInRange:NSMakeRange(gBuf.length-1,1)]; return e; }
            if (kc == 36 || kc == 76) {
                NSString *instr = [gBuf copy];
                L(@"RETURN instr='%@'", instr);
                if (instr.length) writeInstr(instr);
                [gBuf setString:@""];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ viewPress(@"Rewrite"); });
                return nil; // swallow Return
            }
            if (ch.length && [ch characterAtIndex:0] >= 32) { [gBuf appendString:ch]; writeInstr(gBuf); }
            return e;
        }];
        L(@"key monitor installed");
    });
}
