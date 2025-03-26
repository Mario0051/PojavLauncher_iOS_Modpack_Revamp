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
#include <objc/runtime.h>

#pragma mark - Custom Cell Definition

// Custom cell for modpack display
@interface ModpackVersionCell : UITableViewCell
@property (nonatomic, strong) UIImageView *modpackIconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIScrollView *tagsScrollView;
@property (nonatomic, strong) NSMutableArray<UIView *> *tagViews;
@property (nonatomic, assign) BOOL shouldTriggerClick;
@end

@implementation ModpackVersionCell

// Helper method for WebP URL conversion
- (NSString *)convertWebPUrl:(NSString *)imageUrl {
    if (!imageUrl || imageUrl.length == 0) {
        return imageUrl;
    }
    
    // Use a static cache to avoid converting the same URLs repeatedly
    static NSCache *webpUrlCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        webpUrlCache = [[NSCache alloc] init];
        webpUrlCache.countLimit = 200; // Limit cache size
    });
    
    // Check if we already converted this URL
    NSString *cachedUrl = [webpUrlCache objectForKey:imageUrl];
    if (cachedUrl) {
        return cachedUrl;
    }
    
    // Handle WebP format by requesting PNG instead
    if ([imageUrl.lowercaseString hasSuffix:@".webp"]) {
        NSString *convertedUrl = nil;
        
        // 1. For Modrinth CDN: Add format=png parameter
        if ([imageUrl containsString:@"cdn.modrinth.com"]) {
            NSURL *url = [NSURL URLWithString:imageUrl];
            
            // Parse existing query items to preserve them
            NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
            NSMutableArray *queryItems = [NSMutableArray array];
            
            if (components.queryItems) {
                [queryItems addObjectsFromArray:components.queryItems];
            }
            
            // Check if format parameter already exists
            BOOL hasFormatParam = NO;
            for (NSURLQueryItem *item in queryItems) {
                if ([item.name isEqualToString:@"format"]) {
                    hasFormatParam = YES;
                    break;
                }
            }
            
            // Add format parameter if needed
            if (!hasFormatParam) {
                [queryItems addObject:[NSURLQueryItem queryItemWithName:@"format" value:@"png"]];
                components.queryItems = queryItems;
                convertedUrl = components.URL.absoluteString;
            } else {
                convertedUrl = imageUrl;
            }
        } else {
            // 2. For other services: Try changing extension
            convertedUrl = [imageUrl stringByReplacingOccurrencesOfString:@".webp" 
                                                               withString:@".png" 
                                                                  options:NSCaseInsensitiveSearch 
                                                                    range:NSMakeRange(0, imageUrl.length)];
        }
        
        // Cache the converted URL for future use
        if (convertedUrl) {
            [webpUrlCache setObject:convertedUrl forKey:imageUrl];
            return convertedUrl;
        }
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
        self.modpackIconView.image = [UIImage imageNamed:@"DefaultProfile"];
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
    
    // Clear any associated objects
    objc_setAssociatedObject(self, @"lastUpdateTime", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, @"lastPercentage", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, @"cellUpdateKey", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// Improved tag handling with better caching
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
    CGFloat tagHeight = 22;
    CGFloat tagSpacing = 8;
    
    // First, sort tags alphabetically and eliminate duplicates
    NSSet *uniqueTags = [NSSet setWithArray:tags];
    NSArray *sortedTags = [[uniqueTags allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    
    // Limit to a reasonable number of tags
    NSInteger maxTags = 5;
    NSArray *displayTags = sortedTags.count > maxTags ? 
                           [sortedTags subarrayWithRange:NSMakeRange(0, maxTags)] : 
                           sortedTags;
    
    // Use a measurement cache to avoid recalculating text sizes
    static NSCache *tagSizeCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tagSizeCache = [[NSCache alloc] init];
        tagSizeCache.countLimit = 100;
    });
    
    for (NSString *tag in displayTags) {
        // Skip empty tags
        if (!tag || tag.length == 0) continue;
        
        // Format tag text with proper capitalization
        NSString *formattedTag = [self formatTagName:tag];
        
        // Create tag container view
        UIView *tagView = [[UIView alloc] init];
        tagView.backgroundColor = [self colorForTag:tag];
        tagView.layer.cornerRadius = tagHeight / 2;
        tagView.layer.masksToBounds = YES;
        [self.tagsScrollView addSubview:tagView];
        [self.tagViews addObject:tagView];
        
        // Create tag label
        UILabel *tagLabel = [[UILabel alloc] init];
        tagLabel.text = formattedTag;
        tagLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        tagLabel.textColor = [UIColor whiteColor];
        tagLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [tagView addSubview:tagLabel];
        
        // Check cache for text size or calculate if needed
        NSString *cacheKey = [NSString stringWithFormat:@"%@-%@", formattedTag, NSStringFromCGSize(CGSizeMake(CGFLOAT_MAX, tagHeight))];
        NSValue *cachedSizeValue = [tagSizeCache objectForKey:cacheKey];
        CGSize textSize;
        
        if (cachedSizeValue) {
            textSize = [cachedSizeValue CGSizeValue];
        } else {
            textSize = [formattedTag boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, tagHeight)
                                                  options:NSStringDrawingUsesLineFragmentOrigin
                                               attributes:@{NSFontAttributeName: tagLabel.font}
                                                  context:nil].size;
            [tagSizeCache setObject:[NSValue valueWithCGSize:textSize] forKey:cacheKey];
        }
        
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
        
        // Check cache for text size or calculate
        NSString *moreCacheKey = [NSString stringWithFormat:@"more-%lu", (unsigned long)(sortedTags.count - maxTags)];
        NSValue *cachedMoreSize = [tagSizeCache objectForKey:moreCacheKey];
        CGSize moreTextSize;
        
        if (cachedMoreSize) {
            moreTextSize = [cachedMoreSize CGSizeValue];
        } else {
            moreTextSize = [moreText boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, tagHeight)
                                                  options:NSStringDrawingUsesLineFragmentOrigin
                                               attributes:@{NSFontAttributeName: moreLabel.font}
                                                  context:nil].size;
            [tagSizeCache setObject:[NSValue valueWithCGSize:moreTextSize] forKey:moreCacheKey];
        }
        
        CGFloat moreWidth = moreTextSize.width + 16;
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
    
    // Add proper KVO monitoring of search active state
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
    
    // Initialize data structures with thread safety
    self.categories = [NSMutableArray new];
    self.visibilityList = [NSMutableArray new];
    self.organizedModpacks = [NSMutableArray new];
    self.filteredModpacks = [NSMutableArray new];
    self.isDataLoading = NO;
    self.dataLock = [[NSLock alloc] init];
    
    // Initialize modrinth API
    self.modrinth = [ModrinthAPI new];
    
    // Setup default filters
    self.filters = @{
        @"isModpack": @(YES),
        @"name": @"",
        @"sortMethod": @"relevance" // Default sort method
    }.mutableCopy;
    
    // Load initial data
    [self updateSearchResults];
}

- (void)dealloc {
    // Remove KVO observer
    [self.searchController removeObserver:self forKeyPath:@"active"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
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

#pragma mark - Action Methods

- (void)refreshModpacks {
    // Reset any active filters that might have been applied
    [self.activeTagFilters removeAllObjects];
    [self updateFilterIndicators];
    
    // Reset search text while preserving search state
    if (self.searchController.isActive) {
        self.searchController.searchBar.text = @"";
        self.searchText = @"";
    }
    
    // Update search results with fresh data
    [self updateSearchResults];
}

- (BOOL)modpack:(NSDictionary *)modpack matchesSearchText:(NSString *)searchText andTags:(NSSet *)tagFilters {
    // Safely extract values with type checking
    NSString *title = [modpack[@"title"] isKindOfClass:[NSString class]] ? modpack[@"title"] : @"";
    NSString *description = [modpack[@"description"] isKindOfClass:[NSString class]] ? modpack[@"description"] : @"";
    
    // Ensure categories is an array
    id categoriesObj = modpack[@"categories"];
    NSArray *categories = [categoriesObj isKindOfClass:[NSArray class]] ? categoriesObj : @[];
    
    // Convert to lowercase once for efficiency
    NSString *lowerTitle = [title lowercaseString];
    NSString *lowerDescription = [description lowercaseString];
    NSString *lowerSearchText = [searchText lowercaseString];
    
    // Check if search text appears in title or description
    BOOL matchesTextContent = (searchText.length == 0) || 
                              [lowerTitle containsString:lowerSearchText] ||
                              [lowerDescription containsString:lowerSearchText];
    
    // Check if search text matches any tag/category
    BOOL matchesTextInTags = NO;
    if (searchText.length > 0) {
        for (id tagObj in categories) {
            // Ensure tag is a string
            if (![tagObj isKindOfClass:[NSString class]]) {
                continue;
            }
            
            NSString *tag = [(NSString *)tagObj lowercaseString];
            if ([tag containsString:lowerSearchText]) {
                matchesTextInTags = YES;
                break;
            }
        }
    }
    
    // Check if modpack has at least one of the active tag filters
    BOOL matchesTagFilters = (tagFilters.count == 0);
    if (!matchesTagFilters) {
        for (id tagObj in categories) {
            // Ensure tag is a string
            if (![tagObj isKindOfClass:[NSString class]]) {
                continue;
            }
            
            NSString *tag = [(NSString *)tagObj lowercaseString];
            if ([tagFilters containsObject:tag]) {
                matchesTagFilters = YES;
                break;
            }
        }
    }
    
    // Include if it matches all applicable filters
    return (matchesTextContent || matchesTextInTags) && matchesTagFilters;
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

- (void)updateSearchResults {
    // Reset pagination state to ensure we get fresh results
    self.hasMoreResults = YES;
    
    // Reset search text if not active to avoid stale results when switching back to search
    if (!self.isSearchActive) {
        self.searchText = @"";
    }
    
    [self loadSearchResultsWithPrevList:NO];
}

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    // Get current search text, ensure it's not nil
    NSString *name = self.searchController.searchBar.text ?: @"";
    
    // Create a threadsafe copy of the search state
    __block BOOL wasSearchActive = self.isSearchActive;
    __block BOOL isInitialLoad = !prevList && self.categories.count == 0;
    
    // Only show loading state for subsequent loads, not the initial load
    if (!isInitialLoad) {
        [self switchToLoadingState];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isDataLoading = NO;
        });
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Create a copy of the filters for this specific search operation to avoid thread safety issues
        NSMutableDictionary *searchFilters;
        @synchronized(self.filters) {
            searchFilters = [NSMutableDictionary dictionaryWithDictionary:self.filters];
            searchFilters[@"name"] = name;
            
            // Update main filters with current search text (in background thread)
            self.filters[@"name"] = name;
        }
        
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
        BOOL hasMoreItems = !self.modrinth.reachedLastPage;
        
        // Update UI on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            // Update pagination status first
            self.hasMoreResults = hasMoreItems;
            
            // Ensure we haven't lost the search state during the background operation
            // Only proceed with updates if current state matches the one we had when we started
            BOOL currentlySearchActive = self.isSearchActive;
            
            if (newResults) {
                // If we're not appending, reorganize completely
                if (!prevList) {
                    [self organizeModpacksByCategory:newResults];
                } else {
                    // If appending, just update our existing organization
                    [self updateOrganizedModpacks:newResults];
                }
            } else {
                // Handle error - but still set up an empty state with categories
                if (self.modrinth.lastError) {
                    showDialog(localize(@"Error", nil), self.modrinth.lastError.localizedDescription);
                } else {
                    showDialog(localize(@"Error", nil), @"Could not load modpacks. Please check your network connection.");
                }
                
                // Set up empty categories if we don't have any
                if (self.categories.count == 0) {
                    [self organizeModpacksByCategory:@[]];
                }
            }
            
            // Always update unified search results if search is active
            // This ensures the unified search results are properly populated
            if (wasSearchActive || currentlySearchActive) {
                [self updateUnifiedSearchResults];
            }
            
            // Always reset loading state and update UI
            self.isLoadingMoreResults = NO;
            [self switchToReadyState];
            
            // Reload with animations only if this is an append operation
            if (prevList) {
                // Calculate the insertion point for new rows
                NSInteger firstNewRowIndex = prevResults.count;
                NSInteger numberOfNewRows = self.unifiedSearchResults.count - firstNewRowIndex;
                
                if (numberOfNewRows > 0 && currentlySearchActive) {
                    // Create indexPaths for new rows
                    NSMutableArray *newIndexPaths = [NSMutableArray arrayWithCapacity:numberOfNewRows];
                    for (NSInteger i = firstNewRowIndex; i < self.unifiedSearchResults.count; i++) {
                        [newIndexPaths addObject:[NSIndexPath indexPathForRow:i inSection:0]];
                    }
                    
                    // Insert rows with animation
                    [self.tableView beginUpdates];
                    [self.tableView insertRowsAtIndexPaths:newIndexPaths withRowAnimation:UITableViewRowAnimationAutomatic];
                    [self.tableView endUpdates];
                } else {
                    // Fall back to full reload if there's an issue
                    [self.tableView reloadData];
                }
            } else {
                // Full reload for initial data
                [self.tableView reloadData];
            }
        });
    });
}

- (void)loadMoreResults {
    // Only proceed if we're not already loading and have more results to fetch
    if (self.isLoadingMoreResults || !self.hasMoreResults) {
        return;
    }
    
    // Set loading flag first to prevent multiple concurrent loads
    self.isLoadingMoreResults = YES;
    
    // Use a weak reference to self to prevent retain cycles
    __weak typeof(self) weakSelf = self;
    
    // Set a timeout to reset loading state if the request takes too long
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.isLoadingMoreResults) {
            weakSelf.isLoadingMoreResults = NO;
            NSLog(@"[ModpackInstall] Warning: Loading more results timed out");
        }
    });
    
    [self loadSearchResultsWithPrevList:YES];
}

#pragma mark - UI State Management

- (void)switchToLoadingState {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Avoid double-setting loading state
        if (self.isDataLoading) return;
        
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
        // Avoid double-setting ready state
        if (!self.isDataLoading) return;
        
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
        // First check if rightBarButtonItems has enough elements
        if (self.navigationItem.rightBarButtonItems.count > 1) {
            if (self.activeTagFilters.count > 0) {
                self.navigationItem.rightBarButtonItems[1].tintColor = [UIColor systemBlueColor];
            } else {
                self.navigationItem.rightBarButtonItems[1].tintColor = nil; // Default tint
            }
        }
        // If there aren't enough items, we'll handle it silently
        // This can happen during UI state transitions
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
    
    // Pre-process for quicker text search
    NSMutableDictionary *keywordCache = [NSMutableDictionary dictionary];
    for (NSString *category in categoryKeywords) {
        NSArray *keywords = categoryKeywords[category];
        for (NSString *keyword in keywords) {
            keywordCache[keyword] = category;
        }
    }
    
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
        // Use pre-processed keyword cache for faster lookups
        NSArray *titleWords = [title componentsSeparatedByString:@" "];
        for (NSString *word in titleWords) {
            NSString *category = keywordCache[word];
            if (category) {
                int currentScore = [categoryScores[category] intValue];
                categoryScores[category] = @(currentScore + 5);
            }
        }
        
        // Check for partial matches in title and description
        for (NSString *category in categoryKeywords) {
            NSArray *keywords = categoryKeywords[category];
            
            for (NSString *keyword in keywords) {
                if ([title containsString:keyword]) {
                    int currentScore = [categoryScores[category] intValue];
                    categoryScores[category] = @(currentScore + 2);
                }
                
                if ([description containsString:keyword]) {
                    int currentScore = [categoryScores[category] intValue];
                    categoryScores[category] = @(currentScore + 1);
                }
                
                // Check tags for this keyword
                for (id tagObj in safeTags) {
                    if (![tagObj isKindOfClass:[NSString class]]) continue;
                    
                    NSString *tag = [(NSString *)tagObj lowercaseString];
                    if ([tag isEqualToString:keyword]) {
                        int currentScore = [categoryScores[category] intValue];
                        categoryScores[category] = @(currentScore + 5);
                    } else if ([tag containsString:keyword]) {
                        int currentScore = [categoryScores[category] intValue];
                        categoryScores[category] = @(currentScore + 3);
                    }
                }
            }
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
    
    // Create a set to track existing modpack IDs
    NSMutableSet *existingModpackIds = [NSMutableSet set];
    
    // Collect all existing modpack IDs to avoid duplicates
    for (NSArray *categoryModpacks in self.organizedModpacks) {
        if (![categoryModpacks isKindOfClass:[NSArray class]]) continue;
        
        for (NSDictionary *modpack in categoryModpacks) {
            if (![modpack isKindOfClass:[NSDictionary class]]) continue;
            
            if ([modpack[@"id"] isKindOfClass:[NSString class]]) {
                [existingModpackIds addObject:modpack[@"id"]];
            }
        }
    }
    
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
    
    // Add new modpacks to the "Other" category, checking for duplicates
    if (otherIndex < self.organizedModpacks.count) {
        NSMutableArray *otherModpacks = self.organizedModpacks[otherIndex];
        if ([otherModpacks isKindOfClass:[NSMutableArray class]]) {
            // Create a copy of new modpacks to avoid mutation issues during iteration
            NSArray *safeNewModpacks = [newModpacks copy];
            
            for (NSDictionary *newModpack in safeNewModpacks) {
                // Skip if not a dictionary
                if (![newModpack isKindOfClass:[NSDictionary class]]) continue;
                
                // Skip if this modpack ID is already in our collection
                if ([newModpack[@"id"] isKindOfClass:[NSString class]] && 
                    [existingModpackIds containsObject:newModpack[@"id"]]) {
                    continue;
                }
                
                // Add this modpack and track its ID
                [otherModpacks addObject:newModpack];
                if ([newModpack[@"id"] isKindOfClass:[NSString class]]) {
                    [existingModpackIds addObject:newModpack[@"id"]];
                }
            }
        }
    }
    
    if (otherIndex < self.filteredModpacks.count) {
        NSMutableArray *filteredOtherModpacks = self.filteredModpacks[otherIndex];
        if ([filteredOtherModpacks isKindOfClass:[NSMutableArray class]]) {
            // Create a copy of new modpacks to avoid mutation issues during iteration
            NSArray *safeNewModpacks = [newModpacks copy];
            
            for (NSDictionary *newModpack in safeNewModpacks) {
                // Skip if not a dictionary
                if (![newModpack isKindOfClass:[NSDictionary class]]) continue;
                
                // Skip if this modpack ID is already in our collection
                if ([newModpack[@"id"] isKindOfClass:[NSString class]] && 
                    [existingModpackIds containsObject:newModpack[@"id"]]) {
                    continue;
                }
                
                // Add to filtered list as well
                [filteredOtherModpacks addObject:newModpack];
            }
        }
    }
    
    // For search mode, also append to unified search results if they match the current criteria
    if (self.isSearchActive) {
        // Create safe copies of the current search criteria
        NSString *currentSearchText = [self.searchText copy];
        NSSet *activeTagFiltersCopy = [NSSet setWithSet:self.activeTagFilters];
        
        // Create a copy of new modpacks to avoid mutation issues during iteration
        NSArray *safeNewModpacks = [newModpacks copy];
        
        for (id modpackObj in safeNewModpacks) {
            // Ensure the modpack is a dictionary
            if (![modpackObj isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            
            NSDictionary *modpack = (NSDictionary *)modpackObj;
            
            // Skip if this modpack ID is already in our collection
            if ([modpack[@"id"] isKindOfClass:[NSString class]] && 
                [existingModpackIds containsObject:modpack[@"id"]]) {
                continue;
            }
            
            // Check if the modpack passes our current filters
            BOOL matchesFilters = [self modpack:modpack matchesSearchText:currentSearchText andTags:activeTagFiltersCopy];
            
            // Add the modpack if it matches our filters
            if (matchesFilters) {
                [self.unifiedSearchResults addObject:modpack];
            }
        }
        
        // Re-sort if we added any new items
        if (currentSearchText.length > 0) {
            [self sortUnifiedResultsByRelevance:currentSearchText];
        }
    }
    
    [self.dataLock unlock];
}

- (void)updateUnifiedSearchResults {
    [self.dataLock lock];
    
    // Clear the existing unified search results
    [self.unifiedSearchResults removeAllObjects];
    
    // Create copies of filter criteria to avoid race conditions
    NSString *searchTextCopy = [self.searchText copy];
    NSSet *activeTagFiltersCopy = [NSSet setWithSet:self.activeTagFilters];
    
    // Create set to track unique modpack IDs
    NSMutableSet *addedModpackIds = [NSMutableSet set];
    
    // If we have active filters (tags or search text), apply them
    if (searchTextCopy.length > 0 || activeTagFiltersCopy.count > 0) {
        // Create a safe copy of organizedModpacks to avoid mutation issues
        NSArray *safeOrganizedModpacks = [self.organizedModpacks copy];
        
        // Process each category's modpacks
        for (NSArray *categoryModpacks in safeOrganizedModpacks) {
            if (![categoryModpacks isKindOfClass:[NSArray class]]) continue;
            
            // Process each modpack in the category
            for (id modpackObj in categoryModpacks) {
                if (![modpackObj isKindOfClass:[NSDictionary class]]) continue;
                
                NSDictionary *modpack = (NSDictionary *)modpackObj;
                
                // Skip duplicate modpacks by ID
                NSString *modpackId = modpack[@"id"];
                if (modpackId && [addedModpackIds containsObject:modpackId]) {
                    continue;
                }
                
                // Check if the modpack passes our filters
                BOOL matchesFilters = [self modpack:modpack matchesSearchText:searchTextCopy andTags:activeTagFiltersCopy];
                
                // Add the modpack if it matches our filters
                if (matchesFilters) {
                    [self.unifiedSearchResults addObject:modpack];
                    
                    // Track this ID to avoid duplicates
                    if (modpackId) {
                        [addedModpackIds addObject:modpackId];
                    }
                }
            }
        }
        
        // Sort results by relevance for text search or by popularity otherwise
        if (searchTextCopy.length > 0) {
            [self sortUnifiedResultsByRelevance:searchTextCopy];
        }
    } else {
        // Without any filters, just organize by category (no need for unified view)
    }
    
    [self.dataLock unlock];
    
    // Reload the table view on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

// New method to sort results by relevance to search term
- (void)sortUnifiedResultsByRelevance:(NSString *)searchText {
    // Convert search text to lowercase for case-insensitive comparison
    NSString *lowercaseSearchText = [searchText lowercaseString];
    
    [self.unifiedSearchResults sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
        NSString *title1 = obj1[@"title"] ?: @"";
        NSString *title2 = obj2[@"title"] ?: @"";
        NSString *lowercaseTitle1 = [title1 lowercaseString];
        NSString *lowercaseTitle2 = [title2 lowercaseString];
        
        // Check for exact title matches (highest priority)
        BOOL isExactMatch1 = [lowercaseTitle1 isEqualToString:lowercaseSearchText];
        BOOL isExactMatch2 = [lowercaseTitle2 isEqualToString:lowercaseSearchText];
        
        if (isExactMatch1 && !isExactMatch2) return NSOrderedAscending;
        if (!isExactMatch1 && isExactMatch2) return NSOrderedDescending;
        
        // Check for prefix matches (second priority)
        BOOL isPrefixMatch1 = [lowercaseTitle1 hasPrefix:lowercaseSearchText];
        BOOL isPrefixMatch2 = [lowercaseTitle2 hasPrefix:lowercaseSearchText];
        
        if (isPrefixMatch1 && !isPrefixMatch2) return NSOrderedAscending;
        if (!isPrefixMatch1 && isPrefixMatch2) return NSOrderedDescending;
        
        // Check for contains matches (third priority)
        BOOL containsMatch1 = [lowercaseTitle1 containsString:lowercaseSearchText];
        BOOL containsMatch2 = [lowercaseTitle2 containsString:lowercaseSearchText];
        
        if (containsMatch1 && !containsMatch2) return NSOrderedAscending;
        if (!containsMatch1 && containsMatch2) return NSOrderedDescending;
        
        // Check if either has the search term in its categories
        NSArray *categories1 = obj1[@"categories"];
        NSArray *categories2 = obj2[@"categories"];
        
        BOOL hasInCategories1 = NO;
        if ([categories1 isKindOfClass:[NSArray class]]) {
            for (NSString *category in categories1) {
                if ([[category lowercaseString] containsString:lowercaseSearchText]) {
                    hasInCategories1 = YES;
                    break;
                }
            }
        }
        
        BOOL hasInCategories2 = NO;
        if ([categories2 isKindOfClass:[NSArray class]]) {
            for (NSString *category in categories2) {
                if ([[category lowercaseString] containsString:lowercaseSearchText]) {
                    hasInCategories2 = YES;
                    break;
                }
            }
        }
        
        if (hasInCategories1 && !hasInCategories2) return NSOrderedAscending;
        if (!hasInCategories1 && hasInCategories2) return NSOrderedDescending;
        
        // If everything else is equal, sort alphabetically
        return [title1 localizedCaseInsensitiveCompare:title2];
    }];
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
    // Don't process if not in search mode or already loading
    if (!self.isSearchActive || self.isLoadingMoreResults || !self.hasMoreResults) {
        return;
    }
    
    // Check if we're near the bottom of the table view and should load more
    CGFloat currentOffset = scrollView.contentOffset.y;
    CGFloat contentHeight = scrollView.contentSize.height;
    CGFloat frameHeight = scrollView.frame.size.height;
    
    // Use relative threshold instead of fixed value
    CGFloat loadMoreThreshold = frameHeight * 0.8; 
    CGFloat bottomDistance = contentHeight - (currentOffset + frameHeight);
    
    if (bottomDistance < loadMoreThreshold) {
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
        return [self configureSearchModeCellAtIndexPath:indexPath cell:cell];
    }
    
    // CATEGORY MODE: Show categorized results
    return [self configureCategoryModeCellAtIndexPath:indexPath cell:cell];
}

// Helper method for configuring cells in search mode
- (UITableViewCell *)configureSearchModeCellAtIndexPath:(NSIndexPath *)indexPath cell:(ModpackVersionCell *)cell {
    // Safely access data with proper locking
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
    
    // Create a safe copy of the modpack data
    NSDictionary *modpack = [self.unifiedSearchResults[indexPath.row] copy];
    
    [self.dataLock unlock];
    
    // Configure cell with the modpack data
    [self configureCell:cell withModpack:modpack];
    
    return cell;
}

// Helper method for configuring cells in category mode
- (UITableViewCell *)configureCategoryModeCellAtIndexPath:(NSIndexPath *)indexPath cell:(ModpackVersionCell *)cell {
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
    
    // Create a safe copy of the modpack data
    NSDictionary *modpack = [self.organizedModpacks[indexPath.section][indexPath.row] copy];
    
    [self.dataLock unlock];
    
    // Configure cell with the modpack data
    [self configureCell:cell withModpack:modpack];
    
    return cell;
}

// Helper method for configuring a cell with modpack data
- (void)configureCell:(ModpackVersionCell *)cell withModpack:(NSDictionary *)modpack {
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
        
        // Extra validation for URL
        if (!iconURL) {
            cell.modpackIconView.image = fallbackImage;
        } else {
            // Use the shared image downloader from AFNetworking with clear cache policy
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:iconURL];
            [request setHTTPShouldHandleCookies:NO];
            [request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData]; // Force reload, ignore cache
            
            // Set a specific timeout to avoid long waits
            [request setTimeoutInterval:15.0];
            
            // Cancel any previous image requests for this cell to prevent wrong images
            [cell.modpackIconView cancelImageDownloadTask];
            
            // Use a tag to track which image URL is being loaded for this cell
            static int lastTag = 1000;
            int currentTag = ++lastTag;
            cell.modpackIconView.tag = currentTag;
            
            // Use the AFNetworking category with our custom request
            [cell.modpackIconView setImageWithURLRequest:request 
                                        placeholderImage:fallbackImage 
                                                 success:^(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image) {
                                                     // Only update if the tag still matches (cell hasn't been reused)
                                                     if (cell.modpackIconView.tag == currentTag) {
                                                         // Apply the image with a fade-in animation
                                                         [UIView transitionWithView:cell.modpackIconView
                                                                           duration:0.3
                                                                            options:UIViewAnimationOptionTransitionCrossDissolve
                                                                         animations:^{
                                                                             cell.modpackIconView.image = image;
                                                                         } completion:nil];
                                                     }
                                                 } 
                                                 failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error) {
                                                     // Ensure fallback image is set if the tag still matches
                                                     if (cell.modpackIconView.tag == currentTag) {
                                                         cell.modpackIconView.image = fallbackImage;
                                                     }
                                                 }];
        }
    } else {
        // If no URL, use fallback immediately
        cell.modpackIconView.image = fallbackImage;
    }
    
    // Always show disclosure indicator, regardless of whether details are loaded
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.accessoryView = nil;
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
    
    // Thread-safe access to get the modpack data
    [self.dataLock lock];
    
    // Get the modpack based on whether we're in search mode or category mode
    if (self.isSearchActive) {
        // Check bounds for search mode
        if (indexPath.row < self.unifiedSearchResults.count && self.unifiedSearchResults.count > 0) {
            // Make a safe copy to avoid race conditions
            modpack = [self.unifiedSearchResults[indexPath.row] copy];
        }
    } else {
        // Check bounds for category mode
        if (indexPath.section < self.organizedModpacks.count && 
            indexPath.row < [self.organizedModpacks[indexPath.section] count] && 
            self.organizedModpacks.count > 0) {
            // Make a safe copy to avoid race conditions
            modpack = [self.organizedModpacks[indexPath.section][indexPath.row] copy];
        }
    }
    
    [self.dataLock unlock];
    
    // Check if we got a valid modpack
    if (!modpack) {
        NSLog(@"[ModpackInstall] Error: No valid modpack found at indexPath (%ld, %ld)", 
              (long)indexPath.section, (long)indexPath.row);
        return;
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
    
    // Create a weak reference to self to avoid retain cycles
    __weak typeof(self) weakSelf = self;
    
    // Store a reference to cell for cancellation check
    static int lastCellTagOperation = 0;
    int thisOperation = ++lastCellTagOperation;
    objc_setAssociatedObject(cell, @"detailLoadOperation", @(thisOperation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Load details in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [weakSelf.modrinth loadDetailsOfMod:modpack];
        
        // Check if this operation was cancelled by a new one
        if (!cell) {
            return; // Cell is no longer available, operation might be cancelled
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Check if this is still the current operation
            NSNumber *currentOperation = objc_getAssociatedObject(cell, @"detailLoadOperation");
            if (![currentOperation isEqual:@(thisOperation)]) {
                return; // A newer operation is in progress, discard this one
            }
            
            // Update cell to use disclosure indicator - check if cell is still visible
            UITableViewCell *updatedCell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
            if (updatedCell) {
                updatedCell.accessoryView = nil;
                updatedCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            
            // Update data model - find the modpack in all lists and update it
            [weakSelf updateModpackInDataStructures:modpack];
            
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
                
                // Use a tag to track which image URL is being loaded
                static int lastImageTag = 1000;
                int currentImageTag = ++lastImageTag;
                versionCell.modpackIconView.tag = currentImageTag;
                
                // Load the updated image
                [versionCell.modpackIconView setImageWithURLRequest:request 
                                                   placeholderImage:versionCell.modpackIconView.image ?: [UIImage imageNamed:@"DefaultProfile"]
                                                            success:^(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image) {
                                                                if (versionCell.modpackIconView.tag == currentImageTag) {
                                                                    [UIView transitionWithView:versionCell.modpackIconView
                                                                                      duration:0.3
                                                                                       options:UIViewAnimationOptionTransitionCrossDissolve
                                                                                    animations:^{
                                                                                        versionCell.modpackIconView.image = image;
                                                                                    } completion:nil];
                                                                }
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
                [weakSelf showVersionMenu:modpack atIndexPath:indexPath];
            } else {
                if (weakSelf.modrinth.lastError) {
                    showDialog(localize(@"Error", nil), weakSelf.modrinth.lastError.localizedDescription);
                } else {
                    showDialog(localize(@"Error", nil), @"Failed to load modpack details. Please try again later.");
                }
            }
        });
    });
}

// Helper method to update modpack data across all data structures
- (void)updateModpackInDataStructures:(NSDictionary *)modpack {
    [self.dataLock lock];
    
    // Get the modpack ID for comparison
    NSString *modpackId = modpack[@"id"];
    if (!modpackId) {
        [self.dataLock unlock];
        return;
    }
    
    // Update in organized lists
    for (NSMutableArray *category in self.organizedModpacks) {
        if (![category isKindOfClass:[NSMutableArray class]]) continue;
        
        for (NSInteger i = 0; i < category.count; i++) {
            NSDictionary *item = category[i];
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            
            if ([item[@"id"] isEqual:modpackId]) {
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
            
            if ([item[@"id"] isEqual:modpackId]) {
                category[i] = modpack;
            }
        }
    }
    
    // Update in unified search results
    for (NSInteger i = 0; i < self.unifiedSearchResults.count; i++) {
        NSDictionary *item = self.unifiedSearchResults[i];
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        
        if ([item[@"id"] isEqual:modpackId]) {
            self.unifiedSearchResults[i] = modpack;
        }
    }
    
    [self.dataLock unlock];
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
    
    // Create a weak reference to self to prevent retain cycles
    __weak typeof(self) weakSelf = self;
    
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
                [weakSelf actionClose];
                
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
                [weakSelf.modrinth installModpackFromDetail:modpackWithCategories atIndex:i];
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
