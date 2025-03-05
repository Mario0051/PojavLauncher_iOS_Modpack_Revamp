#import <UIKit/UIKit.h>

@interface ModpackInstallViewController : UITableViewController<UISearchResultsUpdating>

/**
 * Handles the installation of a modpack
 * @param details The modpack details
 * @param index The version index to install
 */
- (void)installModpackFromDetail:(NSDictionary *)details atIndex:(NSUInteger)index;

@end
