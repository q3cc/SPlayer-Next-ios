#include "NativeJS.h"
#include "vendor/quickjs.h"
#include <Security/SecRandom.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct Message { char *text; struct Message *next; } Message;
struct SPJS { JSRuntime *runtime; JSContext *context; atomic_int cancelled; double deadline; char *error; Message *head; Message *tail; size_t messages; size_t messageBytes; };
static double now_ms(void) { struct timespec time; clock_gettime(CLOCK_MONOTONIC, &time); return time.tv_sec * 1000.0 + time.tv_nsec / 1000000.0; }
static int interrupt(JSRuntime *runtime, void *opaque) { SPJS *e = opaque; return atomic_load(&e->cancelled) || now_ms() > e->deadline; }
static void set_error(SPJS *e) {
    JSValue exception = JS_GetException(e->context);
    const char *text = JS_ToCString(e->context, exception);
    free(e->error); e->error = strdup(text ? text : "插件执行失败");
    if (text) JS_FreeCString(e->context, text);
    JS_FreeValue(e->context, exception);
}
static JSValue send_message(JSContext *context, JSValueConst self, int argc, JSValueConst *argv) {
    SPJS *e = JS_GetContextOpaque(context);
    if (argc < 1 || e->messages >= 128) return JS_ThrowInternalError(context, "插件消息超出上限");
    size_t length; const char *text = JS_ToCStringLen(context, &length, argv[0]);
    if (!text) return JS_EXCEPTION;
    if (length > 9 * 1024 * 1024 || e->messageBytes + length > 16 * 1024 * 1024) { JS_FreeCString(context, text); return JS_ThrowRangeError(context, "插件消息过大"); }
    Message *message = calloc(1, sizeof(Message));
    if (!message) { JS_FreeCString(context, text); return JS_ThrowOutOfMemory(context); }
    message->text = strndup(text, length); JS_FreeCString(context, text);
    if (!message->text) { free(message); return JS_ThrowOutOfMemory(context); }
    if (e->tail) e->tail->next = message; else e->head = message;
    e->tail = message; e->messages++; e->messageBytes += length;
    return JS_UNDEFINED;
}
static JSValue random_bytes(JSContext *context, JSValueConst self, int argc, JSValueConst *argv) {
    int32_t count = 0;
    if (!argc || JS_ToInt32(context, &count, argv[0]) < 0 || count < 0 || count > 65536) return JS_ThrowRangeError(context, "随机数长度无效");
    uint8_t *data = malloc(count ? count : 1);
    if (!data) return JS_ThrowOutOfMemory(context);
    if (SecRandomCopyBytes(kSecRandomDefault, count, data) != errSecSuccess) { free(data); return JS_ThrowInternalError(context, "无法生成随机数"); }
    JSValue array = JS_NewArray(context);
    for (int i = 0; i < count; i++) JS_SetPropertyUint32(context, array, i, JS_NewInt32(context, data[i]));
    free(data); return array;
}
/* URL 解析交给系统，不提供网络或文件访问能力 */
static JSValue cf_string(JSContext *context, CFStringRef text) {
    if (!text) return JS_NewString(context, "");
    CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(text), kCFStringEncodingUTF8) + 1;
    char *buffer = malloc(size);
    if (!buffer) return JS_ThrowOutOfMemory(context);
    CFStringGetCString(text, buffer, size, kCFStringEncodingUTF8);
    JSValue value = JS_NewString(context, buffer); free(buffer); return value;
}
static JSValue parse_url(JSContext *context, JSValueConst self, int argc, JSValueConst *argv) {
    if (!argc) return JS_ThrowTypeError(context, "URL 无效");
    const char *text = JS_ToCString(context, argv[0]); if (!text) return JS_EXCEPTION;
    CFStringRef input = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8); JS_FreeCString(context, text);
    CFURLRef base = NULL;
    if (argc > 1) { const char *value = JS_ToCString(context, argv[1]); if (value && strlen(value)) { CFStringRef string = CFStringCreateWithCString(NULL, value, kCFStringEncodingUTF8); base = CFURLCreateWithString(NULL, string, NULL); CFRelease(string); } if (value) JS_FreeCString(context, value); }
    CFURLRef url = CFURLCreateWithString(NULL, input, base); CFRelease(input); if (base) CFRelease(base);
    if (!url) return JS_ThrowTypeError(context, "URL 无效");
    CFURLRef absolute = CFURLCopyAbsoluteURL(url); CFRelease(url);
    JSValue result = JS_NewObject(context);
    JS_SetPropertyStr(context, result, "href", cf_string(context, CFURLGetString(absolute)));
    CFStringRef host = CFURLCopyHostName(absolute), path = CFURLCopyPath(absolute), scheme = CFURLCopyScheme(absolute), query = CFURLCopyQueryString(absolute, NULL);
    JS_SetPropertyStr(context, result, "hostname", cf_string(context, host));
    JS_SetPropertyStr(context, result, "pathname", cf_string(context, path));
    JS_SetPropertyStr(context, result, "scheme", cf_string(context, scheme));
    JS_SetPropertyStr(context, result, "query", cf_string(context, query));
    JS_SetPropertyStr(context, result, "port", JS_NewInt32(context, CFURLGetPortNumber(absolute)));
    if (host) CFRelease(host); if (path) CFRelease(path); if (scheme) CFRelease(scheme); if (query) CFRelease(query); CFRelease(absolute);
    return result;
}
SPJS *sp_js_create(void) {
    SPJS *e = calloc(1, sizeof(SPJS)); if (!e) return NULL;
    e->runtime = JS_NewRuntime(); if (!e->runtime) { free(e); return NULL; }
    JS_SetMemoryLimit(e->runtime, 64 * 1024 * 1024); JS_SetMaxStackSize(e->runtime, 512 * 1024);
    e->deadline = now_ms() + 3000; JS_SetInterruptHandler(e->runtime, interrupt, e);
    e->context = JS_NewContext(e->runtime); if (!e->context) { JS_FreeRuntime(e->runtime); free(e); return NULL; }
    JS_SetContextOpaque(e->context, e);
    JSValue global = JS_GetGlobalObject(e->context);
    JS_SetPropertyStr(e->context, global, "__nativeSend", JS_NewCFunction(e->context, send_message, "__nativeSend", 1));
    JS_SetPropertyStr(e->context, global, "__nativeRandom", JS_NewCFunction(e->context, random_bytes, "__nativeRandom", 1));
    JS_SetPropertyStr(e->context, global, "__nativeURL", JS_NewCFunction(e->context, parse_url, "__nativeURL", 2));
    JS_FreeValue(e->context, global); return e;
}
int sp_js_eval(SPJS *e, const char *source, double milliseconds) {
    e->deadline = now_ms() + milliseconds;
    JS_UpdateStackTop(e->runtime);
    JSValue result = JS_Eval(e->context, source, strlen(source), "plugin.js", JS_EVAL_TYPE_GLOBAL);
    int failed = JS_IsException(result);
    if (failed) set_error(e);
    JS_FreeValue(e->context, result); return failed ? -1 : 0;
}
int sp_js_jobs(SPJS *e, double milliseconds) {
    e->deadline = now_ms() + milliseconds;
    JS_UpdateStackTop(e->runtime);
    JSContext *context;
    for (int i = 0; i < 1024; i++) {
        int status = JS_ExecutePendingJob(e->runtime, &context);
        if (status < 0) { set_error(e); return -1; }
        if (!status) return 0;
        if (interrupt(e->runtime, e)) return -1;
    }
    return 0;
}
void sp_js_cancel(SPJS *e) { atomic_store(&e->cancelled, 1); }
const char *sp_js_error(SPJS *e) { return e->error ? e->error : "插件执行超时或已取消"; }
char *sp_js_take(SPJS *e) { Message *m = e->head; if (!m) return NULL; e->head = m->next; if (!e->head) e->tail = NULL; e->messages--; e->messageBytes -= strlen(m->text); char *text = m->text; free(m); return text; }
void sp_js_free_string(char *text) { free(text); }
void sp_js_destroy(SPJS *e) { if (!e) return; char *text; while ((text = sp_js_take(e))) free(text); JS_FreeContext(e->context); JS_FreeRuntime(e->runtime); free(e->error); free(e); }
