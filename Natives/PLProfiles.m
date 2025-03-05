#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "utils.h"

static PLProfiles* current;

@interface PLProfiles()
@end

@implementation PLProfiles

+ (id)defaultProfiles {
    return @{
        @"profiles": @{
            @"(Default)": @{
                @"name": @"(Default)",
                @"lastVersionId": @"latest-release",
                @"gameDir": @"./profiles/default"  // Use isolated directory by default
            }
        },
        @"selectedProfile": @"(Default)"
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

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key {
    NSString *value = profile[key];
    if (value.length > 0) {
        //NSDebugLog(@"[PLProfiles] Applying %@: \"%@\"", key, value);
        return value;
    }

    if ([key isEqualToString:@"gameDir"]) {
        // Generate a profile directory if none exists
        NSString *profileDir = [ModpackUtils getUniqueProfileDirectory:profile[@"name"]];
        [ModpackUtils createProfileDirectory:profileDir];
        profile[@"gameDir"] = profileDir;
        [self.current save];
        NSLog(@"[PLProfiles] Generated gameDir for profile %@: %@", profile[@"name"], profileDir);
        return profileDir;
    }
    
    NSDictionary *valueDefaults = @{
        @"javaVersion": @"0"
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
    
    // Ensure all profiles have a proper gameDir
    [self ensureProfileIsolation];

    return self;
}

- (void)ensureProfileIsolation {
    BOOL needsSave = NO;
    
    // Check all profiles
    for (NSString *profileName in self.profiles) {
        NSMutableDictionary *profile = self.profiles[profileName];
        
        // Check if gameDir exists or is the default "."
        if (![profile[@"gameDir"] length] || [profile[@"gameDir"] isEqualToString:@"."]) {
            // Set a properly isolated gameDir
            NSString *profileDir = [ModpackUtils getUniqueProfileDirectory:profileName];
            profile[@"gameDir"] = profileDir;
            
            // Create the directory structure
            [ModpackUtils createProfileDirectory:profileDir];
            
            NSLog(@"[PLProfiles] Updated profile %@ with isolated gameDir: %@", profileName, profileDir);
            needsSave = YES;
        }
    }
    
    if (needsSave) {
        [self save];
    }
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
    
    // Make sure the profile has a proper gameDir
    NSMutableDictionary *profile = self.profiles[name];
    if (![profile[@"gameDir"] length] || [profile[@"gameDir"] isEqualToString:@"."]) {
        NSString *profileDir = [ModpackUtils getUniqueProfileDirectory:name];
        profile[@"gameDir"] = profileDir;
        [ModpackUtils createProfileDirectory:profileDir];
        [self save];
    }
}

- (void)save {
    saveJSONToFile(self.profileDict, self.profilePath);
}

@end
