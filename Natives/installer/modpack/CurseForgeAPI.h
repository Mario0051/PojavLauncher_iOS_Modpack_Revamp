#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * CurseForge API implementation for accessing mods and modpacks from CurseForge
 */
@interface CurseForgeAPI : ModpackAPI

/**
 * Initializes the API with the provided API key
 * @param apiKey The CurseForge API key
 * @return An initialized CurseForgeAPI instance
 */
- (instancetype)initWithAPIKey:(NSString *)apiKey NS_DESIGNATED_INITIALIZER;

/**
 * Searches for mods or modpacks on CurseForge
 * @param searchFilters Dictionary of search filters
 * @param prevResult Previous search results for pagination
 * @param completion Block to call when the search completes
 */
- (void)searchModWithFilters:(NSDictionary *)searchFilters 
         previousPageResult:(nullable NSMutableArray *)prevResult 
                 completion:(void (^)(NSMutableArray * _Nullable results, NSError * _Nullable error))completion;

/**
 * Loads details for a mod or modpack
 * @param item The mod or modpack to load details for
 * @param completion Block to call when the operation completes
 */
- (void)loadDetailsOfMod:(NSMutableDictionary *)item 
              completion:(void (^)(NSError * _Nullable error))completion;

/**
 * Installs a modpack from the provided detail at the selected version
 * @param modDetail The modpack details
 * @param selectedVersion The index of the selected version
 * @param completion Block to call when the installation completes
 */
- (void)installModpackFromDetail:(NSDictionary *)modDetail 
                        atIndex:(NSUInteger)selectedVersion 
                     completion:(void (^)(NSError * _Nullable error))completion;

/**
 * Installs a mod from the provided detail at the selected version
 * @param modDetail The mod details
 * @param selectedVersion The index of the selected version
 */
- (void)installModFromDetail:(NSDictionary *)modDetail 
                     atIndex:(NSUInteger)selectedVersion;

/**
 * Auto-installs Forge for a Minecraft version
 * @param vanillaVer The Minecraft version
 * @param forgeVer The Forge version
 */
- (void)autoInstallForge:(NSString *)vanillaVer 
           loaderVersion:(NSString *)forgeVer;

/**
 * Parent view controller for displaying alerts
 */
@property (nonatomic, weak, nullable) UIViewController *parentViewController;

// Unavailable initializers
- (instancetype)initWithURL:(NSString *)url NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
