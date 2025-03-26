#import <UIKit/UIKit.h>

@interface ModpackInstallViewController : UITableViewController<UISearchResultsUpdating, UIContextMenuInteractionDelegate, UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
- (void)appendToUnifiedSearchResults:(NSArray *)newResults;
- (void)updateSearchAndRefreshUI;

// Setup methods
- (void)setupTagCollectionView;
- (void)setupSegmentedControl;
- (void)setupSearchController;
- (void)setupRefreshControl;
- (void)setupEmptyStateView;

// UI state management methods
- (void)switchToLoadingState;
- (void)switchToReadyState;

// Data loading methods
- (void)updateSearchResults;
- (void)loadSearchResultsWithPrevList:(BOOL)prevList;
- (void)loadMoreResults;
@end
