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
    NSMutableArray *librariesArray = [NSMutableArray array];
    
    // Make sure we have a mutable array for libraries
    if ([json[@"libraries"] isKindOfClass:[NSArray class]]) {
        librariesArray = [json[@"libraries"] mutableCopy];
        json[@"libraries"] = librariesArray;
    } else {
        NSLog(@"[MCDL] Warning: libraries is not an array in version JSON");
        return;
    }
    
    for (NSInteger i = 0; i < librariesArray.count; i++) {
        id libraryObj = librariesArray[i];
        
        // If the library is not already a mutable dictionary, make it mutable
        NSMutableDictionary *library;
        if ([libraryObj isKindOfClass:[NSDictionary class]] && ![libraryObj isKindOfClass:[NSMutableDictionary class]]) {
            library = [libraryObj mutableCopy];
            librariesArray[i] = library;
        } else if ([libraryObj isKindOfClass:[NSMutableDictionary class]]) {
            library = (NSMutableDictionary *)libraryObj;
        } else {
            NSLog(@"[MCDL] Warning: skipping non-dictionary library entry");
            continue;
        }
        
        // Set the skip property
        BOOL shouldSkip = NO;
        
        // Check library classifiers or natives for platform dependency
        id downloads = library[@"downloads"];
        if ([downloads isKindOfClass:[NSDictionary class]]) {
            shouldSkip = (downloads[@"classifiers"] != nil);
        }
        
        // Check for LWJGL libraries
        NSString *name = library[@"name"];
        if ([name isKindOfClass:[NSString class]] && [name hasPrefix:@"org.lwjgl"]) {
            shouldSkip = YES;
        }
        
        // Check for natives
        if (library[@"natives"] != nil) {
            shouldSkip = YES;
        }
        
        // Set the skip flag
        library[@"skip"] = @(shouldSkip);

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
            
            // Handle downloads dictionary
            NSMutableDictionary *safeDownloads;
            if ([library[@"downloads"] isKindOfClass:[NSDictionary class]]) {
                if (![library[@"downloads"] isKindOfClass:[NSMutableDictionary class]]) {
                    safeDownloads = [library[@"downloads"] mutableCopy];
                    library[@"downloads"] = safeDownloads;
                } else {
                    safeDownloads = library[@"downloads"];
                }
            } else {
                safeDownloads = [NSMutableDictionary dictionary];
                library[@"downloads"] = safeDownloads;
            }
            
            // Handle artifact dictionary
            NSMutableDictionary *safeArtifact;
            if ([safeDownloads[@"artifact"] isKindOfClass:[NSDictionary class]]) {
                if (![safeDownloads[@"artifact"] isKindOfClass:[NSMutableDictionary class]]) {
                    safeArtifact = [safeDownloads[@"artifact"] mutableCopy];
                    safeDownloads[@"artifact"] = safeArtifact;
                } else {
                    safeArtifact = safeDownloads[@"artifact"];
                }
            } else {
                safeArtifact = [NSMutableDictionary dictionary];
                safeDownloads[@"artifact"] = safeArtifact;
            }
            
            safeArtifact[@"path"] = @"net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            safeArtifact[@"url"] = @"https://repo1.maven.org/maven2/net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            safeArtifact[@"sha1"] = @"1200e7ebeedbe0d10062093f32925a912020e747";
        } else if ([library[@"name"] hasPrefix:@"org.ow2.asm:asm-all:"]) {
            // Early versions of the ASM library get replaced with 5.0.4 because Pojav's LWJGL is compiled for
            // Java 8, which is not supported by old ASM versions. Mod loaders like Forge, which depend on this
            // library, often include lwjgl in their class transformations, which causes errors with old ASM versions.
            if(version[0].intValue >= 5) continue;
            library[@"name"] = @"org.ow2.asm:asm-all:5.0.4";
            
            // Handle downloads dictionary
            NSMutableDictionary *safeDownloads;
            if ([library[@"downloads"] isKindOfClass:[NSDictionary class]]) {
                if (![library[@"downloads"] isKindOfClass:[NSMutableDictionary class]]) {
                    safeDownloads = [library[@"downloads"] mutableCopy];
                    library[@"downloads"] = safeDownloads;
                } else {
                    safeDownloads = library[@"downloads"];
                }
            } else {
                safeDownloads = [NSMutableDictionary dictionary];
                library[@"downloads"] = safeDownloads;
            }
            
            // Handle artifact dictionary
            NSMutableDictionary *safeArtifact;
            if ([safeDownloads[@"artifact"] isKindOfClass:[NSDictionary class]]) {
                if (![safeDownloads[@"artifact"] isKindOfClass:[NSMutableDictionary class]]) {
                    safeArtifact = [safeDownloads[@"artifact"] mutableCopy];
                    safeDownloads[@"artifact"] = safeArtifact;
                } else {
                    safeArtifact = safeDownloads[@"artifact"];
                }
            } else {
                safeArtifact = [NSMutableDictionary dictionary];
                safeDownloads[@"artifact"] = safeArtifact;
            }
            
            safeArtifact[@"path"] = @"org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
            safeArtifact[@"sha1"] = @"e6244859997b3d4237a552669279780876228909";
            safeArtifact[@"url"] = @"https://repo1.maven.org/maven2/org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
        }
    }

    // Add the client as a library
    NSMutableDictionary *client = [[NSMutableDictionary alloc] init];
    NSMutableDictionary *clientDownloads = [[NSMutableDictionary alloc] init];
    client[@"downloads"] = clientDownloads;
    
    if (json[@"downloads"][@"client"] == nil) {
        NSMutableDictionary *clientArtifact = [[NSMutableDictionary alloc] init];
        clientDownloads[@"artifact"] = clientArtifact;
        client[@"skip"] = @YES;
    } else {
        // Make sure this is mutable if it's not already
        id clientObj = json[@"downloads"][@"client"];
        if ([clientObj isKindOfClass:[NSDictionary class]] && ![clientObj isKindOfClass:[NSMutableDictionary class]]) {
            clientDownloads[@"artifact"] = [clientObj mutableCopy];
        } else {
            clientDownloads[@"artifact"] = clientObj;
        }
    }
    
    clientDownloads[@"artifact"][@"path"] = [NSString stringWithFormat:@"../versions/%1$@/%1$@.jar", json[@"id"]];
    client[@"name"] = [NSString stringWithFormat:@"%@.jar", json[@"id"]];
    [librariesArray addObject:client];

    // Process Forge 1.17+ JVM Arguments
    [self processJvmArguments:json];
}

+ (void)processJvmArguments:(NSMutableDictionary *)json {
    // Only process if this is a Forge version with inheritsFrom and JVM arguments
    if (json[@"inheritsFrom"] == nil || json[@"arguments"][@"jvm"] == nil) {
        return;
    }
    
    // Ensure arguments dictionary exists and is mutable
    NSMutableDictionary *argsDict;
    if (!json[@"arguments"]) {
        argsDict = [NSMutableDictionary dictionary];
        json[@"arguments"] = argsDict;
    } else if ([json[@"arguments"] isKindOfClass:[NSMutableDictionary class]]) {
        argsDict = json[@"arguments"];
    } else {
        argsDict = [json[@"arguments"] mutableCopy];
        json[@"arguments"] = argsDict;
    }
    
    // Create array for processed JVM arguments
    NSMutableArray *processedJvmArgs = [NSMutableArray array];
    argsDict[@"jvm_processed"] = processedJvmArgs;
    
    // Variable replacement map for placeholders
    NSDictionary *varArgMap = @{
        @"${classpath_separator}": @":",
        @"${library_directory}": [NSString stringWithFormat:@"%s/libraries", getenv("POJAV_GAME_DIR")],
        @"${version_name}": json[@"id"]
    };
    
    // Process each JVM argument
    [self processJvmArgumentArray:json[@"arguments"][@"jvm"] 
                     withVarMap:varArgMap 
                     intoResult:processedJvmArgs];
    
    // Log results
    NSLog(@"[MCDL] Processed JVM Arguments (%lu):", (unsigned long)processedJvmArgs.count);
    for (NSString *arg in processedJvmArgs) {
        NSLog(@"  %@", arg);
    }
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
