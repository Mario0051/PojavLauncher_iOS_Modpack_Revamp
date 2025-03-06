#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * View controller for browsing and installing modpacks from Modrinth and CurseForge
 */
@interface ModpackInstallViewController : UITableViewController <UISearchResultsUpdating>

/**
 * Handles the installation of a modpack
 * @param details The modpack details dictionary
 * @param index The version index to install
 * @param source The source of the modpack (0 = Modrinth, 1 = CurseForge)
 */
- (void)installModpackWithDetails:(NSDictionary *)details 
                          atIndex:(NSUInteger)index 
                           source:(NSInteger)source;

@end

NS_ASSUME_NONNULL_END
