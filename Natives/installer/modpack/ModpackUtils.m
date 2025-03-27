#import "installer/FabricUtils.h"
#import "ModpackUtils.h"

@implementation ModpackUtils

#pragma mark - Archive Extraction Methods

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing*)error {
    // Save the original path length to use for path calculation - critical for proper extraction
    NSUInteger dirPrefixLength = dir.length + 1; // +1 for the trailing slash
    
    NSLog(@"[ModpackUtils] Extracting directory '%@' to '%@'", dir, path);
    
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        // Only process files that are in the specified directory
        if (![fileInfo.filename hasPrefix:dir] ||
            fileInfo.filename.length <= dir.length) {
            return;
        }
        
        // Calculate the relative path by removing the directory prefix
        NSString *relativePath;
        if (fileInfo.filename.length > dirPrefixLength) {
            relativePath = [fileInfo.filename substringFromIndex:dirPrefixLength];
        } else {
            // Edge case: the file is exactly at the directory level
            relativePath = @"";
        }
        
        // Construct the destination path
        NSString *destItemPath = [path stringByAppendingPathComponent:relativePath];
        
        // For directories, just create them
        if (fileInfo.isDirectory) {
            BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destItemPath
                withIntermediateDirectories:YES
                attributes:nil error:error];
            if (!createdDir) {
                *stop = YES;
                return;
            }
            return;
        }
        
        // For files, make sure the parent directory exists
        NSString *destDirPath = [destItemPath stringByDeletingLastPathComponent];
        BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath
            withIntermediateDirectories:YES
            attributes:nil error:error];
        if (!createdDir) {
            *stop = YES;
            return;
        }

        // Extract the file data
        NSData *data = [archive extractData:fileInfo error:error];
        if (!data) {
            *stop = YES;
            return;
        }
        
        // Write the file to its destination
        BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:error];
        *stop = !written;
        if (!*stop) {
            NSLog(@"[ModpackUtils] Extracted %@ to %@", fileInfo.filename, destItemPath);
        }
    } error:error];
    
    // Log the result
    if (*error) {
        NSLog(@"[ModpackUtils] Error extracting directory: %@", [*error localizedDescription]);
    } else {
        NSLog(@"[ModpackUtils] Successfully extracted directory '%@' to '%@'", dir, path);
    }
}

+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency {
    NSMutableDictionary *info = [NSMutableDictionary new];
    NSString *minecraftVersion = dependency[@"minecraft"];
    if (dependency[@"forge"]) {
        info[@"id"] = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, dependency[@"forge"]];
    } else if (dependency[@"neoforge"]) {
        info[@"id"] = [NSString stringWithFormat:@"%@-neoforge-%@", minecraftVersion, dependency[@"neoforge"]];
    } else if (dependency[@"fabric-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"fabric-loader-%@-%@", dependency[@"fabric-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], minecraftVersion, dependency[@"fabric-loader"]];
    } else if (dependency[@"quilt-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", dependency[@"quilt-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], minecraftVersion, dependency[@"quilt-loader"]];
    }
    return info;
}

#pragma mark - Dictionary Safety Methods

/**
 * Safely sets an object for a key in a dictionary, ensuring neither is nil.
 * @param object The object to store in the dictionary.
 * @param key The key with which to associate the object.
 * @param dict The dictionary to modify.
 */
+ (void)safeSetObject:(id)object forKey:(id<NSCopying>)key inDictionary:(NSMutableDictionary *)dict {
    if (object != nil && key != nil && dict != nil) {
        [dict setObject:object forKey:key];
    } else {
        NSLog(@"[ModpackUtils] Warning: Attempted to set nil object/key in dictionary");
    }
}

/**
 * Creates a mutable dictionary from another dictionary, skipping any nil values.
 * @param dict The source dictionary to copy from.
 * @return A new mutable dictionary with all non-nil values from the source, or an empty dictionary if source is nil.
 */
+ (NSMutableDictionary *)safeMutableDictionaryWithDictionary:(NSDictionary *)dict {
    if (dict == nil) {
        return [NSMutableDictionary dictionary];
    }
    
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:dict.count];
    
    for (id key in dict) {
        id value = dict[key];
        if (value != nil) {
            result[key] = value;
        } else {
            NSLog(@"[ModpackUtils] Warning: Skipped nil value for key %@ when creating safe dictionary", key);
        }
    }
    
    return result;
}

@end
