// gmhook6: interpose MobileGestalt + eligibility in the target process
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <CoreFoundation/CoreFoundation.h>

static FILE *gLog;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;

static void lg(const char *fmt, ...) __attribute__((format(printf,1,2)));
static void lg(const char *fmt, ...){
  if(!gLog) return;
  va_list ap; va_start(ap,fmt);
  pthread_mutex_lock(&gLock);
  vfprintf(gLog,fmt,ap); fputc('\n',gLog); fflush(gLog);
  pthread_mutex_unlock(&gLock);
  va_end(ap);
}

static uintptr_t imageBase(const char *needle){
  for(uint32_t i=0;i<_dyld_image_count();i++){
    const char *nm=_dyld_get_image_name(i);
    if(nm && strstr(nm,needle)) return (uintptr_t)_dyld_get_image_header(i);
  }
  return 0;
}
static uintptr_t gMGBase, gEligBase;

static bool keyInteresting(const char *k){
  if(!k) return false;
  return strcasestr(k,"GenerativeModel")||strcasestr(k,"AppleIntelligence")||
         strcasestr(k,"Greymatter")||strcasestr(k,"Intelligence")||
         strcasestr(k,"GreyMatter");
}
static char* keyStr(CFStringRef key){
  static __thread char buf[256];
  buf[0]=0;
  if(!key) return buf;
  if(CFGetTypeID(key)==CFStringGetTypeID()){
    if(!CFStringGetCString(key,buf,sizeof(buf),kCFStringEncodingUTF8)) snprintf(buf,sizeof(buf),"?");
  } else snprintf(buf,sizeof(buf),"(non-string %p)",(void*)key);
  return buf;
}


// ---- extern decls (no SDK headers for these) ----
extern CFTypeRef MGCopyAnswer(CFStringRef);
extern CFTypeRef MGCopyAnswerWithError(CFStringRef, int*);
extern bool MGGetBoolAnswer(CFStringRef);
extern int32_t MGGetSInt32Answer(CFStringRef);
extern int64_t MGGetSInt64Answer(CFStringRef);
extern CFStringRef MGGetStringAnswer(CFStringRef);
extern bool MGIsDeviceOfType(int);
extern bool MGIsDeviceOneOfType(const int*);
extern uint64_t os_eligibility_domain_for_name(const char*);
extern int os_eligibility_get_domain_answer(uint64_t,uint64_t*,uint64_t*,void**,void**);

// ---- originals via base+offset ----
typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef);
typedef CFTypeRef (*MGCopyAnswerWithError_t)(CFStringRef, int*);
typedef bool (*MGGetBoolAnswer_t)(CFStringRef);
typedef int32_t (*MGGetSInt32Answer_t)(CFStringRef);
typedef int64_t (*MGGetSInt64Answer_t)(CFStringRef);
typedef CFStringRef (*MGGetStringAnswer_t)(CFStringRef);
typedef bool (*MGIsDeviceOfType_t)(int);
typedef bool (*MGIsDeviceOneOfType_t)(const int*);

#define ORIG(t,name,off) ((t)(gMGBase+(off)))
#define ORIGE(t,name,off) ((t)(gEligBase+(off)))

// ---- replacements ----
static CFTypeRef my_MGCopyAnswer(CFStringRef key){
  const char *k=keyStr(key);
  if(keyInteresting(k)){
    lg("[mg] MGCopyAnswer(%s) -> true (forced)",k);
    return CFRetain(kCFBooleanTrue);
  }
  CFTypeRef r=ORIG(MGCopyAnswer_t,MGCopyAnswer,0x1042)(key);
  lg("[mg] MGCopyAnswer(%s) = %p",k,r);
  return r;
}
static CFTypeRef my_MGCopyAnswerWithError(CFStringRef key,int *err){
  const char *k=keyStr(key);
  if(keyInteresting(k)){
    if(err)*err=0;
    lg("[mg] MGCopyAnswerWithError(%s) -> true (forced)",k);
    return CFRetain(kCFBooleanTrue);
  }
  CFTypeRef r=ORIG(MGCopyAnswerWithError_t,MGCopyAnswerWithError,0x4070)(key,err);
  lg("[mg] MGCopyAnswerWithError(%s) = %p err=%d",k,r,err?*err:0);
  return r;
}
static bool my_MGGetBoolAnswer(CFStringRef key){
  const char *k=keyStr(key);
  if(keyInteresting(k)){ lg("[mg] MGGetBoolAnswer(%s) -> 1 (forced)",k); return true; }
  bool r=ORIG(MGGetBoolAnswer_t,MGGetBoolAnswer,0x105B)(key);
  lg("[mg] MGGetBoolAnswer(%s) = %d",k,(int)r);
  return r;
}
static int32_t my_MGGetSInt32Answer(CFStringRef key){
  const char *k=keyStr(key);
  if(keyInteresting(k)){ lg("[mg] MGGetSInt32Answer(%s) -> 1 (forced)",k); return 1; }
  int32_t r=ORIG(MGGetSInt32Answer_t,MGGetSInt32Answer,0x10CD)(key);
  lg("[mg] MGGetSInt32Answer(%s) = %d",k,r);
  return r;
}
static int64_t my_MGGetSInt64Answer(CFStringRef key){
  const char *k=keyStr(key);
  if(keyInteresting(k)){ lg("[mg] MGGetSInt64Answer(%s) -> 1 (forced)",k); return 1; }
  int64_t r=ORIG(MGGetSInt64Answer_t,MGGetSInt64Answer,0x4740)(key);
  lg("[mg] MGGetSInt64Answer(%s) = %lld",k,(long long)r);
  return r;
}
static CFStringRef my_MGGetStringAnswer(CFStringRef key){
  const char *k=keyStr(key);
  CFStringRef r=ORIG(MGGetStringAnswer_t,MGGetStringAnswer,0x1106)(key);
  lg("[mg] MGGetStringAnswer(%s) = %p",k,(void*)r);
  return r;
}
static bool my_MGIsDeviceOfType(int t){
  bool r=ORIG(MGIsDeviceOfType_t,MGIsDeviceOfType,0x477D)(t);
  lg("[mg] MGIsDeviceOfType(%d) = %d",t,(int)r);
  return r;
}
static bool my_MGIsDeviceOneOfType(const int *t){
  bool r=ORIG(MGIsDeviceOneOfType_t,MGIsDeviceOneOfType,0x47C9)(t);
  lg("[mg] MGIsDeviceOneOfType(%p) = %d",(const void*)t,(int)r);
  return r;
}

// ---- eligibility ----
typedef uint64_t (*elig_domain_for_name_t)(const char*);
typedef int (*elig_get_answer_t)(uint64_t,uint64_t*,uint64_t*,void**,void**);
typedef int (*elig_get_all_t)(void**);

static uint64_t my_domain_for_name(const char *name){
  uint64_t d=ORIGE(elig_domain_for_name_t,os_eligibility_domain_for_name,0x3DC0)(name);
  lg("[elig] domain_for_name(%s) = %llu",name?name:"(null)",(unsigned long long)d);
  return d;
}
static int my_get_answer(uint64_t domain,uint64_t *ans,uint64_t *src,void **status,void **ctx){
  int rc=ORIGE(elig_get_answer_t,os_eligibility_get_domain_answer,0x15D8)(domain,ans,src,status,ctx);
  if(domain==122 && rc==0){
    lg("[elig] GREYMATTER orig answer=%llu src=%llu -> 4/forced",(unsigned long long)*ans,(unsigned long long)*src);
    *ans=4; if(src)*src=2;
  } else if(rc==0){
    lg("[elig] domain=%llu answer=%llu src=%llu",(unsigned long long)domain,(unsigned long long)*ans,(unsigned long long)*src);
  }
  return rc;
}

__attribute__((used)) static struct { const void *repl, *orig; } ip[] __attribute__((section("__DATA,__interpose"))) = {
  { (const void*)my_MGCopyAnswer,          (const void*)MGCopyAnswer },
  { (const void*)my_MGCopyAnswerWithError, (const void*)MGCopyAnswerWithError },
  { (const void*)my_MGGetBoolAnswer,       (const void*)MGGetBoolAnswer },
  { (const void*)my_MGGetSInt32Answer,     (const void*)MGGetSInt32Answer },
  { (const void*)my_MGGetSInt64Answer,     (const void*)MGGetSInt64Answer },
  { (const void*)my_MGGetStringAnswer,     (const void*)MGGetStringAnswer },
  { (const void*)my_MGIsDeviceOfType,      (const void*)MGIsDeviceOfType },
  { (const void*)my_MGIsDeviceOneOfType,   (const void*)MGIsDeviceOneOfType },
  { (const void*)my_domain_for_name,       (const void*)os_eligibility_domain_for_name },
  { (const void*)my_get_answer,            (const void*)os_eligibility_get_domain_answer },
};

__attribute__((constructor)) static void init(void){
  const char *p=getenv("GMHOOK_LOG");
  if(p) gLog=fopen(p,"a");
  gMGBase=imageBase("libMobileGestalt.dylib");
  gEligBase=imageBase("libsystem_eligibility.dylib");
  char nm[256]={0};
  extern int proc_name(int,char*,unsigned);
  proc_name(getpid(),nm,sizeof(nm));
  lg("=== gmhook6 pid=%d proc=%s mg=0x%lx elig=0x%lx ===",getpid(),nm,(unsigned long)gMGBase,(unsigned long)gEligBase);
}
