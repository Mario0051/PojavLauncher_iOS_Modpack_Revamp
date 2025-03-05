#import <Foundation/Foundation.h>
#import "ModpackUtils.h"
#import "UnzipKit.h"

@class MinecraftResourceDownloadTask;

NS_ASSUME_NONNULL_BEGIN

/**
 * Base class for modpack API implementations
 */
@interface ModpackAPI : NSObject

/**
 * Base URL for the API
 */
@property(nonatomic, strong) NSString *baseURL;

/**
 * Last error that occurred during API operations
 */
@property(nonatomic, strong, nullable) NSError *lastError;

/**
 * Indicates if the last search reached the final page of results
 */
@property(nonatomic, assign) BOOL reachedLastPage;

/**
 * Initializes the API with the specified base URL
 * @param url The base URL for the API
 * @return An initialized ModpackAPI instance
 */
- (instancetype)initWithURL:(NSString *)url NS_DESIGNATED_INITIALIZER;

/**
 * Searches for mods or modpacks based on the provided filters
 * @param filters Dictionary of search filters
 * @param prevResult Previous search results for pagination
 * @return Array of search results
 */
- (nullable NSMutableArray *)searchModWithFilters:(NSDictionary *)filters previousPageResult:(nullable NSMutableArray *)prevResult;

/**
 * Loads detailed information for a mod or modpack
 * @param item The mod or modpack to load details for
 */
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;

/**
 * Installs a modpack from the provided detail at the selected version
 * @param modDetail The modpack details
 * @param selectedVersion The index of the selected version
 */
- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

/**
 * Submits download tasks for a modpack package
 * @param downloader The download task manager
 * @param packagePath Path to the modpack package
 * @param destPath Destination path for extraction
 */
- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath;

/**
 * Synchronously requests data from an API endpoint
 * @param endpoint The endpoint path
 * @param params The parameters to include in the request
 * @return The response data or nil if an error occurred
 */
- (nullable id)getEndpoint:(NSString *)endpoint params:(nullable NSDictionary *)params;

/**
 * Asynchronously requests data from an API endpoint
 * @param endpoint The endpoint path
 * @param params The parameters to include in the request
 * @param completion Block to call when the request completes
 */
- (void)getEndpoint:(NSString *)endpoint params:(nullable NSDictionary *)params completion:(void (^)(id _Nullable result, NSError * _Nullable error))completion;

// Unavailable initializers
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
