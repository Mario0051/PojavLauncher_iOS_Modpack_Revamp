#import <Foundation/Foundation.h>
#import "UnzipKit.h"
NS_ASSUME_NONNULL_BEGIN

@interface ModpackUtils : NSObject
+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError **)error;
+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency;
+ (NSDictionary *)parseVersionString:(NSString *)versionString;
@end

NS_ASSUME_NONNULL_END
