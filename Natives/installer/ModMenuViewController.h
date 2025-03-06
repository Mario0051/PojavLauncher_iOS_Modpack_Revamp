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

/**
 * Sets the default instance to use. Call after initialization to use a specific instance.
 * @param instanceName The name of the instance to use
 */
- (void)setDefaultInstance:(nullable NSString *)instanceName;

/**
 * Filters the mod list to show only mods compatible with the current profile
 * @param filterEnabled Whether to enable filtering by current profile
 */
- (void)setFilterByCurrentProfile:(BOOL)filterEnabled;

@end

NS_ASSUME_NONNULL_END
