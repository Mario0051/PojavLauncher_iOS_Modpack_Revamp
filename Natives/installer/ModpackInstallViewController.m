#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "ModpackInstallViewController.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "WFWorkflowProgressView.h"
#import "modpack/ModrinthAPI.h"
#import "config.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <dlfcn.h>

#pragma mark - Custom Cell Definition

// Custom cell for modpack display
@interface ModpackVersionCell : UITableViewCell
@property (nonatomic, strong) UIImageView *modpackIconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *categoryLabel;
@property (nonatomic, strong) UIView *categoryTagView;
@end

@implementation ModpackVersionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        // Container view with proper insets
        UIView *containerView = [[UIView alloc] init];
        containerView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:containerView];
        
        // Modpack icon - circular with auto sizing
        self.modpackIconView = [[UIImageView alloc] init];
        self.modpackIconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.modpackIconView.contentMode = UIViewContentModeScaleAspectFill;
        self.modpackIconView.clipsToBounds = YES;
        self.modpackIconView.layer.cornerRadius = 20; // Will be a circle with size constraints
        self.modpackIconView.backgroundColor = [UIColor systemGray6Color];
        [containerView addSubview:self.modpackIconView];
        
        // Title label (main title) - bolder font
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [containerView addSubview:self.titleLabel];
        
        // Subtitle label - smaller, secondary text
        self.subtitleLabel = [[UILabel alloc] init];
        self.subtitleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
        self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.subtitleLabel.numberOfLines = 2;
        [containerView addSubview:self.subtitleLabel];
        
        // Category tag background - rounded rect with color
        self.categoryTagView = [[UIView alloc] init];
        self.categoryTagView.layer.cornerRadius = 8;
        self.categoryTagView.translatesAutoresizingMaskIntoConstraints = NO;
        self.categoryTagView.backgroundColor = [UIColor systemBlueColor];
        [containerView addSubview:self.categoryTagView];
        
        // Category label - white text on tag
        self.categoryLabel = [[UILabel alloc] init];
        self.categoryLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        self.categoryLabel.textColor = [UIColor whiteColor];
        self.categoryLabel.textAlignment = NSTextAlignmentCenter;
        self.categoryLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.categoryTagView addSubview:self.categoryLabel];
        
        // Add disclosure indicator
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        
        // Container view constraints - full content view with padding
        [NSLayoutConstraint activateConstraints:@[
            [containerView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
            [containerView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
            [containerView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [containerView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16]
        ]];
        
        // Icon constraints - fixed size and positioned at start
        [NSLayoutConstraint activateConstraints:@[
            [self.modpackIconView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor],
            [self.modpackIconView.centerYAnchor constraintEqualToAnchor:containerView.centerYAnchor],
            [self.modpackIconView.widthAnchor constraintEqualToConstant:40],
            [self.modpackIconView.heightAnchor constraintEqualToConstant:40]
        ]];
        
        // Title label constraints - positioned after icon
        [NSLayoutConstraint activateConstraints:@[
            [self.titleLabel.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:2],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.modpackIconView.trailingAnchor constant:12],
            [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.categoryTagView.leadingAnchor constant:-8]
        ]];
        
        // Subtitle label constraints - below title
        [NSLayoutConstraint activateConstraints:@[
            [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
            [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
            [self.subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:containerView.bottomAnchor constant:-2]
        ]];
        
        // Category tag constraints - fixed size at trailing edge
        [NSLayoutConstraint activateConstraints:@[
            [self.categoryTagView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor],
            [self.categoryTagView.centerYAnchor constraintEqualToAnchor:containerView.centerYAnchor],
            [self.categoryTagView.widthAnchor constraintEqualToConstant:70],
            [self.categoryTagView.heightAnchor constraintEqualToConstant:24]
        ]];
        
        // Category label constraints - fill tag
        [NSLayoutConstraint activateConstraints:@[
            [self.categoryLabel.leadingAnchor constraintEqualToAnchor:self.categoryTagView.leadingAnchor constant:4],
            [self.categoryLabel.trailingAnchor constraintEqualToAnchor:self.categoryTagView.trailingAnchor constant:-4],
            [self.categoryLabel.topAnchor constraintEqualToAnchor:self.categoryTagView.topAnchor],
            [self.categoryLabel.bottomAnchor constraintEqualToAnchor:self.categoryTagView.bottomAnchor]
        ]];
    }
    return self;
}

@end

#pragma mark - Section Header View Definition

// Custom header view for modpack categories
@interface ModpackCategoryHeaderView : UITableViewHeaderFooterView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIImageView *chevronImageView;
@property (nonatomic, strong) UIButton *expandCollapseButton;
@property (nonatomic, assign) BOOL isExpanded;
@end

@implementation ModpackCategoryHeaderView

- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithReuseIdentifier:reuseIdentifier];
    if (self) {
        // Create a container view with background
        UIView *containerView = [[UIView alloc] init];
        containerView.backgroundColor = [UIColor systemGroupedBackgroundColor];
        containerView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:containerView];
        
        // Title label - large, bold font
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [containerView addSubview:self.titleLabel];
        
        // Chevron indicator - rotates on expand/collapse
        self.chevronImageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        self.chevronImageView.tintColor = [UIColor systemGrayColor];
        self.chevronImageView.translatesAutoresizingMaskIntoConstraints = NO;
        self.chevronImageView.contentMode = UIViewContentModeScaleAspectFit;
        [containerView addSubview:self.chevronImageView];
        
        // Button covering the entire header - for expansion/collapse
        self.expandCollapseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.expandCollapseButton.translatesAutoresizingMaskIntoConstraints = NO;
        self.expandCollapseButton.backgroundColor = [UIColor clearColor];
        [containerView addSubview:self.expandCollapseButton];
        
        // Constraints for container view (full size)
        [NSLayoutConstraint activateConstraints:@[
            [containerView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [containerView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [containerView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [containerView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor]
        ]];
        
        // Constraints for title label
        [NSLayoutConstraint activateConstraints:@[
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:16],
            [self.titleLabel.centerYAnchor constraintEqualToAnchor:containerView.centerYAnchor],
            [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.chevronImageView.leadingAnchor constant:-16]
        ]];
        
        // Constraints for chevron
        [NSLayoutConstraint activateConstraints:@[
            [self.chevronImageView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-16],
            [self.chevronImageView.centerYAnchor constraintEqualToAnchor:containerView.centerYAnchor],
            [self.chevronImageView.widthAnchor constraintEqualToConstant:20],
            [self.chevronImageView.heightAnchor constraintEqualToConstant:20]
        ]];
        
        // Constraints for button (covers the whole area)
        [NSLayoutConstraint activateConstraints:@[
            [self.expandCollapseButton.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor],
            [self.expandCollapseButton.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor],
            [self.expandCollapseButton.topAnchor constraintEqualToAnchor:containerView.topAnchor],
            [self.expandCollapseButton.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor]
        ]];
    }
    return self;
}

- (void)setIsExpanded:(BOOL)isExpanded {
    _isExpanded = isExpanded;
    
    // Animate chevron rotation
    [UIView animateWithDuration:0.3 animations:^{
        self.chevronImageView.transform = isExpanded ? 
            CGAffineTransformMakeRotation(M_PI_2) : CGAffineTransformIdentity;
    }];
}

@end

#pragma mark - View Controller Implementation

@interface ModpackInstallViewController()<UIContextMenuInteractionDelegate, UIPopoverPresentationControllerDelegate>
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) NSString *searchText;
@property(nonatomic, strong) UIMenu *currentMenu;
@property(nonatomic, strong) ModrinthAPI *modrinth;
@property(nonatomic, atomic) AFURLSessionManager *afManager;
@property(nonatomic, strong) WFWorkflowProgressView *progressView;
@property(nonatomic, strong) NSMutableDictionary *filters;

// Data structure for organized sections
@property(nonatomic, strong) NSMutableArray<NSString *> *categories;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *visibilityList;
@property(nonatomic, strong) NSMutableArray<NSMutableArray *> *organizedModpacks;
@property(nonatomic, strong) NSMutableArray<NSMutableArray *> *filteredModpacks;

// Tracking for current operations
@property(nonatomic, strong) NSIndexPath *currentDownloadIndexPath;
@property(atomic, assign) BOOL isDataLoading;
@property(nonatomic, strong) NSLock *dataLock;
@end

@implementation ModpackInstallViewController

#pragma mark - Initialization Methods

- (instancetype)init {
    return [self initWithStyle:UITableViewStylePlain];
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    self = [super initWithStyle:UITableViewStylePlain];
    return self;
}

#pragma mark - Lifecycle Methods

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Configure table view appearance
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }
    
    // Configure proper insets for navigation and search
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    
    // Ensure the table view doesn't scroll under the navigation bar
    self.extendedLayoutIncludesOpaqueBars = NO;
    self.edgesForExtendedLayout = UIRectEdgeNone;
    
    // Register custom cell and header view
    [self.tableView registerClass:[ModpackVersionCell class] forCellReuseIdentifier:@"ModpackVersionCell"];
    [self.tableView registerClass:[ModpackCategoryHeaderView class] forHeaderFooterViewReuseIdentifier:@"ModpackCategoryHeader"];
    
    // Title for the view controller
    self.title = localize(@"launcher.menu.modpacks", nil);
    
    // Setup category filter - segmented control
    UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:@[
        localize(@"All", nil),
        localize(@"Popular", nil),
        localize(@"Updated", nil)
    ]];
    segment.selectedSegmentIndex = 0;
    [segment addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = segment;
    
    // Setup search controller
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = localize(@"Search modpacks", nil);
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    
    // Setup refresh control
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(refreshModpacks) forControlEvents:UIControlEventValueChanged];
    [self.tableView addSubview:self.refreshControl];
    
    // Load WorkflowProgressView for download progress
    dlopen("/System/Library/PrivateFrameworks/WorkflowUIServices.framework/WorkflowUIServices", RTLD_GLOBAL);
    self.progressView = [[NSClassFromString(@"WFWorkflowProgressView") alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    self.progressView.resolvedTintColor = self.view.tintColor;
    [self.progressView addTarget:self action:@selector(actionCancelDownload) forControlEvents:UIControlEventTouchUpInside];
    
    // Initialize modrinth API
    self.modrinth = [ModrinthAPI new];
    
    // Initialize data structures with thread safety
    self.categories = [NSMutableArray new];
    self.visibilityList = [NSMutableArray new];
    self.organizedModpacks = [NSMutableArray new];
    self.filteredModpacks = [NSMutableArray new];
    self.isDataLoading = NO;
    self.dataLock = [[NSLock alloc] init];
    
    // Setup default filters
    self.filters = @{
        @"isModpack": @(YES),
        @"name": @" "
    }.mutableCopy;
    
    // Load initial data
    [self updateSearchResults];
}

#pragma mark - Action Methods

- (void)actionCancelDownload {
    // Reset the current download cell's appearance
    if (self.currentDownloadIndexPath) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:self.currentDownloadIndexPath];
        if (cell) {
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        self.currentDownloadIndexPath = nil;
    }
    
    [self.afManager invalidateSessionCancelingTasks:YES resetSession:NO];
    showDialog(@"Download Cancelled", @"The download has been cancelled.");
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)segmentChanged:(UISegmentedControl *)segment {
    // Reset search if active
    if (self.searchController.isActive) {
        [self.searchController dismissViewControllerAnimated:YES completion:nil];
    }
    
    // Clear the current results
    [self.organizedModpacks removeAllObjects];
    [self.filteredModpacks removeAllObjects];
    [self.categories removeAllObjects];
    [self.visibilityList removeAllObjects];
    
    // Update filter based on segment
    NSString *sortMethod;
    switch (segment.selectedSegmentIndex) {
        case 1: // Popular
            sortMethod = @"downloads";
            break;
        case 2: // Updated
            sortMethod = @"updated";
            break;
        default: // All (default)
            sortMethod = @"relevance";
            break;
    }
    
    // Update the filter
    self.filters[@"sortMethod"] = sortMethod;
    
    // Reload data with new filter
    [self updateSearchResults];
}

- (void)refreshModpacks {
    // Reload with current filter settings
    [self updateSearchResults];
}

#pragma mark - Data Loading

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    NSString *name = self.searchController.searchBar.text;
    if (!prevList && [self.filters[@"name"] isEqualToString:name]) {
        return;
    }

    [self switchToLoadingState];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        self.filters[@"name"] = name;
        NSMutableArray *newResults = [self.modrinth searchModWithFilters:self.filters previousPageResult:prevList ? self.organizeByCategory : nil];
        
        if (newResults) {
            // If we're not appending, reorganize completely
            if (!prevList) {
                [self organizeModpacksByCategory:newResults];
            } else {
                // If appending, just update our existing organization
                [self updateOrganizedModpacks:newResults];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self switchToReadyState];
                [self.tableView reloadData];
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                showDialog(localize(@"Error", nil), self.modrinth.lastError.localizedDescription);
                [self actionClose];
            });
        }
    });
}

- (void)updateSearchResults {
    [self loadSearchResultsWithPrevList:NO];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateSearchResults) object:nil];
    [self performSelector:@selector(updateSearchResults) withObject:nil afterDelay:0.5];
}

#pragma mark - UI State Management

- (void)switchToLoadingState {
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    [indicator startAnimating];
    self.navigationController.modalInPresentation = YES;
    self.tableView.allowsSelection = NO;
    
    self.isDataLoading = YES;
}

- (void)switchToReadyState {
    UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItem.customView;
    [indicator stopAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationController.modalInPresentation = NO;
    self.tableView.allowsSelection = YES;
    [self.refreshControl endRefreshing];
    
    self.isDataLoading = NO;
}

#pragma mark - Data Organization

- (void)organizeModpacksByCategory:(NSArray *)modpacks {
    [self.dataLock lock];
    
    // Clear previous data
    [self.categories removeAllObjects];
    [self.visibilityList removeAllObjects];
    [self.organizedModpacks removeAllObjects];
    [self.filteredModpacks removeAllObjects];
    
    // If no modpacks, add empty category
    if (modpacks.count == 0) {
        [self.categories addObject:localize(@"No Results", nil)];
        [self.visibilityList addObject:@YES];
        [self.organizedModpacks addObject:[NSMutableArray array]];
        [self.filteredModpacks addObject:[NSMutableArray array]];
        [self.dataLock unlock];
        return;
    }
    
    // Create dictionary to group modpacks by category
    NSMutableDictionary *categorizedModpacks = [NSMutableDictionary dictionary];
    
    // Default categories for organization
    NSArray *defaultCategories = @[
        localize(@"Featured Modpacks", nil),
        localize(@"Magic Modpacks", nil),
        localize(@"Tech Modpacks", nil),
        localize(@"Adventure Modpacks", nil),
        localize(@"Other Modpacks", nil)
    ];
    
    // Initialize categories
    for (NSString *category in defaultCategories) {
        categorizedModpacks[category] = [NSMutableArray array];
    }
    
    // Assign modpacks to categories based on some criteria
    // This is a simplified example - in real implementation, you'd want to 
    // use actual modpack categories from the API response
    for (NSDictionary *modpack in modpacks) {
        NSString *title = modpack[@"title"];
        NSString *description = modpack[@"description"];
        
        // Simple categorization based on title/description keywords
        // In a real implementation, use category data from the API
        NSString *category;
        
        if ([title containsString:@"Magic"] || 
            [description containsString:@"Magic"] ||
            [title containsString:@"Wizard"] ||
            [description containsString:@"Wizard"]) {
            category = localize(@"Magic Modpacks", nil);
        }
        else if ([title containsString:@"Tech"] || 
                [description containsString:@"Tech"] ||
                [title containsString:@"Machine"] ||
                [description containsString:@"Machine"]) {
            category = localize(@"Tech Modpacks", nil);
        }
        else if ([title containsString:@"Adventure"] || 
                [description containsString:@"Adventure"] ||
                [title containsString:@"Quest"] ||
                [description containsString:@"Quest"]) {
            category = localize(@"Adventure Modpacks", nil);
        }
        else {
            category = localize(@"Other Modpacks", nil);
        }
        
        // Add to appropriate category
        [categorizedModpacks[category] addObject:modpack];
    }
    
    // Feature the first few modpacks regardless of category
    NSMutableArray *featuredModpacks = [NSMutableArray array];
    int featuredCount = MIN(5, modpacks.count);
    for (int i = 0; i < featuredCount; i++) {
        [featuredModpacks addObject:modpacks[i]];
    }
    categorizedModpacks[localize(@"Featured Modpacks", nil)] = featuredModpacks;
    
    // Build the final organized arrays
    for (NSString *category in defaultCategories) {
        NSMutableArray *modpacksInCategory = categorizedModpacks[category];
        
        // Only add non-empty categories
        if (modpacksInCategory.count > 0) {
            [self.categories addObject:category];
            [self.visibilityList addObject:@(YES)]; // Start expanded by default
            [self.organizedModpacks addObject:modpacksInCategory];
            [self.filteredModpacks addObject:[modpacksInCategory mutableCopy]];
        }
    }
    
    [self.dataLock unlock];
}

- (void)updateOrganizedModpacks:(NSArray *)newModpacks {
    [self.dataLock lock];
    
    // For simplicity, we'll just add all new modpacks to the "Other" category
    // In a real implementation, you'd categorize them properly
    NSString *otherCategory = localize(@"Other Modpacks", nil);
    
    // Find or create the "Other" category
    NSUInteger otherIndex = [self.categories indexOfObject:otherCategory];
    if (otherIndex == NSNotFound) {
        [self.categories addObject:otherCategory];
        [self.visibilityList addObject:@YES];
        [self.organizedModpacks addObject:[NSMutableArray array]];
        [self.filteredModpacks addObject:[NSMutableArray array]];
        otherIndex = self.categories.count - 1;
    }
    
    // Add new modpacks to the "Other" category
    [self.organizedModpacks[otherIndex] addObjectsFromArray:newModpacks];
    [self.filteredModpacks[otherIndex] addObjectsFromArray:newModpacks];
    
    [self.dataLock unlock];
}

#pragma mark - UIContextMenu

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location
{
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        return self.currentMenu;
    }];
}

- (_UIContextMenuStyle *)_contextMenuInteraction:(UIContextMenuInteraction *)interaction styleForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration
{
    _UIContextMenuStyle *style = [_UIContextMenuStyle defaultStyle];
    style.preferredLayout = 3; // _UIContextMenuLayoutCompactMenu
    return style;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (self.isDataLoading) {
        return 1; // Show a single section with loading indicator
    }
    
    [self.dataLock lock];
    NSInteger count = self.categories.count;
    [self.dataLock unlock];
    
    return count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.isDataLoading) {
        return 1; // Show a single loading row
    }
    
    [self.dataLock lock];
    
    // Add bounds checking
    if (section >= self.visibilityList.count) {
        [self.dataLock unlock];
        return 0;
    }
    
    NSInteger rows = 0;
    
    if (self.visibilityList[section].boolValue) {
        if (self.searchController.isActive && self.searchText.length > 0) {
            if (section < self.filteredModpacks.count) {
                rows = self.filteredModpacks[section].count;
            }
        } else {
            if (section < self.organizedModpacks.count) {
                rows = self.organizedModpacks[section].count;
            }
        }
    }
    
    [self.dataLock unlock];
    return rows > 0 ? rows : 1; // Always show at least one row (for "No results" message)
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    ModpackCategoryHeaderView *headerView = [tableView dequeueReusableHeaderFooterViewWithIdentifier:@"ModpackCategoryHeader"];
    
    // Return a loading header if data is still loading
    if (self.isDataLoading) {
        headerView.titleLabel.text = localize(@"Loading modpacks...", nil);
        headerView.isExpanded = NO;
        headerView.expandCollapseButton.tag = section;
        [headerView.expandCollapseButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        return headerView;
    }
    
    [self.dataLock lock];
    
    // Add bounds checking
    if (section >= self.categories.count || self.categories.count == 0) {
        [self.dataLock unlock];
        headerView.titleLabel.text = localize(@"No Results", nil);
        headerView.isExpanded = NO;
        headerView.expandCollapseButton.tag = section;
        [headerView.expandCollapseButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        return headerView;
    }
    
    // Apply section title
    headerView.titleLabel.text = self.categories[section];
    
    // Set expanded state
    if (section < self.visibilityList.count) {
        headerView.isExpanded = self.visibilityList[section].boolValue;
    } else {
        headerView.isExpanded = NO;
    }
    
    [self.dataLock unlock];
    
    // Store section index
    headerView.expandCollapseButton.tag = section;
    
    // Add action for the button
    [headerView.expandCollapseButton addTarget:self action:@selector(toggleSection:) forControlEvents:UIControlEventTouchUpInside];
    
    return headerView;
}

- (void)toggleSection:(UIButton *)sender {
    if (self.isDataLoading) {
        return;
    }
    
    NSInteger section = sender.tag;
    
    [self.dataLock lock];
    
    if (section >= 0 && section < self.visibilityList.count && self.categories.count > section) {
        // Toggle section visibility
        self.visibilityList[section] = @(!self.visibilityList[section].boolValue);
        
        [self.dataLock unlock];
        
        // Update section
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationFade];
    } else {
        [self.dataLock unlock];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 60.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 80.0; // Taller than ForgeInstallViewController for more modpack details
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModpackVersionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModpackVersionCell" forIndexPath:indexPath];
    
    // If data is loading, return a placeholder cell
    if (self.isDataLoading) {
        cell.titleLabel.text = localize(@"Loading modpacks...", nil);
        cell.subtitleLabel.text = @"";
        cell.categoryLabel.text = @"";
        cell.categoryTagView.backgroundColor = [UIColor clearColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
        
        // Add activity indicator as accessory view
        UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [activityIndicator startAnimating];
        cell.accessoryView = activityIndicator;
        
        return cell;
    }
    
    [self.dataLock lock];
    
    // Add bounds checking
    BOOL outOfBounds = NO;
    NSArray *currentList;
    
    if (self.searchController.isActive && self.searchText.length > 0) {
        currentList = self.filteredModpacks;
    } else {
        currentList = self.organizedModpacks;
    }
    
    outOfBounds = (indexPath.section >= currentList.count || 
                  (indexPath.section < currentList.count && 
                   indexPath.row >= [currentList[indexPath.section] count]));
    
    if (outOfBounds || [currentList[indexPath.section] count] == 0) {
        [self.dataLock unlock];
        
        // Return an empty state cell
        cell.titleLabel.text = localize(@"No modpacks found", nil);
        cell.subtitleLabel.text = localize(@"Try changing your search criteria", nil);
        cell.categoryLabel.text = @"";
        cell.categoryTagView.backgroundColor = [UIColor clearColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.modpackIconView.image = [UIImage systemImageNamed:@"cube.box"];
        cell.modpackIconView.tintColor = [UIColor systemGray3Color];
        
        return cell;
    }
    
    // Get the modpack data
    NSDictionary *modpack = currentList[indexPath.section][indexPath.row];
    
    // Make a copy to use after releasing the lock
    NSString *title = [modpack[@"title"] copy] ?: @"Unknown";
    NSString *description = [modpack[@"description"] copy] ?: @"";
    NSString *imageUrl = [modpack[@"imageUrl"] copy] ?: @"";
    BOOL detailsLoaded = [modpack[@"versionDetailsLoaded"] boolValue];
    
    [self.dataLock unlock];
    
    // Update the cell with modpack data
    cell.titleLabel.text = title;
    cell.subtitleLabel.text = description;
    
    // Set category tag based on section
    NSString *category;
    [self.dataLock lock];
    if (indexPath.section < self.categories.count) {
        category = self.categories[indexPath.section];
    } else {
        category = @"Modpack";
    }
    [self.dataLock unlock];
    
    // Set tag color based on category
    UIColor *tagColor;
    if ([category containsString:@"Featured"]) {
        tagColor = [UIColor systemPurpleColor];
    } else if ([category containsString:@"Magic"]) {
        tagColor = [UIColor systemBlueColor];
    } else if ([category containsString:@"Tech"]) {
        tagColor = [UIColor systemOrangeColor];
    } else if ([category containsString:@"Adventure"]) {
        tagColor = [UIColor systemGreenColor];
    } else {
        tagColor = [UIColor systemGrayColor];
    }
    
    // Set tag appearance
    cell.categoryTagView.backgroundColor = tagColor;
    cell.categoryLabel.text = [category componentsSeparatedByString:@" "][0]; // First word only
    
    // Set modpack icon
    UIImage *fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    if (imageUrl.length > 0) {
        [cell.modpackIconView setImageWithURL:[NSURL URLWithString:imageUrl] 
                             placeholderImage:fallbackImage];
    } else {
        cell.modpackIconView.image = fallbackImage;
    }
    
    // Set accessory based on whether details are loaded
    cell.accessoryType = detailsLoaded ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    if (!detailsLoaded) {
        UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [activityIndicator startAnimating];
        cell.accessoryView = activityIndicator;
    } else {
        cell.accessoryView = nil;
    }
    
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    // Skip if data is still loading or if no sections
    if (self.isDataLoading || self.categories.count == 0) {
        return;
    }
    
    [self.dataLock lock];
    
    // Check bounds and get modpack list
    NSArray *currentList;
    if (self.searchController.isActive && self.searchText.length > 0) {
        currentList = self.filteredModpacks;
    } else {
        currentList = self.organizedModpacks;
    }
    
    // Add bounds checking
    BOOL outOfBounds = (indexPath.section >= currentList.count || 
                      (indexPath.section < currentList.count && 
                       indexPath.row >= [currentList[indexPath.section] count]));
    
    if (outOfBounds || [currentList[indexPath.section] count] == 0) {
        [self.dataLock unlock];
        return;
    }
    
    // Get the modpack
    NSDictionary *modpack = currentList[indexPath.section][indexPath.row];
    
    // Check if details already loaded
    if ([modpack[@"versionDetailsLoaded"] boolValue]) {
        // Make a copy to use after releasing the lock
        NSDictionary *modpackCopy = [modpack copy];
        [self.dataLock unlock];
        
        // Show version selection menu
        [self showVersionMenu:modpackCopy atIndexPath:indexPath];
    } else {
        // Make a copy and unlock
        NSMutableDictionary *modpackCopy = [modpack mutableCopy];
        [self.dataLock unlock];
        
        // Load details first
        [self loadModpackDetails:modpackCopy atIndexPath:indexPath];
    }
}

- (void)loadModpackDetails:(NSMutableDictionary *)modpack atIndexPath:(NSIndexPath *)indexPath {
    // Show loading indicator
    ModpackVersionCell *cell = (ModpackVersionCell *)[self.tableView cellForRowAtIndexPath:indexPath];
    UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [activityIndicator startAnimating];
    cell.accessoryView = activityIndicator;
    cell.accessoryType = UITableViewCellAccessoryNone;
    
    // Load details in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.modrinth loadDetailsOfMod:modpack];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Update cell to use disclosure indicator
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            
            // Update data model - find the modpack in all lists and update it
            [self.dataLock lock];
            
            for (NSMutableArray *category in self.organizedModpacks) {
                for (NSInteger i = 0; i < category.count; i++) {
                    if ([category[i][@"id"] isEqual:modpack[@"id"]]) {
                        category[i] = modpack;
                    }
                }
            }
            
            for (NSMutableArray *category in self.filteredModpacks) {
                for (NSInteger i = 0; i < category.count; i++) {
                    if ([category[i][@"id"] isEqual:modpack[@"id"]]) {
                        category[i] = modpack;
                    }
                }
            }
            
            [self.dataLock unlock];
            
            // Show version menu if details loaded successfully
            if ([modpack[@"versionDetailsLoaded"] boolValue]) {
                [self showVersionMenu:modpack atIndexPath:indexPath];
            } else {
                showDialog(localize(@"Error", nil), self.modrinth.lastError.localizedDescription);
            }
        });
    });
}

- (void)showVersionMenu:(NSDictionary *)modpack atIndexPath:(NSIndexPath *)indexPath {
    ModpackVersionCell *cell = (ModpackVersionCell *)[self.tableView cellForRowAtIndexPath:indexPath];
    
    NSMutableArray<UIAction *> *menuItems = [[NSMutableArray alloc] init];
    [modpack[@"versionNames"] enumerateObjectsUsingBlock:
    ^(NSString *name, NSUInteger i, BOOL *stop) {
        NSString *nameWithVersion = name;
        NSString *mcVersion = modpack[@"mcVersionNames"][i];
        if (![name hasSuffix:mcVersion]) {
            nameWithVersion = [NSString stringWithFormat:@"%@ - %@", name, mcVersion];
        }
        [menuItems addObject:[UIAction
            actionWithTitle:nameWithVersion
            image:nil identifier:nil
            handler:^(UIAction *action) {
                [self actionClose];
                NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
                [UIImagePNGRepresentation([cell.modpackIconView.image _imageWithSize:CGSizeMake(40, 40)]) writeToFile:tmpIconPath atomically:YES];
                [self.modrinth installModpackFromDetail:modpack atIndex:i];
            }]];
    }];
    
    self.currentMenu = [UIMenu menuWithTitle:modpack[@"title"] children:menuItems];
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    cell.interactions = @[interaction];
    [interaction _presentMenuAtLocation:CGPointZero];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    // Store the search text
    self.searchText = searchController.searchBar.text;
    
    // If we're currently loading data, don't do anything
    if (self.isDataLoading) {
        return;
    }
    
    // If search is active with non-empty text, filter results
    if (searchController.isActive && self.searchText.length > 0) {
        [self filterModpacksWithSearchText:self.searchText];
    } else {
        // Reset filtered results to match original
        [self resetFilteredModpacks];
    }
    
    // Reload the table view to show filtered results
    [self.tableView reloadData];
}

- (void)filterModpacksWithSearchText:(NSString *)searchText {
    [self.dataLock lock];
    
    // Clear existing filtered results
    [self.filteredModpacks removeAllObjects];
    
    // For each category, filter the modpacks
    for (NSUInteger i = 0; i < self.organizedModpacks.count; i++) {
        NSMutableArray *categoryModpacks = self.organizedModpacks[i];
        NSMutableArray *filteredCategoryModpacks = [NSMutableArray array];
        
        // Filter by title or description
        for (NSDictionary *modpack in categoryModpacks) {
            NSString *title = modpack[@"title"] ?: @"";
            NSString *description = modpack[@"description"] ?: @"";
            
            if ([title localizedCaseInsensitiveContainsString:searchText] ||
                [description localizedCaseInsensitiveContainsString:searchText]) {
                [filteredCategoryModpacks addObject:modpack];
            }
        }
        
        // Add this category's filtered results
        [self.filteredModpacks addObject:filteredCategoryModpacks];
        
        // Expand any category with matching results
        if (filteredCategoryModpacks.count > 0 && i < self.visibilityList.count) {
            self.visibilityList[i] = @YES;
        }
    }
    
    [self.dataLock unlock];
}

- (void)resetFilteredModpacks {
    [self.dataLock lock];
    
    // Clear and recreate filtered lists from original lists
    [self.filteredModpacks removeAllObjects];
    
    for (NSMutableArray *categoryModpacks in self.organizedModpacks) {
        [self.filteredModpacks addObject:[categoryModpacks mutableCopy]];
    }
    
    [self.dataLock unlock];
}

@end
