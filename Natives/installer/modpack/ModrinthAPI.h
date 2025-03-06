#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

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

@end

NS_ASSUME_NONNULL_END
