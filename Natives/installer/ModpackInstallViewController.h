#import <UIKit/UIKit.h>

@interface ModpackInstallViewController : UITableViewController<UISearchResultsUpdating>
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) NSString *searchText;
@property(nonatomic, strong) UIMenu *currentMenu;
@property(nonatomic, strong) ModrinthAPI *modrinth;
@property(atomic) AFURLSessionManager *afManager;
@property(nonatomic, strong) WFWorkflowProgressView *progressView;
@property(nonatomic, strong) NSMutableDictionary *filters;
@property(nonatomic, strong) NSMutableSet *activeTagFilters;

// Data structure for organized sections
@property(nonatomic, strong) NSMutableArray<NSString *> *categories;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *visibilityList;
@property(nonatomic, strong) NSMutableArray<NSMutableArray *> *organizedModpacks;
@property(nonatomic, strong) NSMutableArray<NSMutableArray *> *filteredModpacks;

// Unified search results array (for search mode)
@property(nonatomic, strong) NSMutableArray *unifiedSearchResults;
@property(nonatomic, assign) BOOL isSearchActive;

// Tracking for current operations
@property(nonatomic, strong) NSIndexPath *currentDownloadIndexPath;
@property(atomic, assign) BOOL isDataLoading;
@property(nonatomic, strong) NSLock *dataLock;

// Infinite scroll support
@property(nonatomic, assign) BOOL isLoadingMoreResults;
@property(nonatomic, assign) BOOL hasMoreResults;

// Search results management (new methods)
- (void)appendToUnifiedSearchResults:(NSArray *)newResults;
- (void)updateSearchAndRefreshUI;
@end
