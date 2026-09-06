#import "SiriAuthorization.h"
#import <Intents/Intents.h>
#import <Security/Security.h>
#include <dlfcn.h>

static BOOL siriUnavailable = NO;

// Intents 在 dispatch_once 内缺少签名权限时直接终止进程，必须在调用前检查。
NSInteger splayerSiriAuthorizationStatus(void) {
  if (siriUnavailable) return -1;
  static BOOL checked = NO;
  if (!checked) {
    checked = YES;
    // iOS SDK 未公开 SecTask 声明；只读查询自身权限，符号不可用时禁用 Siri。
    typedef CFTypeRef (*CreateTask)(CFAllocatorRef);
    typedef CFTypeRef (*CopyEntitlement)(CFTypeRef, CFStringRef, CFErrorRef *);
    CreateTask createTask = (CreateTask)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CopyEntitlement copyEntitlement = (CopyEntitlement)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    CFTypeRef task = createTask ? createTask(kCFAllocatorDefault) : NULL;
    CFTypeRef value = task && copyEntitlement ? copyEntitlement(task, CFSTR("com.apple.developer.siri"), NULL) : NULL;
    BOOL allowed = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
    if (value) CFRelease(value);
    if (task) CFRelease(task);
    siriUnavailable = !allowed;
    if (siriUnavailable) return -1;
  }
  @try {
    return [INPreferences siriAuthorizationStatus];
  } @catch (NSException *exception) {
    siriUnavailable = YES;
    return -1;
  }
}

void splayerRequestSiriAuthorization(void (^completion)(NSInteger)) {
  if (splayerSiriAuthorizationStatus() == -1) {
    completion(-1);
    return;
  }
  @try {
    [INPreferences requestSiriAuthorization:^(INSiriAuthorizationStatus status) {
      completion(status);
    }];
  } @catch (NSException *exception) {
    siriUnavailable = YES;
    completion(-1);
  }
}
