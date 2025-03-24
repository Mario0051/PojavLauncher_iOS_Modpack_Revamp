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
    [self insertSafety:inheritsFrom from:json arr:@[
        @"assetIndex", @"assets", @"id",
        @"inheritsFrom",
        @"mainClass", @"minecraftArguments",
        @"optifineLib", @"releaseTime", @"time", @"type"
    ]];
    inheritsFrom[@"arguments"] = json[@"arguments"];

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

    //inheritsFrom[@"inheritsFrom"] = nil;
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

+ (NSInteger)numberOfArgsToSkip:(NSString *)arg {
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
    // Check if this is a NeoForge version
    BOOL isNeoForge = [json[@"id"] containsString:@"neoforge"];
    
    // Exclude some libraries
    for (NSMutableDictionary *library in json[@"libraries"]) {
        library[@"skip"] = @(
            // Exclude platform-dependant libraries
            library[@"downloads"][@"classifiers"] != nil ||
            library[@"natives"] != nil ||
            // Exclude LWJGL libraries
            [library[@"name"] hasPrefix:@"org.lwjgl"]
        );

        if ([library[@"name"] hasPrefix:@"net.java.dev.jna:jna:"]) {
            // Special handling for JNA (required for both Forge and NeoForge)
            NSString *versionStr = [library[@"name"] componentsSeparatedByString:@":"][2];
            NSArray<NSString *> *versionComponents = [versionStr componentsSeparatedByString:@"."];
            
            // Use safer version comparison logic
            NSInteger majorVersion = versionComponents.count > 0 ? [versionComponents[0] integerValue] : 0;
            NSInteger minorVersion = versionComponents.count > 1 ? [versionComponents[1] integerValue] : 0;
            NSInteger patchVersion = versionComponents.count > 2 ? [versionComponents[2] integerValue] : 0;
            
            // We have libjnidispatch 5.13.0 in Frameworks directory
            BOOL isNewer = (majorVersion > 5) || 
                           (majorVersion == 5 && minorVersion > 13) || 
                           (majorVersion == 5 && minorVersion == 13 && patchVersion > 0);
            
            // For normal Forge, skip replacement if newer version
            // For NeoForge, always use our JNA replacement regardless of version
            if (isNewer && !isNeoForge) {
                NSLog(@"[MCDL] Warning: JNA version required by %@ is %@ > 5.13.0, skipping JNA replacement.", 
                      json[@"id"], versionStr);
                continue;
            }
            
            // Always replace JNA for NeoForge or use our bundled version
            library[@"name"] = @"net.java.dev.jna:jna:5.13.0";
            library[@"downloads"][@"artifact"][@"path"] = @"net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            library[@"downloads"][@"artifact"][@"url"] = @"https://repo1.maven.org/maven2/net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            library[@"downloads"][@"artifact"][@"sha1"] = @"1200e7ebeedbe0d10062093f32925a912020e747";
            
            // Make sure we don't skip JNA for NeoForge
            if (isNeoForge) {
                library[@"skip"] = @NO;
            }
        } else if ([library[@"name"] hasPrefix:@"org.ow2.asm:asm-all:"]) {
            // Early versions of the ASM library get repalced with 5.0.4 because Pojav's LWJGL is compiled for
            // Java 8, which is not supported by old ASM versions. Mod loaders like Forge, which depend on this
            // library, often include lwjgl in their class transformations, which causes errors with old ASM versions.
            NSString *versionStr = [library[@"name"] componentsSeparatedByString:@":"][2];
            NSArray<NSString *> *version = [versionStr componentsSeparatedByString:@"."];
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

    // Parse Forge/NeoForge JVM Arguments
    if (json[@"inheritsFrom"] == nil || json[@"arguments"][@"jvm"] == nil) {
        return;
    }
    
    json[@"arguments"][@"jvm_processed"] = [[NSMutableArray alloc] init];
    NSDictionary *varArgMap = @{
        @"${classpath_separator}": @":",
        @"${library_directory}": [NSString stringWithFormat:@"%s/libraries", getenv("POJAV_GAME_DIR")],
        @"${version_name}": json[@"id"]
    };
    
    // First pass: Check if the module path flag is present and has a value
    BOOL hasModulePath = NO;
    for (id argObj in json[@"arguments"][@"jvm"]) {
        if (![argObj isKindOfClass:[NSString class]]) continue;
        
        NSString *arg = (NSString *)argObj;
        if ([arg isEqualToString:@"-p"] || [arg isEqualToString:@"--module-path"]) {
            hasModulePath = YES;
            break;
        }
    }
    
    // If there's no module path and this is NeoForge, add one with a default value
    if (isNeoForge && !hasModulePath) {
        [json[@"arguments"][@"jvm_processed"] addObject:@"--module-path"];
        [json[@"arguments"][@"jvm_processed"] addObject:[NSString stringWithFormat:@"%s/libraries", getenv("POJAV_GAME_DIR")]];
    }
    
    // Track which type of flag we're processing
    NSString *currentModuleFlag = nil;
    int argsToSkip = 0;
    
    // Second pass: Process the actual arguments
    for (id argObj in json[@"arguments"][@"jvm"]) {
        if (![argObj isKindOfClass:[NSString class]]) {
            // If it's not a string, just skip it
            continue;
        }
        
        NSString *arg = (NSString *)argObj;
        if (argsToSkip > 0) {
            argsToSkip--;
            continue;
        }
        
        argsToSkip = [self numberOfArgsToSkip:arg];
        if (argsToSkip > 0) {
            // Skip this argument and the next one
            continue;
        }
        
        // Check if this is a module-related flag
        BOOL isModuleFlag = [arg isEqualToString:@"-p"] || 
            [arg isEqualToString:@"--module-path"] ||
            [arg isEqualToString:@"--add-modules"] ||
            [arg isEqualToString:@"--add-opens"] ||
            [arg isEqualToString:@"--add-exports"] ||
            [arg isEqualToString:@"--add-reads"] ||
            [arg isEqualToString:@"--patch-module"] ||
            [arg isEqualToString:@"--limit-modules"];
            
        if (isModuleFlag) {
            currentModuleFlag = arg;
            // Add the flag to the processed arguments
            [json[@"arguments"][@"jvm_processed"] addObject:arg];
            continue;
        }
        
        // If we have a pending module flag
        if (currentModuleFlag != nil) {
            // If the argument is empty or starts with -, it's not a valid value
            if (arg.length == 0 || [arg hasPrefix:@"-"]) {
                // Provide an appropriate default value based on the flag type
                NSString *defaultValue = nil;
                
                if ([currentModuleFlag isEqualToString:@"-p"] || 
                    [currentModuleFlag isEqualToString:@"--module-path"]) {
                    defaultValue = [NSString stringWithFormat:@"%s/libraries", getenv("POJAV_GAME_DIR")];
                } else if ([currentModuleFlag isEqualToString:@"--add-modules"]) {
                    defaultValue = @"ALL-MODULE-PATH";
                } else if ([currentModuleFlag isEqualToString:@"--add-opens"]) {
                    defaultValue = @"java.base/java.lang=ALL-UNNAMED";
                } else if ([currentModuleFlag isEqualToString:@"--add-exports"]) {
                    defaultValue = @"java.base/java.lang=ALL-UNNAMED";
                } else if ([currentModuleFlag isEqualToString:@"--add-reads"]) {
                    defaultValue = @"java.base=ALL-UNNAMED";
                } else if ([currentModuleFlag isEqualToString:@"--patch-module"]) {
                    defaultValue = @"java.base=.";
                } else if ([currentModuleFlag isEqualToString:@"--limit-modules"]) {
                    defaultValue = @"java.base";
                }
                
                // Replace variables in the default value
                for (NSString *key in varArgMap) {
                    defaultValue = [defaultValue stringByReplacingOccurrencesOfString:key withString:varArgMap[key]];
                }
                
                [json[@"arguments"][@"jvm_processed"] addObject:defaultValue];
                currentModuleFlag = nil;
                
                // Process this argument now if it's a new flag
                if ([arg hasPrefix:@"-"]) {
                    for (NSString *key in varArgMap) {
                        arg = [arg stringByReplacingOccurrencesOfString:key withString:varArgMap[key]];
                    }
                    [json[@"arguments"][@"jvm_processed"] addObject:arg];
                }
            } else {
                // We have a valid value for the module flag
                for (NSString *key in varArgMap) {
                    arg = [arg stringByReplacingOccurrencesOfString:key withString:varArgMap[key]];
                }
                [json[@"arguments"][@"jvm_processed"] addObject:arg];
                currentModuleFlag = nil;
            }
        } else {
            // Regular argument
            for (NSString *key in varArgMap) {
                arg = [arg stringByReplacingOccurrencesOfString:key withString:varArgMap[key]];
            }
            [json[@"arguments"][@"jvm_processed"] addObject:arg];
        }
    }
    
    // If we ended with a pending module flag, add an appropriate default
    if (currentModuleFlag != nil) {
        NSString *defaultValue = nil;
        
        if ([currentModuleFlag isEqualToString:@"-p"] || 
            [currentModuleFlag isEqualToString:@"--module-path"]) {
            defaultValue = [NSString stringWithFormat:@"%s/libraries", getenv("POJAV_GAME_DIR")];
        } else if ([currentModuleFlag isEqualToString:@"--add-modules"]) {
            defaultValue = @"ALL-MODULE-PATH";
        } else if ([currentModuleFlag isEqualToString:@"--add-opens"]) {
            defaultValue = @"java.base/java.lang=ALL-UNNAMED";
        } else if ([currentModuleFlag isEqualToString:@"--add-exports"]) {
            defaultValue = @"java.base/java.lang=ALL-UNNAMED";
        } else if ([currentModuleFlag isEqualToString:@"--add-reads"]) {
            defaultValue = @"java.base=ALL-UNNAMED";
        } else if ([currentModuleFlag isEqualToString:@"--patch-module"]) {
            defaultValue = @"java.base=.";
        } else if ([currentModuleFlag isEqualToString:@"--limit-modules"]) {
            defaultValue = @"java.base";
        }
        
        for (NSString *key in varArgMap) {
            defaultValue = [defaultValue stringByReplacingOccurrencesOfString:key withString:varArgMap[key]];
        }
        
        [json[@"arguments"][@"jvm_processed"] addObject:defaultValue];
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
