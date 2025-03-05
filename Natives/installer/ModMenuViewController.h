#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * View controller for browsing and installing mods from repositories
 */
@interface ModMenuViewController : UITableViewController <UISearchResultsUpdating>

/**
 * Updates the mod list based on current search filters
 */
- (void)updateModsList;

/**
 * Shows the mod installation queue
 */
- (void)actionShowQueue;

/**
 * Presents a profile selection dialog
 */
- (void)actionChooseProfile;

/**
 * Handles the installation of a mod
 * @param mod The mod to install
 * @param index The version index to install
 */
- (void)installModNow:(NSDictionary *)mod versionIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
