#import "AFNetworking.h"
#import "ForgeInstallViewController.h"
#import "LauncherNavigationController.h"
#import "WFWorkflowProgressView.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <dlfcn.h>

@interface ForgeInstallViewController()<NSXMLParserDelegate>
@property(atomic) AFURLSessionManager *afManager;
@property(nonatomic) WFWorkflowProgressView *progressView;

@property(nonatomic) NSDictionary *endpoints;
@property(nonatomic) NSMutableArray<NSNumber *> *visibilityList;
@property(nonatomic) NSMutableArray<NSString *> *versionList;
@property(nonatomic) NSMutableArray<NSMutableArray *> *forgeList;
@property(nonatomic, assign) BOOL isVersionElement;
@property(nonatomic, strong) NSMutableString *currentVersionValue;
@property(nonatomic, strong) NSString *currentVendor;
@end

@implementation ForgeInstallViewController

#pragma mark - Lifecycle Methods

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Setup segmented control for vendor selection
    UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:@[@"Forge", @"NeoForge"]];
    segment.selectedSegmentIndex = 0;
    [segment addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = segment;
    self.currentVendor = @"Forge";

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
    
    // Load initial data
    [self loadMetadataFromVendor:@"Forge"];
}

#pragma mark - Action Methods

- (void)actionCancelDownload {
    [self.afManager invalidateSessionCancelingTasks:YES resetSession:NO];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)segmentChanged:(UISegmentedControl *)segment {
    // Clear existing data
    [self.visibilityList removeAllObjects];
    [self.versionList removeAllObjects];
    [self.forgeList removeAllObjects];
    [self.tableView reloadData];
    
    // Get selected vendor and load data
    NSString *vendor = [segment titleForSegmentAtIndex:segment.selectedSegmentIndex];
    self.currentVendor = vendor;
    [self loadMetadataFromVendor:vendor];
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
}

#pragma mark - Version Parsing and Management

- (NSString *)extractMinecraftVersionFromForgeVersion:(NSString *)version {
    // Handle Forge versions in format "1.X.Y-Z.W.V" or "1.X-Z.W.V"
    NSRange hyphenRange = [version rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound) {
        return [version substringToIndex:hyphenRange.location];
    }
    
    // For older Forge versions that don't follow the standard format
    NSRange dotRange = [version rangeOfString:@"."];
    if (dotRange.location != NSNotFound) {
        NSString *majorPart = [version substringToIndex:dotRange.location];
        if ([self isNumeric:majorPart]) {
            if (majorPart.intValue < 2) {  // Likely a Minecraft version starting with 1.X
                return version;
            }
        }
    }
    
    return @"Unknown";
}

- (NSString *)extractMinecraftVersionFromNeoForgeVersion:(NSString *)version {
    // First try to extract a standard Minecraft version like "1.X.Y" from the string
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"1\\.[0-9]+(?:\\.[0-9]+)?" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:version options:0 range:NSMakeRange(0, version.length)];
    
    if (match) {
        return [version substringWithRange:match.range];
    }
    
    // For NeoForge's new versioning scheme (e.g., "20.4.72-beta" for MC 1.20.4)
    NSArray *components = [version componentsSeparatedByString:@"."];
    if (components.count >= 2) {
        NSString *majorComponent = components[0];
        
        // Check if this is likely a major version number (below 30)
        if ([self isNumeric:majorComponent] && [majorComponent intValue] < 30) {
            NSString *minorComponent = components[1];
            
            // Format as proper Minecraft version: "20.4" -> "1.20.4"
            if ([self isNumeric:minorComponent]) {
                return [NSString stringWithFormat:@"1.%@.%@", majorComponent, minorComponent];
            } else {
                return [NSString stringWithFormat:@"1.%@", majorComponent];
            }
        }
    }
    
    return @"Unknown";
}

- (BOOL)isNumeric:(NSString *)string {
    NSScanner *scanner = [NSScanner scannerWithString:string];
    return [scanner scanInteger:NULL] && [scanner isAtEnd];
}

- (NSArray *)extractVersionComponents:(NSString *)version {
    NSMutableArray *components = [NSMutableArray new];
    
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        // For NeoForge, get the version part (before any qualifier like "beta")
        NSString *versionBase = version;
        NSRange qualifierRange = [version rangeOfString:@"-"];
        if (qualifierRange.location != NSNotFound) {
            versionBase = [version substringToIndex:qualifierRange.location];
        }
        
        NSArray *parts = [versionBase componentsSeparatedByString:@"."];
        for (NSString *part in parts) {
            if ([self isNumeric:part]) {
                [components addObject:@([part intValue])];
            } else {
                [components addObject:part];
            }
        }
    } else {
        // For Forge, handle the format "1.X.Y-Z.W.V"
        NSRange hyphenRange = [version rangeOfString:@"-"];
        if (hyphenRange.location != NSNotFound && hyphenRange.location < version.length - 1) {
            // Get everything after the hyphen (forge version number)
            NSString *forgeVersion = [version substringFromIndex:hyphenRange.location + 1];
            NSArray *parts = [forgeVersion componentsSeparatedByString:@"."];
            
            for (NSString *part in parts) {
                if ([self isNumeric:part]) {
                    [components addObject:@([part intValue])];
                } else {
                    [components addObject:part];
                }
            }
        }
    }
    
    return components;
}

- (NSString *)getDisplayName:(NSString *)version {
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        // For NeoForge, format as "NeoForge X.Y.Z for Minecraft 1.A.B"
        NSString *mcVersion = [self extractMinecraftVersionFromNeoForgeVersion:version];
        
        // Remove any Minecraft version embedded in the NeoForge version string
        NSString *cleanVersion = version;
        NSRange mcRange = [version rangeOfString:mcVersion];
        if (mcRange.location != NSNotFound) {
            cleanVersion = [version stringByReplacingCharactersInRange:mcRange withString:@""];
            cleanVersion = [cleanVersion stringByReplacingOccurrencesOfString:@"--" withString:@"-"];
            if ([cleanVersion hasPrefix:@"-"]) {
                cleanVersion = [cleanVersion substringFromIndex:1];
            }
            if ([cleanVersion hasSuffix:@"-"]) {
                cleanVersion = [cleanVersion substringToIndex:cleanVersion.length - 1];
            }
        }
        
        // If version is empty after cleanup, just use original
        if (cleanVersion.length == 0) {
            cleanVersion = version;
        }
        
        if (![mcVersion isEqualToString:@"Unknown"]) {
            return [NSString stringWithFormat:@"%@ (Minecraft %@)", cleanVersion, mcVersion];
        } else {
            return cleanVersion;
        }
    } else {
        // For Forge, format as "Forge Z.W.V for Minecraft 1.X.Y"
        NSString *mcVersion = [self extractMinecraftVersionFromForgeVersion:version];
        NSRange hyphenRange = [version rangeOfString:@"-"];
        
        if (hyphenRange.location != NSNotFound && ![mcVersion isEqualToString:@"Unknown"]) {
            NSString *forgeVersion = [version substringFromIndex:hyphenRange.location + 1];
            return [NSString stringWithFormat:@"%@ (Minecraft %@)", forgeVersion, mcVersion];
        } else {
            return version;
        }
    }
}

- (NSString *)getVersionQualifier:(NSString *)version {
    // Extract qualifiers like "beta", "alpha", "recommended", etc.
    NSRange betaRange = [version rangeOfString:@"-beta" options:NSCaseInsensitiveSearch];
    if (betaRange.location != NSNotFound) {
        return @"beta";
    }
    
    NSRange alphaRange = [version rangeOfString:@"-alpha" options:NSCaseInsensitiveSearch];
    if (alphaRange.location != NSNotFound) {
        return @"alpha";
    }
    
    NSRange rcRange = [version rangeOfString:@"-rc" options:NSCaseInsensitiveSearch];
    if (rcRange.location != NSNotFound) {
        return @"rc";
    }
    
    // Check for "recommended" or "latest" by examining the full version string
    if ([version containsString:@"recommended"] || [version containsString:@"latest"]) {
        return @"recommended";
    }
    
    return @"release"; // Default is release
}

- (void)addVersionToList:(NSString *)version {
    // Skip invalid versions
    if (version.length == 0) {
        return;
    }
    
    // Extract minecraft version based on vendor
    NSString *minecraftVersion;
    
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        minecraftVersion = [self extractMinecraftVersionFromNeoForgeVersion:version];
    } else {
        minecraftVersion = [self extractMinecraftVersionFromForgeVersion:version];
    }
    
    // If we couldn't determine a version, use 'Unknown' category
    if (!minecraftVersion || minecraftVersion.length == 0) {
        minecraftVersion = @"Unknown";
    }
    
    // Find or create section for this Minecraft version
    NSUInteger sectionIndex = [self.versionList indexOfObject:minecraftVersion];
    if (sectionIndex == NSNotFound) {
        [self.versionList addObject:minecraftVersion];
        [self.visibilityList addObject:@NO]; // Start collapsed
        [self.forgeList addObject:[NSMutableArray new]];
        sectionIndex = self.versionList.count - 1;
    }
    
    // Add version to this section if not already present
    if (![self.forgeList[sectionIndex] containsObject:version]) {
        [self.forgeList[sectionIndex] addObject:version];
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.versionList.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UITableViewHeaderFooterView *view = [self.tableView dequeueReusableHeaderFooterViewWithIdentifier:@"section"];
    if (!view) {
        view = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:@"section"];
        view.textLabel.font = [UIFont boldSystemFontOfSize:16];
        
        UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tableViewDidSelectSection:)];
        [view addGestureRecognizer:tapGesture];
        
        // Add a disclosure indicator
        UIImageView *disclosureIndicator = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        disclosureIndicator.tag = 1001;
        disclosureIndicator.tintColor = [UIColor systemGrayColor];
        [view.contentView addSubview:disclosureIndicator];
        
        // Add constraints for the disclosure indicator
        disclosureIndicator.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [disclosureIndicator.trailingAnchor constraintEqualToAnchor:view.contentView.trailingAnchor constant:-16],
            [disclosureIndicator.centerYAnchor constraintEqualToAnchor:view.contentView.centerYAnchor]
        ]];
    }
    
    // Update disclosure indicator rotation based on section state
    UIImageView *indicator = [view viewWithTag:1001];
    indicator.transform = self.visibilityList[section].boolValue ? 
        CGAffineTransformMakeRotation(M_PI_2) : CGAffineTransformIdentity;
    
    return view;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *mcVersion = self.versionList[section];
    
    // Enhance the section title for better readability
    if ([mcVersion hasPrefix:@"1."]) {
        return [NSString stringWithFormat:@"Minecraft %@", mcVersion];
    } else {
        return mcVersion;
    }
}

- (void)tableViewDidSelectSection:(UITapGestureRecognizer *)sender {
    UITableViewHeaderFooterView *view = (id)sender.view;
    NSString *sectionTitle = view.textLabel.text;
    
    // Extract the actual Minecraft version from the enhanced section title
    NSString *mcVersion = sectionTitle;
    if ([sectionTitle hasPrefix:@"Minecraft "]) {
        mcVersion = [sectionTitle substringFromIndex:10]; // Remove "Minecraft " prefix
    }
    
    NSInteger section = [self.versionList indexOfObject:mcVersion];
    if (section != NSNotFound) {
        // Toggle section visibility
        self.visibilityList[section] = @(!self.visibilityList[section].boolValue);
        
        // Animate the disclosure indicator
        UIImageView *indicator = [view viewWithTag:1001];
        [UIView animateWithDuration:0.3 animations:^{
            indicator.transform = self.visibilityList[section].boolValue ? 
                CGAffineTransformMakeRotation(M_PI_2) : CGAffineTransformIdentity;
        }];
        
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibilityList[section].boolValue ? self.forgeList[section].count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    NSString *version = self.forgeList[indexPath.section][indexPath.row];
    cell.textLabel.text = [self getDisplayName:version];
    
    // Add version qualifier info as subtitle
    NSString *qualifier = [self getVersionQualifier:version];
    if (![qualifier isEqualToString:@"release"]) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ version", qualifier.capitalizedString];
        
        // Set color based on stability
        if ([qualifier isEqualToString:@"recommended"]) {
            cell.detailTextLabel.textColor = [UIColor systemGreenColor];
        } else if ([qualifier isEqualToString:@"beta"]) {
            cell.detailTextLabel.textColor = [UIColor systemOrangeColor];
        } else if ([qualifier isEqualToString:@"alpha"]) {
            cell.detailTextLabel.textColor = [UIColor systemRedColor];
        } else {
            cell.detailTextLabel.textColor = [UIColor systemGrayColor];
        }
    } else {
        cell.detailTextLabel.text = @"Release version";
        cell.detailTextLabel.textColor = [UIColor systemGrayColor];
    }
    
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    tableView.allowsSelection = NO;

    [self switchToLoadingState];
    self.progressView.fractionCompleted = 0;

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    cell.accessoryView = self.progressView;

    // Get the raw version string (not the display name)
    NSString *versionString = self.forgeList[indexPath.section][indexPath.row];
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
            cell.accessoryView = nil;
            if (error) {
                if (error.code != NSURLErrorCancelled) {
                    NSLog(@"Error: %@", error);
                    showDialog(localize(@"Error", nil), error.localizedDescription);
                }
                [self switchToReadyState];
                return;
            }
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
        
        // Expand the first (newest) section by default
        if (self.versionList.count > 0) {
            self.visibilityList[0] = @YES;
        }
        
        [self switchToReadyState];
        [self.tableView reloadData];
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

#pragma mark - Sorting Methods

- (void)sortVersionSections {
    // Sort Minecraft versions semantically with newest first
    [self.versionList sortUsingComparator:^NSComparisonResult(NSString *version1, NSString *version2) {
        // Handle special categories
        if ([version1 isEqualToString:@"Unknown"]) return NSOrderedDescending;
        if ([version2 isEqualToString:@"Unknown"]) return NSOrderedAscending;
        
        return [self compareMinecraftVersions:version2 to:version1]; // Reversed for newest first
    }];
    
    // Reorder section arrays to match sorted version list
    NSMutableArray *newForgeList = [NSMutableArray arrayWithCapacity:self.versionList.count];
    NSMutableArray *newVisibilityList = [NSMutableArray arrayWithCapacity:self.versionList.count];
    
    for (NSString *version in self.versionList) {
        NSUInteger oldIndex = [self.versionList indexOfObject:version];
        if (oldIndex < self.forgeList.count) {
            [newForgeList addObject:self.forgeList[oldIndex]];
            [newVisibilityList addObject:self.visibilityList[oldIndex]];
        }
    }
    
    self.forgeList = newForgeList;
    self.visibilityList = newVisibilityList;
}

- (void)sortVersionsWithinSections {
    // Sort versions within each section with newest first
    for (NSUInteger i = 0; i < self.forgeList.count; i++) {
        NSMutableArray *sectionVersions = self.forgeList[i];
        
        [sectionVersions sortUsingComparator:^NSComparisonResult(NSString *version1, NSString *version2) {
            // First compare by stability/release type
            NSString *qualifier1 = [self getVersionQualifier:version1];
            NSString *qualifier2 = [self getVersionQualifier:version2];
            
            // Recommended versions first
            if ([qualifier1 isEqualToString:@"recommended"] && ![qualifier2 isEqualToString:@"recommended"]) {
                return NSOrderedAscending;
            } 
            if (![qualifier1 isEqualToString:@"recommended"] && [qualifier2 isEqualToString:@"recommended"]) {
                return NSOrderedDescending;
            }
            
            // Then stable releases before pre-releases
            BOOL isStable1 = [qualifier1 isEqualToString:@"release"];
            BOOL isStable2 = [qualifier2 isEqualToString:@"release"];
            
            if (isStable1 && !isStable2) {
                return NSOrderedAscending;
            }
            if (!isStable1 && isStable2) {
                return NSOrderedDescending;
            }
            
            // Pre-release order: rc > beta > alpha
            if (![qualifier1 isEqualToString:qualifier2]) {
                if ([qualifier1 isEqualToString:@"rc"]) return NSOrderedAscending;
                if ([qualifier2 isEqualToString:@"rc"]) return NSOrderedDescending;
                if ([qualifier1 isEqualToString:@"beta"]) return NSOrderedAscending;
                if ([qualifier2 isEqualToString:@"beta"]) return NSOrderedDescending;
            }
            
            // Finally compare version numbers
            NSArray *components1 = [self extractVersionComponents:version1];
            NSArray *components2 = [self extractVersionComponents:version2];
            
            // Compare each numeric component
            NSInteger minComponents = MIN(components1.count, components2.count);
            
            for (NSInteger j = 0; j < minComponents; j++) {
                id comp1 = components1[j];
                id comp2 = components2[j];
                
                // If both are numbers, compare numerically
                if ([comp1 isKindOfClass:[NSNumber class]] && [comp2 isKindOfClass:[NSNumber class]]) {
                    NSInteger num1 = [comp1 integerValue];
                    NSInteger num2 = [comp2 integerValue];
                    
                    if (num1 != num2) {
                        return num2 - num1; // Higher numbers first (newest)
                    }
                } 
                // If one is a number and one is a string, number comes first
                else if ([comp1 isKindOfClass:[NSNumber class]] && ![comp2 isKindOfClass:[NSNumber class]]) {
                    return NSOrderedAscending;
                }
                else if (![comp1 isKindOfClass:[NSNumber class]] && [comp2 isKindOfClass:[NSNumber class]]) {
                    return NSOrderedDescending;
                }
                // If both are strings, compare lexicographically
                else {
                    NSComparisonResult result = [comp2 compare:comp1];
                    if (result != NSOrderedSame) {
                        return result;
                    }
                }
            }
            
            // If equal up to now, longer version is usually newer
            if (components1.count != components2.count) {
                return components2.count - components1.count;
            }
            
            // Fallback to direct string comparison
            return [version2 compare:version1];
        }];
    }
}

- (NSComparisonResult)compareMinecraftVersions:(NSString *)version1 to:(NSString *)version2 {
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
    
    // If equal so far, more components usually means newer (e.g. 1.19.4 > 1.19)
    if (components1.count != components2.count) {
        return components1.count > components2.count ? NSOrderedDescending : NSOrderedAscending;
    }
    
    // Exactly equal
    return NSOrderedSame;
}

@end
