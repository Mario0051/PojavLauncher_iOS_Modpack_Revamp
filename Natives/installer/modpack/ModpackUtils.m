#import "ModpackUtils.h"
#import "UnzipKit.h"

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
    
    // Check if path exists - create if needed
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
        NSError *dirError = nil;
        BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:path 
                                                 withIntermediateDirectories:YES 
                                                                  attributes:nil 
                                                                       error:&dirError];
        if (!success) {
            if (error) {
                *error = dirError;
            }
            return;
        }
    }
    
    // First pass: count files and build extraction plan
    __block NSUInteger totalFiles = 0;
    __block NSUInteger totalSize = 0;
    __block NSMutableArray<UZKFileInfo *> *filesToExtract = [NSMutableArray array];
    __block NSMutableSet<NSString *> *directoriesToCreate = [NSMutableSet set];
    
    NSError *scanError = nil;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        // Skip files that are not in the specified directory
        if (![fileInfo.filename hasPrefix:dir] || fileInfo.filename.length <= dir.length) {
            return;
        }
        
        // Get relative path within the directory
        NSString *relativePath = [fileInfo.filename substringFromIndex:dir.length];
        if ([relativePath hasPrefix:@"/"]) {
            relativePath = [relativePath substringFromIndex:1];
        }
        
        if (relativePath.length == 0) {
            return;
        }
        
        // Add directory to create
        NSString *destPath = [path stringByAppendingPathComponent:relativePath];
        NSString *destDir = fileInfo.isDirectory ? destPath : [destPath stringByDeletingLastPathComponent];
        [directoriesToCreate addObject:destDir];
        
        if (!fileInfo.isDirectory) {
            [filesToExtract addObject:fileInfo];
            totalFiles++;
            totalSize += fileInfo.uncompressedSize;
        }
    } error:&scanError];
    
    if (scanError) {
        if (error) {
            *error = scanError;
        }
        return;
    }
    
    // Create all required directories first (much faster than creating them one by one)
    for (NSString *dirPath in directoriesToCreate) {
        NSError *createError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:dirPath 
                                       withIntermediateDirectories:YES 
                                                        attributes:nil 
                                                             error:&createError] && createError) {
            NSLog(@"[ModpackDL] Warning: Failed to create directory %@: %@", dirPath, createError);
            // Continue anyway, as the file extraction will fail if directory doesn't exist
        }
    }
    
    // Use batch processing for better performance - group files by size
    NSMutableArray *smallFiles = [NSMutableArray array];
    NSMutableArray *mediumFiles = [NSMutableArray array];
    NSMutableArray *largeFiles = [NSMutableArray array];
    
    // Group files by size for optimal extraction strategy
    for (UZKFileInfo *fileInfo in filesToExtract) {
        if (fileInfo.uncompressedSize < 1024 * 100) {  // < 100KB
            [smallFiles addObject:fileInfo];
        } else if (fileInfo.uncompressedSize < 1024 * 1024 * 5) {  // < 5MB
            [mediumFiles addObject:fileInfo];
        } else {
            [largeFiles addObject:fileInfo];
        }
    }
    
    __block NSUInteger completedFiles = 0;
    __block NSUInteger completedSize = 0;
    __block NSError *extractError = nil;
    
    // Batch process small files (can be loaded all at once)
    if (smallFiles.count > 0) {
        NSMutableDictionary *batchData = [NSMutableDictionary dictionary];
        NSError *batchError = nil;
        
        [archive extractDataFromFiles:smallFiles progress:nil error:&batchError dataPerFile:batchData];
        
        if (batchError) {
            NSLog(@"[ModpackDL] Warning: Batch extraction failed: %@", batchError);
            // Fall back to individual extraction for small files
            for (UZKFileInfo *fileInfo in smallFiles) {
                @autoreleasepool {
                    NSError *fileError = nil;
                    NSData *fileData = [archive extractData:fileInfo error:&fileError];
                    
                    if (fileData) {
                        NSString *relativePath = [fileInfo.filename substringFromIndex:dir.length];
                        if ([relativePath hasPrefix:@"/"]) {
                            relativePath = [relativePath substringFromIndex:1];
                        }
                        
                        NSString *destPath = [path stringByAppendingPathComponent:relativePath];
                        [fileData writeToFile:destPath options:NSDataWritingAtomic error:nil];
                        
                        completedFiles++;
                        completedSize += fileInfo.uncompressedSize;
                    } else if (fileError) {
                        NSLog(@"[ModpackDL] Warning: Failed to extract %@: %@", fileInfo.filename, fileError);
                    }
                }
            }
        } else {
            // Process the batch data
            for (UZKFileInfo *fileInfo in smallFiles) {
                @autoreleasepool {
                    NSData *fileData = batchData[fileInfo.filename];
                    
                    if (fileData) {
                        NSString *relativePath = [fileInfo.filename substringFromIndex:dir.length];
                        if ([relativePath hasPrefix:@"/"]) {
                            relativePath = [relativePath substringFromIndex:1];
                        }
                        
                        NSString *destPath = [path stringByAppendingPathComponent:relativePath];
                        [fileData writeToFile:destPath options:NSDataWritingAtomic error:nil];
                        
                        completedFiles++;
                        completedSize += fileInfo.uncompressedSize;
                    }
                }
            }
        }
    }
    
    // Process medium files with a higher degree of concurrency
    if (mediumFiles.count > 0) {
        dispatch_group_t mediumGroup = dispatch_group_create();
        dispatch_queue_t mediumQueue = dispatch_queue_create("com.pojavlauncher.mediumExtraction", DISPATCH_QUEUE_CONCURRENT);
        dispatch_semaphore_t mediumSemaphore = dispatch_semaphore_create(8); // Allow 8 concurrent extractions
        
        for (UZKFileInfo *fileInfo in mediumFiles) {
            dispatch_group_enter(mediumGroup);
            
            dispatch_async(mediumQueue, ^{
                dispatch_semaphore_wait(mediumSemaphore, DISPATCH_TIME_FOREVER);
                
                @autoreleasepool {
                    NSError *fileError = nil;
                    NSData *fileData = [archive extractData:fileInfo error:&fileError];
                    
                    if (fileData) {
                        NSString *relativePath = [fileInfo.filename substringFromIndex:dir.length];
                        if ([relativePath hasPrefix:@"/"]) {
                            relativePath = [relativePath substringFromIndex:1];
                        }
                        
                        NSString *destPath = [path stringByAppendingPathComponent:relativePath];
                        [fileData writeToFile:destPath options:NSDataWritingAtomic error:nil];
                        
                        @synchronized(self) {
                            completedFiles++;
                            completedSize += fileInfo.uncompressedSize;
                        }
                    } else if (fileError) {
                        NSLog(@"[ModpackDL] Warning: Failed to extract %@: %@", fileInfo.filename, fileError);
                        @synchronized(self) {
                            if (!extractError) {
                                extractError = fileError;
                            }
                        }
                    }
                }
                
                dispatch_semaphore_signal(mediumSemaphore);
                dispatch_group_leave(mediumGroup);
            });
        }
        
        // Wait for all medium files to complete
        dispatch_group_wait(mediumGroup, DISPATCH_TIME_FOREVER);
    }
    
    // Process large files sequentially
    if (largeFiles.count > 0) {
        for (UZKFileInfo *fileInfo in largeFiles) {
            @autoreleasepool {
                // For large files, we'll use a different approach to limit memory usage
                NSString *relativePath = [fileInfo.filename substringFromIndex:dir.length];
                if ([relativePath hasPrefix:@"/"]) {
                    relativePath = [relativePath substringFromIndex:1];
                }
                
                NSString *destPath = [path stringByAppendingPathComponent:relativePath];
                
                // Extract large file directly to destination
                NSError *fileError = nil;
                BOOL success = [archive extractFileToPath:destPath overwrite:YES progress:nil error:&fileError fileInfo:fileInfo];
                
                if (success) {
                    completedFiles++;
                    completedSize += fileInfo.uncompressedSize;
                } else if (fileError) {
                    NSLog(@"[ModpackDL] Warning: Failed to extract large file %@: %@", fileInfo.filename, fileError);
                    if (!extractError) {
                        extractError = fileError;
                    }
                }
            }
        }
    }
    
    // Set error if extraction failed
    if (extractError && error) {
        *error = extractError;
    }
    
    NSLog(@"[ModpackDL] Extracted %lu/%lu files (%lu/%lu bytes) from %@", 
          (unsigned long)completedFiles, (unsigned long)totalFiles,
          (unsigned long)completedSize, (unsigned long)totalSize,
          dir);
}

+ (NSDictionary *)infoForDependencies:(nullable NSDictionary *)dependency {
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
        info[@"json"] = [NSString stringWithFormat:@"https://meta.fabricmc.net/v2/versions/loader/%@/%@/profile/json", minecraftVersion, dependency[@"fabric-loader"]];
    } else if (dependency[@"quilt-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", dependency[@"quilt-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:@"https://meta.quiltmc.org/v3/versions/loader/%@/%@/profile/json", minecraftVersion, dependency[@"quilt-loader"]];
    } else if (dependency[@"neoforge"]) {
        info[@"id"] = [NSString stringWithFormat:@"%@-neoforge-%@", minecraftVersion, dependency[@"neoforge"]];
    }
    
    return info;
}

+ (NSDictionary *)parseVersionString:(nullable NSString *)versionString {
    if (!versionString || versionString.length == 0) {
        return @{};
    }
    
    NSString *trimmed = [[versionString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSArray *components = [trimmed componentsSeparatedByString:@"-"];
    NSMutableDictionary *result = [NSMutableDictionary new];
    
    // Cache for better performance
    static NSMutableDictionary *cachedResults = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cachedResults = [NSMutableDictionary dictionary];
    });
    
    // Check cache first
    @synchronized(cachedResults) {
        NSDictionary *cachedResult = cachedResults[trimmed];
        if (cachedResult) {
            return [cachedResult copy];
        }
    }
    
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
    
    // Cache the result
    @synchronized(cachedResults) {
        // Limit cache to 100 entries to prevent memory issues
        if (cachedResults.count >= 100) {
            [cachedResults removeAllObjects];
        }
        cachedResults[trimmed] = [result copy];
    }
    
    return result;
}

@end
