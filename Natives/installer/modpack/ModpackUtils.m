#import "installer/FabricUtils.h"
#import "ModpackUtils.h"

@implementation ModpackUtils

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing *)error {
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        if (![fileInfo.filename hasPrefix:dir] || fileInfo.filename.length <= dir.length) {
            return;
        }
        NSString *fileName = [fileInfo.filename substringFromIndex:dir.length+1];
        NSString *destItemPath = [path stringByAppendingPathComponent:fileName];
        NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
        BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath withIntermediateDirectories:YES attributes:nil error:error];
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

// Updated method for parsing version strings for different modloaders.
// Supports:
// - Forge: "1.20-forge-46.0.14"
// - Fabric: "fabric-loader-0.16.10-1.21.4" (returns loader = "fabric")
// - NeoForge: "1.20-neoforge-46.0.14"
// - Quilt: "1.20-quilt-<version>"
+ (NSDictionary *)parseVersionString:(NSString *)versionString {
    if (!versionString || versionString.length == 0) return @{};
    NSString *trimmed = [[versionString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSArray *components = [trimmed componentsSeparatedByString:@"-"];
    NSMutableDictionary *result = [NSMutableDictionary new];
    
    if (components.count == 4 && [components[0] isEqualToString:@"fabric"] && [components[1] isEqualToString:@"loader"]) {
        // Fabric example: "fabric-loader-0.16.10-1.21.4"
        result[@"loader"] = @"fabric";
        result[@"loaderVersion"] = components[2];
        result[@"mcVersion"] = components[3];
    } else if (components.count == 3) {
        // For Forge, NeoForge, or Quilt in the format "1.20-loader-46.0.14"
        result[@"mcVersion"] = components[0];
        result[@"loader"] = components[1]; // Expected to be "forge", "neoforge", or "quilt"
        result[@"loaderVersion"] = components[2];
    } else {
        // Fallback: best-effort parsing.
        if (components.count >= 3) {
            result[@"mcVersion"] = components.firstObject;
            result[@"loader"] = components[1];
            result[@"loaderVersion"] = [[components subarrayWithRange:NSMakeRange(2, components.count - 2)] componentsJoinedByString:@"-"];
        }
    }
    return result;
}

@end
