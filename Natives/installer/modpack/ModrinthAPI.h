#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Modrinth API implementation for accessing mods and modpacks from Modrinth
 */
@interface ModrinthAPI : ModpackAPI

/**
 * Initializes a Modrinth API instance with the default base URL
 * @return An initialized ModrinthAPI instance
 */
+ (instancetype)defaultAPI;

/**
 * Filters versions based on game version and loader compatibility
 * @param gameVersion The Minecraft version to filter by
 * @param loader The mod loader to filter by
 * @param versions The array of versions to filter
 * @return An array of versions that match the filters
 */
- (NSArray *)filterVersionsForGameVersion:(nullable NSString *)gameVersion 
                                   loader:(nullable NSString *)loader 
                             fromVersions:(NSArray *)versions;

/**
 * Encodes a search query for URL transmission
 * @param query The raw search query
 * @return The URL-encoded search query
 */
- (NSString *)encodedSearchQuery:(NSString *)query;

/**
 * Creates facets JSON for advanced search
 * @param filters The search filters
 * @return A JSON string representing the search facets
 */
- (NSString *)createFacetsJSON:(NSDictionary *)filters;

@end

NS_ASSUME_NONNULL_END
