#import <Foundation/Foundation.h>

@interface ModpackDownloader : NSObject

- (BOOL)importModpackAtURL:(NSURL *)zipURL toInstance:(NSString *)instanceName;

@end
