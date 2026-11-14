#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/message.h>

static FILE *gF = NULL;
#define L(...) do { if (gF) { fprintf(gF, __VA_ARGS__); fprintf(gF, "\n"); fflush(gF); } } while (0)

static void walk(id el, int depth, int *count) {
    if (!el || depth > 14 || *count > 300) return;
    NSString *role = nil, *title = nil, *label = nil, *desc = nil;
    BOOL enabled = YES;
    @try { role  = [el accessibilityRole]; } @catch (NSException *e) {}
    @try { title = [el accessibilityTitle]; } @catch (NSException *e) {}
    @try { label = [el accessibilityLabel]; } @catch (NSException *e) {}
    @try { desc  = [el accessibilityHelp]; } @catch (NSException *e) {}
    @try { enabled = [el isAccessibilityEnabled]; } @catch (NSException *e) {}
    NSRect f = NSZeroRect;
    @try { f = [el accessibilityFrame]; } @catch (NSException *e) {}
    if (role || title || label) {
        L("[ax] d=%d role=%s title=%s label=%s enabled=%d frame=%.0f,%.0f,%.0f,%.0f help=%s",
          depth, role?[role UTF8String]:"-", title?[title UTF8String]:"-", label?[label UTF8String]:"-",
          (int)enabled, f.origin.x, f.origin.y, f.size.width, f.size.height, desc?[desc UTF8String]:"-");
        (*count)++;
    }
    id kids = nil;
    @try { kids = [el accessibilityChildren]; } @catch (NSException *e) {}
    if ([kids isKindOfClass:[NSArray class]]) {
        for (id k in kids) walk(k, depth+1, count);
    }
}

static id findEl(id el, NSString *needle, int depth) {
    if (!el || depth > 14) return nil;
    NSString *t = nil, *l = nil;
    @try { t = [el accessibilityTitle]; } @catch (NSException *e) {}
    @try { l = [el accessibilityLabel]; } @catch (NSException *e) {}
    if ((t && [t localizedCaseInsensitiveContainsString:needle]) ||
        (l && [l localizedCaseInsensitiveContainsString:needle])) return el;
    id kids = nil;
    @try { kids = [el accessibilityChildren]; } @catch (NSException *e) {}
    if ([kids isKindOfClass:[NSArray class]]) {
        for (id k in kids) { id r = findEl(k, needle, depth+1); if (r) return r; }
    }
    return nil;
}


static id findRole(id el, NSString *role, int depth) {
    if (!el || depth > 14) return nil;
    NSString *r = nil;
    @try { r = [el accessibilityRole]; } @catch (NSException *e) {}
    if (r && [r isEqualToString:role]) return el;
    id kids = nil;
    @try { kids = [el accessibilityChildren]; } @catch (NSException *e) {}
    if ([kids isKindOfClass:[NSArray class]]) {
        for (id k in kids) { id f = findRole(k, role, depth+1); if (f) return f; }
    }
    return nil;
}
static AXUIElementRef axFind(pid_t pid, CFStringRef role, int depth, AXUIElementRef node) {
    if (!node || depth > 12) return NULL;
    CFTypeRef rv = NULL;
    AXUIElementCopyAttributeValue(node, kAXRoleAttribute, &rv);
    if (rv) {
        BOOL match = CFStringCompare((CFStringRef)rv, role, 0) == kCFCompareEqualTo;
        CFRelease(rv);
        if (match) return (AXUIElementRef)CFRetain(node);
    }
    CFTypeRef kids = NULL;
    if (AXUIElementCopyAttributeValue(node, kAXChildrenAttribute, &kids) == kAXErrorSuccess && kids) {
        if (CFGetTypeID(kids) == CFArrayGetTypeID()) {
            CFArrayRef arr = (CFArrayRef)kids;
            for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
                AXUIElementRef k = (AXUIElementRef)CFArrayGetValueAtIndex(arr, i);
                AXUIElementRef f = axFind(pid, role, depth+1, k);
                if (f) { CFRelease(kids); return f; }
            }
        }
        CFRelease(kids);
    }
    return NULL;
}

static NSTextField *findTF(NSView *v) {
    if ([v isKindOfClass:[NSTextField class]]) return (NSTextField *)v;
    for (NSView *k in v.subviews) { NSTextField *r = findTF(k); if (r) return r; }
    return nil;
}

static AXUIElementRef axRec(CFTypeRef node, CFStringRef role, int d) {
    if (!node || d > 12) return NULL;
    CFTypeRef rv = NULL;
    if (AXUIElementCopyAttributeValue((AXUIElementRef)node, kAXRoleAttribute, &rv) == kAXErrorSuccess && rv) {
        BOOL m = CFStringCompare((CFStringRef)rv, role, 0) == kCFCompareEqualTo;
        CFRelease(rv);
        if (m) return (AXUIElementRef)CFRetain((AXUIElementRef)node);
    }
    CFTypeRef kids = NULL;
    if (AXUIElementCopyAttributeValue((AXUIElementRef)node, kAXChildrenAttribute, &kids) == kAXErrorSuccess && kids) {
        if (CFGetTypeID(kids) == CFArrayGetTypeID()) {
            CFArrayRef a = (CFArrayRef)kids;
            for (CFIndex i = 0; i < CFArrayGetCount(a); i++) {
                AXUIElementRef f = axRec(CFArrayGetValueAtIndex(a, i), role, d+1);
                if (f) { CFRelease(kids); return f; }
            }
        }
        CFRelease(kids);
    }
    return NULL;
}
static void axSubmit(NSString *text) {
    AXUIElementRef app = AXUIElementCreateApplication(getpid());
    AXUIElementRef field = NULL;
    CFTypeRef wins = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &wins) == kAXErrorSuccess && wins) {
        CFArrayRef a = (CFArrayRef)wins;
        for (CFIndex i = 0; i < CFArrayGetCount(a) && !field; i++) field = axRec(CFArrayGetValueAtIndex(a, i), kAXTextFieldRole, 0);
        CFRelease(wins);
    }
    L("[gmax] axSubmit field=%p", field);
    if (!field) { CFRelease(app); return; }
    AXError e1 = AXUIElementSetAttributeValue(field, kAXFocusedAttribute, kCFBooleanTrue);
    AXError e2 = AXUIElementSetAttributeValue(field, kAXValueAttribute, (CFTypeRef)text);
    AXError e3 = AXUIElementPerformAction(field, kAXConfirmAction);
    L("[gmax] ax focus=%d setValue=%d confirm=%d", e1, e2, e3);
    if (e3 != kAXErrorSuccess) L("[gmax] ax confirm unsupported (%d)", e3);
    CFRelease(field); CFRelease(app);
}
static void dumpViews(NSView *v, int d, int *n) {
    if (!v || d > 8 || *n > 200) return;
    L("[vd] %*s%s frame=%.0f,%.0f,%.0f,%.0f", d*2, "", class_getName([v class]),
      v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height);
    (*n)++;
    for (NSView *k in v.subviews) dumpViews(k, d+1, n);
}
static NSTextField *findField(NSView *v, int d) {
    if (!v || d > 6) return nil;
    if ([v isKindOfClass:[NSTextField class]]) return (NSTextField *)v;
    for (NSView *k in v.subviews) { NSTextField *r = findField(k, d+1); if (r) return r; }
    return nil;
}
static void submitInstruction(NSString *text) {
    L("[gmax] === windows in VS: %lu", (unsigned long)[[NSApp windows] count]);
    NSWindow *panel = nil;
    for (NSWindow *w in [NSApp windows]) {
        L("[gmax] win class=%s title=%@ vis=%d key=%d frame=%.0f,%.0f,%.0f,%.0f",
          class_getName([w class]), w.title, (int)w.isVisible, (int)w.isKeyWindow,
          w.frame.origin.x, w.frame.origin.y, w.frame.size.width, w.frame.size.height);
        NSString *cn = [NSString stringWithUTF8String:class_getName([w class])];
        if ([cn containsString:@"ServiceViewController"] || [cn containsString:@"Popover"]) { if (!panel) panel = w; }
        if (w.isVisible && !panel) panel = w;
    }
    if (!panel) { L("[gmax] no panel window"); return; }
    L("[gmax] chosen panel=%s", class_getName([panel class]));
    int cnt = 0;
    if (getenv("GMAX_VDUMP")) dumpViews(panel.contentView, 0, &cnt);
    axSubmit(text);
    if (getenv("GMAX_VDUMP")) {
        __block NSView *pe = nil;
        void (^findPE)(NSView *) = ^(NSView *v) {
            if (!v || pe) return;
            if ([[NSString stringWithUTF8String:class_getName([v class])] containsString:@"PromptEntryView"]) { pe = v; return; }
            for (NSView *k in v.subviews) findPE(k);
        };
        findPE(panel.contentView);
        if (pe) { L("[gmax] PromptEntryView found: %s", class_getName([pe class])); int c2 = 0; dumpViews(pe, 0, &c2); }
        else L("[gmax] PromptEntryView not found");
    }
    NSTextField *tf = findField(panel.contentView, 0);
    if (!tf) { L("[gmax] no text field in panel"); return; }
    L("[gmax] field class=%s", class_getName([tf class]));
    [tf setStringValue:text];
    BOOL fr = [panel makeFirstResponder:tf];
    L("[gmax] firstResponder=%d value=%@", (int)fr, [tf stringValue]);
    NSInteger wn = panel.windowNumber;
    for (int rep = 0; rep < 2; rep++) {
        NSEvent *down = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
            timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:wn context:nil
            characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
        [NSApp sendEvent:down];
        NSEvent *up = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:0
            timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:wn context:nil
            characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
        [NSApp sendEvent:up];
        L("[gmax] return sent rep=%d", rep);
    }
    [NSApp sendAction:@selector(insertNewline:) to:tf from:nil];
    L("[gmax] insertNewline sent");
}
__attribute__((constructor)) static void initMe(void) {
    const char *p = getenv("GMAX_LOG");
    gF = fopen(p ? p : "/tmp/gmax.log", "w");
    L("[gmax] loaded pid=%d", getpid());
    for (int t = 1; t <= 7; t++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t*1200*NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            NSWindow *w = [NSApp keyWindow] ?: [[NSApp windows] firstObject];
            if (!w) { L("[gmax] t=%d no window", t); return; }
            id root = [w contentView];
            if (t == 1 || t == 3 || t == 6) {
                int c = 0;
                L("[gmax] ---- t=%d tree of %s ----", t, class_getName([root class]));
                walk(root, 0, &c);
                L("[gmax] ---- %d elements ----", c);
            }
            if (t == 2) {
                const char *hb = getenv("GMAX_HOSTBTN");
                if (hb) {
                    NSString *N = [NSString stringWithUTF8String:hb];
                    id eb = findEl(root, N, 0);
                    if (eb) {
                        L("[gmax] host button %s found (%s) -> performClick", hb, class_getName([eb class]));
                        @try { [(NSButton *)eb performClick:nil]; L("[gmax] host button clicked"); } @catch (NSException *e) { L("[gmax] click threw %@", e.reason); }
                    } else L("[gmax] host button %s not found", hb);
                }
            }
            if (t == 7 && getenv("GMAX_INSTR")) {
                submitInstruction([NSString stringWithUTF8String:getenv("GMAX_INSTR")]);
            }
            if (t == 5) {
                const char *txt = getenv("GMAX_TEXT");
                if (txt) {
                    NSString *S = [NSString stringWithUTF8String:txt];
                    NSTextField *tf = (NSTextField *)findRole(root, @"AXTextField", 0);
                    if (tf) {
                        @try { [tf setStringValue:S]; L("[gmax] setStringValue ok on %s", class_getName([tf class])); } @catch (NSException *e) { L("[gmax] setStringValue threw %@", e.reason); }
                        @try { BOOL ok = [tf accessibilityPerformPress]; L("[gmax] AXPress field=%d", (int)ok); } @catch (NSException *e) {}
                    } else { L("[gmax] no NSTextField in tree"); }
                    AXUIElementRef app = AXUIElementCreateApplication(getpid());
                    AXUIElementRef tfe = axFind(getpid(), kAXTextFieldRole, 0, app);
                    if (!tfe) { L("[gmax] no AXTextField"); }
                    else {
                        AXError er = AXUIElementSetAttributeValue(tfe, kAXValueAttribute, (CFTypeRef)S);
                        L("[gmax] set AXValue rc=%d text=%s", er, txt);
                        AXError er2 = AXUIElementPerformAction(tfe, kAXConfirmAction);
                        L("[gmax] AXConfirm rc=%d", er2);
                        if (er2 != kAXErrorSuccess) {
                            AXUIElementSetAttributeValue(tfe, kAXFocusedAttribute, kCFBooleanTrue);
                            AXUIElementPerformAction(tfe, kAXPressAction);
                            L("[gmax] pressed field instead");
                        }
                        CFRelease(tfe);
                    }
                    CFRelease(app);
                }
            }
            if (t == 6 && getenv("GMAX_TEXT")) {
                NSWindow *pw = w;
                L("[gmax] panel window = %@ number=%ld", pw.title, (long)[pw windowNumber]);
                for (NSWindow *ww in [NSApp windows]) L("[gmax]   win %@ num=%ld vis=%d key=%d", ww.title, (long)[ww windowNumber], (int)[ww isVisible], (int)[ww isKeyWindow]);
                NSView *cv = [pw contentView];
                NSEvent *ev = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:[pw windowNumber] context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
                L("[gmax] sending Return to panel window %ld", (long)[pw windowNumber]);
                [NSApp sendEvent:ev];
            }
            if (t >= 4) {
                const char *lab = getenv("GMAX_LABEL");
                NSArray *all = lab ? [[NSString stringWithUTF8String:lab] componentsSeparatedByString:@","] : @[@"Proofread", @"Rewrite", @"Summary"];
                NSUInteger idx = (NSUInteger)(t - 4);
                NSArray *list = idx < all.count ? @[all[idx]] : @[];
                for (NSString *n in list) {
                    id el = findEl(root, n, 0);
                    if (!el) { L("[gmax] not found: %s", [n UTF8String]); continue; }
                    BOOL en = YES; @try { en = [el isAccessibilityEnabled]; } @catch (NSException *e) {}
                    L("[gmax] found %s enabled=%d -> pressing", [n UTF8String], (int)en);
                    @try {
                        if ([el respondsToSelector:@selector(accessibilityPerformPress)]) [el accessibilityPerformPress];
                        else [el accessibilityPerformAction:NSAccessibilityPressAction];
                        L("[gmax] pressed %s ok", [n UTF8String]);
                    } @catch (NSException *ex) { L("[gmax] press %s threw %s", [n UTF8String], [[ex description] UTF8String]); }
                    break;
                }
            }
        });
    }
}
