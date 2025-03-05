#import <Foundation/Foundation.h>
#import "UnzipKit.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Utility class for Minecraft modpack installation
 */
@interface ModpackUtils : NSObject

/**
 * Extracts a directory from a zip archive to a specified path
 * @param archive The UZKArchive to extract from
 * @param dir The directory within the archive to extract
 * @param path The destination path to extract to
 * @param error If an error occurs, upon return contains an NSError object that describes the problem
 */
+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError **)error;

/**
 * Parses dependency information from a modpack manifest
 * @param dependency The dependency dictionary from a modpack manifest
 * @return A dictionary with parsed dependency information
 */
+ (NSDictionary *)infoForDependencies:(nullable NSDictionary *)dependency;

/**
 * Parses a version string to extract information about Minecraft version and mod loader
 * @param versionString The version string to parse
 * @return A dictionary with parsed version information
 */
+ (NSDictionary *)parseVersionString:(nullable NSString *)versionString;

@end

NS_ASSUME_NONNULL_END
