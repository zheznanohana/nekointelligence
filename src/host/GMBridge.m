// GMBridge.m — 内置中继（无 Python 依赖）
//
// 作用：把「本地 unix socket + JSON 行协议」翻译成任意 OpenAI 兼容的 HTTPS 请求。
// 为什么需要它：Apple 的 ViewService 在我们的可写副本里运行，但它的 stub 只连
// 本机 socket；本进程无沙盒，可以做真正的 TLS 请求。
//
// 协议（一行 JSON 进，一行 JSON 出）:
//   请求  {"system":"...","user":"...","max_tokens":800}
//   响应  {"ok":true,"text":"..."} 或 {"ok":false,"error":"..."}
//
// 配置：~/Library/Application Support/AppleIntel/providers.json
//   {"active":"qwen","providers":[{"id","name","base_url","chat_path","api_key","model","ips":[]}]}

#import <Foundation/Foundation.h>
#import "GMLang.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <netdb.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <Security/Security.h>
#include <Security/SecureTransport.h>

#ifndef GM_SOCK_PATH
#define GM_SOCK_PATH "/tmp/qwen.sock"
#endif

static NSString *gSupDir(void){
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/AppleIntel"];
}
static NSString *gLogPath(void){ return [gSupDir() stringByAppendingPathComponent:@"qwen_proxy.log"]; }
static NSString *gCfgPath(void){ return [gSupDir() stringByAppendingPathComponent:@"providers.json"]; }

static void bridgeLog(NSString *fmt, ...){
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate dateWithTimeIntervalSince1970:[[NSDate date] timeIntervalSince1970]], s];
    FILE *f = fopen([gLogPath() fileSystemRepresentation], "a");
    if (f) { fputs([line UTF8String], f); fclose(f); }
}

#pragma mark - 配置

// 从 providers.json 读当前供应商；若不存在则用旧的 tp_cfg.json 迁移一份。
static NSDictionary *activeProvider(void){
    NSData *d = [NSData dataWithContentsOfFile:gCfgPath()];
    if (d) {
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        NSArray *list = root[@"providers"];
        NSString *act = root[@"active"];
        if ([list isKindOfClass:[NSArray class]]) {
            for (NSDictionary *p in list) {
                if ([p[@"id"] isEqual:act]) return p;
            }
            if (list.count) return list.firstObject;
        }
    }
    // 迁移：旧配置
    NSString *legacy = [gSupDir() stringByAppendingPathComponent:@"tp_cfg.json"];
    NSData *ld = [NSData dataWithContentsOfFile:legacy];
    if (!ld) return nil;
    NSDictionary *lc = [NSJSONSerialization JSONObjectWithData:ld options:0 error:NULL];
    if (![lc isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    p[@"id"] = @"qwen";
    p[@"name"] = @"千问 Token Plan";
    p[@"base_url"] = lc[@"base_url"] ?: @"https://token-plan.cn-beijing.maas.aliyuncs.com";
    p[@"chat_path"] = @"/compatible-mode/v1/chat/completions";
    p[@"api_key"] = lc[@"api_key"] ?: @"";
    p[@"model"] = lc[@"chat_model"] ?: @"qwen3.8-flash";
    p[@"ips"] = @[@"39.106.104.16", @"39.106.80.255"];
    p[@"no_think"] = @YES;
    return p;
}

#pragma mark - TLS

typedef struct { int fd; } tlsConn;

static OSStatus tlsRead(SSLConnectionRef conn, void *data, size_t *len){
    tlsConn *c = (tlsConn*)conn; size_t want = *len, got = 0;
    while (got < want) {
        ssize_t n = read(c->fd, (char*)data + got, want - got);
        if (n <= 0) { *len = got; return n < 0 ? errSSLClosedAbort : errSSLClosedGraceful; }
        got += n;
    }
    *len = got; return noErr;
}
static OSStatus tlsWrite(SSLConnectionRef conn, const void *data, size_t *len){
    tlsConn *c = (tlsConn*)conn; size_t want = *len, sent = 0;
    while (sent < want) {
        ssize_t n = write(c->fd, (const char*)data + sent, want - sent);
        if (n <= 0) { *len = sent; return errSSLClosedAbort; }
        sent += n;
    }
    *len = sent; return noErr;
}
static int tcpConnectHost(const char *host, int port){
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
    char ps[8]; snprintf(ps, sizeof ps, "%d", port);
    if (getaddrinfo(host, ps, &hints, &res) != 0) return -3;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { freeaddrinfo(res); return -1; }
    struct timeval tv = {30, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    int rc = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);
    if (rc != 0) { close(fd); return -2; }
    return fd;
}
static int tcpConnectIP(const char *ip, int port){
    int fd = socket(AF_INET, SOCK_STREAM, 0); if (fd < 0) return -1;
    struct timeval tv = {30, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    struct sockaddr_in sa; memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET; sa.sin_port = htons(port);
    inet_pton(AF_INET, ip, &sa.sin_addr);
    if (connect(fd, (struct sockaddr*)&sa, sizeof sa) != 0) { close(fd); return -2; }
    return fd;
}

static NSData *unchunk(NSData *body){
    NSData *marker = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange hr = [body rangeOfData:marker options:0 range:NSMakeRange(0, body.length)];
    if (hr.location == NSNotFound) return body;
    NSData *head = [body subdataWithRange:NSMakeRange(0, hr.location)];
    NSData *rest = [body subdataWithRange:NSMakeRange(NSMaxRange(hr), body.length - NSMaxRange(hr))];
    NSString *hs = [[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding];
    if (![hs.lowercaseString containsString:@"transfer-encoding: chunked"]) return rest;
    NSMutableData *out = [NSMutableData data]; NSUInteger p = 0;
    const unsigned char *b = rest.bytes;
    while (p < rest.length) {
        NSUInteger nl = p;
        while (nl < rest.length && b[nl] != '\n') nl++;
        if (nl >= rest.length) break;
        NSString *szs = [[NSString alloc] initWithBytes:b + p length:nl - p encoding:NSUTF8StringEncoding];
        szs = [[szs componentsSeparatedByString:@";"] firstObject];
        unsigned long long sz = 0;
        if (![[NSScanner scannerWithString:szs] scanHexLongLong:&sz] || sz == 0) break;
        NSUInteger start = nl + 1;
        if (start + sz > rest.length) break;
        [out appendBytes:b + start length:(NSUInteger)sz];
        p = start + (NSUInteger)sz;
        while (p + 1 < rest.length && b[p] == '\r' && b[p+1] == '\n') p += 2;
    }
    return out.length ? out : rest;
}

static NSData *httpsPost(NSString *host, NSArray *ips, NSString *path, NSString *key, NSData *body, NSInteger *statusOut){
    int fd = tcpConnectHost(host.UTF8String, 443);
    if (fd < 0 && ips.count) {
        for (NSString *ip in ips) { fd = tcpConnectIP(ip.UTF8String, 443); if (fd >= 0) break; }
    }
    if (fd < 0) { bridgeLog(@"[bridge] connect failed %@", host); return nil; }
    tlsConn conn = { fd };
    SSLContextRef ctx = SSLCreateContext(NULL, kSSLClientSide, kSSLStreamType);
    SSLSetIOFuncs(ctx, tlsRead, tlsWrite);
    SSLSetConnection(ctx, (SSLConnectionRef)&conn);
    SSLSetPeerDomainName(ctx, host.UTF8String, strlen(host.UTF8String));
    SSLSetSessionOption(ctx, kSSLSessionOptionBreakOnServerAuth, true);
    OSStatus st = errSSLWouldBlock;
    for (int i = 0; i < 12; i++) {
        st = SSLHandshake(ctx);
        if (st == errSSLWouldBlock || st == errSSLServerAuthCompleted) continue;
        break;
    }
    if (st != noErr && st != errSSLServerAuthCompleted) {
        bridgeLog(@"[bridge] TLS handshake %d host=%@", (int)st, host);
        close(fd); CFRelease(ctx); return nil;
    }
    NSMutableString *req = [NSMutableString stringWithFormat:
        @"POST %@ HTTP/1.1\r\nHost: %@\r\nAuthorization: Bearer %@\r\n"
         "Content-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        path, host, key, (unsigned long)body.length];
    NSMutableData *reqD = [[req dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [reqD appendData:body];
    size_t wrote = 0;
    OSStatus wr = SSLWrite(ctx, reqD.bytes, reqD.length, &wrote);
    if (wr != noErr && wr != errSSLWouldBlock) { bridgeLog(@"[bridge] SSLWrite %d", (int)wr); }
    NSMutableData *resp = [NSMutableData data]; char buf[16384];
    while (1) {
        size_t got = 0;
        OSStatus r = SSLRead(ctx, buf, sizeof buf, &got);
        if (got) [resp appendBytes:buf length:got];
        if (r == errSSLWouldBlock) continue;
        if (r != noErr && r != errSSLClosedGraceful) break;
        if (got == 0) break;
    }
    SSLClose(ctx); CFRelease(ctx); close(fd);
    if (statusOut) {
        NSData *m = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange hr = [resp rangeOfData:m options:0 range:NSMakeRange(0, resp.length)];
        if (hr.location != NSNotFound) {
            NSString *hs = [[NSString alloc] initWithData:[resp subdataWithRange:NSMakeRange(0, hr.location)] encoding:NSISOLatin1StringEncoding];
            NSArray *parts = [hs componentsSeparatedByString:@" "];
            if (parts.count > 1) *statusOut = [parts[1] integerValue];
        }
    }
    return unchunk(resp);
}

#pragma mark - 一问一答

static NSString *askProvider(NSDictionary *p, NSString *system, NSString *user, int maxTokens, NSString **errOut){
    if (!p) { if (errOut) *errOut = GMTr(@"没有可用的服务商配置"); return nil; }
    NSString *key = p[@"api_key"]; NSString *model = p[@"model"] ?: @"qwen3.8-flash";
    NSString *base = p[@"base_url"] ?: @"";
    NSString *path = p[@"chat_path"] ?: @"/v1/chat/completions";
    NSString *host = [[NSURL URLWithString:base] host] ?: base;
    if (!key.length || !host.length) { if (errOut) *errOut = GMTr(@"服务商配置不完整"); return nil; }

    NSMutableArray *msgs = [NSMutableArray array];
    if (system.length) [msgs addObject:@{@"role":@"system", @"content":system}];
    [msgs addObject:@{@"role":@"user", @"content":user ?: @""}];
    NSMutableDictionary *payload = [@{
        @"model": model,
        @"messages": msgs,
        @"max_tokens": @(maxTokens > 0 ? maxTokens : 800),
        @"temperature": @(0.4),
        @"stream": @NO
    } mutableCopy];
    if ([p[@"no_think"] boolValue]) {
        payload[@"enable_thinking"] = @NO;
        payload[@"chat_template_kwargs"] = @{@"enable_thinking": @NO};
    }
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    NSInteger status = 0;
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    NSData *resp = httpsPost(host, p[@"ips"], path, key, body, &status);
    NSTimeInterval dt = [NSDate timeIntervalSinceReferenceDate] - t0;
    if (!resp) { if (errOut) *errOut = [NSString stringWithFormat:GMTr(@"网络失败（%.1f 秒）"), dt]; return nil; }
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:resp options:0 error:NULL];
    if (![j isKindOfClass:[NSDictionary class]]) {
        NSString *raw = [[NSString alloc] initWithData:resp encoding:NSUTF8StringEncoding];
        NSString *snip = raw.length > 80 ? [raw substringToIndex:80] : (raw ?: @"");
        if (errOut) *errOut = [NSString stringWithFormat:GMTr(@"响应不是 JSON（HTTP %ld）：%@"), (long)status, snip];
        return nil;
    }
    NSArray *choices = j[@"choices"];
    NSString *text = nil;
    if ([choices isKindOfClass:[NSArray class]] && choices.count) {
        NSDictionary *m = choices[0][@"message"];
        if ([m isKindOfClass:[NSDictionary class]]) text = m[@"content"];
        if (![text isKindOfClass:[NSString class]] || !text.length) {
            NSString *rc = m[@"reasoning_content"];
            if ([rc isKindOfClass:[NSString class]] && rc.length) text = rc; // 兜底
        }
    }
    if (![text isKindOfClass:[NSString class]] || !text.length) {
        id e = j[@"error"];
        if (errOut) *errOut = [NSString stringWithFormat:GMTr(@"服务商返回错误（HTTP %ld）：%@"), (long)status,
                               [e isKindOfClass:[NSDictionary class]] ? (e[@"message"] ?: e) : (e ?: j)];
        return nil;
    }
    bridgeLog(@"[bridge] ok %@ model=%@ %lu->%lu chars %.2fs", p[@"name"] ?: p[@"id"], model,
              (unsigned long)user.length, (unsigned long)text.length, dt);
    return text;
}

#pragma mark - socket 服务

static void *connThread(void *arg){
    @autoreleasepool {
        int fd = (int)(intptr_t)arg;
        NSMutableData *buf = [NSMutableData data];
        char tmp[8192];
        struct timeval tv = {60, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        while (buf.length < 4 * 1024 * 1024) {
            ssize_t n = read(fd, tmp, sizeof tmp);
            if (n <= 0) break;
            [buf appendBytes:tmp length:(NSUInteger)n];
            if (((const char*)buf.bytes)[buf.length-1] == '\n') break;
        }
        NSString *lineStr = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
        lineStr = [lineStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *reply = nil;
        if (!lineStr.length) {
            reply = @"{\"ok\":false,\"error\":\"empty request\"}\n";
        } else {
            NSError *je = nil;
            NSDictionary *req = [NSJSONSerialization JSONObjectWithData:[lineStr dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&je];
            if (![req isKindOfClass:[NSDictionary class]]) {
                reply = [NSString stringWithFormat:@"{\"ok\":false,\"error\":\"bad json: %@\"}\n", je.localizedDescription ?: @"?"];
            } else if ([req[@"ping"] boolValue]) {
                reply = @"{\"ok\":true,\"text\":\"pong\"}\n";
            } else {
                NSString *err = nil;
                int mt = [req[@"max_tokens"] intValue];
                NSString *text = askProvider(activeProvider(), req[@"system"], req[@"user"], mt, &err);
                if (text) {
                    NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"ok":@YES, @"text":text} options:0 error:NULL];
                    reply = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByAppendingString:@"\n"];
                } else {
                    NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"ok":@NO, @"error":err ?: @"unknown"} options:0 error:NULL];
                    reply = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByAppendingString:@"\n"];
                }
            }
        }
        if (reply) { const char *s = reply.UTF8String; size_t len = strlen(s), sent = 0;
            while (sent < len) { ssize_t n = write(fd, s + sent, len - sent); if (n <= 0) break; sent += n; } }
        close(fd);
    }
    return NULL;
}

static void *acceptThread(void *arg){
    (void)arg;
    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (lfd < 0) { bridgeLog(@"[bridge] socket() failed"); return NULL; }
    NSString *sp = @GM_SOCK_PATH;
    unlink(sp.UTF8String);
    struct sockaddr_un a; memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, sp.UTF8String, sizeof(a.sun_path) - 1);
    if (bind(lfd, (struct sockaddr*)&a, sizeof a) != 0) {
        bridgeLog(@"[bridge] bind %@ failed errno=%d", sp, errno);
        close(lfd); return NULL;
    }
    chmod(sp.UTF8String, 0777);
    listen(lfd, 32);
    bridgeLog(@"[bridge] listening %@ (built-in relay)", sp);
    while (1) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) { usleep(100000); continue; }
        pthread_t th;
        if (pthread_create(&th, NULL, connThread, (void*)(intptr_t)cfd) == 0) pthread_detach(th);
        else close(cfd);
    }
    return NULL;
}

NSString *GMBridgeAsk(NSDictionary *provider, NSString *system, NSString *user, int maxTokens, NSString **errOut){
    return askProvider(provider, system, user, maxTokens, errOut);
}

NSDictionary *GMBridgeActiveProvider(void){ return activeProvider(); }

NSString *GMBridgeSummary(void){
    NSDictionary *p = activeProvider();
    NSString *name = p[@"name"] ?: p[@"id"] ?: GMTr(@"未配置");
    return [NSString stringWithFormat:GMTr(@"中继已启动 · %@ · %@ · socket %s"), name, p[@"model"] ?: @"", GM_SOCK_PATH];
}

static void migrateConfigIfNeeded(void){
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:gCfgPath()]) return;
    NSDictionary *p = activeProvider();          // 会从 tp_cfg.json 迁移
    if (!p) return;
    NSDictionary *root = @{ @"active": p[@"id"] ?: @"qwen", @"providers": @[p] };
    NSData *d = [NSJSONSerialization dataWithJSONObject:root
                                               options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    [fm createDirectoryAtPath:gSupDir() withIntermediateDirectories:YES attributes:nil error:NULL];
    [d writeToFile:gCfgPath() atomically:YES];
    [fm setAttributes:@{NSFilePosixPermissions:@(0600)} ofItemAtPath:gCfgPath() error:NULL];
    bridgeLog(@"[bridge] migrated providers.json from tp_cfg.json");
}

void GMBridgeStart(void){
    static int started = 0;
    if (started) return;
    started = 1;
    migrateConfigIfNeeded();
    pthread_t th;
    pthread_create(&th, NULL, acceptThread, NULL);
    pthread_detach(th);
}

void GMBridgeStop(void){
    unlink(GM_SOCK_PATH);
}