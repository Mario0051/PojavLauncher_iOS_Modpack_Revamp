#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

static PLProfiles* current;

@interface PLProfiles()
@end

// Simple icon cache to avoid repeatedly loading the same icons
@interface PLProfileIconCache : NSObject
@property (nonatomic, strong) NSCache *iconCache;
+ (instancetype)sharedCache;
- (nullable UIImage *)imageForKey:(NSString *)key;
- (void)setImage:(UIImage *)image forKey:(NSString *)key;
@end

@implementation PLProfileIconCache

+ (instancetype)sharedCache {
    static PLProfileIconCache *sharedCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedCache = [[self alloc] init];
    });
    return sharedCache;
}

- (instancetype)init {
    if (self = [super init]) {
        _iconCache = [[NSCache alloc] init];
        _iconCache.countLimit = 50; // Limit to 50 cached icons
    }
    return self;
}

- (nullable UIImage *)imageForKey:(NSString *)key {
    return [_iconCache objectForKey:key];
}

- (void)setImage:(UIImage *)image forKey:(NSString *)key {
    [_iconCache setObject:image forKey:key];
}

@end

@implementation PLProfiles

+ (id)defaultProfiles {
    NSString *defaultProfileName = @"(Default)";
    return @{
        @"profiles": @{
            defaultProfileName: @{
                @"name": defaultProfileName,
                @"lastVersionId": @"latest-release",
                @"gameDir": [self uniqueGameDirForProfileName:defaultProfileName]
            }
        },
        @"selectedProfile": defaultProfileName
    }.mutableCopy;
}

+ (PLProfiles *)current {
    if (!current) {
        [self updateCurrent];
    }
    return current;
}

+ (void)updateCurrent {
    current = [[PLProfiles alloc] initWithCurrentInstance];
}

+ (NSString *)uniqueGameDirForProfileName:(NSString *)profileName {
    // Create a normalized directory name from profile name
    // If it's the default "New Profile", don't create directory yet - wait for final name
    if ([profileName isEqualToString:@"New Profile"] || profileName.length == 0) {
        return @"./profiles/pending_profile";
    }
    
    NSString *safeName = [profileName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    safeName = [safeName stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
    safeName = [safeName stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    return [NSString stringWithFormat:@"./profiles/%@", safeName];
}

+ (NSString *)fullPathForProfileWithName:(NSString *)profileName gameDir:(NSString *)gameDir {
    if (!gameDir || gameDir.length == 0) {
        gameDir = [self uniqueGameDirForProfileName:profileName];
    }
    
    // Handle relative paths (starting with ./) by resolving against the instance directory
    if ([gameDir hasPrefix:@"./"]) {
        gameDir = [gameDir substringFromIndex:2]; // Remove "./" prefix
        return [NSString stringWithFormat:@"%s/instances/%@/%@", 
                getenv("POJAV_HOME"), 
                getPrefObject(@"general.game_directory"),
                gameDir];
    }
    
    // If it's an absolute path, return it as is
    if ([gameDir hasPrefix:@"/"]) {
        return gameDir;
    }
    
    // Otherwise, assume it's relative to the instance
    return [NSString stringWithFormat:@"%s/instances/%@/%@", 
            getenv("POJAV_HOME"), 
            getPrefObject(@"general.game_directory"),
            gameDir];
}

+ (BOOL)ensureProfileDirectoryExists:(NSString *)profileName gameDir:(NSString *)gameDir {
    NSString *fullPath = [self fullPathForProfileWithName:profileName gameDir:gameDir];
    NSError *error = nil;
    
    BOOL success = [NSFileManager.defaultManager createDirectoryAtPath:fullPath 
                                         withIntermediateDirectories:YES 
                                                          attributes:nil 
                                                               error:&error];
    if (!success) {
        NSLog(@"[PLProfiles] Failed to create profile directory at %@: %@", fullPath, error.localizedDescription);
        return NO;
    }
    
    // Create essential subdirectories for Minecraft
    NSArray *essentialDirs = @[@"mods", @"resourcepacks", @"shaderpacks", @"saves", @"config"];
    for (NSString *dir in essentialDirs) {
        NSString *dirPath = [fullPath stringByAppendingPathComponent:dir];
        [NSFileManager.defaultManager createDirectoryAtPath:dirPath 
                               withIntermediateDirectories:YES 
                                                attributes:nil 
                                                     error:nil];
    }
    
    return YES;
}

+ (BOOL)renameProfileDirectory:(NSString *)oldProfileName to:(NSString *)newProfileName gameDir:(NSString *)oldGameDir {
    if ([oldProfileName isEqualToString:newProfileName]) {
        return YES; // Nothing to rename
    }
    
    // Don't rename directories when launching - only when user explicitly renames
    // If the old profile was using the pending directory
    BOOL isPending = [oldGameDir hasSuffix:@"pending_profile"];
    
    // Only for new profiles or explicit user rename
    if (isPending || ![[NSFileManager defaultManager] fileExistsAtPath:[self fullPathForProfileWithName:oldProfileName gameDir:oldGameDir]]) {
        // For pending profiles or if old path doesn't exist, just create the new directory
        return [self ensureProfileDirectoryExists:newProfileName gameDir:[self uniqueGameDirForProfileName:newProfileName]];
    }
    
    // For explicit renames (from profile editor), we can move the directory
    NSString *oldPath = [self fullPathForProfileWithName:oldProfileName gameDir:oldGameDir];
    NSString *newPath = [self fullPathForProfileWithName:newProfileName gameDir:[self uniqueGameDirForProfileName:newProfileName]];
    
    // Check if directory exists and needs to be moved
    if ([[NSFileManager defaultManager] fileExistsAtPath:oldPath] && ![oldPath isEqualToString:newPath]) {
        NSError *error = nil;
        
        // Create parent directory for new path if needed
        [[NSFileManager defaultManager] createDirectoryAtPath:[newPath stringByDeletingLastPathComponent]
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];
        
        // Move directory
        BOOL success = [[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:&error];
        if (!success) {
            NSLog(@"[PLProfiles] Failed to rename profile directory: %@", error);
            return NO;
        }
        
        return YES;
    }
    
    return YES;
}

+ (UIImage *)iconForProfileWithName:(NSString *)profileName iconValue:(NSString *)iconValue {
    PLProfileIconCache *cache = [PLProfileIconCache sharedCache];
    NSString *cacheKey = [NSString stringWithFormat:@"profile_%@", profileName];
    
    // Check cache first
    UIImage *cachedImage = [cache imageForKey:cacheKey];
    if (cachedImage) {
        return cachedImage;
    }
    
    // Parse base64 icon data if available
    if ([iconValue hasPrefix:@"data:image/"]) {
        NSString *base64String = [iconValue componentsSeparatedByString:@","].lastObject;
        if (base64String) {
            NSData *imageData = [[NSData alloc] initWithBase64EncodedString:base64String options:0];
            if (imageData) {
                UIImage *image = [UIImage imageWithData:imageData];
                if (image) {
                    [cache setImage:image forKey:cacheKey];
                    return image;
                }
            }
        }
    }
    
    // Fallback to default icon
    UIImage *defaultImage = [UIImage imageNamed:@"DefaultProfile"];
    [cache setImage:defaultImage forKey:cacheKey];
    return defaultImage;
}

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key {
    NSString *value = profile[key];
    if (value.length > 0) {
        //NSDebugLog(@"[PLProfiles] Applying %@: \"%@\"", key, value);
        return value;
    }

    NSDictionary *valueDefaults = @{
        @"javaVersion": @"0",
        @"gameDir": [self uniqueGameDirForProfileName:profile[@"name"]]
    };
    if (valueDefaults[key]) {
        return valueDefaults[key];
    }

    NSDictionary *prefDefaults = @{
        @"defaultTouchCtrl": @"control.default_ctrl",
        @"defaultGamepadCtrl": @"control.default_gamepad_ctrl",
        @"javaArgs": @"java.java_args",
        @"renderer": @"video.renderer"
    };
    return getPrefObject(prefDefaults[key]);
}

+ (id)resolveKeyForCurrentProfile:(id)key {
    return [self profile:self.current.selectedProfile resolveKey:key];
}

- (id)initWithCurrentInstance {
    self = [super init];
    self.profilePath = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:@"launcher_profiles.json"];
    self.profileDict = parseJSONFromFile(self.profilePath);
    if (self.profileDict[@"NSErrorObject"]) {
        self.profileDict = PLProfiles.defaultProfiles;
        [self save];
    }
    
    // Ensure all existing profiles have a gameDir
    for (NSString *profileName in self.profiles) {
        NSMutableDictionary *profile = self.profiles[profileName];
        if (!profile[@"gameDir"] || [profile[@"gameDir"] isEqualToString:@"."]) {
            profile[@"gameDir"] = [PLProfiles uniqueGameDirForProfileName:profileName];
            [PLProfiles ensureProfileDirectoryExists:profileName gameDir:profile[@"gameDir"]];
        }
    }
    
    return self;
}

- (id)profiles {
    return self.profileDict[@"profiles"];
}

- (id)selectedProfile {
    return self.profiles[self.selectedProfileName];
}

- (NSString *)selectedProfileName {
    return (id)self.profileDict[@"selectedProfile"];
}

- (void)setSelectedProfileName:(NSString *)name {
    self.profileDict[@"selectedProfile"] = (id)name;
    [self save];
}

- (void)save {
    saveJSONToFile(self.profileDict, self.profilePath);
}

@end
