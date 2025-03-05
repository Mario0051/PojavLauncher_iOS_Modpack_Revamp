#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Modrinth API implementation for accessing mods and modpacks from Modrinth
 */
@interface ModrinthAPI : ModpackAPI

/**
 * Searches for mods or modpacks on Modrinth
 * @param searchFilters Dictionary of search filters
 * @param modrinthSearchResult Previous search results for pagination
 * @return Array of search results
 */
- (nullable NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters 
                                previousPageResult:(nullable NSMutableArray *)modrinthSearchResult;

/**
 * Synchronously loads details for a mod or modpack
 * @param item The mod or modpack to load details for
 */
- (void)loadDetailsOfModSync:(NSMutableDictionary *)item;

/**
 * Asynchronously loads details for a mod or modpack
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

@end

NS_ASSUME_NONNULL_END
