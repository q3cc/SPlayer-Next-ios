#import "SiriAuthorization.h"
#import <Intents/Intents.h>

// 缺失签名权限时 Apple 抛出 Objective-C 异常，Swift 的 do/catch 无法拦截。
NSInteger splayerSiriAuthorizationStatus(void) {
  @try {
    return [INPreferences siriAuthorizationStatus];
  } @catch (NSException *exception) {
    return -1;
  }
}

void splayerRequestSiriAuthorization(void (^completion)(NSInteger)) {
  @try {
    [INPreferences requestSiriAuthorization:^(INSiriAuthorizationStatus status) {
      completion(status);
    }];
  } @catch (NSException *exception) {
    completion(-1);
  }
}
