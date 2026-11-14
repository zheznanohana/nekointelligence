// vsstub.m - client-side stub for TextComposer XPC inside WritingToolsViewService.
// The real daemon (textcomposerd) is App-Sandboxed and cannot reach the network,
// so instead of bridging the server we intercept the *client* proxy in our own
// (unsandboxed) ViewService copy and answer with Qwen directly.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <sys/un.h>
#include <dlfcn.h>

static FILE *gLog;
static void lg(NSString *fmt, ...) {
    if (!gLog) return;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(gLog, "%s\n", s.UTF8String); fflush(gLog);
}


static NSString *gInstrCache = nil;
static NSTimeInterval gInstrUntil = 0;
static NSString *readUserInstruction(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (gInstrCache && now < gInstrUntil) return gInstrCache;
    const char *path = getenv("VSSTUB_INSTR_FILE") ?: "/tmp/bridge/instruction.txt";
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:@(path) error:NULL];
    if (!a) return nil;
    NSDate *m = a[NSFileModificationDate];
    if (!m || -[m timeIntervalSinceNow] > 600) return nil;
    NSString *s = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:NULL];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length) { [[NSFileManager defaultManager] removeItemAtPath:@(path) error:NULL]; return s; }
    return nil;
}

static NSString *qwenRaw(NSString *system, NSString *user) {
    NSString *uinstr = nil;
    if (uinstr.length) {
        system = [NSString stringWithFormat:@"You are a text transformation engine inside the macOS Writing Tools panel. The user instruction is: %@. Apply that instruction to the provided text. Return ONLY the resulting text with no quotes, no preamble, no explanations.", uinstr];
        lg(@"[vsstub] using user instruction (%lu chars)", (unsigned long)uinstr.length);
    }
    const char *sockPath = getenv("VSSTUB_SOCK");
    if (!sockPath) sockPath = "/tmp/qwen.sock";
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { lg(@"[vsstub] socket errno=%d", errno); return nil; }
    struct timeval tv = {90, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_un sa; memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX; sa.sun_len = sizeof sa;
    snprintf(sa.sun_path, sizeof sa.sun_path, "%s", sockPath);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) {
        lg(@"[vsstub] connect %s errno=%d", sockPath, errno); close(fd); return nil;
    }
    NSUInteger ulen = user.length;
    NSUInteger mt = ulen/2 + 200; if (mt < 600) mt = 600; if (mt > 6000) mt = 6000;
    NSDictionary *req = @{ @"system": system ?: @"", @"user": user ?: @"", @"max_tokens": @(mt) };
    NSData *rd = [NSJSONSerialization dataWithJSONObject:req options:0 error:NULL];
    NSMutableData *line = [rd mutableCopy]; [line appendBytes:"\n" length:1];
    write(fd, line.bytes, line.length);
    NSMutableData *acc = [NSMutableData data]; char buf[4096];
    while (1) {
        ssize_t n = read(fd, buf, sizeof buf);
        if (n <= 0) break;
        [acc appendBytes:buf length:(NSUInteger)n];
        if (buf[n-1] == '\n') break;
    }
    close(fd);
    if (!acc.length) { lg(@"[vsstub] empty reply"); return nil; }
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:acc options:0 error:NULL];
    if (![j[@"ok"] boolValue]) { lg(@"[vsstub] proxy err %@", j[@"err"]); return nil; }
    id t = j[@"text"];
    return [t isKindOfClass:[NSString class]] ? t : nil;
}

// 改写类请求的完整性守卫：模型偶尔只改第一句就收尾（内容丢失）。
// 输出明显短于输入时追加「覆盖全文」要求重试一次；仍明显偏短则返回 nil（调用方回落原文）。
static NSString *qwenAsk(NSString *system, NSString *user) {
    NSString *uinstr = readUserInstruction();
    if (uinstr.length) {
        system = [NSString stringWithFormat:@"You are a text transformation engine inside the macOS Writing Tools panel. The user instruction is: %@. Apply that instruction to the provided text. Cover the entire input. Return ONLY the resulting text with no quotes, no preamble, no explanations.", uinstr];
        lg(@"[vsstub] using user instruction (%lu chars)", (unsigned long)uinstr.length);
    }
    NSString *r = qwenRaw(system, user);
    BOOL rewriteLike = [system containsString:@"improve clarity"] || [system containsString:@"user instruction is"];
    if (rewriteLike && r.length && user.length >= 40 && r.length * 100 < user.length * 60) {
        lg(@"[vsstub] reply too short (%lu vs %lu) -> retry strict", (unsigned long)r.length, (unsigned long)user.length);
        NSString *s2 = [system stringByAppendingString:@" Important: cover the ENTIRE input. Rewrite every sentence; do not drop, merge or summarise any content. The output must be roughly the same length as the input."];
        NSString *r2 = qwenRaw(s2, user);
        if (r2.length > r.length) r = r2;
        if (r.length * 100 < user.length * 45) { lg(@"[vsstub] still too short -> identity fallback"); return nil; }
    }
    // 保留输入的首尾空白：Apple 把长文按 ~2025 字符分段后逐段替换，
    // 段首段尾的空格/换行若被模型吃掉，两段拼接处就会变成 "milestone.Sentence 09:"。
    if (r.length && user.length) {
        NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        unichar u0 = [user characterAtIndex:0], r0 = [r characterAtIndex:0];
        if ([ws characterIsMember:u0] && ![ws characterIsMember:r0]) {
            r = [u0 == '\n' ? @"\n" : @" " stringByAppendingString:r];
        }
        unichar ue = [user characterAtIndex:user.length - 1], re = [r characterAtIndex:r.length - 1];
        if ([ws characterIsMember:ue] && ![ws characterIsMember:re]) r = [r stringByAppendingString:@" "];
    }
    return r;
}

static NSString *textOf(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSString class]]) return obj;
    if ([obj isKindOfClass:[NSAttributedString class]]) return [(NSAttributedString *)obj string];
    if ([obj isKindOfClass:[NSData class]]) return [[NSString alloc] initWithData:obj encoding:NSUTF8StringEncoding];
    for (NSString *k in @[@"string", @"text", @"attributedString", @"input", @"content", @"source"]) {
        @try { id v = [obj valueForKey:k]; if ([v isKindOfClass:[NSString class]]) return v;
               if ([v isKindOfClass:[NSAttributedString class]]) return [(NSAttributedString *)v string]; } @catch (NSException *e) {}
    }
    return [obj description];
}

static NSString *instructionFor(id type) {
    NSString *t = [type isKindOfClass:[NSString class]] ? [type lowercaseString] : [[type description] lowercaseString];
    if ([t containsString:@"proofread"] || [t containsString:@"review"])
        return @"You are a proofreader. Fix spelling, grammar and punctuation without changing wording or length. Return ONLY the corrected text, no quotes, no explanations, keep the original language.";
    if ([t containsString:@"friendly"]) return @"Rewrite the text in a friendlier, warmer tone. Return ONLY the rewritten text, keep the original language.";
    if ([t containsString:@"professional"]) return @"Rewrite the text in a professional, polished tone. Return ONLY the rewritten text, keep the original language.";
    if ([t containsString:@"concise"]) return @"Rewrite the text more concisely without losing meaning. Return ONLY the rewritten text, keep the original language.";
    if ([t containsString:@"summar"])
        return @"Summarize the text. Return ONLY the summary, keep the original language, no preamble.";
    if ([t containsString:@"keypoint"] || [t containsString:@"takeaway"])
        return @"Extract the key points as a short bulleted list. Return ONLY the list, keep the original language.";
    if ([t containsString:@"list"]) return @"Convert the text into a clean bulleted list. Return ONLY the list, keep the original language.";
    if ([t containsString:@"table"]) return @"Convert the text into a markdown table. Return ONLY the table, keep the original language.";
    if ([t containsString:@"magic"] || [t containsString:@"rewrite"] || [t containsString:@"default"] || [t containsString:@"adjust"])
        return @"Rewrite the text to improve clarity and naturalness. Preserve ALL information: rewrite every sentence, do not drop or merge content. Keep the original language. Preserve the original structure exactly: keep line breaks, numbering and any labels or prefixes that appear in the input. Return ONLY the rewritten text with no quotes and no explanation.";
    if ([t containsString:@"compose"] || [t containsString:@"draft"])
        return @"Produce the requested text. Return ONLY the final text, keep the original language, match the length implied by the request.";
    return @"Rewrite the text to improve clarity and naturalness. Preserve ALL information: rewrite every sentence, do not drop or merge content. Keep the original language. Preserve the original structure exactly: keep line breaks, numbering and any labels or prefixes that appear in the input. Return ONLY the rewritten text with no quotes and no explanation.";
}

// ---- stub object -----------------------------------------------------------
@interface VSStub : NSObject
@end
static VSStub *gStub;

static void callReply(id reply, id out, id err) {
    if (!reply) { lg(@"[vsstub] callReply: nil block"); return; }
    const char *sig = NULL;
    void *(*bs)(id) = (void *(*)(id))dlsym(RTLD_DEFAULT, "_Block_signature");
    if (bs) sig = (const char *)bs(reply);
    lg(@"[vsstub] callReply block=%p sig=%s out=%s err=%s", reply, sig ? sig : "?", out ? class_getName([out class]) : "nil", err ? class_getName([err class]) : "nil");
    ((void (^)(id, id))reply)(out, err);
    lg(@"[vsstub] callReply returned");
}

static NSString *fixBoundarySpacing(NSString *q, NSString *input, NSRange eff) {
    if (!q.length) return q;
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    // Apple 分段改写：第二段起点 range.location > 0，若模型吃掉了段首空格，
    // 拼接处会变成 "milestone.Sentence 09:"，这里补回来。
    if (eff.location > 0 && ![ws characterIsMember:[q characterAtIndex:0]])
        q = [@" " stringByAppendingString:q];
    // 模型偶尔把句子标签并到前一句后面（"milestone.Sentence 09:"），补空格
    {
        NSMutableString *ms = [NSMutableString stringWithCapacity:q.length + 8];
        NSUInteger n = q.length;
        for (NSUInteger i = 0; i < n; i++) {
            unichar c = [q characterAtIndex:i];
            [ms appendFormat:@"%C", c];
            if ((c == '.' || c == '!' || c == '?' || c == ':' || c == ';') && i + 1 < n) {
                unichar d = [q characterAtIndex:i + 1];
                if (d >= 'A' && d <= 'Z') [ms appendString:@" "];
            }
        }
        q = ms;
    }
    if (input.length && ![q isEqualToString:input]) {
        unichar ci = [input characterAtIndex:input.length - 1];
        unichar cl = [q characterAtIndex:q.length - 1];
        if ([ws characterIsMember:ci] && ![ws characterIsMember:cl]) q = [q stringByAppendingString:@" "];
    }
    return q;
}

static id makeOutputWithRange(id input, NSString *text, NSRange range, id options) {
    Class cls = objc_getClass("TCTextCompositionOutput");
    if (!cls) { lg(@"[vsstub] no TCTextCompositionOutput class"); return text; }
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:(text ?: @"")];
    NSArray *inLens = @[@(range.length ? range.length : (NSUInteger)0)];
    NSArray *outLens = @[@(text.length)];
    id out = nil;
    @try {
        out = ((id (*)(id, SEL, id, NSRange, id, id, id))objc_msgSend)([cls alloc],
            sel_registerName("initWithRewrittenAttributedString:range:inputLengths:outputLengths:options:"),
            as, range, inLens, outLens, options ?: @{});
    } @catch (NSException *e) { lg(@"[vsstub] output(range) init exception %@", e.reason); }
    if (!out) {
        @try {
            out = ((id (*)(id, SEL, id, id))objc_msgSend)([cls alloc], sel_registerName("initWithInput:rewrittenString:"), input, text);
        } @catch (NSException *e) { lg(@"[vsstub] output init(legacy) exception %@", e.reason); }
    }
    lg(@"[vsstub] makeOutput range=%lu,%lu out=%s desc=%@", (unsigned long)range.location, (unsigned long)range.length,
       out ? class_getName([out class]) : "nil", out);
    return out ?: text;
}

static id makeReviewOutput(NSRange range, NSString *corrected, id options) {
    Class outCls = objc_getClass("TCTextCompositionReviewOutput");
    Class resCls = objc_getClass("NSTextCheckingResult");
    id result = nil;
    @try {
        result = ((id (*)(id, SEL, NSRange, id))objc_msgSend)(resCls,
            sel_registerName("replacementCheckingResultWithRange:replacementString:"), range, corrected);
    } @catch (NSException *e) { lg(@"[vsstub] result factory exception %@", e.reason); }
    if (outCls) {
        @try {
            return ((id (*)(id, SEL, id, id))objc_msgSend)([outCls alloc],
                sel_registerName("initWithResults:options:"), result ? @[result] : @[], options);
        } @catch (NSException *e) { lg(@"[vsstub] review out init exception %@", e.reason); }
    }
    return nil;
}

static void captureWindows(NSString *tag) {
    int i = 0;
    for (NSWindow *w in [NSApp windows]) {
        if (!w.isVisible) continue;
        NSView *cv = w.contentView;
        if (!cv) continue;
        NSRect r = cv.bounds;
        if (r.size.width < 40 || r.size.height < 40) continue;
        NSBitmapImageRep *rep = [cv bitmapImageRepForCachingDisplayInRect:r];
        if (!rep) continue;
        [cv cacheDisplayInRect:r toBitmapImageRep:rep];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString *path = [NSString stringWithFormat:@"/tmp/vsstub_%@_%d.png", tag, i++];
        [png writeToFile:path atomically:YES];
        lg(@"[vsstub] capture %@ %dx%d %lu bytes", path, (int)r.size.width, (int)r.size.height, (unsigned long)png.length);
    }
}

static NSString *inputText(id input) {
    if (!input) return @"";
    if ([input isKindOfClass:[NSString class]]) return (NSString *)input;
    if ([input isKindOfClass:[NSAttributedString class]]) return [(NSAttributedString *)input string];
    for (NSString *k in @[@"string", @"text", @"content", @"inputString", @"attributedString"]) {
        @try {
            id v = [input valueForKey:k];
            if ([v isKindOfClass:[NSString class]]) return v;
            if ([v isKindOfClass:[NSAttributedString class]]) return [(NSAttributedString *)v string];
            if ([v respondsToSelector:NSSelectorFromString(@"string")]) {
                id s2 = [v valueForKey:@"string"];
                if ([s2 isKindOfClass:[NSString class]]) return s2;
            }
        } @catch (NSException *e) {}
    }
    return [input description] ?: @"";
}

static void stubRewriteString(id self, SEL _cmd, id str, NSRange range, id type, id options, id reply) {
    NSString *text = textOf(str);
    lg(@"[vsstub] rewrite type=%@ len=%lu text=<<%@>>", type, (unsigned long)text.length, text.length > 80 ? [text substringToIndex:80] : text);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *q = qwenAsk(instructionFor(type), text);
        if (!q) { lg(@"[vsstub] qwen nil -> identity fallback"); q = text; }
        if (!q.length) { callReply(reply, nil, [NSError errorWithDomain:@"local.vsstub" code:1 userInfo:@{NSLocalizedDescriptionKey: @"qwen unavailable"}]); return; }
        lg(@"[vsstub] reply rewrite len=%lu", (unsigned long)q.length);
        NSString *plain = inputText(str);
        NSRange eff = range.length ? range : NSMakeRange(0, plain.length);
        q = fixBoundarySpacing(q, plain, eff);
        callReply(reply, makeOutputWithRange(plain, q, eff, options), nil);
        for (double d = 0.3; d <= 6.0; d += 1.4) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                captureWindows([NSString stringWithFormat:@"rw_%.1f", d]);
            });
        }
    });
}

static void stubReviewString(id self, SEL _cmd, id str, NSRange range, id options, id reply) {
    NSString *text = textOf(str);
    lg(@"[vsstub] review len=%lu", (unsigned long)text.length);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *q = qwenAsk(instructionFor(@"proofread"), text);
        if (!q) { lg(@"[vsstub] qwen nil -> identity fallback"); q = text; }
        if (!q.length) { callReply(reply, nil, [NSError errorWithDomain:@"local.vsstub" code:2 userInfo:nil]); return; }
        NSRange r = range.length ? range : NSMakeRange(0, text.length);
        if (r.location + r.length > text.length) r = NSMakeRange(0, text.length);
        if (q.length && [q isEqualToString:text]) { lg(@"[vsstub] review unchanged -> empty results"); callReply(reply, makeReviewOutput(NSMakeRange(0,0), @"", options), nil); return; }
        if (![q isEqualToString:text]) {
            [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/bridge/review.txt" error:NULL];
            [q writeToFile:@"/tmp/bridge/review.txt" atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            lg(@"[vsstub] review handoff -> /tmp/bridge/review.txt (%lu chars)", (unsigned long)q.length);
        }
        id out = makeReviewOutput(r, q, options);
        lg(@"[vsstub] reply review out=%s", out ? class_getName([out class]) : "(nil)");
        callReply(reply, out, nil);
        for (double d = 0.3; d <= 6.0; d += 1.4) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                captureWindows([NSString stringWithFormat:@"rv_%.1f", d]);
            });
        }
    });
}

static void stubRewriteInput(id self, SEL _cmd, id input, id type, id reply) {
    stubRewriteString(self, _cmd, input, NSMakeRange(0, 0), type, nil, reply);
}
static void stubReviewInput(id self, SEL _cmd, id input, id reply) {
    stubReviewString(self, _cmd, input, NSMakeRange(0, 0), nil, reply);
}
static void stubDNR(id self, SEL _cmd, SEL sel) {
    lg(@"[vsstub] UNRECOGNIZED %@", NSStringFromSelector(sel));
}
static void stubNoop(id self, SEL _cmd) { lg(@"[vsstub] noop %s", sel_getName(_cmd)); }
static void stubNoop1(id self, SEL _cmd, id a) { lg(@"[vsstub] noop1 %s arg=%s", sel_getName(_cmd), a ? class_getName([a class]) : "nil"); }
static void stubNoop2(id self, SEL _cmd, id a, id b) { lg(@"[vsstub] noop2 %s", sel_getName(_cmd)); }


static NSMutableSet *gProtoSels;
static BOOL stubResponds(id self, SEL _cmd, SEL sel) {
    if (!gProtoSels) gProtoSels = [NSMutableSet new];
    NSString *n = NSStringFromSelector(sel);
    if ([gProtoSels containsObject:n]) return YES;
    if ([n hasPrefix:@"rewrite"] || [n hasPrefix:@"review"] || [n hasPrefix:@"prewarm"] || [n hasPrefix:@"cancel"] || [n hasPrefix:@"smart"]) return YES;
    BOOL r = class_respondsToSelector(object_getClass(self), sel);
    if (!r) lg(@"[vsstub] respondsToSelector:%@ -> NO", n);
    return r;
}
static NSMethodSignature *stubMethodSig(id self, SEL _cmd, SEL sel) {
    lg(@"[vsstub] methodSignatureForSelector:%@", NSStringFromSelector(sel));
    return [NSMethodSignature signatureWithObjCTypes:"v@:@@@@@@@@"];
}
static void stubForward(id self, SEL _cmd, NSInvocation *inv) {
    lg(@"[vsstub] forward %@ argc=%lu", NSStringFromSelector(inv.selector), (unsigned long)inv.methodSignature.numberOfArguments);
}

static void installStubClass(void) {
    Class c = objc_allocateClassPair([NSObject class], "VSStub", 0);
    struct { const char *sel; IMP imp; const char *types; } m[] = {
        {"rewriteWithString:range:rewritingType:options:with:", (IMP)stubRewriteString, "v@:@{_NSRange=QQ}@@@?"},
        {"reviewWithString:range:options:with:", (IMP)stubReviewString, "v@:@{_NSRange=QQ}@@?"},
        {"rewriteWithInput:rewritingType:with:", (IMP)stubRewriteInput, "v@:@@@?"},
        {"reviewWithInput:with:", (IMP)stubReviewInput, "v@:@@?"},
        {"cancelWithToken:", (IMP)stubNoop1, "v@:@"},
        {"doesNotRecognizeSelector:", (IMP)stubDNR, "v@::"},
        {"respondsToSelector:", (IMP)stubResponds, "B@::"},
        {"methodSignatureForSelector:", (IMP)stubMethodSig, "@@::"},
        {"forwardInvocation:", (IMP)stubForward, "v@:@"},
        {"prewarmWithInput:rewritingTypes:", (IMP)stubNoop2, "v@:@@@"},
        {"prewarmWithRewritingTypes:", (IMP)stubNoop1, "v@:@"},
        {"prewarmWithFeature:options:", (IMP)stubNoop2, "v@:@@@"},
        {"prewarmSmartRepliesWithDocumentType:", (IMP)stubNoop1, "v@:@"},
        {"prewarmSmartRepliesWithDocumentType:options:", (IMP)stubNoop2, "v@:@@@"},
        {NULL, NULL, NULL}
    };
    for (int i = 0; m[i].sel; i++)
        class_addMethod(c, sel_registerName(m[i].sel), m[i].imp, m[i].types);
    // no-op everything else the protocol declares
    Protocol *p = objc_getProtocol("TCTextCompositionXPCProtocol");
    if (p) {
        unsigned int n = 0; struct objc_method_description *d = protocol_copyMethodDescriptionList(p, NO, YES, &n);
        for (unsigned int i = 0; i < n; i++) {
            if (!d[i].name || class_getInstanceMethod(c, d[i].name)) continue;
            const char *t = d[i].types ?: "v@:";
            int args = (int)strlen(t) - 3; // crude
            IMP imp = (args <= 0) ? (IMP)stubNoop : ((args == 1) ? (IMP)stubNoop1 : (IMP)stubNoop2);
            class_addMethod(c, d[i].name, imp, t);
        }
        if (d) free(d);
    }
    if (p) {
        gProtoSels = [NSMutableSet new];
        unsigned int n2 = 0; struct objc_method_description *d2 = protocol_copyMethodDescriptionList(p, NO, YES, &n2);
        for (unsigned int i = 0; i < n2; i++) if (d2[i].name) [gProtoSels addObject:NSStringFromSelector(d2[i].name)];
        if (d2) free(d2);
        unsigned int n3 = 0; struct objc_method_description *d3 = protocol_copyMethodDescriptionList(p, YES, YES, &n3);
        for (unsigned int i = 0; i < n3; i++) if (d3[i].name) [gProtoSels addObject:NSStringFromSelector(d3[i].name)];
        if (d3) free(d3);
        lg(@"[vsstub] protocol selectors cached: %lu", (unsigned long)gProtoSels.count);
    }
    Protocol *pp = objc_getProtocol("TCTextCompositionXPCProtocol");
    if (pp) { /* disabled: conformance switched client to sync/prewarm path */ lg(@"[vsstub] protocol found (conformance skipped)"); }
    else { lg(@"[vsstub] protocol not found"); }
    objc_registerClassPair(c);
    gStub = [[c alloc] init];
    lg(@"[vsstub] stub class ready (%s)", class_getName(c));
}

// ---- NSXPCConnection swizzle ----------------------------------------------
static char kSvcNameKey;
static id (*orig_remoteObjectProxyWithErrorHandler)(id, SEL, id);
static id (*orig_remoteObjectProxy)(id, SEL);
static id (*orig_syncProxyWithHandler)(id, SEL, id);
static id (*orig_initMach)(id, SEL, NSString *, NSUInteger);

static id new_remoteObjectProxyWithErrorHandler(id self, SEL _cmd, id handler) {
    NSString *svc = objc_getAssociatedObject(self, &kSvcNameKey);
    if (svc && [svc containsString:@"textcompos"]) { lg(@"[vsstub] proxy requested for %@", svc); return gStub; }
    return orig_remoteObjectProxyWithErrorHandler(self, _cmd, handler);
}
static id new_remoteObjectProxy(id self, SEL _cmd) {
    NSString *svc = objc_getAssociatedObject(self, &kSvcNameKey);
    if (svc && [svc containsString:@"textcompos"]) { lg(@"[vsstub] raw proxy requested for %@", svc); return gStub; }
    return orig_remoteObjectProxy(self, _cmd);
}
static id new_syncProxyWithHandler(id self, SEL _cmd, id handler) {
    NSString *svc = objc_getAssociatedObject(self, &kSvcNameKey);
    if (svc && [svc containsString:@"textcompos"]) { lg(@"[vsstub] SYNC proxy requested for %@", svc); return gStub; }
    return orig_syncProxyWithHandler(self, _cmd, handler);
}
static id new_initMach(id self, SEL _cmd, NSString *name, NSUInteger opts) {
    id r = orig_initMach(self, _cmd, name, opts);
    if (r) { objc_setAssociatedObject(r, &kSvcNameKey, name, OBJC_ASSOCIATION_RETAIN); lg(@"[vsstub] connection %@", name); }
    return r;
}


// ---- TextCompositionAssistant facade hooks (bypass availability gating) ----

static BOOL (*orig_fastCan)(id, SEL, id, NSRange);
static BOOL (*orig_canRange)(id, SEL, id, NSRange);
static BOOL new_fastCan(id self, SEL _cmd, id as, NSRange r) {
    BOOL o = orig_fastCan ? orig_fastCan(self, _cmd, as, r) : NO;
    lg(@"[vsstub] fastCanLikely orig=%d -> YES", (int)o);
    return YES;
}
static BOOL new_canRange(id self, SEL _cmd, id as, NSRange r) {
    BOOL o = orig_canRange ? orig_canRange(self, _cmd, as, r) : NO;
    lg(@"[vsstub] canHandle(range) orig=%d -> YES", (int)o);
    return YES;
}
static BOOL vs_retYes(id self, SEL _cmd) { (void)self; (void)_cmd; return YES; }
static id (*orig_reqRewrite)(id, SEL, id, NSRange, id, id, id);
static id (*orig_reqReview)(id, SEL, id, NSRange, id, id);
static BOOL gFacadeInstalled = NO;

static void new_reqRewrite(id self, SEL _cmd, id as, NSRange range, id rtype, id options, id completion) {
    NSString *text = nil;
    if ([as isKindOfClass:[NSAttributedString class]]) text = [(NSAttributedString *)as string];
    else if ([as isKindOfClass:[NSString class]]) text = as;
    if (!text.length) { orig_reqRewrite(self, _cmd, as, range, rtype, options, completion); return; }
    NSRange r = range.length ? range : NSMakeRange(0, text.length);
    NSString *q = qwenAsk(instructionFor(rtype), text);
    if (!q) { lg(@"[vsstub] qwen nil -> identity fallback"); q = text; }
    lg(@"[vsstub] facade rewrite type=%@ len=%lu -> %lu", rtype, (unsigned long)text.length, (unsigned long)(q.length));
    if (!q.length) { orig_reqRewrite(self, _cmd, as, range, rtype, options, completion); return; }
    q = fixBoundarySpacing(q, text, r);
    id out = makeOutputWithRange(text, q, r, options);
    if (completion) ((void (^)(id, id))completion)(out, nil);
}

static void new_reqReview(id self, SEL _cmd, id as, NSRange range, id options, id completion) {
    NSString *text = nil;
    if ([as isKindOfClass:[NSAttributedString class]]) text = [(NSAttributedString *)as string];
    else if ([as isKindOfClass:[NSString class]]) text = as;
    if (!text.length) { orig_reqReview(self, _cmd, as, range, options, completion); return; }
    NSRange r = range.length ? range : NSMakeRange(0, text.length);
    NSString *q = qwenAsk(instructionFor(@"proofread"), text);
    if (!q) { lg(@"[vsstub] qwen nil -> identity fallback"); q = text; }
    lg(@"[vsstub] facade review len=%lu -> %lu", (unsigned long)text.length, (unsigned long)(q.length));
    if (!q.length) { orig_reqReview(self, _cmd, as, range, options, completion); return; }
    id out = makeReviewOutput(r, q, options);
    if (completion) ((void (^)(id, id))completion)(out, nil);
}

static void tryInstallFacade(void) {
    if (gFacadeInstalled) return;
    Class c = objc_getClass("TCTextCompositionAssistant");
    if (!c) return;
    Method m1 = class_getInstanceMethod(c, sel_registerName("requestRewritingOfAttributedString:range:rewritingType:options:completionHandler:"));
    Method m2 = class_getInstanceMethod(c, sel_registerName("requestReviewOfAttributedString:range:options:completionHandler:"));
    if (!m1 || !m2) return;
    static BOOL (*dummy0)(void) = NULL; (void)dummy0;
    unsigned mc = 0; Method *ml = class_copyMethodList(c, &mc);
    for (unsigned i = 0; i < mc; i++) {
        const char *nm = sel_getName(method_getName(ml[i]));
        if (strstr(nm, "canHandle") || strstr(nm, "fastCanLikely")) {
            if (strcmp(nm, "fastCanLikelyHandleAttributedString:range:") == 0) {
                orig_fastCan = (void *)method_setImplementation(ml[i], (IMP)new_fastCan);
            } else if (strcmp(nm, "canHandleAttributedString:range:") == 0) {
                orig_canRange = (void *)method_setImplementation(ml[i], (IMP)new_canRange);
            } else { (void)nm; }
        }
    }
    free(ml);
    orig_reqRewrite = (void *)method_setImplementation(m1, (IMP)new_reqRewrite);
    orig_reqReview = (void *)method_setImplementation(m2, (IMP)new_reqReview);
    gFacadeInstalled = YES;
    lg(@"[vsstub] facade hooks installed (TCTextCompositionAssistant)");
}

__attribute__((constructor)) static void vsstub_init(void) {
    const char *p = getenv("VSSTUB_LOG");
    gLog = fopen(p ? p : "/tmp/bridge/vsstub.log", "a");
    if (!gLog) { fprintf(stderr, "vsstub: cannot open log\n"); return; }
    setvbuf(gLog, NULL, _IONBF, 0);
    lg(@"[vsstub] loaded pid=%d", getpid());
    installStubClass();
    Class nsc = objc_getClass("NSXPCConnection");
    Method m;
    if ((m = class_getInstanceMethod(nsc, sel_registerName("remoteObjectProxyWithErrorHandler:")))) {
        orig_remoteObjectProxyWithErrorHandler = (void *)method_setImplementation(m, (IMP)new_remoteObjectProxyWithErrorHandler);
    }
    if ((m = class_getInstanceMethod(nsc, sel_registerName("remoteObjectProxy")))) {
        orig_remoteObjectProxy = (void *)method_setImplementation(m, (IMP)new_remoteObjectProxy);
    }
    if ((m = class_getInstanceMethod(nsc, sel_registerName("synchronousRemoteObjectProxyWithErrorHandler:")))) {
        orig_syncProxyWithHandler = (void *)method_setImplementation(m, (IMP)new_syncProxyWithHandler);
    }
    if ((m = class_getInstanceMethod(nsc, sel_registerName("initWithMachServiceName:options:")))) {
        orig_initMach = (void *)method_setImplementation(m, (IMP)new_initMach);
    }
    lg(@"[vsstub] hooks installed");
    {
        /* preload disabled */
    }
    tryInstallFacade();
    for (int i = 1; i <= 40; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ tryInstallFacade(); });
    }
}
