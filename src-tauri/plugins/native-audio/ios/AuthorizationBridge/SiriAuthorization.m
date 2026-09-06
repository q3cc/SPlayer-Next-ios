#import "SiriAuthorization.h"
#import <Intents/Intents.h>

static BOOL siriUnavailable = NO;

// 缺失签名权限时 Apple 抛出 Objective-C 异常，Swift 的 do/catch 无法拦截。
NSInteger splayerSiriAuthorizationStatus(void) {
  if (siriUnavailable) return -1;
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
