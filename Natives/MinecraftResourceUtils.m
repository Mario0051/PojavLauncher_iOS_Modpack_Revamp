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
    // Copy basic properties from child to parent version
    [self insertSafety:inheritsFrom from:json arr:@[
        @"assetIndex", @"assets", @"id",
        @"inheritsFrom",
        @"mainClass", @"minecraftArguments",
        @"optifineLib", @"releaseTime", @"time", @"type"
    ]];
    
    // Copy arguments
    inheritsFrom[@"arguments"] = json[@"arguments"];

    // Process libraries
    if (json[@"libraries"] && [json[@"libraries"] isKindOfClass:[NSArray class]]) {
        for (NSMutableDictionary *lib in json[@"libraries"]) {
            // Get library name up to last colon
            NSRange lastColonRange = [lib[@"name"] rangeOfString:@":" options:NSBackwardsSearch];
            if (lastColonRange.location == NSNotFound) continue;
            
            NSString *libName = [lib[@"name"] substringToIndex:lastColonRange.location];
            int i;
            
            // Look for matching libraries in parent version
            for (i = 0; i < [inheritsFrom[@"libraries"] count]; i++) {
                NSMutableDictionary *libAdded = inheritsFrom[@"libraries"][i];
                
                // Get parent library name up to last colon
                NSRange parentLastColonRange = [libAdded[@"name"] rangeOfString:@":" options:NSBackwardsSearch];
                if (parentLastColonRange.location == NSNotFound) continue;
                
                NSString *libAddedName = [libAdded[@"name"] substringToIndex:parentLastColonRange.location];

                // If library exists in parent, replace it with child version
                if ([libAdded[@"name"] hasPrefix:libName]) {
                    inheritsFrom[@"libraries"][i] = lib;
                    i = -1; // Signal that we found and replaced the library
                    break;
                }
            }

            // If library wasn't found in parent, add it
            if (i != -1) {
                [inheritsFrom[@"libraries"] addObject:lib];
            }
        }
    }
}

+ (void)insertSafety:(NSMutableDictionary *)targetVer from:(NSDictionary *)fromVer arr:(NSArray *)arr {
    for (NSString *key in arr) {
        // Check if source value exists and is valid, or target value doesn't exist
        if (([fromVer[key] isKindOfClass:[NSString class]] && [fromVer[key] length] > 0) || 
            targetVer[key] == nil) {
            targetVer[key] = fromVer[key];
        } else {
            NSLog(@"[MCDL] insertSafety: how to insert %@?", key);
        }
    }
}

+ (NSInteger)numberOfArgsToSkipForArg:(NSString *)arg {
    // Basic validation
    if (![arg isKindOfClass:[NSString class]]) {
        // Skip non-string arg
        return 1;
    } 
    
    // Skip classpath arguments which have a parameter
    if ([arg hasPrefix:@"-cp"]) {
        return 2;
    } 
    
    // Skip other known arguments that have parameters
    if ([arg hasPrefix:@"-Djava.library.path="]) {
        return 1;
    } 
    
    if ([arg hasPrefix:@"-XX:HeapDumpPath"]) {
        return 1;
    }
    
    // Special handling for Java module arguments
    if ([arg isEqualToString:@"--add-exports"] || 
        [arg isEqualToString:@"--add-opens"] || 
        [arg isEqualToString:@"--add-modules"] || 
        [arg isEqualToString:@"--limit-modules"]) {
        return 2;
    }
    
    // Default - no args to skip
    return 0;
}

+ (void)tweakVersionJson:(NSMutableDictionary *)json {
    NSLog(@"[MCDL] Tweaking version JSON for: %@", json[@"id"]);
    
    // Only process libraries if they exist and are in correct format
    if (json[@"libraries"] && [json[@"libraries"] isKindOfClass:[NSArray class]]) {
        // Process each library
        for (NSMutableDictionary *library in json[@"libraries"]) {
            // Skip if not a valid dictionary
            if (![library isKindOfClass:[NSMutableDictionary class]]) {
                continue;
            }
            
            // Determine if library should be skipped
            BOOL hasClassifiers = (library[@"downloads"] && 
                                  library[@"downloads"][@"classifiers"] && 
                                  [library[@"downloads"][@"classifiers"] isKindOfClass:[NSDictionary class]]);
                                  
            BOOL hasNatives = (library[@"natives"] && 
                              [library[@"natives"] isKindOfClass:[NSDictionary class]]);
                              
            BOOL isLWJGL = ([library[@"name"] isKindOfClass:[NSString class]] && 
                           [library[@"name"] hasPrefix:@"org.lwjgl"]);
            
            // Special handling for Forge libraries - don't skip Forge libraries
            BOOL isForgeLibrary = ([library[@"name"] isKindOfClass:[NSString class]] && 
                                 ([library[@"name"] containsString:@"minecraftforge"] || 
                                  [library[@"name"] containsString:@"net.minecraftforge:forge"]));
            
            // Mark library to be skipped if it meets skip conditions and is not a Forge library
            library[@"skip"] = @(hasClassifiers || hasNatives || isLWJGL);
            
            // Don't skip Forge libraries that we need
            if (isForgeLibrary && ![library[@"name"] hasSuffix:@":client"] && ![library[@"name"] hasSuffix:@":universal"]) {
                library[@"skip"] = @NO;
            }

            // Only process libraries with valid names
            if (![library[@"name"] isKindOfClass:[NSString class]]) {
                continue;
            }

            // Extract version information
            NSArray *nameParts = [library[@"name"] componentsSeparatedByString:@":"];
            if (nameParts.count < 3) continue;
            
            NSString *versionStr = nameParts[2];
            NSArray<NSString *> *version = [versionStr componentsSeparatedByString:@"."];
            
            // Special handling for JNA libraries
            if ([library[@"name"] hasPrefix:@"net.java.dev.jna:jna:"]) {
                // We need at least 3 version components
                if (version.count < 3) continue;
                
                // Check if the required version is newer than our bundled version
                uint32_t bundledVer = 5 << 16 | 13 << 8 | 0; // 5.13.0
                uint32_t requiredVer = 0;
                
                @try {
                    requiredVer = (char)version[0].intValue << 16 | (char)version[1].intValue << 8 | (char)version[2].intValue;
                } @catch (NSException *exception) {
                    NSLog(@"[MCDL] Error parsing JNA version: %@", exception);
                    continue;
                }
                
                if (requiredVer > bundledVer) {
                    NSLog(@"[MCDL] Warning: JNA version required by %@ is %@ > 5.13.0, skipping JNA replacement.", json[@"id"], versionStr);
                    continue;
                }
                
                // Replace with our bundled version
                library[@"name"] = @"net.java.dev.jna:jna:5.13.0";
                
                // Make sure downloads and artifact dictionaries exist
                if (!library[@"downloads"]) {
                    library[@"downloads"] = [NSMutableDictionary dictionary];
                }
                
                if (!library[@"downloads"][@"artifact"]) {
                    library[@"downloads"][@"artifact"] = [NSMutableDictionary dictionary];
                }
                
                // Update paths and checksums
                library[@"downloads"][@"artifact"][@"path"] = @"net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
                library[@"downloads"][@"artifact"][@"url"] = @"https://repo1.maven.org/maven2/net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
                library[@"downloads"][@"artifact"][@"sha1"] = @"1200e7ebeedbe0d10062093f32925a912020e747";
            } 
            // Special handling for ASM libraries
            else if ([library[@"name"] hasPrefix:@"org.ow2.asm:asm-all:"]) {
                // Check if version is already 5 or higher
                if (version.count < 1 || version[0].intValue >= 5) continue;
                
                // Replace with our compatible version
                library[@"name"] = @"org.ow2.asm:asm-all:5.0.4";
                
                // Make sure downloads and artifact dictionaries exist
                if (!library[@"downloads"]) {
                    library[@"downloads"] = [NSMutableDictionary dictionary];
                }
                
                if (!library[@"downloads"][@"artifact"]) {
                    library[@"downloads"][@"artifact"] = [NSMutableDictionary dictionary];
                }
                
                // Update paths and checksums
                library[@"downloads"][@"artifact"][@"path"] = @"org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
                library[@"downloads"][@"artifact"][@"sha1"] = @"e6244859997b3d4237a552669279780876228909";
                library[@"downloads"][@"artifact"][@"url"] = @"https://repo1.maven.org/maven2/org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
            }
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
    
    // Set client path and name
    client[@"downloads"][@"artifact"][@"path"] = [NSString stringWithFormat:@"../versions/%1$@/%1$@.jar", json[@"id"]];
    client[@"name"] = [NSString stringWithFormat:@"%@.jar", json[@"id"]];
    
    // Ensure libraries array exists
    if (!json[@"libraries"]) {
        json[@"libraries"] = [NSMutableArray array];
    }
    
    // Add client to libraries
    [json[@"libraries"] addObject:client];

    // Process Forge JVM arguments
    [self processJvmArguments:json];
}

+ (void)processJvmArguments:(NSMutableDictionary *)json {
    // Only process if this is a Forge version with inheritsFrom and JVM arguments
    if (json[@"inheritsFrom"] == nil || 
        json[@"arguments"] == nil || 
        json[@"arguments"][@"jvm"] == nil || 
        ![json[@"arguments"][@"jvm"] isKindOfClass:[NSArray class]]) {
        return;
    }
    
    NSLog(@"[MCDL] Processing JVM arguments for %@", json[@"id"]);
    
    // Create array for processed JVM arguments
    NSMutableArray *processedJvmArgs = [NSMutableArray array];
    json[@"arguments"][@"jvm_processed"] = processedJvmArgs;
    
    // Variable replacement map for placeholders
    NSDictionary *varArgMap = @{
        @"${classpath_separator}": @":",
        @"${library_directory}": [NSString stringWithFormat:@"%s/libraries", getenv("POJAV_GAME_DIR")],
        @"${version_name}": json[@"id"]
    };
    
    // Process arguments one by one
    int argsToSkip = 0;
    for (id arg in json[@"arguments"][@"jvm"]) {
        // Skip arguments if needed
        if (argsToSkip > 0) {
            argsToSkip--;
            continue;
        }
        
        // Skip non-string arguments
        if (![arg isKindOfClass:[NSString class]]) {
            continue;
        }
        
        // Check if we need to skip additional arguments
        argsToSkip = [self numberOfArgsToSkipForArg:arg];
        
        // If we don't need to skip, process and add the argument
        if (argsToSkip == 0) {
            NSString *argStr = arg;
            for (NSString *key in varArgMap.allKeys) {
                argStr = [argStr stringByReplacingOccurrencesOfString:key withString:varArgMap[key]];
            }
            [processedJvmArgs addObject:argStr];
        }
    }
    
    NSLog(@"[MCDL] Processed %lu JVM arguments", (unsigned long)processedJvmArgs.count);
}

+ (void)processJvmArgumentArray:(NSArray *)jvmArgs 
                     withVarMap:(NSDictionary *)varArgMap 
                     intoResult:(NSMutableArray *)processedJvmArgs {
    // Skip if arguments array is nil or empty
    if (!jvmArgs || jvmArgs.count == 0) {
        return;
    }
    
    // These keys will be deduplicated by checking the entire argument string
    NSMutableSet *moduleTypeArgs = [NSMutableSet setWithArray:@[
        @"--add-modules", 
        @"--add-opens",
        @"--add-exports",
        @"--add-reads",
        @"--patch-module",
        @"--limit-modules"
    ]];
    
    // Track already added arguments to avoid duplicates
    NSMutableSet *addedArgs = [NSMutableSet set];
    
    // Process arguments one by one
    NSUInteger i = 0;
    while (i < jvmArgs.count) {
        id currentArg = jvmArgs[i];
        
        // Skip non-string arguments
        if (![currentArg isKindOfClass:[NSString class]]) {
            i++;
            continue;
        }
        
        NSString *argStr = currentArg;
        
        // Apply variable replacements
        for (NSString *key in varArgMap.allKeys) {
            argStr = [argStr stringByReplacingOccurrencesOfString:key 
                                                       withString:varArgMap[key]];
        }
        
        // Handle module-type arguments that need their own parameter
        if ([moduleTypeArgs containsObject:argStr] && i + 1 < jvmArgs.count) {
            // Get the next argument which is the parameter
            id nextArg = jvmArgs[i + 1];
            
            // Skip if nextArg is not a string
            if (![nextArg isKindOfClass:[NSString class]]) {
                i += 2;
                continue;
            }
            
            // Apply variable replacements to parameter
            NSString *paramStr = nextArg;
            for (NSString *key in varArgMap.allKeys) {
                paramStr = [paramStr stringByReplacingOccurrencesOfString:key 
                                                               withString:varArgMap[key]];
            }
            
            // Combine the flag and parameter
            NSString *combinedArg = [NSString stringWithFormat:@"%@ %@", argStr, paramStr];
            
            // Only add if not already added
            if (![addedArgs containsObject:combinedArg]) {
                [processedJvmArgs addObject:combinedArg];
                [addedArgs addObject:combinedArg];
            }
            
            // Skip both arguments
            i += 2;
        }
        // Handle single arguments
        else {
            // Only add if not already added
            if (![addedArgs containsObject:argStr]) {
                [processedJvmArgs addObject:argStr];
                [addedArgs addObject:argStr];
            }
            
            // Move to next argument
            i++;
        }
    }
}

+ (NSObject *)findVersion:(NSString *)version inList:(NSArray *)list {
    // Check parameters
    if (!version || !list || ![list isKindOfClass:[NSArray class]]) {
        return nil;
    }
    
    // Use a predicate to find the version by ID
    return [list filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(id == %@)", version]].firstObject;
}

+ (NSObject *)findNearestVersion:(NSObject *)version expectedType:(int)type {
    // Only support finding releases and snapshots for now
    if (type != TYPE_RELEASE && type != TYPE_SNAPSHOT) {
        return nil;
    }

    // Handle string version (inheritsFrom cases)
    if ([version isKindOfClass:[NSString class]]) {
        // Find in inheritsFrom
        NSString *versionPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", 
                                getenv("POJAV_GAME_DIR"), version];
        
        NSDictionary *versionDict = parseJSONFromFile(versionPath);
        if (!versionDict) {
            NSLog(@"[MCDL] Error: Could not load version JSON from %@", versionPath);
            return nil;
        }
        
        // Check for inheritsFrom property
        if (versionDict[@"inheritsFrom"] == nil) {
            return nil; 
        }
        
        // Find the parent version
        NSObject *inheritsFrom = [self findVersion:versionDict[@"inheritsFrom"] inList:remoteVersionList];
        
        if (type == TYPE_RELEASE) {
            return inheritsFrom;
        } else if (type == TYPE_SNAPSHOT) {
            return [self findNearestVersion:inheritsFrom expectedType:type];
        }
    }

    // Handle version dictionary
    NSString *versionType = [version valueForKey:@"type"];
    int index = [remoteVersionList indexOfObject:(NSDictionary *)version];
    
    // Convert release to snapshot
    if ([versionType isEqualToString:@"release"] && type == TYPE_SNAPSHOT) {
        // Returns the (possible) latest snapshot for the version
        if (index + 1 >= remoteVersionList.count) {
            return nil;
        }
        
        NSDictionary *result = remoteVersionList[index + 1];
        
        // Sometimes, a release is followed with another release (1.16->1.16.1), go lower in this case
        if ([result[@"type"] isEqualToString:@"release"]) {
            return [self findNearestVersion:result expectedType:type];
        }
        return result;
    } 
    // Convert snapshot to release
    else if ([versionType isEqualToString:@"snapshot"] && type == TYPE_RELEASE) {
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

    // Fallback - no suitable version found
    return nil;
}

@end
