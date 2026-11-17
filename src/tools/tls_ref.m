#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Security/Security.h>
#include <Security/SecureTransport.h>
#include <Security/SecBase.h>

static OSStatus sslRead(SSLConnectionRef conn, void *data, size_t *len){
    int fd = *(int*)conn; size_t want=*len, got=0;
    while(got<want){ ssize_t n = read(fd,(char*)data+got,want-got); if(n<=0){ if(n<0&&errno==EAGAIN) break; *len=got; return n<0?errSSLClosedAbort:errSSLClosedGraceful;} got+=n; }
    *len=got; return noErr;
}
static OSStatus sslWrite(SSLConnectionRef conn, const void *data, size_t *len){
    int fd = *(int*)conn; size_t want=*len, sent=0;
    while(sent<want){ ssize_t n = write(fd,(const char*)data+sent,want-sent); if(n<=0){ *len=sent; return errSSLClosedAbort;} sent+=n; }
    *len=sent; return noErr;
}
static int tcpConnect(const char *ip, int port){
    int fd = socket(AF_INET, SOCK_STREAM, 0); if(fd<0) return -1;
    struct timeval tv={8,0}; setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof tv); setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&tv,sizeof tv);
    struct sockaddr_in sa; memset(&sa,0,sizeof sa); sa.sin_family=AF_INET; sa.sin_port=htons(port); inet_pton(AF_INET, ip, &sa.sin_addr);
    if(connect(fd,(struct sockaddr*)&sa,sizeof sa)!=0){ close(fd); return -2; }
    return fd;
}
static NSData *httpsPost(NSString *host, NSString *ip, NSString *path, NSString *apiKey, NSData *body, int *outStatus){
    int fd = tcpConnect([ip UTF8String], 443);
    fprintf(stderr,"fd=%d\n",fd); if(fd<0) return nil;
    SSLContextRef ctx = SSLCreateContext(NULL, kSSLClientSide, kSSLStreamType);
    SSLSetIOFuncs(ctx, sslRead, sslWrite);
    SSLSetConnection(ctx, &fd);
    SSLSetPeerDomainName(ctx, [host UTF8String], strlen([host UTF8String]));
    SSLSetSessionOption(ctx, kSSLSessionOptionBreakOnServerAuth, true);
    OSStatus st = errSSLWouldBlock;
    BOOL trusted = NO;
    for(int i=0;i<32;i++){
        st = SSLHandshake(ctx);
        if(st==errSSLWouldBlock) continue;
        if(st==errSSLServerAuthCompleted){
            SecTrustRef trust=NULL;
            if(SSLCopyPeerTrust(ctx,&trust)==noErr && trust && SecTrustEvaluateWithError(trust,NULL)) trusted=YES;
            if(trust) CFRelease(trust);
            if(!trusted){ fprintf(stderr,"TLS trust failed\n"); close(fd); CFRelease(ctx); return nil; }
            continue;
        }
        break;
    }
    fprintf(stderr,"handshake=%d trusted=%d\n",(int)st,(int)trusted);
    if(st!=noErr || !trusted){ close(fd); CFRelease(ctx); return nil; }
    NSMutableString *req = [NSMutableString stringWithFormat:
        @"POST %@ HTTP/1.1\r\nHost: %@\r\nAuthorization: Bearer %@\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        path, host, apiKey, (unsigned long)body.length];
    NSMutableData *reqD = [[req dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [reqD appendData:body];
    size_t wrote=0; SSLWrite(ctx, reqD.bytes, reqD.length, &wrote);
    NSMutableData *resp = [NSMutableData data]; char buf[8192];
    while(1){ size_t got=0; OSStatus r = SSLRead(ctx, buf, sizeof buf, &got); if(got) [resp appendBytes:buf length:got];
        if(r==errSSLWouldBlock){ continue; } if(r!=noErr && r!=errSSLClosedGraceful) break; if(got==0) break; }
    SSLClose(ctx); CFRelease(ctx); close(fd);
    // split headers/body
    NSString *all = [[NSString alloc] initWithData:resp encoding:NSISOLatin1StringEncoding];
    NSRange hr = [all rangeOfString:@"\r\n\r\n"];
    fprintf(stderr,"resp=%lu headers=%lu\n",(unsigned long)resp.length,(unsigned long)hr.location);
    NSUInteger bodyStart = hr.location==NSNotFound?0:NSMaxRange(hr);
    NSData *bd = bodyStart?[resp subdataWithRange:NSMakeRange(bodyStart, resp.length-bodyStart)]:resp;
    return bd;
}
int main(int argc, char**argv){ @autoreleasepool{
    NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@"/tmp/tp_cfg.json"] options:0 error:NULL];
    NSString *host = @"token-plan.cn-beijing.maas.aliyuncs.com";
    NSDictionary *payload = @{@"model":cfg[@"chat_model"]?:@"qwen3.8-flash",
        @"messages":@[@{@"role":@"user",@"content":@"Reply with exactly: HELLO-TLS"}],@"max_tokens":@50};
    NSData *body=[NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    int st=0;
    NSData *d = httpsPost(host, argc>1?[NSString stringWithUTF8String:argv[1]]:@"39.106.104.16", @"/compatible-mode/v1/chat/completions", cfg[@"api_key"], body, &st);
    NSString *s = d?[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]:nil;
    NSLog(@"BODY: %@", [s substringToIndex:MIN(s.length,400)]);
    return d?0:1;
}}
