#import <Foundation/Foundation.h>
#import "ModpackAPI.h"
#import "UnzipKit.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Modrinth API implementation for accessing mods and modpacks from Modrinth
 */
@interface ModrinthAPI : ModpackAPI

/**
 * Creates a default instance of ModrinthAPI with standard Modrinth URL
 * @return An initialized ModrinthAPI instance
 */
+ (instancetype)defaultAPI;

/**
 * Searches for mods or modpacks on Modrinth
 * @param searchFilters Dictionary of search filters
 * @param modrinthSearchResult Previous search results for pagination
 * @return Array of search results
 */
- (nullable NSMutableArray *)searchModWithFilters:(NSDictionary *)searchFilters 
                                previousPageResult:(nullable NSMutableArray *)modrinthSearchResult;

/**
 * Loads details for a mod or modpack asynchronously
 * @param item The mod or modpack to load details for
 * @param completion Block to call when the operation completes
 */
- (void)loadDetailsOfMod:(NSMutableDictionary *)item 
              completion:(void (^)(NSError * _Nullable error))completion;

/**
 * Installs a mod from the provided detail at the selected version
 * @param modDetail The mod details
 * @param selectedVersion The index of the selected version
 */
- (void)installModFromDetail:(NSDictionary *)modDetail 
                     atIndex:(NSUInteger)selectedVersion;

/**
 * Filters versions based on game version and loader compatibility
 * @param gameVersion The Minecraft version to filter for (can be nil)
 * @param loader The mod loader to filter for (can be nil)
 * @param versions Array of version dictionaries to filter
 * @return Filtered array of versions
 */
- (NSArray *)filterVersionsForGameVersion:(nullable NSString *)gameVersion 
                                   loader:(nullable NSString *)loader 
                             fromVersions:(NSArray *)versions;

/**
 * Extracts overrides from a modpack archive with progress reporting
 * @param archive The archive to extract from
 * @param destPath The destination path
 * @param progressCallback Block to call with progress updates (0.0 - 1.0)
 * @param error Pointer to an error object that will be populated on failure
 */
- (void)extractOverrides:(UZKArchive *)archive 
                  toPath:(NSString *)destPath 
            withProgress:(void (^)(double progress))progressCallback 
                   error:(NSError * __strong *)error;

/**
 * Downloads mod files from a modpack manifest
 * @param files Array of files to download
 * @param destPath Destination path for downloaded files
 * @param downloader The download task handler
 * @param completion Block to call when all downloads are complete
 */
- (void)downloadModFiles:(NSArray *)files 
               toDestPath:(NSString *)destPath 
           withDownloader:(MinecraftResourceDownloadTask *)downloader 
            andCompletion:(void (^)(void))completion;

/**
 * Finalizes modpack installation by setting up profile and completing progress
 * @param indexDict The modpack index dictionary
 * @param destPath The destination path
 * @param downloader The download task handler
 */
- (void)finalizeModpackInstallation:(NSDictionary *)indexDict 
                           destPath:(NSString *)destPath 
                         downloader:(MinecraftResourceDownloadTask *)downloader;

@end

NS_ASSUME_NONNULL_END
