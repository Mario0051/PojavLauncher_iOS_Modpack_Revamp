#import "installer/FabricUtils.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"

@implementation ModpackUtils

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing *)error {
    // Ensure path exists
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&dirError];
    if (dirError) {
        NSLog(@"[ModpackUtils] Error creating directory %@: %@", path, dirError);
        if (error) *error = dirError;
        return;
    }
    
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        if (![fileInfo.filename hasPrefix:dir] || fileInfo.filename.length <= dir.length) {
            return;
        }
        NSString *fileName = [fileInfo.filename substringFromIndex:dir.length+1];
        NSString *destItemPath = [path stringByAppendingPathComponent:fileName];
        NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
        BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath 
                                                   withIntermediateDirectories:YES 
                                                                    attributes:nil 
                                                                         error:error];
        if (!createdDir) {
            *stop = YES;
            return;
        } else if (fileInfo.isDirectory) {
            return;
        }
        NSData *data = [archive extractData:fileInfo error:error];
        BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:error];
        *stop = !data || !written;
        if (!*stop) {
            NSLog(@"[ModpackDL] Extracted %@", fileInfo.filename);
        }
    } error:error];
}

+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency {
    NSMutableDictionary *info = [NSMutableDictionary new];
    NSString *minecraftVersion = dependency[@"minecraft"];
    if (dependency[@"forge"]) {
        info[@"id"] = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, dependency[@"forge"]];
    } else if (dependency[@"fabric-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"fabric-loader-%@-%@", dependency[@"fabric-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], minecraftVersion, dependency[@"fabric-loader"]];
    } else if (dependency[@"quilt-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", dependency[@"quilt-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], minecraftVersion, dependency[@"quilt-loader"]];
    }
    return info;
}

// Updated method for parsing version strings for different modloaders with improved logging
+ (NSDictionary *)parseVersionString:(NSString *)versionString {
    if (!versionString || versionString.length == 0) {
        NSLog(@"[ModpackUtils] Warning: Empty version string");
        return @{};
    }
    
    NSString *trimmed = [[versionString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSArray *components = [trimmed componentsSeparatedByString:@"-"];
    NSMutableDictionary *result = [NSMutableDictionary new];
    
    if (components.count == 4 && [components[0] isEqualToString:@"fabric"] && [components[1] isEqualToString:@"loader"]) {
        // Fabric example: "fabric-loader-0.16.10-1.21.4"
        result[@"loader"] = @"fabric";
        result[@"loaderVersion"] = components[2];
        result[@"mcVersion"] = components[3];
        NSLog(@"[ModpackUtils] Parsed Fabric version: loader=%@, version=%@, minecraft=%@", 
              result[@"loader"], result[@"loaderVersion"], result[@"mcVersion"]);
    } else if (components.count == 3) {
        // For Forge, NeoForge, or Quilt in the format "1.20-loader-46.0.14"
        result[@"mcVersion"] = components[0];
        result[@"loader"] = components[1]; // Expected to be "forge", "neoforge", or "quilt"
        result[@"loaderVersion"] = components[2];
        NSLog(@"[ModpackUtils] Parsed mod loader version: minecraft=%@, loader=%@, version=%@", 
              result[@"mcVersion"], result[@"loader"], result[@"loaderVersion"]);
    } else {
        // Fallback: best-effort parsing.
        if (components.count >= 3) {
            result[@"mcVersion"] = components.firstObject;
            result[@"loader"] = components[1];
            result[@"loaderVersion"] = [[components subarrayWithRange:NSMakeRange(2, components.count - 2)] componentsJoinedByString:@"-"];
            NSLog(@"[ModpackUtils] Parsed using fallback: minecraft=%@, loader=%@, version=%@", 
                  result[@"mcVersion"], result[@"loader"], result[@"loaderVersion"]);
        } else {
            NSLog(@"[ModpackUtils] Warning: Could not parse version string: %@", versionString);
        }
    }
    return result;
}

+ (NSString *)getUniqueProfileDirectory:(NSString *)profileName {
    // Generate a normalized directory name from profile name
    NSString *normalized = [[profileName lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    normalized = [normalized stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    
    return [NSString stringWithFormat:@"./profiles/%@", normalized];
}

+ (BOOL)createProfileDirectory:(NSString *)gameDir {
    NSString *fullPath = [NSString stringWithFormat:@"%s/instances/%@/%@", 
                          getenv("POJAV_HOME"), 
                          getPrefObject(@"general.game_directory"), 
                          gameDir];
    
    // Ensure normalized path (resolve ./ etc.)
    fullPath = [fullPath stringByStandardizingPath];
    
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:fullPath
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:&error];
    if (!success) {
        NSLog(@"[ModpackUtils] Error creating profile directory %@: %@", fullPath, error);
        return NO;
    }
    
    // Create subdirectories for common Minecraft folders
    NSArray *subDirs = @[@"mods", @"config", @"resourcepacks", @"shaderpacks", @"saves"];
    for (NSString *subDir in subDirs) {
        NSString *subDirPath = [fullPath stringByAppendingPathComponent:subDir];
        [[NSFileManager defaultManager] createDirectoryAtPath:subDirPath
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:nil];
    }
    
    NSLog(@"[ModpackUtils] Created profile directory structure at %@", fullPath);
    return YES;
}

@end
