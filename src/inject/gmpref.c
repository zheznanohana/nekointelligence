#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <CoreFoundation/CoreFoundation.h>

static FILE *gF;
#define L(...) do { if (gF) { fprintf(gF, __VA_ARGS__); fprintf(gF, "\n"); fflush(gF); } } while (0)

static void *imgBase(const char *needle) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, needle)) return (void *)_dyld_get_image_header(i);
    }
    return NULL;
}

static void logcf(const char *what, CFStringRef key, CFStringRef app) {
    char kb[256] = "-", ab[256] = "-";
    if (key) CFStringGetCString(key, kb, sizeof kb, kCFStringEncodingUTF8);
    if (app) CFStringGetCString(app, ab, sizeof ab, kCFStringEncodingUTF8);
    L("[pref] %s app=%s key=%s", what, ab, kb);
}
static void dumpdata(CFStringRef key, CFDataRef d) {
    char kb[256] = "-"; if (key) CFStringGetCString(key, kb, sizeof kb, kCFStringEncodingUTF8);
    const char *shortk = strrchr(kb, '.'); shortk = shortk ? shortk + 1 : kb;
    char path[512]; snprintf(path, sizeof path, "/tmp/pref_%s.bin", shortk);
    FILE *f = fopen(path, "wb");
    if (f) { fwrite(CFDataGetBytePtr(d), 1, CFDataGetLength(d), f); fclose(f); }
    L("[pref]   dumped %s -> %s (%ld bytes)", kb, path, (long)CFDataGetLength(d));
}
static CFDataRef gFakeReadiness = NULL;
static CFDataRef gFakeUnified = NULL;

static CFDataRef fakeFor(CFStringRef key) {
    char kb[256] = "-"; if (key) CFStringGetCString(key, kb, sizeof kb, kCFStringEncodingUTF8);
    if (strstr(kb, "useCaseReadiness")) return gFakeReadiness;
    if (strstr(kb, "unifiedReasons")) return gFakeUnified;
    return NULL;
}

static void logval(const char *what, CFStringRef key, CFTypeRef v) {
    char kb[256] = "-";
    if (key) CFStringGetCString(key, kb, sizeof kb, kCFStringEncodingUTF8);
    if (!v) { L("[pref]   %s key=%s = NULL", what, kb); return; }
    if (CFGetTypeID(v) == CFDataGetTypeID()) { dumpdata(key, (CFDataRef)v); return; }
    CFStringRef d = CFCopyDescription(v);
    char db[1200] = "-";
    if (d) { CFStringGetCString(d, db, sizeof db, kCFStringEncodingUTF8); CFRelease(d); }
    L("[pref]   %s key=%s = %s", what, kb, db);
}

static CFPropertyListRef (*real_copy_app_value)(CFStringRef, CFStringRef);
static CFPropertyListRef (*real_copy_value)(CFStringRef, CFStringRef, CFStringRef, CFStringRef);
static CFDictionaryRef (*real_copy_multiple)(CFArrayRef, CFStringRef, CFStringRef, CFStringRef);
static Boolean (*real_get_bool)(CFStringRef, CFStringRef, Boolean *);
static CFIndex (*real_get_int)(CFStringRef, CFStringRef, Boolean *);
static Boolean (*real_is_forced)(CFStringRef, CFStringRef);

static CFPropertyListRef my_copy_app_value(CFStringRef key, CFStringRef app) {
    CFPropertyListRef v = real_copy_app_value(key, app);
    logcf("CopyAppValue", key, app);
    CFDataRef fk = fakeFor(key);
    if (fk) { L("[pref]   OVERRIDE CopyAppValue"); return CFRetain(fk); }
    logval("CopyAppValue", key, v);
    return v;
}
static CFPropertyListRef my_copy_value(CFStringRef key, CFStringRef app, CFStringRef user, CFStringRef host) {
    CFPropertyListRef v = real_copy_value(key, app, user, host);
    logcf("CopyValue", key, app);
    CFDataRef fk = fakeFor(key);
    if (fk) { L("[pref]   OVERRIDE CopyValue"); return CFRetain(fk); }
    logval("CopyValue", key, v);
    return v;
}
static CFDictionaryRef my_copy_multiple(CFArrayRef keys, CFStringRef app, CFStringRef user, CFStringRef host) {
    CFDictionaryRef v = real_copy_multiple(keys, app, user, host);
    char ab[256] = "-"; if (app) CFStringGetCString(app, ab, sizeof ab, kCFStringEncodingUTF8);
    L("[pref] CopyMultiple app=%s nkeys=%ld", ab, keys ? (long)CFArrayGetCount(keys) : -1L);
    if (keys) for (CFIndex i = 0; i < CFArrayGetCount(keys); i++) logval("CopyMultiple", CFArrayGetValueAtIndex(keys, i), NULL);
    if (v) logval("CopyMultiple->", CFSTR("result"), v);
    return v;
}
static Boolean my_get_bool(CFStringRef key, CFStringRef app, Boolean *ok) {
    Boolean r = real_get_bool(key, app, ok);
    logcf("GetAppBooleanValue", key, app); L("[pref]   => %d", (int)r);
    return r;
}
static CFIndex my_get_int(CFStringRef key, CFStringRef app, Boolean *ok) {
    CFIndex r = real_get_int(key, app, ok);
    logcf("GetAppIntegerValue", key, app); L("[pref]   => %ld", (long)r);
    return r;
}
static Boolean my_is_forced(CFStringRef key, CFStringRef app) {
    Boolean r = real_is_forced(key, app);
    logcf("AppValueIsForced", key, app); L("[pref]   => %d", (int)r);
    return r;
}

extern CFPropertyListRef CFPreferencesCopyAppValue(CFStringRef, CFStringRef);
extern CFPropertyListRef CFPreferencesCopyValue(CFStringRef, CFStringRef, CFStringRef, CFStringRef);
extern CFDictionaryRef CFPreferencesCopyMultiple(CFArrayRef, CFStringRef, CFStringRef, CFStringRef);
extern Boolean CFPreferencesGetAppBooleanValue(CFStringRef, CFStringRef, Boolean *);
extern CFIndex CFPreferencesGetAppIntegerValue(CFStringRef, CFStringRef, Boolean *);
extern Boolean CFPreferencesAppValueIsForced(CFStringRef, CFStringRef);

#define DYLD_INTERPOSE_(_rep, _orig) \
    __attribute__((used)) static struct { const void *r; const void *o; } \
    _interpose_##_orig __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&_rep, (const void *)(unsigned long)&_orig };

DYLD_INTERPOSE_(my_copy_app_value, CFPreferencesCopyAppValue)
DYLD_INTERPOSE_(my_copy_value, CFPreferencesCopyValue)
DYLD_INTERPOSE_(my_copy_multiple, CFPreferencesCopyMultiple)
DYLD_INTERPOSE_(my_get_bool, CFPreferencesGetAppBooleanValue)
DYLD_INTERPOSE_(my_get_int, CFPreferencesGetAppIntegerValue)
DYLD_INTERPOSE_(my_is_forced, CFPreferencesAppValueIsForced)

__attribute__((constructor)) static void initMe(void) {
    const char *p = getenv("GMPREF_LOG");
    gF = fopen(p ? p : "/tmp/gmpref.log", "w");
    char *base = (char *)imgBase("CoreFoundation");
    L("[gmpref] loaded pid=%d CF=%p", getpid(), base);
    { FILE *f = fopen("/tmp/fake_readiness.bin", "rb");
      if (f) { static UInt8 buf[262144]; size_t n = fread(buf,1,sizeof buf,f); fclose(f);
               gFakeReadiness = CFDataCreate(NULL, buf, (CFIndex)n); L("[gmpref] fake readiness %zu bytes", n); } }
    { FILE *f = fopen("/tmp/fake_unifiedreasons.bin", "rb");
      if (f) { static UInt8 buf[4096]; size_t n = fread(buf,1,sizeof buf,f); fclose(f);
               gFakeUnified = CFDataCreate(NULL, buf, (CFIndex)n); L("[gmpref] fake unified %zu bytes", n); } else {
               gFakeUnified = CFDataCreate(NULL, (const UInt8*)"{}", 2); } }
    if (base) {
        real_copy_app_value = (void *)(base + 0x2A0E4);
        real_copy_value     = (void *)(base + 0x53CDD);
        real_copy_multiple  = (void *)(base + 0xAF6E5);
        real_get_bool       = (void *)(base + 0x4E866);
        real_get_int        = (void *)(base + 0x4E6A5);
        real_is_forced      = (void *)(base + 0xD45A3);
    }
}
