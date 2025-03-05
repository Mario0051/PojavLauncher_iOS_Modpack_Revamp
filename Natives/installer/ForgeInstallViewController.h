#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * View controller for installing Forge and NeoForge mod loaders
 */
@interface ForgeInstallViewController : UITableViewController <NSXMLParserDelegate>

/**
 * Handles user selection of a Forge version
 */
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;

/**
 * Handles tap on section headers to expand/collapse them
 */
- (void)tableViewDidSelectSection:(UITapGestureRecognizer *)sender;

/**
 * Changes between Forge and NeoForge repositories
 */
- (void)segmentChanged:(UISegmentedControl *)segment;

/**
 * Cancels ongoing downloads
 */
- (void)actionCancelDownload;

/**
 * Closes the installation view
 */
- (void)actionClose;

@end

NS_ASSUME_NONNULL_END
