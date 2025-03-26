#import <UIKit/UIKit.h>

@interface ModpackInstallViewController : UITableViewController<UISearchResultsUpdating>
- (void)appendToUnifiedSearchResults:(NSArray *)newResults;
- (void)updateSearchAndRefreshUI;
@end
