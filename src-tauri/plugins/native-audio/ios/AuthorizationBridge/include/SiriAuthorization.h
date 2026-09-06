#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
NSInteger splayerSiriAuthorizationStatus(void);
void splayerRequestSiriAuthorization(void (^completion)(NSInteger));
NS_ASSUME_NONNULL_END
