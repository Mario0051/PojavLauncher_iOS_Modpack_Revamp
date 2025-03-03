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

+ (NSDictionary *)parseVersionString:(NSString *)versionString {
    if (!versionString || versionString.length == 0) return @{};
    NSString *trimmed = [[versionString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSArray *components = [trimmed componentsSeparatedByString:@"-"];
    NSMutableDictionary *result = [NSMutableDictionary new];
    if (components.count == 3) {
        // If first component is "fabric-loader" (or variant) then treat as Fabric
        if ([components[0] isEqualToString:@"fabricloader"] || [components[0] isEqualToString:@"fabric-loader"]) {
            result[@"loader"] = components[0];
            result[@"loaderVersion"] = components[1];
            result[@"mcVersion"] = components[2];
        } else {
            // Otherwise, assume format: mcVersion - loader - loaderVersion (for forge or neoforge)
            result[@"mcVersion"] = components[0];
            result[@"loader"] = components[1];
            result[@"loaderVersion"] = components[2];
        }
    } else if (components.count >= 4) {
        if ([components[0] isEqualToString:@"fabricloader"] || [components[0] isEqualToString:@"fabric-loader"]) {
            result[@"loader"] = components[0];
            NSRange range = NSMakeRange(1, components.count - 2);
            NSString *loaderVersion = [[components subarrayWithRange:range] componentsJoinedByString:@"-"];
            result[@"loaderVersion"] = loaderVersion;
            result[@"mcVersion"] = [components lastObject];
        } else {
            result[@"mcVersion"] = components.firstObject;
            result[@"loader"] = components[1];
            result[@"loaderVersion"] = [[components subarrayWithRange:NSMakeRange(2, components.count-2)] componentsJoinedByString:@"-"];
        }
    }
    return result;
}

@end
