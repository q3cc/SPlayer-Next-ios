#import <Foundation/Foundation.h>
#import "SiriAuthorization.h"
#include <assert.h>

int main(void) {
  @autoreleasepool {
    NSInteger first = splayerSiriAuthorizationStatus();
    NSInteger second = splayerSiriAuthorizationStatus();
    assert(first == second);
    if (first == -1) {
      __block BOOL completed = NO;
      splayerRequestSiriAuthorization(^(NSInteger status) {
        assert(status == -1);
        completed = YES;
      });
      assert(completed);
    }
    NSLog(@"PASS: Siri 授权检查重复调用及缺少签名权限时的安全回传（%ld）", (long)first);
  }
  return 0;
}
