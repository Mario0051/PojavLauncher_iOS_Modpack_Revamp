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
@property (nonatomic, strong) UIScrollView *tagsScrollView;
@property (nonatomic, strong) NSMutableArray<UIView *> *tagViews;
@end

@implementation ModpackVersionCell

// Helper method for WebP URL conversion
- (NSString *)convertWebPUrl:(NSString *)imageUrl {
    if (!imageUrl || imageUrl.length == 0) {
        return imageUrl;
    }
    
    // Handle WebP format by requesting PNG instead
    if ([imageUrl.lowercaseString hasSuffix:@".webp"]) {
        // Try one of several approaches:
        
        // 1. For Modrinth CDN: Add format=png parameter
        if ([imageUrl containsString:@"cdn.modrinth.com"]) {
            // Check if URL already has parameters
            if ([imageUrl containsString:@"?"]) {
                return [imageUrl stringByAppendingString:@"&format=png"];
            } else {
                return [imageUrl stringByAppendingString:@"?format=png"];
            }
        }
        
        // 2. For other services: Try changing extension
        return [imageUrl stringByReplacingOccurrencesOfString:@".webp" 
                                                   withString:@".png" 
                                                      options:NSCaseInsensitiveSearch 
                                                        range:NSMakeRange(0, imageUrl.length)];
    }
    
    return imageUrl;
}

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
        
        // Tags scroll view - for multiple category tags
        self.tagsScrollView = [[UIScrollView alloc] init];
        self.tagsScrollView.translatesAutoresizingMaskIntoConstraints = NO;
        self.tagsScrollView.showsHorizontalScrollIndicator = NO;
        self.tagsScrollView.showsVerticalScrollIndicator = NO;
        self.tagsScrollView.clipsToBounds = YES;
        [containerView addSubview:self.tagsScrollView];
        
        // Initialize tag views array
        self.tagViews = [NSMutableArray array];
        
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
            [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:containerView.trailingAnchor constant:-8]
        ]];
        
        // Subtitle label constraints - below title
        [NSLayoutConstraint activateConstraints:@[
            [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
            [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor]
        ]];
        
        // Tags scroll view constraints
        [NSLayoutConstraint activateConstraints:@[
            [self.tagsScrollView.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor constant:4],
            [self.tagsScrollView.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.tagsScrollView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor],
            [self.tagsScrollView.heightAnchor constraintEqualToConstant:24],
            [self.tagsScrollView.bottomAnchor constraintLessThanOrEqualToAnchor:containerView.bottomAnchor constant:-2]
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    
    // Reset the image view to avoid image flicker between cells
    // First cancel any active download to prevent callback race conditions
    if (self.modpackIconView) {
        [self.modpackIconView cancelImageDownloadTask];
        self.modpackIconView.image = nil;
    }
    
    // Reset the title and subtitle to ensure they're cleared for reuse
    if (self.titleLabel) {
        self.titleLabel.text = nil;
        self.titleLabel.attributedText = nil;
    }
    
    if (self.subtitleLabel) {
        self.subtitleLabel.text = nil;
    }
    
    // Clear existing tag views
    for (UIView *tagView in self.tagViews) {
        [tagView removeFromSuperview];
    }
    [self.tagViews removeAllObjects];
    
    // Reset the scroll view content size
    if (self.tagsScrollView) {
        self.tagsScrollView.contentSize = CGSizeZero;
    }
    
    // Reset accessory view if needed
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    self.accessoryView = nil;
}

- (UIColor *)colorForTag:(NSString *)tag {
    // Enhanced category color mapping with semantically appropriate colors
    static NSDictionary *tagColors = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tagColors = @{
            // Core gameplay categories
            @"adventure": [UIColor systemGreenColor],          // Green: exploration, nature
            @"challenging": [UIColor systemRedColor],          // Red: danger, difficulty
            @"combat": [UIColor systemOrangeColor],            // Orange: action, intensity
            @"kitchen sink": [UIColor systemPurpleColor],      // Purple: variety, abundance
            @"lightweight": [UIColor systemTealColor],         // Teal: light, breezy
            @"magic": [UIColor systemBlueColor],               // Blue: mystical, arcane
            @"multiplayer": [UIColor systemIndigoColor],       // Indigo: social, connectivity
            @"optimization": [UIColor colorWithRed:0.0 green:0.8 blue:0.9 alpha:1.0], // Cyan: efficiency, performance
            @"quests": [UIColor systemYellowColor],            // Yellow: rewards, achievements
            @"technology": [UIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1.0], // Gray: industrial, mechanical
            
            // Additional categories for better coverage
            @"building": [UIColor colorWithRed:0.76 green:0.60 blue:0.42 alpha:1.0], // Brown: construction
            @"exploration": [UIColor systemGreenColor],        // Same as adventure
            @"survival": [UIColor systemOrangeColor],          // Survival-oriented
            @"rpg": [UIColor systemPinkColor],                 // Pink: role-playing, fantasy
            @"skyblock": [UIColor colorWithRed:0.53 green:0.81 blue:0.92 alpha:1.0], // Light blue: sky theme
            @"mini game": [UIColor systemYellowColor],         // Mini-games like quests
            @"modded": [UIColor systemPurpleColor],            // General modded category
            @"fabric": [UIColor colorWithRed:0.31 green:0.31 blue:0.31 alpha:1.0],  // Dark gray: Fabric loader
            @"forge": [UIColor colorWithRed:0.60 green:0.40 blue:0.20 alpha:1.0],   // Bronze: Forge loader
            @"vanilla+": [UIColor colorWithRed:0.82 green:0.71 blue:0.55 alpha:1.0] // Vanilla enhanced
        };
    });
    
    // Convert tag to lowercase for case-insensitive matching
    NSString *lowercaseTag = [tag lowercaseString];
    
    // First try exact match
    for (NSString *key in tagColors) {
        if ([lowercaseTag isEqualToString:key]) {
            return tagColors[key];
        }
    }
    
    // Then try contains matching
    for (NSString *key in tagColors.allKeys) {
        if ([lowercaseTag containsString:key] || [key containsString:lowercaseTag]) {
            return tagColors[key];
        }
    }
    
    // Calculate a unique color based on the tag string (for unknown tags)
    NSUInteger hash = 0;
    for (NSUInteger i = 0; i < tag.length; i++) {
        NSUInteger character = [tag characterAtIndex:i];
        hash = ((hash << 5) - hash) + character;
    }
    
    // Use the hash to create a repeatable color with good saturation and brightness
    CGFloat hue = (hash % 256) / 256.0;
    return [UIColor colorWithHue:hue saturation:0.75 brightness:0.85 alpha:1.0];
}

// Helper method to capitalize first letter of each word in a tag
- (NSString *)formatTagName:(NSString *)tagName {
    if (tagName.length == 0) return @"";
    
    NSMutableString *formattedTag = [NSMutableString string];
    NSArray *words = [tagName componentsSeparatedByString:@" "];
    
    for (NSString *word in words) {
        if (word.length > 0) {
            // Capitalize first letter, keep rest lowercase
            NSString *firstLetter = [[word substringToIndex:1] uppercaseString];
            NSString *restOfWord = word.length > 1 ? [[word substringFromIndex:1] lowercaseString] : @"";
            [formattedTag appendString:firstLetter];
            [formattedTag appendString:restOfWord];
            
            // Add space if not the last word
            if (![word isEqual:[words lastObject]]) {
                [formattedTag appendString:@" "];
            }
        }
    }
    
    return formattedTag;
}

- (void)setTags:(NSArray<NSString *> *)tags {
    // Clear existing tags first
    for (UIView *tagView in self.tagViews) {
        [tagView removeFromSuperview];
    }
    [self.tagViews removeAllObjects];
    
    if (!tags || tags.count == 0) {
        return;
    }
    
    // Create a horizontal stack to hold tags
    CGFloat xOffset = 0;
    CGFloat tagHeight = 22; // Slightly larger
    CGFloat tagSpacing = 8;
    
    // First, sort tags alphabetically and limit to a reasonable number
    // Convert to a set first to eliminate duplicates
    NSSet *uniqueTags = [NSSet setWithArray:tags];
    NSArray *sortedTags = [[uniqueTags allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSInteger maxTags = 5; // Show only 5 tags at most to avoid clutter
    NSArray *displayTags = sortedTags.count > maxTags ? 
                          [sortedTags subarrayWithRange:NSMakeRange(0, maxTags)] : 
                          sortedTags;
    
    
    for (NSString *tag in displayTags) {
        // Skip empty tags
        if (!tag || tag.length == 0) continue;
        
        // Create tag container view
        UIView *tagView = [[UIView alloc] init];
        tagView.backgroundColor = [self colorForTag:tag];
        tagView.layer.cornerRadius = tagHeight / 2;
        tagView.layer.masksToBounds = YES; // Ensure content stays within rounded corners
        [self.tagsScrollView addSubview:tagView];
        [self.tagViews addObject:tagView];
        
        // Format tag text with proper capitalization
        NSString *formattedTag = [self formatTagName:tag];
        
        // Create tag label
        UILabel *tagLabel = [[UILabel alloc] init];
        tagLabel.text = formattedTag;
        tagLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        tagLabel.textColor = [UIColor whiteColor];
        tagLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [tagView addSubview:tagLabel];
        
        // Size the tag based on text content
        CGSize textSize = [formattedTag boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, tagHeight)
                                           options:NSStringDrawingUsesLineFragmentOrigin
                                        attributes:@{NSFontAttributeName: tagLabel.font}
                                           context:nil].size;
        
        CGFloat tagWidth = textSize.width + 16; // Padding
        tagView.frame = CGRectMake(xOffset, 0, tagWidth, tagHeight);
        
        // Position label centered in tag
        [NSLayoutConstraint activateConstraints:@[
            [tagLabel.centerXAnchor constraintEqualToAnchor:tagView.centerXAnchor],
            [tagLabel.centerYAnchor constraintEqualToAnchor:tagView.centerYAnchor]
        ]];
        
        // Update offset for next tag
        xOffset += tagWidth + tagSpacing;
    }
    
    // If we limited the tags, add a +X more indicator
    if (sortedTags.count > maxTags) {
        NSString *moreText = [NSString stringWithFormat:@"+%lu more", (unsigned long)(sortedTags.count - maxTags)];
        
        UIView *moreView = [[UIView alloc] init];
        moreView.backgroundColor = [UIColor systemGrayColor];
        moreView.layer.cornerRadius = tagHeight / 2;
        [self.tagsScrollView addSubview:moreView];
        [self.tagViews addObject:moreView];
        
        UILabel *moreLabel = [[UILabel alloc] init];
        moreLabel.text = moreText;
        moreLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        moreLabel.textColor = [UIColor whiteColor];
        moreLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [moreView addSubview:moreLabel];
        
        CGSize textSize = [moreText boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, tagHeight)
                                               options:NSStringDrawingUsesLineFragmentOrigin
                                            attributes:@{NSFontAttributeName: moreLabel.font}
                                               context:nil].size;
        
        CGFloat moreWidth = textSize.width + 16;
        moreView.frame = CGRectMake(xOffset, 0, moreWidth, tagHeight);
        
        [NSLayoutConstraint activateConstraints:@[
            [moreLabel.centerXAnchor constraintEqualToAnchor:moreView.centerXAnchor],
            [moreLabel.centerYAnchor constraintEqualToAnchor:moreView.centerYAnchor]
        ]];
        
        xOffset += moreWidth + tagSpacing;
    }
    
    // Set content size of scroll view
    self.tagsScrollView.contentSize = CGSizeMake(xOffset, tagHeight);
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
    
    // Initialize tag filter set
    self.activeTagFilters = [NSMutableSet new];
    
    // Initialize unified search results array
    self.unifiedSearchResults = [NSMutableArray new];
    self.isSearchActive = NO;
    self.hasMoreResults = YES;
    
    // Setup category filter - segmented control
    UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:@[
        localize(@"All", nil),
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
    
    // Monitor search active state changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(searchActiveChanged:)
                                                 name:@"UISearchControllerDidBeginSearchNotification"
                                               object:self.searchController];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(searchActiveChanged:)
                                                 name:@"UISearchControllerDidEndSearchNotification"
                                               object:self.searchController];
    
    // Also observe the searchController's active property directly
    [self.searchController addObserver:self
                            forKeyPath:@"active"
                               options:NSKeyValueObservingOptionNew
                               context:NULL];
    
    // Setup refresh control
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(refreshModpacks) forControlEvents:UIControlEventValueChanged];
    [self.tableView addSubview:self.refreshControl];
    
    // Load WorkflowProgressView for download progress
    dlopen("/System/Library/PrivateFrameworks/WorkflowUIServices.framework/WorkflowUIServices", RTLD_GLOBAL);
    self.progressView = [[NSClassFromString(@"WFWorkflowProgressView") alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    self.progressView.resolvedTintColor = self.view.tintColor;
    [self.progressView addTarget:self action:@selector(actionCancelDownload) forControlEvents:UIControlEventTouchUpInside];
    
    // Add tag filter button to navigation
    UIBarButtonItem *tagFilterButton = [[UIBarButtonItem alloc] 
                                        initWithImage:[UIImage systemImageNamed:@"tag"]
                                        style:UIBarButtonItemStylePlain 
                                        target:self 
                                        action:@selector(showTagFilterMenu:)];
    
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] 
                                   initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                   target:self 
                                   action:@selector(actionClose)];
    
    self.navigationItem.rightBarButtonItems = @[closeButton, tagFilterButton];
    
    // Initialize modrinth API
    self.modrinth = [ModrinthAPI new];
    
    // Initialize data structures with thread safety
    self.categories = [NSMutableArray new];
    self.visibilityList = [NSMutableArray new];
    self.organizedModpacks = [NSMutableArray new];
    self.filteredModpacks = [NSMutableArray new];
    self.isDataLoading = NO;
    self.dataLock = [[NSLock alloc] init];
    
    // Setup default filters - change from " " to empty string to avoid unnecessary searches
    self.filters = @{
        @"isModpack": @(YES),
        @"name": @"",
        @"sortMethod": @"relevance" // Default sort method
    }.mutableCopy;
    
    // Load initial data
    [self updateSearchResults];
}

#pragma mark - Action Methods

- (void)refreshModpacks {
    // Reset any active filters that might have been applied
    [self.activeTagFilters removeAllObjects];
    [self updateFilterIndicators];
    
    // Update search results with fresh data
    [self updateSearchResults];
}

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
    [self.dataLock lock];
    [self.organizedModpacks removeAllObjects];
    [self.filteredModpacks removeAllObjects];
    [self.categories removeAllObjects];
    [self.visibilityList removeAllObjects];
    [self.unifiedSearchResults removeAllObjects];
    [self.dataLock unlock];
    
    // Update filter based on segment
    NSString *sortMethod;
    switch (segment.selectedSegmentIndex) {
        case 1: // Updated (was index 2 before)
            sortMethod = @"updated";
            break;
        default: // All (default)
            sortMethod = @"relevance";
            break;
    }
    
    // Update the filter
    self.filters[@"sortMethod"] = sortMethod;
    
    // Reset pagination state
    self.hasMoreResults = YES;
    
    // Reload data with new filter
    [self updateSearchResults];
}

- (void)showTagFilterMenu:(UIBarButtonItem *)sender {
    // Create a set of all available tags
    NSMutableSet *allTagsSet = [NSMutableSet new];
    
    // Get all tags from all modpacks - thread safe approach
    [self.dataLock lock];
    // Create a copy of organized modpacks to avoid mutation issues
    NSArray *safeCategoriesArray = [NSArray arrayWithArray:self.organizedModpacks];
    [self.dataLock unlock];
    
    // Get all tags from all modpacks
    for (NSArray *categoryModpacks in safeCategoriesArray) {
        // Skip if not an array
        if (![categoryModpacks isKindOfClass:[NSArray class]]) continue;
        
        for (NSDictionary *modpack in categoryModpacks) {
            // Skip if not a dictionary
            if (![modpack isKindOfClass:[NSDictionary class]]) continue;
            
            NSArray *categories = modpack[@"categories"];
            // Skip if categories is not an array
            if (![categories isKindOfClass:[NSArray class]]) continue;
            
            for (NSString *category in categories) {
                // Skip if not a string
                if (![category isKindOfClass:[NSString class]]) continue;
                
                // Store lowercase version for case-insensitive matching
                [allTagsSet addObject:[category lowercaseString]];
            }
        }
    }
    
    // Format tag names with proper capitalization
    NSMutableDictionary *formattedTagMap = [NSMutableDictionary dictionary];
    for (NSString *tag in allTagsSet) {
        // Use the ModpackVersionCell helper to format tag names consistently
        ModpackVersionCell *dummyCell = [[ModpackVersionCell alloc] init];
        NSString *formattedTag = [dummyCell formatTagName:tag];
        formattedTagMap[tag] = formattedTag;
    }
    
    // Convert to sorted array using formatted names
    NSArray *allTags = [[allTagsSet allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *tag1, NSString *tag2) {
        NSString *formattedTag1 = formattedTagMap[tag1];
        NSString *formattedTag2 = formattedTagMap[tag2];
        return [formattedTag1 localizedCaseInsensitiveCompare:formattedTag2];
    }];
    
    // Create alert controller for tag selection
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:localize(@"Filter by Tags", nil)
                                                                            message:localize(@"Select tags to filter modpacks", nil)
                                                                     preferredStyle:UIAlertControllerStyleActionSheet];
    
    // Add actions for each tag
    for (NSString *tag in allTags) {
        // Create a copy of activeTagFilters to avoid any mutation during enumeration
        NSSet *activeTagFiltersCopy = [NSSet setWithSet:self.activeTagFilters];
        BOOL isSelected = [activeTagFiltersCopy containsObject:tag];
        NSString *formattedTag = formattedTagMap[tag];
        NSString *title = isSelected ? [NSString stringWithFormat:@"✓ %@", formattedTag] : formattedTag;
        
        UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction * _Nonnull action) {
            // Toggle tag selection - use main thread for UI updates
            dispatch_async(dispatch_get_main_queue(), ^{
                if (isSelected) {
                    [self.activeTagFilters removeObject:tag];
                } else {
                    [self.activeTagFilters addObject:tag];
                }
                
                // Apply filters without dismissing the menu
                [self updateUnifiedSearchResults];
                [self updateFilterIndicators];
                
                // Show the tag menu again with updated selection state
                [self showTagFilterMenu:sender];
            });
        }];
        
        [alertController addAction:action];
    }
    
    // Add clear filters option
    UIAlertAction *clearAction = [UIAlertAction actionWithTitle:localize(@"Clear All Filters", nil)
                                                         style:UIAlertActionStyleDestructive
                                                       handler:^(UIAlertAction * _Nonnull action) {
        // Clear all filters - use main thread for UI updates
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.activeTagFilters removeAllObjects];
            [self updateUnifiedSearchResults];
            [self updateFilterIndicators];
        });
    }];
    [alertController addAction:clearAction];
    
    // Add done option to close the menu
    UIAlertAction *doneAction = [UIAlertAction actionWithTitle:localize(@"Done", nil)
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil];
    [alertController addAction:doneAction];
    
    // Present the alert on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        // Configure popover presentation for iPad
        alertController.popoverPresentationController.barButtonItem = sender;
        [self presentViewController:alertController animated:YES completion:nil];
    });
}

#pragma mark - Data Loading

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    // Get current search text, ensure it's not nil
    NSString *name = self.searchController.searchBar.text ?: @"";

    [self switchToLoadingState];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Create a copy of the filters for this specific search operation to avoid thread safety issues
        NSMutableDictionary *searchFilters = [NSMutableDictionary dictionaryWithDictionary:self.filters];
        searchFilters[@"name"] = name;
        
        // Update main filters with current search text (in background thread)
        self.filters[@"name"] = name;
        
        // Log the search parameters for debugging
        NSLog(@"[ModpackInstall] Searching with filters: %@, appending: %@", 
              searchFilters, prevList ? @"YES" : @"NO");
        
        // Perform the search, using the previous results if appending
        NSMutableArray *prevResults = nil;
        if (prevList) {
            // Thread-safe copy of previous results
            [self.dataLock lock];
            prevResults = [NSMutableArray arrayWithArray:self.unifiedSearchResults];
            [self.dataLock unlock];
        }
        
        NSMutableArray *newResults = [self.modrinth searchModWithFilters:searchFilters 
                                             previousPageResult:prevResults];
        
        // Check for pagination status
        self.hasMoreResults = !self.modrinth.reachedLastPage;
        
        if (newResults) {
            // Ensure UI updates happen on main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                // If we're not appending, reorganize completely
                if (!prevList) {
                    [self organizeModpacksByCategory:newResults];
                } else {
                    // If appending, just update our existing organization
                    [self updateOrganizedModpacks:newResults];
                }
                
                // Update unified search results if search is active
                if (self.isSearchActive) {
                    [self updateUnifiedSearchResults];
                }
                
                self.isLoadingMoreResults = NO;
                [self switchToReadyState];
                [self.tableView reloadData];
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isLoadingMoreResults = NO;
                if (self.modrinth.lastError) {
                    showDialog(localize(@"Error", nil), self.modrinth.lastError.localizedDescription);
                } else {
                    showDialog(localize(@"Error", nil), @"Could not load modpacks. Please check your network connection.");
                }
                [self switchToReadyState];
            });
        }
    });
}

- (void)updateSearchResults {
    // Reset pagination state to ensure we get fresh results
    self.hasMoreResults = YES;
    [self loadSearchResultsWithPrevList:NO];
}

- (void)loadMoreResults {
    // Only proceed if we're not already loading and have more results to fetch
    if (self.isLoadingMoreResults || !self.hasMoreResults) {
        return;
    }
    
    self.isLoadingMoreResults = YES;
    [self loadSearchResultsWithPrevList:YES];
}

#pragma mark - UI State Management

- (void)switchToLoadingState {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        self.navigationItem.rightBarButtonItems = @[[[UIBarButtonItem alloc] initWithCustomView:indicator]];
        [indicator startAnimating];
        self.navigationController.modalInPresentation = YES;
        self.tableView.allowsSelection = NO;
        
        self.isDataLoading = YES;
    });
}

- (void)switchToReadyState {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItems[0].customView;
        [indicator stopAnimating];
        
        UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] 
                                       initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                       target:self 
                                       action:@selector(actionClose)];
                                       
        UIBarButtonItem *tagFilterButton = [[UIBarButtonItem alloc] 
                                            initWithImage:[UIImage systemImageNamed:@"tag"]
                                            style:UIBarButtonItemStylePlain 
                                            target:self 
                                            action:@selector(showTagFilterMenu:)];
                                            
        if (self.activeTagFilters.count > 0) {
            tagFilterButton.tintColor = [UIColor systemBlueColor];
        }
        
        self.navigationItem.rightBarButtonItems = @[closeButton, tagFilterButton];
        self.navigationController.modalInPresentation = NO;
        self.tableView.allowsSelection = YES;
        [self.refreshControl endRefreshing];
        
        self.isDataLoading = NO;
    });
}

- (void)updateFilterIndicators {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Update navigation title to indicate active filters
        if (self.activeTagFilters.count > 0) {
            self.navigationItem.rightBarButtonItems[1].tintColor = [UIColor systemBlueColor];
        } else {
            self.navigationItem.rightBarButtonItems[1].tintColor = nil; // Default tint
        }
    });
}

#pragma mark - Data Organization and Filtering

- (void)organizeModpacksByCategory:(NSArray *)modpacks {
    // Guard against nil input
    if (!modpacks) {
        modpacks = @[];
    }
    
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
    
    // Define expanded keywords for better categorization
    NSDictionary *categoryKeywords = @{
        localize(@"Magic Modpacks", nil): @[@"magic", @"wizard", @"spell", @"arcane", @"mage", @"witch", @"sorcery", @"mystical", @"enchant", @"thaumcraft", @"blood magic", @"botania"],
        
        localize(@"Tech Modpacks", nil): @[@"tech", @"machine", @"redstone", @"industrial", @"energy", @"power", @"mechanism", @"factory", @"automation", @"engineer", @"buildcraft", @"immersive engineering", @"thermal", @"computercraft", @"create"],
        
        localize(@"Adventure Modpacks", nil): @[@"adventure", @"quest", @"explore", @"journey", @"dungeon", @"rpg", @"dimension", @"battle", @"biome", @"structure", @"twilight forest", @"aether"]
    };
    
    // Create a safe copy of modpacks to iterate through
    NSArray *safeModpacks = [modpacks copy];
    
    // Assign modpacks to categories based on keywords
    for (id modpackObj in safeModpacks) {
        if (![modpackObj isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        
        NSDictionary *modpack = (NSDictionary *)modpackObj;
        
        NSString *title = [[modpack[@"title"] ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *description = [[modpack[@"description"] ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        // Ensure tags is an array
        id tagsObj = modpack[@"categories"];
        NSArray *tags = [tagsObj isKindOfClass:[NSArray class]] ? tagsObj : @[];
        
        // Create a safe copy of tags to iterate through
        NSArray *safeTags = [tags copy];
        
        // Start with a score for each category
        NSMutableDictionary *categoryScores = [NSMutableDictionary dictionary];
        for (NSString *category in defaultCategories) {
            categoryScores[category] = @0;
        }
        
        // Calculate a score for each category based on keyword matching
        for (NSString *category in categoryKeywords) {
            NSArray *keywords = categoryKeywords[category];
            int score = 0;
            
            for (NSString *keyword in keywords) {
                // Full word match gets higher score than partial match
                if ([title isEqualToString:keyword] || 
                    [[title componentsSeparatedByString:@" "] containsObject:keyword]) {
                    score += 5;
                } else if ([title containsString:keyword]) {
                    score += 2;
                }
                
                if ([description containsString:keyword]) {
                    score += 1;
                }
                
                // Check if the keyword appears in any of the modpack's categories/tags
                for (id tagObj in safeTags) {
                    if (![tagObj isKindOfClass:[NSString class]]) {
                        continue;
                    }
                    
                    NSString *tag = (NSString *)tagObj;
                    NSString *lowercaseTag = [[tag lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if ([lowercaseTag isEqualToString:keyword]) {
                        score += 5; // Exact tag match gets high score
                    } else if ([lowercaseTag containsString:keyword]) {
                        score += 3; // Partial tag match still valuable
                    }
                }
            }
            
            categoryScores[category] = @(score);
        }
        
        // Find the category with the highest score
        NSString *bestCategory = localize(@"Other Modpacks", nil);
        int highestScore = 0;
        
        for (NSString *category in categoryScores) {
            int score = [categoryScores[category] intValue];
            if (score > highestScore) {
                highestScore = score;
                bestCategory = category;
            }
        }
        
        // If no category had a score, use the default "Other"
        NSString *category = (highestScore > 0) ? bestCategory : localize(@"Other Modpacks", nil);
        
        // Add to appropriate category - check for valid arrays first
        NSMutableArray *categoryArray = categorizedModpacks[category];
        if (categoryArray && [categoryArray isKindOfClass:[NSMutableArray class]]) {
            [categoryArray addObject:modpack];
        } else {
            // If category doesn't exist for some reason, add to Other
            NSMutableArray *otherArray = categorizedModpacks[localize(@"Other Modpacks", nil)];
            if (otherArray && [otherArray isKindOfClass:[NSMutableArray class]]) {
                [otherArray addObject:modpack];
            }
        }
    }
    
    // Feature the first few modpacks regardless of category
    NSMutableArray *featuredModpacks = [NSMutableArray array];
    NSInteger featuredCount = MIN(5, modpacks.count);
    for (NSInteger i = 0; i < featuredCount; i++) {
        if (i < safeModpacks.count) {
            [featuredModpacks addObject:safeModpacks[i]];
        }
    }
    
    if (categorizedModpacks[localize(@"Featured Modpacks", nil)]) {
        categorizedModpacks[localize(@"Featured Modpacks", nil)] = featuredModpacks;
    }
    
    // Build the final organized arrays
    for (NSString *category in defaultCategories) {
        NSMutableArray *modpacksInCategory = categorizedModpacks[category];
        
        // Only add non-empty categories
        if (modpacksInCategory && modpacksInCategory.count > 0) {
            [self.categories addObject:category];
            [self.visibilityList addObject:@(YES)]; // Start expanded by default
            [self.organizedModpacks addObject:modpacksInCategory];
            [self.filteredModpacks addObject:[modpacksInCategory mutableCopy]];
        }
    }
    
    // If no categories were created (which shouldn't happen), add a fallback
    if (self.categories.count == 0) {
        [self.categories addObject:localize(@"All Modpacks", nil)];
        [self.visibilityList addObject:@YES];
        [self.organizedModpacks addObject:[modpacks mutableCopy]];
        [self.filteredModpacks addObject:[modpacks mutableCopy]];
    }
    
    [self.dataLock unlock];
}

- (void)updateOrganizedModpacks:(NSArray *)newModpacks {
    // Validate input to prevent crashes
    if (!newModpacks || ![newModpacks isKindOfClass:[NSArray class]]) {
        NSLog(@"[ModpackInstall] Warning: updateOrganizedModpacks called with invalid array");
        return;
    }
    
    [self.dataLock lock];
    
    // For simplicity, we'll just add all new modpacks to the "Other" category
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
    if (otherIndex < self.organizedModpacks.count) {
        NSMutableArray *otherModpacks = self.organizedModpacks[otherIndex];
        if ([otherModpacks isKindOfClass:[NSMutableArray class]]) {
            [otherModpacks addObjectsFromArray:newModpacks];
        }
    }
    
    if (otherIndex < self.filteredModpacks.count) {
        NSMutableArray *filteredOtherModpacks = self.filteredModpacks[otherIndex];
        if ([filteredOtherModpacks isKindOfClass:[NSMutableArray class]]) {
            [filteredOtherModpacks addObjectsFromArray:newModpacks];
        }
    }
    
    // For search mode, also append to unified search results if they match the current criteria
    if (self.isSearchActive) {
        // Create a safe copy of newModpacks to iterate through
        NSArray *safeModpacks = [newModpacks copy];
        
        // Get a copy of search text and active tag filters to avoid race conditions
        NSString *currentSearchText = [self.searchText copy];
        NSSet *activeTagFiltersCopy = [NSSet setWithSet:self.activeTagFilters];
        
        for (id modpackObj in safeModpacks) {
            // Ensure the modpack is a dictionary
            if (![modpackObj isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            
            NSDictionary *modpack = (NSDictionary *)modpackObj;
            
            // Safely extract values with type checking
            NSString *title = [modpack[@"title"] isKindOfClass:[NSString class]] ? modpack[@"title"] : @"";
            NSString *description = [modpack[@"description"] isKindOfClass:[NSString class]] ? modpack[@"description"] : @"";
            
            // Ensure categories is an array
            id categoriesObj = modpack[@"categories"];
            NSArray *categories = [categoriesObj isKindOfClass:[NSArray class]] ? categoriesObj : @[];
            
            // Create a safe copy of categories to iterate through
            NSArray *safeCategories = [categories copy];
            
            // Check if search text appears in title or description
            BOOL matchesTextContent = (currentSearchText.length == 0) || 
                                      [title localizedCaseInsensitiveContainsString:currentSearchText] ||
                                      [description localizedCaseInsensitiveContainsString:currentSearchText];
            
            // Check if search text matches any tag/category
            BOOL matchesTextInTags = NO;
            if (currentSearchText.length > 0) {
                for (id tagObj in safeCategories) {
                    // Ensure tag is a string
                    if (![tagObj isKindOfClass:[NSString class]]) {
                        continue;
                    }
                    
                    NSString *tag = (NSString *)tagObj;
                    if ([tag localizedCaseInsensitiveContainsString:currentSearchText]) {
                        matchesTextInTags = YES;
                        break;
                    }
                }
            }
            
            // Check if modpack has at least one of the active tag filters
            BOOL matchesTagFilters = (activeTagFiltersCopy.count == 0);
            if (!matchesTagFilters) {
                for (id tagObj in safeCategories) {
                    // Ensure tag is a string
                    if (![tagObj isKindOfClass:[NSString class]]) {
                        continue;
                    }
                    
                    NSString *tag = (NSString *)tagObj;
                    if ([activeTagFiltersCopy containsObject:[tag lowercaseString]]) {
                        matchesTagFilters = YES;
                        break;
                    }
                }
            }
            
            // Include if it matches all applicable filters
            if ((matchesTextContent || matchesTextInTags) && matchesTagFilters) {
                [self.unifiedSearchResults addObject:modpack];
            }
        }
    }
    
    [self.dataLock unlock];
}

#pragma mark - Search State Handling

- (void)searchActiveChanged:(NSNotification *)notification {
    // Check if search is becoming active or inactive
    if ([notification.name isEqualToString:@"UISearchControllerDidBeginSearchNotification"]) {
        self.isSearchActive = YES;
        
        // When search becomes active, create unified search results
        [self updateUnifiedSearchResults];
        
    } else if ([notification.name isEqualToString:@"UISearchControllerDidEndSearchNotification"]) {
        self.isSearchActive = NO;
        
        // When search is dismissed, reload table to restore category view
        [self.tableView reloadData];
    }
}

// Add KVO observation for search controller's active property
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (object == self.searchController && [keyPath isEqualToString:@"active"]) {
        BOOL isActive = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
        
        // Only update if the state has changed
        if (isActive != self.isSearchActive) {
            self.isSearchActive = isActive;
            
            if (isActive) {
                // When search becomes active, create unified search results
                [self updateUnifiedSearchResults];
            } else {
                // When search is dismissed, reload table to restore category view
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.tableView reloadData];
                });
            }
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)updateUnifiedSearchResults {
    [self.dataLock lock];
    
    // Clear the existing unified search results
    [self.unifiedSearchResults removeAllObjects];
    
    // If we have active filters (tags or search text), apply them
    if (self.searchText.length > 0 || self.activeTagFilters.count > 0) {
        // Combine all modpacks from all categories into one array for filtering
        NSMutableArray *allModpacks = [NSMutableArray array];
        
        // Create a copy of organizedModpacks to avoid mutation issues
        NSArray *safeOrganizedModpacks = [self.organizedModpacks copy];
        
        for (NSArray *categoryModpacks in safeOrganizedModpacks) {
            if ([categoryModpacks isKindOfClass:[NSArray class]]) {
                [allModpacks addObjectsFromArray:categoryModpacks];
            }
        }
        
        // Apply filters
        // Create a copy of allModpacks to avoid mutation issues
        NSArray *safeAllModpacks = [allModpacks copy];
        
        // Create copies of filter criteria to avoid race conditions
        NSString *searchTextCopy = [self.searchText copy];
        NSSet *activeTagFiltersCopy = [NSSet setWithSet:self.activeTagFilters];
        
        for (id modpackObj in safeAllModpacks) {
            if (![modpackObj isKindOfClass:[NSDictionary class]]) {
                continue; // Skip invalid modpacks
            }
            
            NSDictionary *modpack = (NSDictionary *)modpackObj;
            
            NSString *title = [modpack[@"title"] isKindOfClass:[NSString class]] ? modpack[@"title"] : @"";
            NSString *description = [modpack[@"description"] isKindOfClass:[NSString class]] ? modpack[@"description"] : @"";
            
            // Ensure categories is an array
            id categoriesObj = modpack[@"categories"];
            NSArray *categories = [categoriesObj isKindOfClass:[NSArray class]] ? categoriesObj : @[];
            
            // Create a safe copy of the categories array
            NSArray *safeCategories = [categories copy];
            
            // Check if search text appears in title or description
            BOOL matchesTextContent = (searchTextCopy.length == 0) || 
                                      [title localizedCaseInsensitiveContainsString:searchTextCopy] ||
                                      [description localizedCaseInsensitiveContainsString:searchTextCopy];
            
            // Check if search text matches any tag/category
            BOOL matchesTextInTags = NO;
            if (searchTextCopy.length > 0) {
                for (id tagObj in safeCategories) {
                    // Ensure tag is a string
                    if (![tagObj isKindOfClass:[NSString class]]) {
                        continue;
                    }
                    
                    NSString *tag = (NSString *)tagObj;
                    if ([tag localizedCaseInsensitiveContainsString:searchTextCopy]) {
                        matchesTextInTags = YES;
                        break;
                    }
                }
            }
            
            // Check if modpack has at least one of the active tag filters
            BOOL matchesTagFilters = (activeTagFiltersCopy.count == 0);
            if (!matchesTagFilters) {
                for (id tagObj in safeCategories) {
                    // Ensure tag is a string
                    if (![tagObj isKindOfClass:[NSString class]]) {
                        continue;
                    }
                    
                    NSString *tag = (NSString *)tagObj;
                    if ([activeTagFiltersCopy containsObject:[tag lowercaseString]]) {
                        matchesTagFilters = YES;
                        break;
                    }
                }
            }
            
            // Include if it matches all applicable filters
            if ((matchesTextContent || matchesTextInTags) && matchesTagFilters) {
                [self.unifiedSearchResults addObject:modpack];
            }
        }
        
        // Sort results by relevance to search query if text search is active
        if (searchTextCopy.length > 0) {
            [self.unifiedSearchResults sortUsingComparator:^NSComparisonResult(NSDictionary *modpack1, NSDictionary *modpack2) {
                NSString *title1 = modpack1[@"title"] ?: @"";
                NSString *title2 = modpack2[@"title"] ?: @"";
                
                // If one title contains the search text exactly but the other doesn't, prioritize the exact match
                BOOL title1ContainsExact = [title1 localizedCaseInsensitiveContainsString:searchTextCopy];
                BOOL title2ContainsExact = [title2 localizedCaseInsensitiveContainsString:searchTextCopy];
                
                if (title1ContainsExact && !title2ContainsExact) {
                    return NSOrderedAscending;
                } else if (!title1ContainsExact && title2ContainsExact) {
                    return NSOrderedDescending;
                }
                
                // Otherwise, sort alphabetically
                return [title1 localizedCaseInsensitiveCompare:title2];
            }];
        }
    } else {
        // If no active filters, include all modpacks
        // Create a copy of organizedModpacks to avoid mutation issues
        NSArray *safeOrganizedModpacks = [self.organizedModpacks copy];
        
        for (NSArray *categoryModpacks in safeOrganizedModpacks) {
            if ([categoryModpacks isKindOfClass:[NSArray class]]) {
                [self.unifiedSearchResults addObjectsFromArray:categoryModpacks];
            }
        }
    }
    
    [self.dataLock unlock];
    
    // Reload the table view with the unified results on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    // Update search results text
    self.searchText = searchController.searchBar.text ?: @"";
    
    // Make sure isSearchActive is set if the search controller is active
    if (searchController.active && !self.isSearchActive) {
        self.isSearchActive = YES;
    }
    
    // Debounce the search to prevent excessive updates while typing
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateUnifiedSearchResults) object:nil];
    [self performSelector:@selector(updateUnifiedSearchResults) withObject:nil afterDelay:0.5];
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Check if we're near the bottom of the table view and should load more
    CGFloat currentOffset = scrollView.contentOffset.y;
    CGFloat contentHeight = scrollView.contentSize.height;
    CGFloat frameHeight = scrollView.frame.size.height;
    
    // When we're 400 points from the bottom, consider loading more
    CGFloat bottomEdge = contentHeight - (currentOffset + frameHeight);
    
    if (bottomEdge < 400 && !self.isLoadingMoreResults && self.hasMoreResults && self.isSearchActive) {
        [self loadMoreResults];
    }
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
    
    // When in search mode, show a single section
    if (self.isSearchActive) {
        return 1;
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
    
    // When in search mode, show unified search results
    if (self.isSearchActive) {
        [self.dataLock lock];
        NSInteger count = self.unifiedSearchResults.count;
        BOOL hasMore = self.hasMoreResults;
        [self.dataLock unlock];
        
        // If we have no results but might get more, show a loading indicator
        if (count == 0 && hasMore) {
            return 1;
        }
        
        // If we have results and might get more, add 1 for the loading indicator
        if (count > 0 && hasMore) {
            return count + 1;
        }
        
        // Otherwise just show the results (or a "no results" row if empty)
        return MAX(count, 1);
    }
    
    [self.dataLock lock];
    
    // Add bounds checking
    if (section >= self.visibilityList.count) {
        [self.dataLock unlock];
        return 0;
    }
    
    // If the section is collapsed, don't show any rows
    if (!self.visibilityList[section].boolValue) {
        [self.dataLock unlock];
        return 0;
    }
    
    NSInteger rows = 0;
    
    if (section < self.organizedModpacks.count) {
        rows = self.organizedModpacks[section].count;
    }
    
    [self.dataLock unlock];
    
    // Better handling of empty categories
    if (rows == 0 && self.categories.count == 1) {
        // If we only have one category and it's empty, show a "No results" message
        return 1;
    } else if (rows == 0) {
        // If this particular category is empty, don't show any rows
        return 0;
    } else {
        // Return the actual number of rows
        return rows;
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    // When in search mode, never show section headers
    if (self.isSearchActive) {
        return nil;
    }
    
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
    
    // Remove existing targets to avoid duplicate actions
    [headerView.expandCollapseButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    
    // Add action for the button
    [headerView.expandCollapseButton addTarget:self action:@selector(toggleSection:) forControlEvents:UIControlEventTouchUpInside];
    
    return headerView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    // When in search mode, don't show section headers at all
    if (self.isSearchActive) {
        return 0.0;
    }
    
    return 60.0;
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
        
        // Update section on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationFade];
        });
    } else {
        [self.dataLock unlock];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 100.0; // Increased height to accommodate tags
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModpackVersionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModpackVersionCell" forIndexPath:indexPath];
    
    // If data is loading, return a placeholder cell
    if (self.isDataLoading) {
        cell.titleLabel.text = localize(@"Loading modpacks...", nil);
        cell.subtitleLabel.text = @"";
        [cell setTags:@[]];
        cell.accessoryType = UITableViewCellAccessoryNone;
        
        // Add activity indicator as accessory view
        UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [activityIndicator startAnimating];
        cell.accessoryView = activityIndicator;
        
        return cell;
    }
    
    // SEARCH MODE: Show unified search results
    if (self.isSearchActive) {
        [self.dataLock lock];
        
        NSInteger resultsCount = self.unifiedSearchResults.count;
        BOOL hasMore = self.hasMoreResults;
        
        // If we're showing the loading indicator row
        if (hasMore && indexPath.row == resultsCount) {
            cell.titleLabel.text = localize(@"Loading more results...", nil);
            cell.subtitleLabel.text = @"";
            [cell setTags:@[]];
            cell.accessoryType = UITableViewCellAccessoryNone;
            
            // Add activity indicator as accessory view
            UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [activityIndicator startAnimating];
            cell.accessoryView = activityIndicator;
            
            [self.dataLock unlock];
            
            // Trigger loading more results if not already loading
            if (!self.isLoadingMoreResults) {
                [self loadMoreResults];
            }
            
            return cell;
        }
        
        // If we have no results
        if (resultsCount == 0) {
            cell.titleLabel.text = localize(@"No modpacks found", nil);
            cell.subtitleLabel.text = localize(@"Try changing your search criteria", nil);
            [cell setTags:@[]];
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.modpackIconView.image = [UIImage systemImageNamed:@"cube.box"];
            cell.modpackIconView.tintColor = [UIColor systemGray3Color];
            
            [self.dataLock unlock];
            return cell;
        }
        
        // Make sure the index path is in range
        if (indexPath.row >= resultsCount) {
            [self.dataLock unlock];
            
            // Return a generic cell if out of range
            cell.titleLabel.text = @"";
            cell.subtitleLabel.text = @"";
            [cell setTags:@[]];
            return cell;
        }
        
        // Regular result row - get a safe copy
        NSDictionary *modpack = [self.unifiedSearchResults[indexPath.row] copy];
        
        [self.dataLock unlock];
        
        // Safely extract values with type checking
        NSString *title = [modpack[@"title"] isKindOfClass:[NSString class]] ? modpack[@"title"] : @"Unknown";
        NSString *description = [modpack[@"description"] isKindOfClass:[NSString class]] ? modpack[@"description"] : @"";
        NSString *imageUrl = [modpack[@"imageUrl"] isKindOfClass:[NSString class]] ? modpack[@"imageUrl"] : @"";
        NSArray *categories = [modpack[@"categories"] isKindOfClass:[NSArray class]] ? modpack[@"categories"] : @[];
        
        // Update the cell with modpack data
        cell.titleLabel.text = title;
        cell.subtitleLabel.text = description;
        
        // Set tags from categories
        [cell setTags:categories];
        
        // Set modpack icon with improved image loading
        cell.modpackIconView.image = nil; // Reset image first to avoid stale images
        UIImage *fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
        
        if (imageUrl.length > 0) {
            // Convert WebP URLs to supported formats
            imageUrl = [cell convertWebPUrl:imageUrl];
            
            // Create an absolute URL if it's not already
            NSURL *iconURL = [NSURL URLWithString:imageUrl];
            
            // Use the shared image downloader from AFNetworking with clear cache policy
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:iconURL];
            [request setHTTPShouldHandleCookies:NO];
            [request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData]; // Force reload, ignore cache
            
            // Set a specific timeout to avoid long waits
            [request setTimeoutInterval:15.0];
            
            // Cancel any previous image requests for this cell to prevent wrong images
            [cell.modpackIconView cancelImageDownloadTask];
            
            // Use the AFNetworking category with our custom request
            [cell.modpackIconView setImageWithURLRequest:request 
                                        placeholderImage:fallbackImage 
                                                 success:^(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image) {
                                                     // Apply the image with a fade-in animation
                                                     [UIView transitionWithView:cell.modpackIconView
                                                                       duration:0.3
                                                                        options:UIViewAnimationOptionTransitionCrossDissolve
                                                                     animations:^{
                                                                         cell.modpackIconView.image = image;
                                                                     } completion:nil];
                                                 } 
                                                 failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error) {
                                                     // Ensure fallback image is set
                                                     cell.modpackIconView.image = fallbackImage;
                                                 }];
        } else {
            // If no URL, use fallback immediately
            cell.modpackIconView.image = fallbackImage;
        }
        
        // Always show disclosure indicator, regardless of whether details are loaded
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessoryView = nil;
        
        return cell;
    }
    
    // CATEGORY MODE: Show categorized results
    [self.dataLock lock];
    
    // Add bounds checking
    BOOL outOfBounds = (indexPath.section >= self.organizedModpacks.count || 
                      (indexPath.section < self.organizedModpacks.count && 
                       indexPath.row >= [self.organizedModpacks[indexPath.section] count]));
    
    if (outOfBounds || [self.organizedModpacks[indexPath.section] count] == 0) {
        [self.dataLock unlock];
        
        // Return an empty state cell
        cell.titleLabel.text = localize(@"No modpacks found", nil);
        cell.subtitleLabel.text = localize(@"Try changing your search criteria", nil);
        [cell setTags:@[]];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.modpackIconView.image = [UIImage systemImageNamed:@"cube.box"];
        cell.modpackIconView.tintColor = [UIColor systemGray3Color];
        
        return cell;
    }
    
    // Get the modpack data and make a safe copy
    NSDictionary *modpack = [self.organizedModpacks[indexPath.section][indexPath.row] copy];
    
    [self.dataLock unlock];
    
    // Safely extract values with type checking
    NSString *title = [modpack[@"title"] isKindOfClass:[NSString class]] ? modpack[@"title"] : @"Unknown";
    NSString *description = [modpack[@"description"] isKindOfClass:[NSString class]] ? modpack[@"description"] : @"";
    NSString *imageUrl = [modpack[@"imageUrl"] isKindOfClass:[NSString class]] ? modpack[@"imageUrl"] : @"";
    NSArray *categories = [modpack[@"categories"] isKindOfClass:[NSArray class]] ? modpack[@"categories"] : @[];
    
    // Update the cell with modpack data
    cell.titleLabel.text = title;
    cell.subtitleLabel.text = description;
    
    // Set tags from categories
    [cell setTags:categories];
    
    // Set modpack icon with improved image loading
    cell.modpackIconView.image = nil; // Reset image first to avoid stale images
    UIImage *fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    
    if (imageUrl.length > 0) {
        // Convert WebP URLs to supported formats
        imageUrl = [cell convertWebPUrl:imageUrl];
        
        // Create an absolute URL if it's not already
        NSURL *iconURL = [NSURL URLWithString:imageUrl];
        
        // Use the shared image downloader from AFNetworking with clear cache policy
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:iconURL];
        [request setHTTPShouldHandleCookies:NO];
        [request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData]; // Force reload, ignore cache
        
        // Set a specific timeout to avoid long waits
        [request setTimeoutInterval:15.0];
        
        // Cancel any previous image requests for this cell to prevent wrong images
        [cell.modpackIconView cancelImageDownloadTask];
        
        // Use the AFNetworking category with our custom request
        [cell.modpackIconView setImageWithURLRequest:request 
                                    placeholderImage:fallbackImage 
                                             success:^(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image) {
                                                 // Apply the image with a fade-in animation
                                                 [UIView transitionWithView:cell.modpackIconView
                                                                   duration:0.3
                                                                    options:UIViewAnimationOptionTransitionCrossDissolve
                                                                 animations:^{
                                                                     cell.modpackIconView.image = image;
                                                                 } completion:nil];
                                             } 
                                             failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error) {
                                                 // Ensure fallback image is set
                                                 cell.modpackIconView.image = fallbackImage;
                                             }];
    } else {
        // If no URL, use fallback immediately
        cell.modpackIconView.image = fallbackImage;
    }
    
    // Always show disclosure indicator, regardless of whether details are loaded
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.accessoryView = nil;
    
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    // Skip if data is still loading
    if (self.isDataLoading) {
        return;
    }
    
    // Skip if this is the "loading more" row in search mode
    if (self.isSearchActive && self.hasMoreResults && indexPath.row == self.unifiedSearchResults.count) {
        return;
    }
    
    NSDictionary *modpack = nil;
    
    // Get the modpack based on whether we're in search mode or category mode
    if (self.isSearchActive) {
        [self.dataLock lock];
        
        // Check bounds
        if (indexPath.row >= self.unifiedSearchResults.count || self.unifiedSearchResults.count == 0) {
            [self.dataLock unlock];
            return;
        }
        
        // Make a safe copy to avoid race conditions
        modpack = [self.unifiedSearchResults[indexPath.row] copy];
        [self.dataLock unlock];
    } else {
        [self.dataLock lock];
        
        // Check bounds for category mode
        if (indexPath.section >= self.organizedModpacks.count || 
            indexPath.row >= [self.organizedModpacks[indexPath.section] count] || 
            self.organizedModpacks.count == 0) {
            [self.dataLock unlock];
            return;
        }
        
        // Make a safe copy to avoid race conditions
        modpack = [self.organizedModpacks[indexPath.section][indexPath.row] copy];
        [self.dataLock unlock];
    }
    
    // Check if details already loaded
    if ([modpack[@"versionDetailsLoaded"] boolValue]) {
        // Show version selection menu
        [self showVersionMenu:modpack atIndexPath:indexPath];
    } else {
        // Load details first - preserve original categories
        NSMutableDictionary *modpackCopy = [modpack mutableCopy];
        
        // Store original categories to ensure modloader info isn't lost
        if ([modpack[@"categories"] isKindOfClass:[NSArray class]]) {
            modpackCopy[@"original_categories"] = [modpack[@"categories"] copy];
        }
        
        // Load details first
        [self loadModpackDetails:modpackCopy atIndexPath:indexPath];
    }
}

- (void)loadModpackDetails:(NSMutableDictionary *)modpack atIndexPath:(NSIndexPath *)indexPath {
    // Show loading indicator
    ModpackVersionCell *cell = (ModpackVersionCell *)[self.tableView cellForRowAtIndexPath:indexPath];
    if (!cell) {
        return; // Cell might have been scrolled offscreen
    }
    
    UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [activityIndicator startAnimating];
    cell.accessoryView = activityIndicator;
    cell.accessoryType = UITableViewCellAccessoryNone;
    
    // Load details in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.modrinth loadDetailsOfMod:modpack];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Update cell to use disclosure indicator - check if cell is still visible
            UITableViewCell *updatedCell = [self.tableView cellForRowAtIndexPath:indexPath];
            if (updatedCell) {
                updatedCell.accessoryView = nil;
                updatedCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            
            // Update data model - find the modpack in all lists and update it
            [self.dataLock lock];
            
            // Update in organized lists
            for (NSMutableArray *category in self.organizedModpacks) {
                if (![category isKindOfClass:[NSMutableArray class]]) continue;
                
                for (NSInteger i = 0; i < category.count; i++) {
                    NSDictionary *item = category[i];
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    
                    if ([item[@"id"] isEqual:modpack[@"id"]]) {
                        category[i] = modpack;
                    }
                }
            }
            
            // Update in filtered lists
            for (NSMutableArray *category in self.filteredModpacks) {
                if (![category isKindOfClass:[NSMutableArray class]]) continue;
                
                for (NSInteger i = 0; i < category.count; i++) {
                    NSDictionary *item = category[i];
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    
                    if ([item[@"id"] isEqual:modpack[@"id"]]) {
                        category[i] = modpack;
                    }
                }
            }
            
            // Update in unified search results
            for (NSInteger i = 0; i < self.unifiedSearchResults.count; i++) {
                NSDictionary *item = self.unifiedSearchResults[i];
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                
                if ([item[@"id"] isEqual:modpack[@"id"]]) {
                    self.unifiedSearchResults[i] = modpack;
                }
            }
            
            [self.dataLock unlock];
            
            // If icon URL has been updated, reload image - check if cell is still visible
            if (modpack[@"imageUrl"] && [updatedCell isKindOfClass:[ModpackVersionCell class]]) {
                ModpackVersionCell *versionCell = (ModpackVersionCell *)updatedCell;
                
                // Create an absolute URL if it's not already
                NSString *imageUrl = [modpack[@"imageUrl"] isKindOfClass:[NSString class]] ? modpack[@"imageUrl"] : @"";
                imageUrl = [versionCell convertWebPUrl:imageUrl];
                NSURL *iconURL = [NSURL URLWithString:imageUrl];
                
                // Use the shared image downloader from AFNetworking with clear cache policy
                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:iconURL];
                [request setHTTPShouldHandleCookies:NO];
                [request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData]; // Force reload, ignore cache
                [request setTimeoutInterval:15.0];
                
                // Cancel any previous image tasks
                [versionCell.modpackIconView cancelImageDownloadTask];
                
                // Load the updated image
                [versionCell.modpackIconView setImageWithURLRequest:request 
                                                   placeholderImage:versionCell.modpackIconView.image ?: [UIImage imageNamed:@"DefaultProfile"]
                                                            success:^(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image) {
                                                                [UIView transitionWithView:versionCell.modpackIconView
                                                                                  duration:0.3
                                                                                   options:UIViewAnimationOptionTransitionCrossDissolve
                                                                                animations:^{
                                                                                    versionCell.modpackIconView.image = image;
                                                                                } completion:nil];
                                                            } failure:nil];
                
                // Fix the tag duplication issue by creating a unique set of categories
                NSMutableSet *uniqueCategories = [NSMutableSet set];
                
                // Add new categories if they exist
                if ([modpack[@"categories"] isKindOfClass:[NSArray class]]) {
                    [uniqueCategories addObjectsFromArray:modpack[@"categories"]];
                }
                
                // Add original categories if they exist and weren't already added
                if ([modpack[@"original_categories"] isKindOfClass:[NSArray class]]) {
                    [uniqueCategories addObjectsFromArray:modpack[@"original_categories"]];
                }
                
                // Convert set back to array for the tags
                NSArray *uniqueCategoriesArray = [uniqueCategories allObjects];
                
                // Update the cell's tags with the unique categories
                [versionCell setTags:uniqueCategoriesArray];
            }
            
            // Show version menu if details loaded successfully
            if ([modpack[@"versionDetailsLoaded"] boolValue]) {
                [self showVersionMenu:modpack atIndexPath:indexPath];
            } else {
                if (self.modrinth.lastError) {
                    showDialog(localize(@"Error", nil), self.modrinth.lastError.localizedDescription);
                } else {
                    showDialog(localize(@"Error", nil), @"Failed to load modpack details. Please try again later.");
                }
            }
        });
    });
}

- (void)showVersionMenu:(NSDictionary *)modpack atIndexPath:(NSIndexPath *)indexPath {
    ModpackVersionCell *cell = (ModpackVersionCell *)[self.tableView cellForRowAtIndexPath:indexPath];
    if (!cell) {
        // The cell might have been scrolled off-screen
        // Create a new temporary cell that won't be displayed just to handle the menu
        cell = [[ModpackVersionCell alloc] init];
        cell.modpackIconView = [[UIImageView alloc] init];
        cell.modpackIconView.image = [UIImage imageNamed:@"DefaultProfile"];
    }
    
    NSMutableArray<UIAction *> *menuItems = [[NSMutableArray alloc] init];
    
    // Validate the version arrays
    NSArray *versionNames = modpack[@"versionNames"];
    NSArray *mcVersionNames = modpack[@"mcVersionNames"];
    
    if (!versionNames || ![versionNames isKindOfClass:[NSArray class]] || 
        !mcVersionNames || ![mcVersionNames isKindOfClass:[NSArray class]]) {
        showDialog(localize(@"Error", nil), @"Invalid version information. Please try again.");
        return;
    }
    
    [versionNames enumerateObjectsUsingBlock:
    ^(NSString *name, NSUInteger i, BOOL *stop) {
        // Skip invalid indices
        if (i >= mcVersionNames.count) return;
        
        // Skip non-string values
        if (![name isKindOfClass:[NSString class]] || 
            ![mcVersionNames[i] isKindOfClass:[NSString class]]) return;
        
        NSString *nameWithVersion = name;
        NSString *mcVersion = mcVersionNames[i];
        if (![name hasSuffix:mcVersion]) {
            nameWithVersion = [NSString stringWithFormat:@"%@ - %@", name, mcVersion];
        }
        
        [menuItems addObject:[UIAction
            actionWithTitle:nameWithVersion
            image:nil identifier:nil
            handler:^(UIAction *action) {
                [self actionClose];
                
                // Create a mutable copy of modpack to include original categories
                NSMutableDictionary *modpackWithCategories = [modpack mutableCopy];
                
                // If we have original categories stored, make sure they're included
                if (modpack[@"original_categories"]) {
                    NSMutableArray *allCategories = [NSMutableArray array];
                    
                    // Add original categories
                    if ([modpack[@"original_categories"] isKindOfClass:[NSArray class]]) {
                        [allCategories addObjectsFromArray:modpack[@"original_categories"]];
                    }
                    
                    // Add new categories if different from originals
                    if ([modpack[@"categories"] isKindOfClass:[NSArray class]]) {
                        for (id category in modpack[@"categories"]) {
                            if (![allCategories containsObject:category]) {
                                [allCategories addObject:category];
                            }
                        }
                    }
                    
                    // Use the combined categories
                    modpackWithCategories[@"categories"] = allCategories;
                }
                
                // Safely create the icon path
                NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
                UIImage *iconImage = cell.modpackIconView.image ?: [UIImage imageNamed:@"DefaultProfile"];
                [UIImagePNGRepresentation([iconImage _imageWithSize:CGSizeMake(40, 40)]) writeToFile:tmpIconPath atomically:YES];
                
                // Safely install the modpack with preserved categories
                [self.modrinth installModpackFromDetail:modpackWithCategories atIndex:i];
            }]];
    }];
    
    // If no valid menu items, show error
    if (menuItems.count == 0) {
        showDialog(localize(@"Error", nil), @"No valid versions available for this modpack.");
        return;
    }
    
    self.currentMenu = [UIMenu menuWithTitle:modpack[@"title"] ?: @"Select Version" children:menuItems];
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    
    // Only set interactions if cell is visible
    if ([cell superview]) {
        cell.interactions = @[interaction];
        [interaction _presentMenuAtLocation:CGPointZero];
    } else {
        // If cell isn't visible, present menu from a fixed point
        UIView *containerView = self.view;
        containerView.interactions = @[interaction];
        [interaction _presentMenuAtLocation:CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2)];
    }
}

@end
