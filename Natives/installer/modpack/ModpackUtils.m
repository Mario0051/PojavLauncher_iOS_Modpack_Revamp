#import "installer/FabricUtils.h"
#import "ModpackUtils.h"

@implementation ModpackUtils

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing *)error {
    if (!archive || !dir || !path) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackUtilsErrorDomain" 
                                         code:100 
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid parameters for extraction"}];
        }
        return;
    }
    
    __block NSError *extractError = nil;
    
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        // Skip files that are not in the specified directory
        if (![fileInfo.filename hasPrefix:dir] || fileInfo.filename.length <= dir.length) {
            return;
        }
        
        // Get relative path within the directory
        NSString *fileName = [fileInfo.filename substringFromIndex:dir.length+1];
        NSString *destItemPath = [path stringByAppendingPathComponent:fileName];
        NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
        
        // Create destination directory
        NSError *dirError = nil;
        BOOL createdDir = [[NSFileManager defaultManager] createDirectoryAtPath:destDirPath 
                                                    withIntermediateDirectories:YES 
                                                                     attributes:nil 
                                                                          error:&dirError];
        if (!createdDir) {
            extractError = dirError;
            *stop = YES;
            return;
        } else if (fileInfo.isDirectory) {
            return;
        }
        
        // Extract file data
        NSError *dataError = nil;
        NSData *data = [archive extractData:fileInfo error:&dataError];
        if (!data) {
            extractError = dataError;
            *stop = YES;
            return;
        }
        
        // Write data to destination
        NSError *writeError = nil;
        BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:&writeError];
        if (!written) {
            extractError = writeError;
            *stop = YES;
            return;
        }
        
        NSLog(@"[ModpackDL] Extracted %@", fileInfo.filename);
    } error:error];
    
    // If we encountered an error during extraction, pass it back
    if (extractError && error && !*error) {
        *error = extractError;
    }
}

+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency {
    if (!dependency) {
        return @{};
    }
    
    NSMutableDictionary *info = [NSMutableDictionary new];
    NSString *minecraftVersion = dependency[@"minecraft"];
    
    if (!minecraftVersion) {
        return info;
    }
    
    if (dependency[@"forge"]) {
        info[@"id"] = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, dependency[@"forge"]];
    } else if (dependency[@"fabric-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"fabric-loader-%@-%@", dependency[@"fabric-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], minecraftVersion, dependency[@"fabric-loader"]];
    } else if (dependency[@"quilt-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", dependency[@"quilt-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], minecraftVersion, dependency[@"quilt-loader"]];
    } else if (dependency[@"neoforge"]) {
        info[@"id"] = [NSString stringWithFormat:@"%@-neoforge-%@", minecraftVersion, dependency[@"neoforge"]];
    }
    
    return info;
}

// Updated method for parsing version strings for different modloaders.
// Supports:
// - Forge: "1.20-forge-46.0.14"
// - Fabric: "fabric-loader-0.16.10-1.21.4" (returns loader = "fabric")
// - NeoForge: "1.20-neoforge-46.0.14"
// - Quilt: "quilt-loader-0.16.10-1.21.4" or "1.20-quilt-<version>"
+ (NSDictionary *)parseVersionString:(NSString *)versionString {
    if (!versionString || versionString.length == 0) {
        return @{};
    }
    
    NSString *trimmed = [[versionString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSArray *components = [trimmed componentsSeparatedByString:@"-"];
    NSMutableDictionary *result = [NSMutableDictionary new];
    
    if (components.count >= 2) {
        // First identify the pattern
        if (components.count == 4 && 
            ([components[0] isEqualToString:@"fabric"] || [components[0] isEqualToString:@"quilt"]) && 
            [components[1] isEqualToString:@"loader"]) {
            // Fabric/Quilt format: "fabric-loader-0.16.10-1.21.4" or "quilt-loader-0.16.10-1.21.4"
            result[@"loader"] = components[0];
            result[@"loaderVersion"] = components[2];
            result[@"mcVersion"] = components[3];
        } else if (components.count == 3) {
            // Standard format: "1.20-forge-46.0.14" or "1.20-neoforge-46.0.14"
            result[@"mcVersion"] = components[0];
            result[@"loader"] = components[1]; // Expected to be "forge", "neoforge", or "quilt"
            result[@"loaderVersion"] = components[2];
        } else {
            // Try to make a best guess 
            if ([components[0] isEqualToString:@"fabric"] || 
                [components[0] isEqualToString:@"forge"] || 
                [components[0] isEqualToString:@"neoforge"] || 
                [components[0] isEqualToString:@"quilt"]) {
                
                result[@"loader"] = components[0];
                
                // Extract other components as best we can
                if (components.count > 1) {
                    // Likely a loader version or MC version next
                    if ([components[1] hasPrefix:@"1."] || [components[1] hasPrefix:@"0."]) {
                        if ([components[1] hasPrefix:@"1."]) {
                            result[@"mcVersion"] = components[1];
                            if (components.count > 2) {
                                result[@"loaderVersion"] = components[2];
                            }
                        } else {
                            result[@"loaderVersion"] = components[1];
                            if (components.count > 2) {
                                result[@"mcVersion"] = components[2];
                            }
                        }
                    }
                }
            } else if ([components[0] hasPrefix:@"1."]) {
                // Starts with Minecraft version
                result[@"mcVersion"] = components[0];
                if (components.count > 1) {
                    result[@"loader"] = components[1];
                    if (components.count > 2) {
                        result[@"loaderVersion"] = [[components subarrayWithRange:NSMakeRange(2, components.count - 2)] componentsJoinedByString:@"-"];
                    }
                }
            }
        }
    }
    
    return result;
}

@end
