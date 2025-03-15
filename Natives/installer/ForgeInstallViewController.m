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

// Custom structure to represent a semantic version
typedef struct {
    NSInteger major;
    NSInteger minor;
    NSInteger patch;
    NSString *preRelease; // alpha, beta, rc, etc.
    NSInteger preReleaseVersion;
    BOOL isValid;
} SemanticVersion;

// Parse a version string into components following semantic versioning principles
- (SemanticVersion)parseSemanticVersion:(NSString *)versionString {
    SemanticVersion result = {-1, -1, -1, nil, -1, NO};
    
    if (!versionString || versionString.length == 0) {
        return result;
    }
    
    // Handle the different vendor formats differently
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        return [self parseNeoForgeSemanticVersion:versionString];
    }
    
    // Standard SemVer parsing for Forge and Minecraft versions
    
    // First, separate the pre-release part if any
    NSString *versionPart = versionString;
    NSString *preReleasePart = nil;
    
    NSRange hyphenRange = [versionString rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound) {
        versionPart = [versionString substringToIndex:hyphenRange.location];
        if (hyphenRange.location + 1 < versionString.length) {
            preReleasePart = [versionString substringFromIndex:hyphenRange.location + 1];
        }
    }
    
    // Parse version components
    NSArray *components = [versionPart componentsSeparatedByString:@"."];
    
    // Need at least one component
    if (components.count == 0) {
        return result;
    }
    
    // Parse major
    if (components.count > 0 && [self isNumeric:components[0]]) {
        result.major = [components[0] integerValue];
    } else {
        return result; // Invalid version
    }
    
    // Parse minor if available
    if (components.count > 1 && [self isNumeric:components[1]]) {
        result.minor = [components[1] integerValue];
    } else {
        result.minor = 0; // Default to 0
    }
    
    // Parse patch if available
    if (components.count > 2 && [self isNumeric:components[2]]) {
        result.patch = [components[2] integerValue];
    } else {
        result.patch = 0; // Default to 0
    }
    
    // Parse pre-release identifier
    if (preReleasePart) {
        // Extract pre-release type (alpha, beta, rc)
        NSRegularExpression *preReleaseTypeRegex = [NSRegularExpression 
            regularExpressionWithPattern:@"^(alpha|beta|rc|pre|snapshot)" 
            options:NSRegularExpressionCaseInsensitive 
            error:nil];
        
        NSTextCheckingResult *typeMatch = [preReleaseTypeRegex 
            firstMatchInString:preReleasePart 
            options:0 
            range:NSMakeRange(0, preReleasePart.length)];
        
        if (typeMatch) {
            result.preRelease = [[preReleasePart substringWithRange:typeMatch.range] lowercaseString];
            
            // Try to extract a version number after the type
            NSString *remaining = [preReleasePart substringFromIndex:typeMatch.range.length];
            NSRegularExpression *numberRegex = [NSRegularExpression 
                regularExpressionWithPattern:@"\\d+" 
                options:0 
                error:nil];
            
            NSTextCheckingResult *numberMatch = [numberRegex 
                firstMatchInString:remaining 
                options:0 
                range:NSMakeRange(0, remaining.length)];
            
            if (numberMatch) {
                result.preReleaseVersion = [[remaining substringWithRange:numberMatch.range] integerValue];
            } else {
                result.preReleaseVersion = 0;
            }
        } else {
            // If no recognized pre-release type, just use the whole string
            result.preRelease = preReleasePart;
            result.preReleaseVersion = 0;
        }
    }
    
    result.isValid = YES;
    return result;
}

- (SemanticVersion)parseNeoForgeSemanticVersion:(NSString *)versionString {
    SemanticVersion result = {-1, -1, -1, nil, -1, NO};
    
    if (!versionString || versionString.length == 0) {
        return result;
    }
    
    // Try to identify and strip any embedded Minecraft version
    NSString *cleanVersion = [versionString copy];
    NSRegularExpression *mcRegex = [NSRegularExpression 
        regularExpressionWithPattern:@"(?:mc)?(1\\.[0-9]+(?:\\.[0-9]+)?)" 
        options:0 error:nil];
        
    NSTextCheckingResult *mcMatch = [mcRegex 
        firstMatchInString:versionString 
        options:0 
        range:NSMakeRange(0, versionString.length)];
        
    if (mcMatch) {
        // Remove the Minecraft version
        NSRange mcRange = [mcMatch rangeAtIndex:0];
        NSMutableString *mutableVersion = [versionString mutableCopy];
        [mutableVersion deleteCharactersInRange:mcRange];
        cleanVersion = [mutableVersion copy];
        
        // Clean up artifacts
        cleanVersion = [cleanVersion stringByReplacingOccurrencesOfString:@"--" withString:@"-"];
        if ([cleanVersion hasPrefix:@"-"]) {
            cleanVersion = [cleanVersion substringFromIndex:1];
        }
        if ([cleanVersion hasSuffix:@"-"]) {
            cleanVersion = [cleanVersion substringToIndex:cleanVersion.length - 1];
        }
    }
    
    // Clean version should now only have NeoForge version info
    
    // Separate pre-release suffix if any
    NSString *versionPart = cleanVersion;
    NSString *preReleasePart = nil;
    
    NSRange hyphenRange = [cleanVersion rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound) {
        versionPart = [cleanVersion substringToIndex:hyphenRange.location];
        if (hyphenRange.location + 1 < cleanVersion.length) {
            preReleasePart = [cleanVersion substringFromIndex:hyphenRange.location + 1];
        }
    }
    
    // Parse version components
    NSArray *components = [versionPart componentsSeparatedByString:@"."];
    
    // Need at least one component
    if (components.count == 0) {
        return result;
    }
    
    // For NeoForge, their version is typically X.Y.Z where X.Y often corresponds to MC 1.X.Y
    
    // Parse components - NeoForge often has just one or two main version components
    if (components.count > 0 && [self isNumeric:components[0]]) {
        result.major = [components[0] integerValue];
    } else {
        return result; // Invalid version
    }
    
    // Parse second component
    if (components.count > 1 && [self isNumeric:components[1]]) {
        result.minor = [components[1] integerValue];
    } else {
        result.minor = 0;
    }
    
    // Parse third component
    if (components.count > 2 && [self isNumeric:components[2]]) {
        result.patch = [components[2] integerValue];
    } else {
        result.patch = 0;
    }
    
    // Handle pre-release part
    if (preReleasePart) {
        // Common pre-release identifiers
        NSArray *preReleaseTypes = @[@"alpha", @"beta", @"rc", @"pre", @"snapshot"];
        
        for (NSString *type in preReleaseTypes) {
            if ([preReleasePart hasPrefix:type]) {
                result.preRelease = type;
                
                // Extract version number if present
                NSString *remaining = [preReleasePart substringFromIndex:type.length];
                NSScanner *scanner = [NSScanner scannerWithString:remaining];
                NSInteger preReleaseNum = 0;
                
                if ([scanner scanInteger:&preReleaseNum]) {
                    result.preReleaseVersion = preReleaseNum;
                }
                
                break;
            }
        }
        
        // If no recognized pre-release type found, use the whole string
        if (!result.preRelease) {
            result.preRelease = preReleasePart;
            result.preReleaseVersion = 0;
        }
    }
    
    result.isValid = YES;
    return result;
}

// Compare two semantic versions
- (NSComparisonResult)compareSemanticVersion:(SemanticVersion)ver1 to:(SemanticVersion)ver2 {
    // Handle invalid versions
    if (!ver1.isValid && !ver2.isValid) return NSOrderedSame;
    if (!ver1.isValid) return NSOrderedAscending;
    if (!ver2.isValid) return NSOrderedDescending;
    
    // Compare major versions
    if (ver1.major != ver2.major) {
        return ver1.major > ver2.major ? NSOrderedDescending : NSOrderedAscending;
    }
    
    // Compare minor versions
    if (ver1.minor != ver2.minor) {
        return ver1.minor > ver2.minor ? NSOrderedDescending : NSOrderedAscending;
    }
    
    // Compare patch versions
    if (ver1.patch != ver2.patch) {
        return ver1.patch > ver2.patch ? NSOrderedDescending : NSOrderedAscending;
    }
    
    // At this point, the base versions are equal (e.g., 1.20 == 1.20.0)
    
    // If one has a pre-release and the other doesn't, the one without is greater
    // This properly handles 1.20 vs 1.20-beta, where 1.20 is higher
    if (ver1.preRelease && !ver2.preRelease) return NSOrderedAscending;
    if (!ver1.preRelease && ver2.preRelease) return NSOrderedDescending;
    
    // If both have pre-releases, compare them
    if (ver1.preRelease && ver2.preRelease) {
        // Compare pre-release types first
        NSArray *preReleaseOrder = @[@"snapshot", @"alpha", @"beta", @"pre", @"rc"];
        NSInteger index1 = [preReleaseOrder indexOfObject:ver1.preRelease];
        NSInteger index2 = [preReleaseOrder indexOfObject:ver2.preRelease];
        
        // Handle unknown pre-release types
        if (index1 == NSNotFound && index2 == NSNotFound) {
            // If both unknown, compare lexicographically
            NSComparisonResult result = [ver1.preRelease compare:ver2.preRelease];
            if (result != NSOrderedSame) return result;
        } else if (index1 == NSNotFound) {
            return NSOrderedAscending;  // Unknown types are considered lower
        } else if (index2 == NSNotFound) {
            return NSOrderedDescending;
        } else if (index1 != index2) {
            return index1 > index2 ? NSOrderedDescending : NSOrderedAscending;
        }
        
        // Same pre-release type, compare versions
        if (ver1.preReleaseVersion != ver2.preReleaseVersion) {
            return ver1.preReleaseVersion > ver2.preReleaseVersion ? 
                NSOrderedDescending : NSOrderedAscending;
        }
    }
    
    // Versions are equal
    return NSOrderedSame;
}

- (NSString *)extractMinecraftVersionFromForgeVersion:(NSString *)version {
    // Regular expression to match a Minecraft version at the beginning
    NSRegularExpression *regex = [NSRegularExpression 
        regularExpressionWithPattern:@"^(1\\.[0-9]+(?:\\.[0-9]+)?)" 
        options:0 error:nil];
    
    NSTextCheckingResult *match = [regex firstMatchInString:version options:0 range:NSMakeRange(0, version.length)];
    
    if (match) {
        return [version substringWithRange:match.range];
    }
    
    // Fallback: Look for a version separator
    NSRange hyphenRange = [version rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound) {
        NSString *possibleMcVersion = [version substringToIndex:hyphenRange.location];
        
        // Validate if this looks like a Minecraft version
        NSRegularExpression *mcRegex = [NSRegularExpression 
            regularExpressionWithPattern:@"^\\d+(?:\\.\\d+)+$" 
            options:0 error:nil];
        
        if ([mcRegex firstMatchInString:possibleMcVersion options:0 
                 range:NSMakeRange(0, possibleMcVersion.length)]) {
            return possibleMcVersion;
        }
    }
    
    return @"Unknown";
}

- (NSString *)extractMinecraftVersionFromNeoForgeVersion:(NSString *)version {
    // First try to find an embedded Minecraft version (pattern: 1.X.Y)
    NSRegularExpression *mcRegex = [NSRegularExpression 
        regularExpressionWithPattern:@"(1\\.[0-9]+(?:\\.[0-9]+)?)" 
        options:0 error:nil];
    
    NSTextCheckingResult *match = [mcRegex firstMatchInString:version options:0 range:NSMakeRange(0, version.length)];
    
    if (match) {
        return [version substringWithRange:match.range];
    }
    
    // Fallback for the newer NeoForge versioning scheme (e.g., 20.4.x for Minecraft 1.20.4)
    // Strip any pre-release suffix first
    NSString *cleanVersion = version;
    NSRange hyphenRange = [version rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound) {
        cleanVersion = [version substringToIndex:hyphenRange.location];
    }
    
    NSArray *components = [cleanVersion componentsSeparatedByString:@"."];
    
    // Need at least major.minor components
    if (components.count >= 2) {
        NSString *majorComponent = components[0];
        NSString *minorComponent = components[1];
        
        // Validate components
        if ([self isNumeric:majorComponent] && [self isNumeric:minorComponent]) {
            NSInteger majorValue = [majorComponent integerValue];
            
            // Is this likely a new-style NeoForge version? (e.g. 20.4.x for MC 1.20.4)
            if (majorValue >= 19 && majorValue <= 30) { // Reasonable range for Minecraft versions
                NSString *mcVersion = [NSString stringWithFormat:@"1.%@.%@", majorComponent, minorComponent];
                return mcVersion;
            }
        }
    }
    
    // Look for version pattern at the end that might indicate Minecraft version
    NSRegularExpression *versionRegex = [NSRegularExpression 
        regularExpressionWithPattern:@"-(?:mc)?(1\\.[0-9]+(?:\\.[0-9]+)?)" 
        options:0 error:nil];
    
    match = [versionRegex firstMatchInString:version options:0 range:NSMakeRange(0, version.length)];
    
    if (match) {
        // Extract just the version part, not the "mc" prefix if present
        NSRange versionRange = [match rangeAtIndex:1];
        if (versionRange.location != NSNotFound) {
            return [version substringWithRange:versionRange];
        }
    }
    
    return @"Unknown";
}

- (BOOL)isNumeric:(NSString *)string {
    if (!string || string.length == 0) return NO;
    
    NSCharacterSet *nonNumbers = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [string rangeOfCharacterFromSet:nonNumbers].location == NSNotFound;
}

- (NSArray *)extractVersionComponents:(NSString *)version {
    NSMutableArray *components = [NSMutableArray new];
    
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        // For NeoForge, handle specialized format
        
        // First, remove any Minecraft version references
        NSString *cleanVersion = version;
        NSRegularExpression *mcRegex = [NSRegularExpression 
            regularExpressionWithPattern:@"(1\\.[0-9]+(?:\\.[0-9]+)?)" 
            options:0 error:nil];
        
        cleanVersion = [mcRegex stringByReplacingMatchesInString:cleanVersion 
                                               options:0 
                                                 range:NSMakeRange(0, cleanVersion.length) 
                                          withTemplate:@""];
        
        // Parse modloader version part (before any qualifier)
        NSString *versionBase = cleanVersion;
        NSRange qualifierRange = [cleanVersion rangeOfString:@"-"];
        if (qualifierRange.location != NSNotFound) {
            versionBase = [cleanVersion substringToIndex:qualifierRange.location];
            
            // Add the qualifier to the components array
            if (qualifierRange.location + 1 < cleanVersion.length) {
                NSString *qualifier = [cleanVersion substringFromIndex:qualifierRange.location + 1];
                [components addObject:qualifier]; // Keep qualifier for comparison
            }
        }
        
        // Extract numeric components
        NSArray *parts = [versionBase componentsSeparatedByString:@"."];
        for (NSString *part in parts) {
            if ([self isNumeric:part]) {
                [components addObject:@([part intValue])];
            } else if (part.length > 0) {
                [components addObject:part];
            }
        }
    } else {
        // For Forge, extract the version part after the Minecraft version
        NSRange hyphenRange = [version rangeOfString:@"-"];
        if (hyphenRange.location != NSNotFound && hyphenRange.location + 1 < version.length) {
            NSString *forgeVersion = [version substringFromIndex:hyphenRange.location + 1];
            
            // Check for additional qualifiers
            NSRange secondHyphenRange = [forgeVersion rangeOfString:@"-"];
            NSString *versionPart = forgeVersion;
            
            if (secondHyphenRange.location != NSNotFound) {
                versionPart = [forgeVersion substringToIndex:secondHyphenRange.location];
                
                // Add the qualifier to components
                if (secondHyphenRange.location + 1 < forgeVersion.length) {
                    NSString *qualifier = [forgeVersion substringFromIndex:secondHyphenRange.location + 1];
                    [components addObject:qualifier];
                }
            }
            
            // Parse the numeric parts
            NSArray *parts = [versionPart componentsSeparatedByString:@"."];
            for (NSString *part in parts) {
                if ([self isNumeric:part]) {
                    [components addObject:@([part intValue])];
                } else if (part.length > 0) {
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
    // More comprehensive pattern matching for pre-release identifiers
    NSArray *patterns = @[
        @[@"-beta", @"beta"],
        @[@"beta", @"beta"],
        @[@"-alpha", @"alpha"],
        @[@"alpha", @"alpha"],
        @[@"-rc", @"rc"],
        @[@"rc", @"rc"],
        @[@"-pre", @"pre"],
        @[@"pre", @"pre"],
        @[@"-snapshot", @"snapshot"],
        @[@"snapshot", @"snapshot"],
        @[@"experimental", @"alpha"],
        @[@"dev", @"alpha"]
    ];
    
    // Check each pattern
    for (NSArray *patternPair in patterns) {
        NSRange range = [version rangeOfString:patternPair[0] options:NSCaseInsensitiveSearch];
        if (range.location != NSNotFound) {
            return patternPair[1];
        }
    }
    
    // Check for "recommended" or "latest" in special versions
    if ([version containsString:@"recommended"] || 
        [version containsString:@"latest"] || 
        [version containsString:@"promoted"]) {
        return @"recommended";
    }
    
    // Check for special NeoForge qualifiers
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        // NeoForge "release" versions might have specific formats
        if ([version containsString:@"-release"] || 
            [version hasSuffix:@"release"]) {
            return @"release";
        }
    }
    
    return @"release"; // Default is release
}

- (void)addVersionToList:(NSString *)version {
    // Skip invalid versions
    if (version.length == 0) {
        return;
    }
    
    // Skip known problematic versions for NeoForge/Forge that cause issues
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        // Skip NeoForge versions with these patterns
        NSArray *skipPatterns = @[@"sources", @"userdev", @"javadoc", @"universal", @"slim"];
        for (NSString *pattern in skipPatterns) {
            if ([version containsString:pattern]) {
                NSLog(@"[ForgeInstall] Skipping problematic NeoForge version: %@", version);
                return;
            }
        }
    } else {
        // Skip Forge versions with these patterns
        NSArray *skipPatterns = @[@"mdk", @"userdev", @"javadoc", @"src", @"sources", @"universal"];
        for (NSString *pattern in skipPatterns) {
            if ([version containsString:pattern]) {
                NSLog(@"[ForgeInstall] Skipping problematic Forge version: %@", version);
                return;
            }
        }
        
        // For Forge, also validate it has a proper format with Minecraft version
        // Forge versions should have format "mcVersion-forgeVersion"
        if (![version containsString:@"-"]) {
            NSLog(@"[ForgeInstall] Skipping invalid Forge version format: %@", version);
            return;
        }
    }
    
    // Extract minecraft version based on vendor
    NSString *minecraftVersion;
    
    if ([self.currentVendor isEqualToString:@"NeoForge"]) {
        minecraftVersion = [self extractMinecraftVersionFromNeoForgeVersion:version];
    } else {
        minecraftVersion = [self extractMinecraftVersionFromForgeVersion:version];
        
        // For Forge, verify that the minecraft version is correctly extracted
        NSRange hyphenRange = [version rangeOfString:@"-"];
        if (hyphenRange.location != NSNotFound) {
            NSString *mcPortion = [version substringToIndex:hyphenRange.location];
            
            // If the extracted version doesn't match the part before the hyphen, this is likely incorrect
            if (![minecraftVersion isEqualToString:mcPortion]) {
                NSLog(@"[ForgeInstall] Possible version mismatch: '%@' extracted as '%@', using explicit '%@'", 
                      version, minecraftVersion, mcPortion);
                minecraftVersion = mcPortion;
            }
        }
    }
    
    // If we couldn't determine a version, use 'Unknown' category
    if (!minecraftVersion || minecraftVersion.length == 0) {
        minecraftVersion = @"Unknown";
    }
    
    // Skip unreasonable Minecraft versions (validation step)
    if (![minecraftVersion isEqualToString:@"Unknown"]) {
        // For Forge, ensure we have a valid Minecraft version format
        if ([self.currentVendor isEqualToString:@"Forge"]) {
            // Most Minecraft versions should match pattern 1.X.Y or 1.X
            NSRegularExpression *mcRegex = [NSRegularExpression 
                regularExpressionWithPattern:@"^1\\.[0-9]+(\\.[0-9]+)?$" 
                options:0 error:nil];
                
            NSRange fullRange = NSMakeRange(0, minecraftVersion.length);
            NSArray *matches = [mcRegex matchesInString:minecraftVersion options:0 range:fullRange];
            
            if (matches.count == 0) {
                NSLog(@"[ForgeInstall] Invalid Minecraft version format: %@, using Unknown", minecraftVersion);
                minecraftVersion = @"Unknown";
            }
        }
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
        NSLog(@"[ForgeInstall] Added %@ to %@ section", version, minecraftVersion);
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
