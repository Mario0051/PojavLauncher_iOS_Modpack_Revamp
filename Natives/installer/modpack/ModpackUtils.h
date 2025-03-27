#import <Foundation/Foundation.h>
#import "UnzipKit.h"

@interface ModpackUtils : NSObject

// Archive extraction methods
+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError **)error;
+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency;

// Dictionary safety methods
+ (void)safeSetObject:(id)object forKey:(id<NSCopying>)key inDictionary:(NSMutableDictionary *)dict;
+ (NSMutableDictionary *)safeMutableDictionaryWithDictionary:(NSDictionary *)dict;

@end
