#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"
#import "ios_uikit_bridge.h"

static PLProfiles* current;
static BOOL hasShownMigrationMessage = NO;
static NSString *const kMigrationCompletedKey = @"profiles.migration_completed";

@interface PLProfiles()
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

+ (void)showMigrationCompletedMessage:(NSInteger)profileCount {
    // Skip showing dialog if it's already been shown in this session
    if (hasShownMigrationMessage) {
        return;
    }
    
    hasShownMigrationMessage = YES;
    
    NSString *title = @"Files Migrated";
    NSString *message = [NSString stringWithFormat:
                         @"PojavLauncher has been updated with a new filesystem layout. Your game files "
                         @"have been moved to the \"Migrated\" profile folder, and %ld %@ been updated to use this location. "
                         @"All your saves, mods, and resource packs are safe and will continue to work normally.",
                         (long)profileCount,
                         profileCount == 1 ? @"profile has" : @"profiles have"];
    
    // Display the message on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        showDialog(title, message);
    });
}

+ (BOOL)needsFileMigration {
    // Check if migration has already been performed
    if (getPrefBool(kMigrationCompletedKey)) {
        return NO;
    }
    
    // Check if there are any Minecraft files in the instance root that need migration
    NSString *instancePath = [NSString stringWithFormat:@"%s/instances/%@", 
                             getenv("POJAV_HOME"), 
                             getPrefObject(@"general.game_directory")];
    
    // Important Minecraft folders and files that would indicate a legacy installation
    NSArray *importantItems = @[@"mods", @"resourcepacks", @"shaderpacks", @"saves", @"config", @"options.txt", @"servers.dat"];
    
    // Check if any of these items exist in the instance root
    for (NSString *item in importantItems) {
        NSString *itemPath = [instancePath stringByAppendingPathComponent:item];
        if ([NSFileManager.defaultManager fileExistsAtPath:itemPath]) {
            return YES;
        }
    }
    
    // No migration needed if no files found
    return NO;
}

+ (void)migrateAllLegacyProfiles:(NSMutableDictionary *)profiles {
    // Check if migration has already been performed or is not needed
    if (!self.needsFileMigration) {
        // Mark all profiles with missing gameDir to use the new structure
        for (NSString *profileName in profiles) {
            NSMutableDictionary *profile = profiles[profileName];
            if (!profile[@"gameDir"] || [profile[@"gameDir"] isEqualToString:@"."]) {
                profile[@"gameDir"] = [self uniqueGameDirForProfileName:profileName];
            }
        }
        return;
    }
    
    // Collect all legacy profiles that need migration
    NSMutableArray *legacyProfiles = [NSMutableArray new];
    for (NSString *profileName in profiles) {
        NSMutableDictionary *profile = profiles[profileName];
        if (!profile[@"gameDir"] || [profile[@"gameDir"] isEqualToString:@"."]) {
            [legacyProfiles addObject:profileName];
        }
    }
    
    // If no legacy profiles, nothing to do
    if (legacyProfiles.count == 0) {
        setPrefBool(kMigrationCompletedKey, YES);
        return;
    }
    
    NSLog(@"[PLProfiles] Found %ld legacy profiles that need migration", (long)legacyProfiles.count);
    
    // Define migration destination - using "profiles/Migrated" instead of "custom_gamedir/default"
    NSString *migratedDir = @"./profiles/Migrated";
    NSString *destPath = [self fullPathForProfileWithName:@"" gameDir:migratedDir];
    
    // Define source (old) path - the instance root
    NSString *srcPath = [NSString stringWithFormat:@"%s/instances/%@", 
                         getenv("POJAV_HOME"), 
                         getPrefObject(@"general.game_directory")];
    
    // Create destination directory if it doesn't exist
    NSError *error = nil;
    if (![NSFileManager.defaultManager fileExistsAtPath:destPath]) {
        [NSFileManager.defaultManager createDirectoryAtPath:destPath 
                                withIntermediateDirectories:YES 
                                                attributes:nil 
                                                    error:&error];
        if (error) {
            NSLog(@"[PLProfiles] Failed to create migration directory at %@: %@", destPath, error.localizedDescription);
            return;
        }
    }
    
    // Define important Minecraft folders and files to migrate
    NSArray *importantItems = @[@"mods", @"resourcepacks", @"shaderpacks", @"saves", @"config", @"options.txt", @"servers.dat"];
    
    // Migrate each important directory/file if it exists in source
    BOOL migratedAnyFiles = NO;
    for (NSString *itemName in importantItems) {
        NSString *srcItem = [srcPath stringByAppendingPathComponent:itemName];
        NSString *destItem = [destPath stringByAppendingPathComponent:itemName];
        
        // Skip if source doesn't exist
        if (![NSFileManager.defaultManager fileExistsAtPath:srcItem]) {
            continue;
        }
        
        // Handle case where destination already exists
        if ([NSFileManager.defaultManager fileExistsAtPath:destItem]) {
            // Create a backup of the existing destination
            NSString *backupPath = [NSString stringWithFormat:@"%@.bak-%@", destItem, [[NSUUID UUID] UUIDString]];
            NSLog(@"[PLProfiles] Destination %@ already exists, creating backup at %@", destItem, backupPath);
            
            error = nil;
            [NSFileManager.defaultManager moveItemAtPath:destItem toPath:backupPath error:&error];
            if (error) {
                NSLog(@"[PLProfiles] Failed to create backup of %@: %@", destItem, error.localizedDescription);
                continue;  // Skip this item if we can't create a backup
            }
        }
        
        // Move the item (file or directory)
        error = nil;
        [NSFileManager.defaultManager moveItemAtPath:srcItem toPath:destItem error:&error];
        
        if (error) {
            NSLog(@"[PLProfiles] Failed to move %@ to %@: %@", srcItem, destItem, error.localizedDescription);
        } else {
            NSLog(@"[PLProfiles] Successfully moved %@ to %@", srcItem, destItem);
            migratedAnyFiles = YES;
        }
    }
    
    if (migratedAnyFiles) {
        NSLog(@"[PLProfiles] Successfully migrated game files to the Migrated profile directory");
        
        // Update all legacy profiles to use the migrated directory
        for (NSString *profileName in legacyProfiles) {
            NSMutableDictionary *profile = profiles[profileName];
            profile[@"gameDir"] = migratedDir;
            NSLog(@"[PLProfiles] Updated profile '%@' to use migrated gameDir: %@", profileName, migratedDir);
        }
        
        NSLog(@"[PLProfiles] Migration complete: %ld legacy profiles now use the Migrated profile directory %@", 
              (long)legacyProfiles.count, migratedDir);
        
        // Show notification to the user that migration has completed
        [self showMigrationCompletedMessage:legacyProfiles.count];
    } else {
        NSLog(@"[PLProfiles] No game files needed migration or all migrations failed");
        
        // For profiles with no gameDir, set to default profile directory
        for (NSString *profileName in legacyProfiles) {
            NSMutableDictionary *profile = profiles[profileName];
            profile[@"gameDir"] = [self uniqueGameDirForProfileName:profileName];
            NSLog(@"[PLProfiles] Updated profile '%@' to use its own gameDir: %@", profileName, profile[@"gameDir"]);
        }
    }
    
    // Mark migration as completed
    setPrefBool(kMigrationCompletedKey, YES);
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
    
    // Migrate legacy profiles to a shared directory
    [PLProfiles migrateAllLegacyProfiles:self.profiles];
    
    // Ensure all profile directories exist
    for (NSString *profileName in self.profiles) {
        NSMutableDictionary *profile = self.profiles[profileName];
        [PLProfiles ensureProfileDirectoryExists:profileName gameDir:profile[@"gameDir"]];
    }
    
    // Save the updated profiles
    [self save];
    
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
