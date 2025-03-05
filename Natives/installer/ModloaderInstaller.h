#import <Foundation/Foundation.h>

@interface ModloaderInstaller : NSObject

- (void)installModloader:(NSString *)modloaderName forInstance:(NSString *)instanceName version:(NSString *)versionString;

@end
