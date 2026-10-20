#ifndef SPLAYER_NATIVE_JS_H
#define SPLAYER_NATIVE_JS_H
#include <stddef.h>
typedef struct SPJS SPJS;
/* 单个插件独占运行时，仅提供 JSON 消息和系统随机数，不注册文件或操作系统模块 */
SPJS *sp_js_create(void);
void sp_js_destroy(SPJS *engine);
/* 每轮执行有时间限制；cancel 可跨线程调用，destroy 必须在执行线程调用 */
int sp_js_eval(SPJS *engine, const char *source, double milliseconds);
int sp_js_jobs(SPJS *engine, double milliseconds);
void sp_js_cancel(SPJS *engine);
const char *sp_js_error(SPJS *engine);
char *sp_js_take(SPJS *engine);
void sp_js_free_string(char *text);
#endif
