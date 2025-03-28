#include <CommonCrypto/CommonDigest.h>

#import "authenticator/BaseAuthenticator.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@implementation MinecraftResourceUtils

// Handle inheritsFrom
+ (void)processVersion:(NSMutableDictionary *)json inheritsFrom:(NSMutableDictionary *)inheritsFrom {
    // Explicitly preserve the javaVersion field from the mod version
    NSDictionary *originalJavaVersion = [json[@"javaVersion"] copy];
    
    // Log the Java version for debugging
    if (originalJavaVersion) {
        NSLog(@"[MCDL] Found javaVersion in modded version %@: %@", json[@"id"], originalJavaVersion);
    }
    
    [self insertSafety:inheritsFrom from:json arr:@[
        @"assetIndex", @"assets", @"id",
        @"inheritsFrom",
        @"mainClass", @"minecraftArguments",
        @"optifineLib", @"releaseTime", @"time", @"type"
    ]];
    inheritsFrom[@"arguments"] = json[@"arguments"];
    
    // Ensure we preserve the javaVersion field from the mod version if it exists
    if (originalJavaVersion) {
        inheritsFrom[@"javaVersion"] = originalJavaVersion;
        NSLog(@"[MCDL] Applied javaVersion from mod version to final version");
    } else if (!inheritsFrom[@"javaVersion"]) {
        // If neither has a javaVersion field but it's a modern mod like Forge for 1.18+,
        // we should explicitly set Java 17
        if (([json[@"id"] containsString:@"forge-"] && 
            ([json[@"id"] hasPrefix:@"1.18"] || 
             [json[@"id"] hasPrefix:@"1.19"] || 
             [json[@"id"] hasPrefix:@"1.20"])) ||
            [json[@"id"] containsString:@"neoforge"]) {
            
            inheritsFrom[@"javaVersion"] = @{
                @"component": @"java-runtime-gamma",
                @"majorVersion": @17
            };
            NSLog(@"[MCDL] Added javaVersion explicitly for modern modloader %@", json[@"id"]);
        }
    }
    
    for (NSMutableDictionary *lib in json[@"libraries"]) {
        NSString *libName = [lib[@"name"] substringToIndex:[lib[@"name"] rangeOfString:@":" options:NSBackwardsSearch].location];
        int i;
        for (i = 0; i < [inheritsFrom[@"libraries"] count]; i++) {
            NSMutableDictionary *libAdded = inheritsFrom[@"libraries"][i];
            NSString *libAddedName = [libAdded[@"name"] substringToIndex:[libAdded[@"name"] rangeOfString:@":" options:NSBackwardsSearch].location];

            if ([libAdded[@"name"] hasPrefix:libName]) {
                inheritsFrom[@"libraries"][i] = lib;
                i = -1;
                break;
            }
        }

        if (i != -1) {
            [inheritsFrom[@"libraries"] addObject:lib];
        }
    }

    // Print final Java version for debugging
    if (inheritsFrom[@"javaVersion"]) {
        NSLog(@"[MCDL] Final version will use Java %@", inheritsFrom[@"javaVersion"][@"majorVersion"]);
    } else {
        NSLog(@"[MCDL] Final version has no javaVersion field, will default to Java 8");
    }
}

+ (void)insertSafety:(NSMutableDictionary *)targetVer from:(NSDictionary *)fromVer arr:(NSArray *)arr {
    for (NSString *key in arr) {
        if (([fromVer[key] isKindOfClass:NSString.class] && [fromVer[key] length] > 0) || targetVer[key] == nil) {
            targetVer[key] = fromVer[key];
        } else {
            NSLog(@"[MCDL] insertSafety: how to insert %@?", key);
        }
    }
}

+ (NSInteger)numberOfArgsToSkipForArg:(NSString *)arg {
    if (![arg isKindOfClass:NSString.class]) {
        // Skip non-string arg
        return 1;
    } else if ([arg hasPrefix:@"-cp"]) {
        // Skip "-cp <classpath>"
        return 2;
    } else if ([arg hasPrefix:@"-Djava.library.path="]) {
        return 1;
    } else if ([arg hasPrefix:@"-XX:HeapDumpPath"]) {
        return 1;
    } else {
        return 0;
    }
}

+ (void)tweakVersionJson:(NSMutableDictionary *)json {
    // Exclude some libraries
    for (NSMutableDictionary *library in json[@"libraries"]) {
        library[@"skip"] = @(
            // Exclude platform-dependant libraries
            library[@"downloads"][@"classifiers"] != nil ||
            library[@"natives"] != nil ||
            // Exclude LWJGL libraries
            [library[@"name"] hasPrefix:@"org.lwjgl"]
        );

        NSString *versionStr = [library[@"name"] componentsSeparatedByString:@":"][2];
        NSArray<NSString *> *version = [versionStr componentsSeparatedByString:@"."];
        if ([library[@"name"] hasPrefix:@"net.java.dev.jna:jna:"]) {
            // Special handling for LabyMod 1.8.9 and Forge 1.12.2(?)
            // we have libjnidispatch 5.13.0 in Frameworks directory
            uint32_t bundledVer = 5 << 16 | 13 << 8 | 0;
            uint32_t requiredVer = (char)version[0].intValue << 16 | (char)version[1].intValue << 8 | (char)version[2].intValue;
            if (requiredVer > bundledVer) {
                NSLog(@"[MCDL] Warning: JNA version required by %@ is %@ > 5.13.0, skipping JNA replacement.", json[@"id"], versionStr);
                continue;
            }
            library[@"name"] = @"net.java.dev.jna:jna:5.13.0";
            library[@"downloads"][@"artifact"][@"path"] = @"net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            library[@"downloads"][@"artifact"][@"url"] = @"https://repo1.maven.org/maven2/net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            library[@"downloads"][@"artifact"][@"sha1"] = @"1200e7ebeedbe0d10062093f32925a912020e747";
        } else if ([library[@"name"] hasPrefix:@"org.ow2.asm:asm-all:"]) {
            // Early versions of the ASM library get repalced with 5.0.4 because Pojav's LWJGL is compiled for
            // Java 8, which is not supported by old ASM versions. Mod loaders like Forge, which depend on this
            // library, often include lwjgl in their class transformations, which causes errors with old ASM versions.
            if(version[0].intValue >= 5) continue;
            library[@"name"] = @"org.ow2.asm:asm-all:5.0.4";
            library[@"downloads"][@"artifact"][@"path"] = @"org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
            library[@"downloads"][@"artifact"][@"sha1"] = @"e6244859997b3d4237a552669279780876228909";
            library[@"downloads"][@"artifact"][@"url"] = @"https://repo1.maven.org/maven2/org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
        }
    }

    // Add the client as a library
    NSMutableDictionary *client = [[NSMutableDictionary alloc] init];
    client[@"downloads"] = [[NSMutableDictionary alloc] init];
    if (json[@"downloads"][@"client"] == nil) {
        client[@"downloads"][@"artifact"] = [[NSMutableDictionary alloc] init];
        client[@"skip"] = @YES;
    } else {
        client[@"downloads"][@"artifact"] = json[@"downloads"][@"client"];
    }
    client[@"downloads"][@"artifact"][@"path"] = [NSString stringWithFormat:@"../versions/%1$@/%1$@.jar", json[@"id"]];
    client[@"name"] = [NSString stringWithFormat:@"%@.jar", json[@"id"]];
    [json[@"libraries"] addObject:client];

    // Parse Forge 1.17+ additional JVM Arguments
    if (json[@"inheritsFrom"] == nil || json[@"arguments"][@"jvm"] == nil) {
        return;
    }
    
    // Create jvm_processed array only if it doesn't already exist
    if (json[@"arguments"][@"jvm_processed"] == nil) {
        json[@"arguments"][@"jvm_processed"] = [[NSMutableArray alloc] init];
    } else {
        // If it already exists, ensure it's mutable
        if (![json[@"arguments"][@"jvm_processed"] isKindOfClass:[NSMutableArray class]]) {
            json[@"arguments"][@"jvm_processed"] = [json[@"arguments"][@"jvm_processed"] mutableCopy];
        }
        // Clear existing items to avoid duplicates
        [json[@"arguments"][@"jvm_processed"] removeAllObjects];
    }
    
    NSDictionary *varArgMap = @{
        @"${classpath_separator}": @":",
        @"${library_directory}": [NSString stringWithFormat:@"%s/libraries", getenv("POJAV_GAME_DIR")],
        @"${version_name}": json[@"id"]
    };
    
    int argsToSkip = 0;
    
    // Properly process each JVM argument
    for (id arg in json[@"arguments"][@"jvm"]) {
        // Skip non-string items or rule-based items
        if (![arg isKindOfClass:[NSString class]]) {
            // Check if it's a dictionary with rules
            if ([arg isKindOfClass:[NSDictionary class]] && arg[@"value"]) {
                // Handle rule-based arguments (typically OS-specific)
                // For now, we skip these as they need special handling
                continue;
            }
            continue; // Skip any other non-string args
        }
        
        NSString *argStr = (NSString *)arg;
        
        if (argsToSkip > 0) {
            argsToSkip--;
            continue;
        }
        
        // Check if we need to skip this and subsequent args
        argsToSkip = [self numberOfArgsToSkipForArg:argStr];
        
        if (argsToSkip == 0) {
            // Replace variables in argument string
            for (NSString *key in varArgMap.allKeys) {
                argStr = [argStr stringByReplacingOccurrencesOfString:key withString:varArgMap[key]];
            }        
            [json[@"arguments"][@"jvm_processed"] addObject:argStr];
        }
    }
}

+ (NSObject *)findVersion:(NSString *)version inList:(NSArray *)list {
    return [list filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(id == %@)", version]].firstObject;
}

+ (NSObject *)findNearestVersion:(NSObject *)version expectedType:(int)type {
    if (type != TYPE_RELEASE && type != TYPE_SNAPSHOT) {
        // Only support finding for releases and snapshot for now
        return nil;
    }

    if ([version isKindOfClass:NSString.class]){
        // Find in inheritsFrom
        NSDictionary *versionDict = parseJSONFromFile([NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), version]);
        NSAssert(versionDict != nil, @"version should not be null");
        if (versionDict[@"inheritsFrom"] == nil) {
            // How then?
            return nil; 
        }
        NSObject *inheritsFrom = [self findVersion:versionDict[@"inheritsFrom"] inList:remoteVersionList];
        if (type == TYPE_RELEASE) {
            return inheritsFrom;
        } else if (type == TYPE_SNAPSHOT) {
            return [self findNearestVersion:inheritsFrom expectedType:type];
        }
    }

    NSString *versionType = [version valueForKey:@"type"];
    int index = [remoteVersionList indexOfObject:(NSDictionary *)version];
    if ([versionType isEqualToString:@"release"] && type == TYPE_SNAPSHOT) {
        // Returns the (possible) latest snapshot for the version
        NSDictionary *result = remoteVersionList[index + 1];
        // Sometimes, a release is followed with another release (1.16->1.16.1), go lower in this case
        if ([result[@"type"] isEqualToString:@"release"]) {
            return [self findNearestVersion:result expectedType:type];
        }
        return result;
    } else if ([versionType isEqualToString:@"snapshot"] && type == TYPE_RELEASE) {
        while (remoteVersionList.count > abs(index)) {
            // In case the snapshot has yet attached to a release, perform a reverse find
            NSDictionary *result = remoteVersionList[abs(index)];
            // Returns the corresponding release for the snapshot, or latest release if none found
            if ([result[@"type"] isEqualToString:@"release"]) {
                return result;
            }
            // Continue to decrement, later abs() it
            index--;
        }
    }

    // No idea on handling everything else
    return nil;
}

@end
