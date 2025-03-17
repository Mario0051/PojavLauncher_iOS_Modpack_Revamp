#import "AFNetworking.h"
#import "ForgeInstallViewController.h"
#import "LauncherNavigationController.h"
#import "WFWorkflowProgressView.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <dlfcn.h>

// Custom cell for version display
@interface ForgeVersionCell : UITableViewCell
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *releaseTypeLabel;
@property (nonatomic, strong) UIView *releaseTypeTagView;
@end

@implementation ForgeVersionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        // Version label (main title)
        self.versionLabel = [[UILabel alloc] init];
        self.versionLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.versionLabel];
        
        // Release type tag background
        self.releaseTypeTagView = [[UIView alloc] init];
        self.releaseTypeTagView.layer.cornerRadius = 10;
        self.releaseTypeTagView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.releaseTypeTagView];
        
        // Release type label
        self.releaseTypeLabel = [[UILabel alloc] init];
        self.releaseTypeLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        self.releaseTypeLabel.textColor = [UIColor whiteColor];
        self.releaseTypeLabel.textAlignment = NSTextAlignmentCenter;
        self.releaseTypeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.releaseTypeTagView addSubview:self.releaseTypeLabel];
        
        // Add disclosure indicator
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        
        // Constraints for version label
        [NSLayoutConstraint activateConstraints:@[
            [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [self.versionLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.releaseTypeTagView.leadingAnchor constant:-8],
            [self.versionLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10]
        ]];
        
        // Constraints for tag view
        [NSLayoutConstraint activateConstraints:@[
            [self.releaseTypeTagView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-44],
            [self.releaseTypeTagView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.releaseTypeTagView.widthAnchor constraintGreaterThanOrEqualToConstant:80],
            [self.releaseTypeTagView.heightAnchor constraintEqualToConstant:24]
        ]];
        
        // Constraints for release type label
        [NSLayoutConstraint activateConstraints:@[
            [self.releaseTypeLabel.leadingAnchor constraintEqualToAnchor:self.releaseTypeTagView.leadingAnchor constant:8],
            [self.releaseTypeLabel.trailingAnchor constraintEqualToAnchor:self.releaseTypeTagView.trailingAnchor constant:-8],
            [self.releaseTypeLabel.topAnchor constraintEqualToAnchor:self.releaseTypeTagView.topAnchor],
            [self.releaseTypeLabel.bottomAnchor constraintEqualToAnchor:self.releaseTypeTagView.bottomAnchor]
        ]];
    }
    return self;
}

@end

// Custom header view for Minecraft versions
@interface MinecraftVersionHeaderView : UITableViewHeaderFooterView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIImageView *chevronImageView;
@property (nonatomic, strong) UIButton *expandCollapseButton;
@property (nonatomic, assign) BOOL isExpanded;
@end

@implementation MinecraftVersionHeaderView

- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithReuseIdentifier:reuseIdentifier];
    if (self) {
        // Create a container view with background
        UIView *containerView = [[UIView alloc] init];
        containerView.backgroundColor = [UIColor systemGroupedBackgroundColor];
        containerView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:containerView];
        
        // Title label
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [containerView addSubview:self.titleLabel];
        
        // Chevron indicator
        self.chevronImageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        self.chevronImageView.tintColor = [UIColor systemGrayColor];
        self.chevronImageView.translatesAutoresizingMaskIntoConstraints = NO;
        self.chevronImageView.contentMode = UIViewContentModeScaleAspectFit;
        [containerView addSubview:self.chevronImageView];
        
        // Button to expand/collapse (covers the whole header area)
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

@interface ForgeInstallViewController()<NSXMLParserDelegate>
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) NSString *searchText;
@property(atomic) AFURLSessionManager *afManager;
@property(nonatomic) WFWorkflowProgressView *progressView;
// Use UITableViewController's built-in refreshControl

@property(nonatomic) NSDictionary *endpoints;
@property(nonatomic) NSMutableArray<NSNumber *> *visibilityList;
@property(nonatomic) NSMutableArray<NSString *> *versionList;
@property(nonatomic) NSMutableArray<NSMutableArray *> *forgeList;
@property(nonatomic) NSMutableArray<NSMutableArray *> *filteredForgeList;
@property(nonatomic, assign) BOOL isVersionElement;
@property(nonatomic, strong) NSMutableString *currentVersionValue;
@property(nonatomic, strong) NSString *currentVendor;
@property(nonatomic, strong) NSIndexPath *currentDownloadIndexPath;
@end

@implementation ForgeInstallViewController
// Acknowledge that refreshControl is implemented by superclass
@dynamic refreshControl;

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
    
    // Configure table view
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }
    
    // Additional settings to prevent header stickiness
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    
    // Register custom cell and header view
    [self.tableView registerClass:[ForgeVersionCell class] forCellReuseIdentifier:@"ForgeVersionCell"];
    [self.tableView registerClass:[MinecraftVersionHeaderView class] forHeaderFooterViewReuseIdentifier:@"MinecraftVersionHeader"];
    
    // Setup segmented control for vendor selection
    UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:@[@"Forge", @"NeoForge"]];
    segment.selectedSegmentIndex = 0;
    [segment addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = segment;
    self.currentVendor = @"Forge";

    // Setup search controller
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = (id<UISearchResultsUpdating>)self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search versions";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    
    // Setup refresh control
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(refreshVersions) forControlEvents:UIControlEventValueChanged];
    [self.tableView addSubview:self.refreshControl];

    // Load WorkflowProgressView for download progress
    dlopen("/System/Library/PrivateFrameworks/WorkflowUIServices.framework/WorkflowUIServices", RTLD_GLOBAL);
    self.progressView = [[NSClassFromString(@"WFWorkflowProgressView") alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    self.progressView.resolvedTintColor = self.view.tintColor;
    [self.progressView addTarget:self action:@selector(actionCancelDownload) forControlEvents:UIControlEventTouchUpInside];

    // Configure endpoints for both Forge and NeoForge
    self.endpoints = @{
        @"Forge": @{
            @"installer": @"https://maven.minecraftforge.net/net/minecraftforge/forge/%1$@/forge-%1$@-installer.jar",
            @"metadata": @"https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
        },
        @"NeoForge": @{
            @"installer": @"https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@/neoforge-%1$@-installer.jar",
            @"metadata": @"https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
        }
    };
    
    // Initialize data structures
    self.visibilityList = [NSMutableArray new];
    self.versionList = [NSMutableArray new];
    self.forgeList = [NSMutableArray new];
    self.filteredForgeList = [NSMutableArray new];
    self.currentVersionValue = [NSMutableString new];
    
    // Load initial data
    [self loadMetadataFromVendor:@"Forge"];
}

#pragma mark - Action Methods

- (void)actionCancelDownload {
    // Reset the current download cell's appearance
    if (self.currentDownloadIndexPath) {
        [self resetCellAppearance:self.currentDownloadIndexPath];
        self.currentDownloadIndexPath = nil;
    }
    
    [self.afManager invalidateSessionCancelingTasks:YES resetSession:NO];
    showDialog(@"Download Cancelled", @"The download has been cancelled.");
}

- (void)resetCellAppearance:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)segmentChanged:(UISegmentedControl *)segment {
    // Clear existing data
    [self.visibilityList removeAllObjects];
    [self.versionList removeAllObjects];
    [self.forgeList removeAllObjects];
    [self.filteredForgeList removeAllObjects];
    [self.tableView reloadData];
    
    // Reset search if active
    if (self.searchController.isActive) {
        [self.searchController dismissViewControllerAnimated:YES completion:nil];
    }
    
    // Get selected vendor and load data
    NSString *vendor = [segment titleForSegmentAtIndex:segment.selectedSegmentIndex];
    self.currentVendor = vendor;
    [self loadMetadataFromVendor:vendor];
}

- (void)refreshVersions {
    // Clear existing data
    [self.visibilityList removeAllObjects];
    [self.versionList removeAllObjects];
    [self.forgeList removeAllObjects];
    [self.filteredForgeList removeAllObjects];
    
    // Load data again
    [self loadMetadataFromVendor:self.currentVendor];
}

#pragma mark - Data Loading

- (void)loadMetadataFromVendor:(NSString *)vendor {
    [self switchToLoadingState];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *url = [[NSURL alloc] initWithString:self.endpoints[vendor][@"metadata"]];
        NSXMLParser *parser = [[NSXMLParser alloc] initWithContentsOfURL:url];
        parser.delegate = self;
        
        // Initialize version value buffer
        self.currentVersionValue = [NSMutableString new];
        
        if (![parser parse]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.refreshControl endRefreshing];
                showDialog(localize(@"Error", nil), parser.parserError.localizedDescription);
                [self actionClose];
            });
        }
    });
}

#pragma mark - UI State Management

- (void)switchToLoadingState {
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    [indicator startAnimating];
    self.navigationController.modalInPresentation = YES;
}

- (void)switchToReadyState {
    UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItem.customView;
    [indicator stopAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationController.modalInPresentation = NO;
    [self.refreshControl endRefreshing];
}

#pragma mark - Search Results Updating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *searchText = searchController.searchBar.text;
    self.searchText = searchText;
    
    if (searchText.length == 0) {
        // If search is empty, clear filtered data and show all sections
        [self.filteredForgeList removeAllObjects];
        for (NSMutableArray *forgeVersions in self.forgeList) {
            [self.filteredForgeList addObject:[forgeVersions mutableCopy]];
        }
    } else {
        // Filter versions based on search text
        [self.filteredForgeList removeAllObjects];
        
        for (NSUInteger i = 0; i < self.forgeList.count; i++) {
            NSMutableArray *sectionVersions = self.forgeList[i];
            NSMutableArray *filteredSectionVersions = [NSMutableArray new];
            
            for (NSString *version in sectionVersions) {
                NSString *displayName = [self getDisplayName:version];
                if ([displayName localizedCaseInsensitiveContainsString:searchText]) {
                    [filteredSectionVersions addObject:version];
                }
            }
            
            [self.filteredForgeList addObject:filteredSectionVersions];
            
            // Expand sections with matching results
            if (filteredSectionVersions.count > 0) {
                self.visibilityList[i] = @YES;
            }
        }
    }
    
    [self.tableView reloadData];
}

#pragma mark - Version Parsing and Management

- (NSString *)extractMinecraftVersionFromForgeVersion:(NSString *)version {
    // For Forge, we want to use a simpler approach similar to the older implementation
    // First check for a valid format like "1.X.Y-forgeVersion" or "1.X-forgeVersion"
    NSRange hyphenRange = [version rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound) {
        NSString *mcPortion = [version substringToIndex:hyphenRange.location];
        
        // Simple validation for Minecraft version format (1.X or 1.X.Y)
        NSRegularExpression *mcRegex = [NSRegularExpression 
            regularExpressionWithPattern:@"^1\\.[0-9]+(\\.[0-9]+)?$" 
            options:0 error:nil];
            
        NSRange fullRange = NSMakeRange(0, mcPortion.length);
        if ([mcRegex firstMatchInString:mcPortion options:0 range:fullRange]) {
            return mcPortion;
        }
    }
    
    return @"Unknown";
}

- (NSString *)extractMinecraftVersionFromNeoForgeVersion:(NSString *)version {
    // NeoForge versioning scheme:
    // Format: [Minecraft version without 1.].[NeoForge version][-beta/alpha]
    // Example: "21.4.114-beta" for Minecraft 1.21.4
    
    // First remove any beta/alpha/etc. suffix
    NSString *cleanVersion = version;
    NSRange hyphenRange = [version rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound) {
        cleanVersion = [version substringToIndex:hyphenRange.location];
    }
    
    // Extract the first part (Minecraft version without the leading "1.")
    NSArray *components = [cleanVersion componentsSeparatedByString:@"."];
    if (components.count >= 2) {
        // Take first two components which represent Minecraft version (without the 1.)
        NSString *majorComponent = components[0];
        NSString *minorComponent = components[1];
        
        // Validate components are numeric
        if ([self isNumeric:majorComponent] && [self isNumeric:minorComponent]) {
            // Reconstruct as 1.x.y
            NSString *mcVersion = [NSString stringWithFormat:@"1.%@.%@", majorComponent, minorComponent];
            return mcVersion;
        }
    }
    
    // Fallback: Look for version pattern that might indicate Minecraft version
    NSRegularExpression *versionRegex = [NSRegularExpression 
        regularExpressionWithPattern:@"(\\d+\\.\\d+)" 
        options:0 error:nil];
    
    NSTextCheckingResult *match = [versionRegex firstMatchInString:version options:0 range:NSMakeRange(0, version.length)];
    if (match) {
        NSString *extractedPart = [version substringWithRange:match.range];
        return [NSString stringWithFormat:@"1.%@", extractedPart];
    }
    
    return @"Unknown";
}

// Check if a Forge version is unsupported (Forge 1.5.1 and below)
- (BOOL)isUnsupportedForgeVersion:(NSString *)version {
    if (![self.currentVendor isEqualToString:@"Forge"]) {
        return NO; // Only applies to Forge
    }
    
    NSString *mcVersion = [self extractMinecraftVersionFromForgeVersion:version];
    if ([mcVersion isEqualToString:@"Unknown"]) {
        return NO;
    }
    
    // Compare the Minecraft version to 1.5.1
    NSArray *components = [mcVersion componentsSeparatedByString:@"."];
    
    // Must have at least major.minor format
    if (components.count < 2) {
        return NO;
    }
    
    // Check major version (must be 1)
    if ([components[0] integerValue] != 1) {
        return NO;
    }
    
    // Check minor version
    NSInteger minorVersion = [components[1] integerValue];
    if (minorVersion > 5) {
        return NO; // Forge for MC > 1.5 is supported
    }
    
    if (minorVersion < 5) {
        return YES; // Forge for MC < 1.5 is unsupported
    }
    
    // For 1.5.x, we need to check patch version
    if (components.count > 2) {
        NSInteger patchVersion = [components[2] integerValue];
        if (patchVersion <= 1) {
            return YES; // 1.5.0 and 1.5.1 are unsupported
        }
    } else {
        return YES; // Just "1.5" is considered unsupported
    }
    
    return NO;
}

- (NSString *)getDisplayName:(NSString *)version {
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        // For NeoForge, we need a clear display format that shows both version components
        NSString *mcVersion = [self extractMinecraftVersionFromNeoForgeVersion:version];
        
        // Format: "NeoForge [Version] (Minecraft [mcVersion])"
        if (![mcVersion isEqualToString:@"Unknown"]) {
            return [NSString stringWithFormat:@"NeoForge %@ (Minecraft %@)", 
                    version, mcVersion];
        } else {
            return [NSString stringWithFormat:@"NeoForge %@", version];
        }
    } else {
        // For Forge, extract the forge version part after the hyphen
        NSString *mcVersion = [self extractMinecraftVersionFromForgeVersion:version];
        NSRange hyphenRange = [version rangeOfString:@"-"];
        
        if (hyphenRange.location != NSNotFound && ![mcVersion isEqualToString:@"Unknown"]) {
            NSString *forgeVersion = [version substringFromIndex:hyphenRange.location + 1];
            return [NSString stringWithFormat:@"Forge %@ (Minecraft %@)", forgeVersion, mcVersion];
        } else {
            return version;
        }
    }
}

- (UIColor *)getColorForVersionType:(NSString *)version {
    if ([version containsString:@"recommended"]) {
        return [UIColor systemGreenColor];
    } else if ([version containsString:@"beta"] || [version containsString:@"-beta"]) {
        return [UIColor systemOrangeColor];
    } else if ([version containsString:@"alpha"] || [version containsString:@"-alpha"]) {
        return [UIColor systemRedColor];
    } else {
        return [UIColor systemBlueColor]; // Release version
    }
}

- (NSString *)getLabelForVersionType:(NSString *)version {
    if ([version containsString:@"recommended"]) {
        return @"Recommended";
    } else if ([version containsString:@"beta"] || [version containsString:@"-beta"]) {
        return @"Beta";
    } else if ([version containsString:@"alpha"] || [version containsString:@"-alpha"]) {
        return @"Alpha";
    } else {
        return @"Release";
    }
}

- (BOOL)isNumeric:(NSString *)string {
    if (!string || string.length == 0) return NO;
    
    NSCharacterSet *nonNumbers = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [string rangeOfCharacterFromSet:nonNumbers].location == NSNotFound;
}

- (void)addVersionToList:(NSString *)version {
    // Skip invalid versions
    if (version.length == 0) {
        return;
    }
    
    // Handle Forge and NeoForge differently
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        // Skip NeoForge versions with problematic patterns
        NSArray *skipPatterns = @[
            @"sources", @"userdev", @"javadoc", @"universal", @"slim", 
            @"-javadoc", @"-sources", @"-all", @"-changelog", 
            @"-installer-win", @"-mdk"
        ];
        
        for (NSString *pattern in skipPatterns) {
            if ([version containsString:pattern]) {
                NSLog(@"[ForgeInstall] Skipping problematic NeoForge version: %@", version);
                return;
            }
        }
        
        // Extract NeoForge minecraft version
        NSString *minecraftVersion = [self extractMinecraftVersionFromNeoForgeVersion:version];
        
        // Skip versions with unknown Minecraft version
        if ([minecraftVersion isEqualToString:@"Unknown"]) {
            NSLog(@"[ForgeInstall] Skipping NeoForge version with unknown MC version: %@", version);
            return;
        }
        
        // Add to section - do exact string matching for section headers
        NSUInteger sectionIndex = NSNotFound;
        for (NSUInteger i = 0; i < self.versionList.count; i++) {
            if ([self.versionList[i] isEqualToString:minecraftVersion]) {
                sectionIndex = i;
                break;
            }
        }
        
        if (sectionIndex == NSNotFound) {
            [self.versionList addObject:minecraftVersion];
            [self.visibilityList addObject:@NO]; // Start collapsed
            [self.forgeList addObject:[NSMutableArray new]];
            sectionIndex = self.versionList.count - 1;
        }
        
        // Add version to this section if not already present
        if (![self.forgeList[sectionIndex] containsObject:version]) {
            [self.forgeList[sectionIndex] addObject:version];
            NSLog(@"[ForgeInstall] Added NeoForge %@ to %@ section", version, minecraftVersion);
        }
    } else {
        // FORGE SPECIFIC HANDLING - SIMPLIFIED VERSION
        // Skip versions without a hyphen (need mcVersion-forgeVersion format)
        if (![version containsString:@"-"]) {
            NSLog(@"[ForgeInstall] Skipping invalid Forge version format: %@", version);
            return;
        }
        
        // Skip Forge versions with these known problematic patterns
        NSArray *skipPatterns = @[
            @"mdk", @"userdev", @"javadoc", @"src", @"sources", @"universal",
            @"-all", @"-changelog", @"-client", @"-server", @"-launcher"
        ];
        
        for (NSString *pattern in skipPatterns) {
            if ([version containsString:pattern]) {
                NSLog(@"[ForgeInstall] Skipping problematic Forge version: %@", version);
                return;
            }
        }
        
        // Simply get minecraft version - part before the hyphen
        NSRange hyphenRange = [version rangeOfString:@"-"];
        NSString *minecraftVersion = [version substringToIndex:hyphenRange.location];
        
        // Add to section - do exact string matching for section headers
        NSUInteger sectionIndex = NSNotFound;
        for (NSUInteger i = 0; i < self.versionList.count; i++) {
            if ([self.versionList[i] isEqualToString:minecraftVersion]) {
                sectionIndex = i;
                break;
            }
        }
        
        if (sectionIndex == NSNotFound) {
            [self.versionList addObject:minecraftVersion];
            [self.visibilityList addObject:@NO]; // Start collapsed
            [self.forgeList addObject:[NSMutableArray new]];
            sectionIndex = self.versionList.count - 1;
        }
        
        // Add version to this section if not already present
        if (![self.forgeList[sectionIndex] containsObject:version]) {
            [self.forgeList[sectionIndex] addObject:version];
            NSLog(@"[ForgeInstall] Added Forge %@ to %@ section", version, minecraftVersion);
        }
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.versionList.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < self.visibilityList.count && self.visibilityList[section].boolValue) {
        return self.searchController.isActive ? self.filteredForgeList[section].count : self.forgeList[section].count;
    }
    return 0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    MinecraftVersionHeaderView *headerView = [tableView dequeueReusableHeaderFooterViewWithIdentifier:@"MinecraftVersionHeader"];
    
    // Apply the section title
    NSString *mcVersion = self.versionList[section];
    if ([mcVersion hasPrefix:@"1."]) {
        headerView.titleLabel.text = [NSString stringWithFormat:@"Minecraft %@", mcVersion];
    } else {
        headerView.titleLabel.text = mcVersion;
    }
    
    // Set expanded state
    headerView.isExpanded = self.visibilityList[section].boolValue;
    
    // Store the section index
    headerView.expandCollapseButton.tag = section;
    
    // Add action for the button
    [headerView.expandCollapseButton addTarget:self action:@selector(toggleSection:) forControlEvents:UIControlEventTouchUpInside];
    
    return headerView;
}

- (void)toggleSection:(UIButton *)sender {
    NSInteger section = sender.tag;
    
    // Check if the section is valid
    if (section >= 0 && section < self.visibilityList.count) {
        // Toggle section visibility
        self.visibilityList[section] = @(!self.visibilityList[section].boolValue);
        
        // Update section
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationFade];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 60.0; // Consistent height
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 56.0; // Consistent cell height
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ForgeVersionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ForgeVersionCell" forIndexPath:indexPath];
    
    // Get the version based on search state
    NSString *version = self.searchController.isActive ? 
        self.filteredForgeList[indexPath.section][indexPath.row] : 
        self.forgeList[indexPath.section][indexPath.row];
    
    BOOL isUnsupported = [self isUnsupportedForgeVersion:version];
    
    // Update text label
    NSString *displayName = [self getDisplayName:version];
    if (isUnsupported) {
        NSMutableAttributedString *attributedText = [[NSMutableAttributedString alloc] initWithString:displayName];
        [attributedText appendAttributedString:[[NSAttributedString alloc] initWithString:@" (UNSUPPORTED)" attributes:@{
            NSForegroundColorAttributeName: [UIColor systemRedColor],
            NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightBold]
        }]];
        cell.versionLabel.attributedText = attributedText;
    } else {
        cell.versionLabel.attributedText = nil;
        cell.versionLabel.text = displayName;
    }
    
    // Set release type tag
    cell.releaseTypeLabel.text = [self getLabelForVersionType:version];
    cell.releaseTypeTagView.backgroundColor = [self getColorForVersionType:version];
    
    // Disable selection for unsupported versions
    cell.selectionStyle = isUnsupported ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    cell.accessoryType = isUnsupported ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    // Get the version based on search state
    NSString *versionString = self.searchController.isActive ? 
        self.filteredForgeList[indexPath.section][indexPath.row] : 
        self.forgeList[indexPath.section][indexPath.row];
    
    // Check if the selected version is unsupported
    if ([self isUnsupportedForgeVersion:versionString]) {
        // Show dialog for unsupported versions
        showDialog(@"Unsupported Version", 
                  @"This version is currently not available due to how it requires manual setup.");
        return;
    }
    
    // Store the current download index path
    self.currentDownloadIndexPath = indexPath;
    
    // Continue with normal installation for supported versions
    tableView.allowsSelection = NO;
    [self switchToLoadingState];
    self.progressView.fractionCompleted = 0;

    ForgeVersionCell *cell = (ForgeVersionCell *)[tableView cellForRowAtIndexPath:indexPath];
    cell.accessoryView = self.progressView;
    cell.accessoryType = UITableViewCellAccessoryNone;

    NSString *jarURL = [NSString stringWithFormat:self.endpoints[self.currentVendor][@"installer"], versionString];
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tmp.jar"];
    NSLog(@"[%@ Installer] Downloading %@", self.currentVendor, jarURL);

    self.afManager = [AFURLSessionManager new];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:jarURL]];
    NSURLSessionDownloadTask *downloadTask = [self.afManager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull progress){
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressView.fractionCompleted = progress.fractionCompleted;
        });
    } destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
        [NSFileManager.defaultManager removeItemAtPath:outPath error:nil];
        return [NSURL fileURLWithPath:outPath];
    } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            tableView.allowsSelection = YES;
            [self resetCellAppearance:indexPath];
            self.currentDownloadIndexPath = nil;
            
            if (error) {
                if (error.code != NSURLErrorCancelled) {
                    NSLog(@"Error: %@", error);
                    showDialog(localize(@"Error", nil), error.localizedDescription);
                }
                [self switchToReadyState];
                return;
            }
            
            // Show success message
            showDialog(@"Download Complete", 
                      [NSString stringWithFormat:@"%@ installer will now run. After installation completes, you may need to restart the app.", self.currentVendor]);
            
            LauncherNavigationController *navVC = (id)((UISplitViewController *)self.presentingViewController).viewControllers[1];
            [self dismissViewControllerAnimated:YES completion:^{
                [navVC enterModInstallerWithPath:outPath hitEnterAfterWindowShown:YES];
            }];
        });
    }];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [downloadTask resume];
    });
}

#pragma mark - NSXMLParserDelegate

- (void)parserDidEndDocument:(NSXMLParser *)parser {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Sort Minecraft versions (sections) with newest first
        [self sortVersionSections];
        
        // Sort versions within each section with newest first
        [self sortVersionsWithinSections];
        
        // Create filtered list (initially same as full list)
        [self.filteredForgeList removeAllObjects];
        for (NSMutableArray *forgeVersions in self.forgeList) {
            [self.filteredForgeList addObject:[forgeVersions mutableCopy]];
        }
        
        // Expand the first (newest) section by default
        if (self.versionList.count > 0) {
            self.visibilityList[0] = @YES;
        }
        
        [self switchToReadyState];
        [self.tableView reloadData];
        
        // Scroll to top
        if (self.versionList.count > 0) {
            [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0] 
                                  atScrollPosition:UITableViewScrollPositionTop 
                                          animated:YES];
        }
    });
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qualifiedName attributes:(NSDictionary *)attributeDict {
    self.isVersionElement = [elementName isEqualToString:@"version"];
    if (self.isVersionElement) {
        [self.currentVersionValue setString:@""];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (self.isVersionElement) {
        [self.currentVersionValue appendString:string];
    }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if ([elementName isEqualToString:@"version"]) {
        NSString *versionString = [self.currentVersionValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (versionString.length > 0) {
            [self addVersionToList:versionString];
        }
        self.isVersionElement = NO;
    }
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.refreshControl endRefreshing];
        showDialog(@"Error Loading Versions", parseError.localizedDescription);
        [self switchToReadyState];
    });
}

#pragma mark - Sorting Methods

- (void)sortVersionSections {
    // Create maps to maintain the relationship between versions and their data
    NSMutableDictionary *versionToForgeList = [NSMutableDictionary new];
    NSMutableDictionary *versionToVisibility = [NSMutableDictionary new];
    
    // Store the current data in the dictionaries
    for (NSInteger i = 0; i < self.versionList.count; i++) {
        NSString *version = self.versionList[i];
        versionToForgeList[version] = self.forgeList[i];
        versionToVisibility[version] = self.visibilityList[i];
    }
    
    // Sort the version list
    NSArray *sortedVersions = [self.versionList sortedArrayUsingComparator:^NSComparisonResult(NSString *version1, NSString *version2) {
        // Handle special categories
        if ([version1 isEqualToString:@"Unknown"]) return NSOrderedDescending;
        if ([version2 isEqualToString:@"Unknown"]) return NSOrderedAscending;
        
        return [self compareMinecraftVersions:version2 to:version1]; // Reversed for newest first
    }];
    
    // Clear and refill the arrays in the sorted order
    [self.versionList removeAllObjects];
    [self.forgeList removeAllObjects];
    [self.visibilityList removeAllObjects];
    
    for (NSString *version in sortedVersions) {
        [self.versionList addObject:version];
        [self.forgeList addObject:versionToForgeList[version]];
        [self.visibilityList addObject:versionToVisibility[version]];
    }
}

- (void)sortVersionsWithinSections {
    // Sort versions within each section with newest first
    for (NSUInteger i = 0; i < self.forgeList.count; i++) {
        NSMutableArray *sectionVersions = self.forgeList[i];
        
        [sectionVersions sortUsingComparator:^NSComparisonResult(NSString *version1, NSString *version2) {
            // For Forge versions, compare version numbers
            if ([self.currentVendor isEqualToString:@"Forge"]) {
                // Extract forge version numbers
                NSRange hyphen1 = [version1 rangeOfString:@"-"];
                NSRange hyphen2 = [version2 rangeOfString:@"-"];
                
                if (hyphen1.location != NSNotFound && hyphen2.location != NSNotFound) {
                    NSString *forgeVersion1 = [version1 substringFromIndex:hyphen1.location + 1];
                    NSString *forgeVersion2 = [version2 substringFromIndex:hyphen2.location + 1];
                    
                    // Compare by recommended/latest first, then release type, then version number
                    BOOL isRecommended1 = [forgeVersion1 containsString:@"recommended"];
                    BOOL isRecommended2 = [forgeVersion2 containsString:@"recommended"];
                    
                    if (isRecommended1 && !isRecommended2) return NSOrderedAscending;
                    if (!isRecommended1 && isRecommended2) return NSOrderedDescending;
                    
                    // Check for beta/alpha
                    BOOL isBeta1 = [forgeVersion1 containsString:@"beta"];
                    BOOL isBeta2 = [forgeVersion2 containsString:@"beta"];
                    BOOL isAlpha1 = [forgeVersion1 containsString:@"alpha"];
                    BOOL isAlpha2 = [forgeVersion2 containsString:@"alpha"];
                    
                    // Stable releases first
                    if (!isBeta1 && !isAlpha1 && (isBeta2 || isAlpha2)) return NSOrderedAscending;
                    if ((isBeta1 || isAlpha1) && !isBeta2 && !isAlpha2) return NSOrderedDescending;
                    
                    // Beta comes before alpha
                    if (isBeta1 && isAlpha2) return NSOrderedAscending;
                    if (isAlpha1 && isBeta2) return NSOrderedDescending;
                    
                    // Now compare version numbers - extract numbers and compare
                    NSArray *components1 = [forgeVersion1 componentsSeparatedByString:@"."];
                    NSArray *components2 = [forgeVersion2 componentsSeparatedByString:@"."];
                    
                    NSInteger minCount = MIN(components1.count, components2.count);
                    
                    for (NSInteger j = 0; j < minCount; j++) {
                        NSString *comp1 = components1[j];
                        NSString *comp2 = components2[j];
                        
                        // Extract just the numeric part if there's text
                        NSScanner *scanner1 = [NSScanner scannerWithString:comp1];
                        NSInteger num1 = 0;
                        [scanner1 scanInteger:&num1];
                        
                        NSScanner *scanner2 = [NSScanner scannerWithString:comp2];
                        NSInteger num2 = 0;
                        [scanner2 scanInteger:&num2];
                        
                        if (num1 != num2) {
                            return (num1 > num2) ? NSOrderedAscending : NSOrderedDescending;
                        }
                    }
                    
                    // If equal to this point, more components usually means newer
                    if (components1.count != components2.count) {
                        return (components1.count > components2.count) ? NSOrderedAscending : NSOrderedDescending;
                    }
                }
            }
            
            // Default sorting - newer versions typically have higher version numbers
            return [version2 compare:version1]; // Reversed for descending order
        }];
    }
}

- (NSComparisonResult)compareMinecraftVersions:(NSString *)version1 to:(NSString *)version2 {
    // Handle exact string equality case first
    if ([version1 isEqualToString:version2]) {
        return NSOrderedSame;
    }
    
    // Split versions into components
    NSArray *components1 = [version1 componentsSeparatedByString:@"."];
    NSArray *components2 = [version2 componentsSeparatedByString:@"."];
    
    // Compare each component numerically
    NSInteger minComponents = MIN(components1.count, components2.count);
    for (NSInteger i = 0; i < minComponents; i++) {
        NSInteger num1 = [components1[i] integerValue];
        NSInteger num2 = [components2[i] integerValue];
        
        if (num1 != num2) {
            return num1 > num2 ? NSOrderedDescending : NSOrderedAscending;
        }
    }
    
    // If all components so far are equal, the version with MORE components is newer
    // (e.g., 1.21.4 is newer than 1.21)
    if (components1.count != components2.count) {
        return components1.count > components2.count ? NSOrderedDescending : NSOrderedAscending;
    }
    
    // If we get here, then the versions have same numeric value but possibly different string representation
    // In this case, preserve string comparison to ensure uniqueness and predictable sorting
    return [version1 compare:version2];
}

@end
