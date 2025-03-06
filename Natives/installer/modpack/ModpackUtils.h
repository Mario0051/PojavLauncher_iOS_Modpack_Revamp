#import <Foundation/Foundation.h>
#import "UnzipKit.h"

NS_ASSUME_NONNULL_BEGIN

// Error domain and codes for modpack operations
extern NSString * const ModpackUtilsErrorDomain;

typedef NS_ENUM(NSInteger, ModpackUtilsErrorCode) {
    ModpackUtilsErrorCodeInvalidParameters = 100,
    ModpackUtilsErrorCodeExtractionFailed = 101,
    ModpackUtilsErrorCodeInvalidManifest = 102,
    ModpackUtilsErrorCodeJsonCreationFailed = 103,
    ModpackUtilsErrorCodeProfileCreationFailed = 104,
    ModpackUtilsErrorCodeDownloadFailed = 105,
    ModpackUtilsErrorCodeParsingFailed = 106,
    ModpackUtilsErrorCodeNetworkError = 107,
    ModpackUtilsErrorCodeAuthenticationFailed = 108
};

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
+ (void)archive:(UZKArchive *)archive 
extractDirectory:(NSString *)dir 
         toPath:(NSString *)path 
          error:(NSError **)error;

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

/**
 * Create Forge JSON file for the specified version
 * @param vanillaVer The Minecraft version
 * @param forgeVer The Forge version
 * @param error On failure, will be set to an error describing the problem
 * @return YES if successful, NO otherwise
 */
+ (BOOL)createForgeJSON:(NSString *)vanillaVer 
          loaderVersion:(NSString *)forgeVer 
                  error:(NSError **)error;

/**
 * Create Fabric JSON file for the specified version
 * @param fabricString The Fabric version string
 * @param error On failure, will be set to an error describing the problem
 * @return YES if successful, NO otherwise
 */
+ (BOOL)createFabricJSON:(NSString *)fabricString 
                   error:(NSError **)error;

/**
 * Create NeoForge JSON file for the specified version
 * @param vanillaVer The Minecraft version
 * @param neoforgeVer The NeoForge version
 * @param error On failure, will be set to an error describing the problem
 * @return YES if successful, NO otherwise
 */
+ (BOOL)createNeoForgeJSON:(NSString *)vanillaVer 
             loaderVersion:(NSString *)neoforgeVer 
                     error:(NSError **)error;

/**
 * Set up a profile with information from a modpack manifest
 * @param manifestDict The modpack manifest dictionary
 * @param destPath The destination path for the modpack
 * @param finalVersionString The version string to use for the profile
 * @return The created profile name or nil if creation failed
 */
+ (nullable NSString *)setupProfileWithManifest:(NSDictionary *)manifestDict 
                                       destPath:(NSString *)destPath 
                             finalVersionString:(NSString *)finalVersionString;

/**
 * Verifies a modpack manifest has the required fields
 * @param manifest The manifest dictionary to verify
 * @param error On failure, will be set to an error describing the problem
 * @return YES if valid, NO otherwise
 */
+ (BOOL)verifyManifest:(NSDictionary *)manifest error:(NSError **)error;

/**
 * Creates a standardized error object
 * @param code The error code
 * @param message The error message
 * @param underlyingError The underlying error that caused this error, if any
 * @return An NSError object
 */
+ (NSError *)errorWithCode:(ModpackUtilsErrorCode)code 
                   message:(NSString *)message 
           underlyingError:(nullable NSError *)underlyingError;

@end

NS_ASSUME_NONNULL_END
