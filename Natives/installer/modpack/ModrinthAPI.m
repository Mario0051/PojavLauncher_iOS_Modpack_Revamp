#import "ModrinthAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "AFNetworking.h"
#import "utils.h"

@implementation ModrinthAPI

+ (instancetype)defaultAPI {
    return [[self alloc] initWithURL:@"https://api.modrinth.com/v2"];
}

#pragma mark - API Implementation

- (NSMutableArray *)searchModWithFilters:(NSDictionary *)searchFilters previousPageResult:(NSMutableArray *)prevResult {
    // Build facets string for Modrinth API
    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", [searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod"];
    
    if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    
    if (searchFilters[@"loader"] && [searchFilters[@"loader"] length] > 0) {
        [facetString appendFormat:@",[\"categories:%@\"]", searchFilters[@"loader"]];
    }
    
    [facetString appendString:@"]"];
    
    NSString *searchQuery = searchFilters[@"name"] ?: @"";
    NSString *formattedQuery = [searchQuery stringByReplacingOccurrencesOfString:@" " withString:@"+"];
    
    NSDictionary *params = @{
        @"facets": facetString,
        @"query": formattedQuery,
        @"limit": @(50),
        @"index": @"relevance",
        @"offset": @(prevResult.count)
    };
    
    // Make the API request
    id response = [self getEndpoint:@"search" params:params];
    if (!response) {
        return nil;
    }
    
    return [self processSearchResponse:response previousResult:prevResult];
}

- (NSMutableArray *)processSearchResponse:(NSDictionary *)response previousResult:(NSMutableArray *)prevResult {
    NSMutableArray *result = prevResult ?: [NSMutableArray new];
    NSArray *hits = response[@"hits"];
    
    if (![hits isKindOfClass:[NSArray class]]) {
        NSLog(@"[ModrinthAPI] Invalid search response format");
        return result;
    }
    
    for (NSDictionary *hit in hits) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        
        // Process icon URL properly
        NSString *iconUrl = hit[@"icon_url"];
        // Ensure icon URL is valid and not null
        if ([iconUrl isEqual:[NSNull null]]) {
            iconUrl = @"";
        }
        
        NSMutableDictionary *entry = [@{
            @"apiSource": @(0), // 0 = Modrinth
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"] ?: @"",
            @"title": hit[@"title"] ?: @"",
            @"description": hit[@"description"] ?: @"",
            @"imageUrl": iconUrl ?: @""
        } mutableCopy];
        
        [result addObject:entry];
    }
    
    // Update pagination status
    NSUInteger totalCount = [response[@"total_hits"] unsignedLongValue];
    self.reachedLastPage = result.count >= totalCount;
    
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError *))completion {
    NSString *modId = item[@"id"];
    if (!modId || ![modId isKindOfClass:[NSString class]] || modId.length == 0) {
        NSError *error = [self errorWithCode:ModpackAPIErrorCodeParsing
                                     message:@"Invalid mod ID"
                             underlyingError:nil];
        if (completion) {
            completion(error);
        }
        return;
    }
    
    NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", modId];
    
    [self getEndpoint:endpoint params:nil completion:^(id response, NSError *error) {
        if (!response) {
            if (completion) {
                completion(error);
            }
            return;
        }
        
        if (![response isKindOfClass:[NSArray class]]) {
            NSError *formatError = [self errorWithCode:ModpackAPIErrorCodeParsing
                                              message:@"Invalid response format"
                                      underlyingError:nil];
            if (completion) {
                completion(formatError);
            }
            return;
        }
        
        NSMutableArray *versionNames = [NSMutableArray new];
        NSMutableArray *mcVersionsArray = [NSMutableArray new];
        NSMutableArray *versionUrls = [NSMutableArray new];
        NSMutableArray *versionSizes = [NSMutableArray new];
        NSMutableArray *versionHashes = [NSMutableArray new];
        NSMutableArray *versionLoaders = [NSMutableArray new];
        
        NSArray *versions = (NSArray *)response;
        
        // Apply filters if specified
        NSString *gameVersionFilter = item[@"gameVersionFilter"];
        NSString *loaderFilter = item[@"loaderFilter"];
        
        for (NSDictionary *version in versions) {
            // Apply filters if needed
            if (gameVersionFilter && gameVersionFilter.length > 0) {
                NSArray *gameVersions = version[@"game_versions"];
                BOOL matches = NO;
                
                for (NSString *gameVersion in gameVersions) {
                    if ([gameVersion isEqualToString:gameVersionFilter] ||
                        [gameVersion hasPrefix:[gameVersionFilter stringByAppendingString:@"."]] ||
                        [gameVersionFilter hasPrefix:[gameVersion stringByAppendingString:@"."]]) {
                        matches = YES;
                        break;
                    }
                }
                
                if (!matches) continue;
            }
            
            if (loaderFilter && loaderFilter.length > 0) {
                NSArray *loaders = version[@"loaders"];
                BOOL matches = NO;
                
                for (NSString *loader in loaders) {
                    if ([loader caseInsensitiveCompare:loaderFilter] == NSOrderedSame) {
                        matches = YES;
                        break;
                    }
                }
                
                if (!matches) continue;
            }
            
            // Extract version name
            NSString *versionName = version[@"version_number"] ?: version[@"name"] ?: @"Unknown";
            [versionNames addObject:versionName];
            
            // Extract game versions
            NSArray *gameVersions = version[@"game_versions"] ?: @[];
            [mcVersionsArray addObject:gameVersions];
            
            // Extract files
            NSArray *files = version[@"files"];
            if (![files isKindOfClass:[NSArray class]] || files.count == 0) {
                // Skip versions with no files
                continue;
            }
            
            // Get primary file
            NSDictionary *primaryFile = files[0];
            if (![primaryFile isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            
            // Extract URL
            NSString *url = primaryFile[@"url"] ?: @"";
            [versionUrls addObject:url];
            
            // Extract size
            NSNumber *size = primaryFile[@"size"] ?: @0;
            [versionSizes addObject:size];
            
            // Extract hash
            NSString *sha1 = @"";
            NSDictionary *hashes = primaryFile[@"hashes"];
            if ([hashes isKindOfClass:[NSDictionary class]]) {
                sha1 = hashes[@"sha1"] ?: @"";
            }
            [versionHashes addObject:sha1];
            
            // Extract loaders
            NSArray *loaders = version[@"loaders"] ?: @[];
            [versionLoaders addObject:loaders];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Update the item with all version information
            item[@"versionNames"] = versionNames;
            item[@"mcVersionNames"] = mcVersionsArray;
            item[@"versionUrls"] = versionUrls;
            item[@"versionSizes"] = versionSizes;
            item[@"versionHashes"] = versionHashes;
            item[@"versionLoaders"] = versionLoaders;
            item[@"versionDetailsLoaded"] = @YES;
            
            NSLog(@"[ModrinthAPI] Loaded %lu versions for mod %@", (unsigned long)versionNames.count, modId);
            
            if (completion) {
                completion(nil);
            }
        });
    }];
}

#pragma mark - Template Method Implementations

- (NSString *)getManifestFilename {
    return @"modrinth.index.json";
}

- (NSDictionary *)processManifest:(NSDictionary *)manifest error:(NSError **)error {
    // Validate manifest
    if (!manifest[@"formatVersion"] || ![manifest[@"formatVersion"] isEqual:@(1)]) {
        if (error) {
            *error = [self errorWithCode:ModpackAPIErrorCodeInvalidManifest
                                 message:@"Invalid or unsupported manifest format version"
                         underlyingError:nil];
        }
        return nil;
    }
    
    return manifest;
}

- (NSArray *)getFilesFromManifest:(NSDictionary *)manifest {
    return manifest[@"files"] ?: @[];
}

- (void)downloadModFiles:(NSArray *)files toPath:(NSString *)destPath withDownloader:(MinecraftResourceDownloadTask *)downloader {
    // Create mods directory
    NSString *modsDir = [destPath stringByAppendingPathComponent:@"mods"];
    [[NSFileManager defaultManager] createDirectoryAtPath:modsDir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    
    // Setup progress tracking
    dispatch_async(dispatch_get_main_queue(), ^{
        [downloader.fileList addObject:@"Downloading mod files"];
        NSProgress *modsProgress = [NSProgress progressWithTotalUnitCount:files.count];
        modsProgress.kind = NSProgressKindFile;
        [downloader.progressList addObject:modsProgress];
        [downloader.progress addChild:modsProgress withPendingUnitCount:files.count];
    });
    
    // Dispatch group to track all downloads
    dispatch_group_t downloadGroup = dispatch_group_create();
    dispatch_semaphore_t downloadSemaphore = dispatch_semaphore_create(5); // Limit concurrent downloads
    
    __block NSUInteger completedFiles = 0;
    __block NSUInteger failedFiles = 0;
    
    for (NSDictionary *file in files) {
        // Check required fields
        NSArray *downloads = file[@"downloads"];
        if (![downloads isKindOfClass:[NSArray class]] || downloads.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failedFiles++;
                NSProgress *modsProgress = [downloader.progressList lastObject];
                modsProgress.completedUnitCount++;
                
                // Check if all done
                if ((completedFiles + failedFiles) >= files.count) {
                    [self finalizeInstallation:nil toPath:destPath withDownloader:downloader];
                }
            });
            continue;
        }
        
        NSString *url = [downloads firstObject];
        if (![url isKindOfClass:[NSString class]] || url.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                failedFiles++;
                NSProgress *modsProgress = [downloader.progressList lastObject];
                modsProgress.completedUnitCount++;
                
                // Check if all done
                if ((completedFiles + failedFiles) >= files.count) {
                    [self finalizeInstallation:nil toPath:destPath withDownloader:downloader];
                }
            });
            continue;
        }
        
        // Determine file path
        NSString *path;
        if ([file[@"path"] isKindOfClass:[NSString class]] && [file[@"path"] length] > 0) {
            path = [destPath stringByAppendingPathComponent:file[@"path"]];
        } else {
            NSString *fileName = [[NSURL URLWithString:url] lastPathComponent];
            if (!fileName || fileName.length == 0) {
                fileName = [NSString stringWithFormat:@"mod_%@.jar", [[NSUUID UUID] UUIDString]];
            }
            path = [modsDir stringByAppendingPathComponent:fileName];
        }
        
        // Get size and hash
        NSDictionary *hashes = file[@"hashes"];
        NSString *sha = [hashes isKindOfClass:[NSDictionary class]] ? hashes[@"sha1"] : nil;
        
        NSNumber *fileSizeNumber = file[@"fileSize"];
        NSUInteger size = [fileSizeNumber isKindOfClass:[NSNumber class]] ? [fileSizeNumber unsignedLongLongValue] : 0;
        
        // Enter download group
        dispatch_group_enter(downloadGroup);
        
        // Wait for semaphore in the background
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            dispatch_semaphore_wait(downloadSemaphore, DISPATCH_TIME_FOREVER);
            
            NSString *displayName = [NSString stringWithFormat:@"Mod %lu/%lu", (unsigned long)(completedFiles + failedFiles + 1), (unsigned long)files.count];
            
            NSURLSessionDownloadTask *task = [downloader createDownloadTask:url
                                                                    size:size
                                                                     sha:sha
                                                                 altName:displayName
                                                                  toPath:path
                                                                 success:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    completedFiles++;
                    NSProgress *modsProgress = [downloader.progressList lastObject];
                    modsProgress.completedUnitCount++;
                    
                    // Check if all done
                    if ((completedFiles + failedFiles) >= files.count) {
                        [self finalizeInstallation:nil toPath:destPath withDownloader:downloader];
                    }
                });
                
                // Release semaphore
                dispatch_semaphore_signal(downloadSemaphore);
                dispatch_group_leave(downloadGroup);
            }];
            
            if (task) {
                [task resume];
            } else {
                // Task creation failed
                dispatch_async(dispatch_get_main_queue(), ^{
                    failedFiles++;
                    NSProgress *modsProgress = [downloader.progressList lastObject];
                    modsProgress.completedUnitCount++;
                    
                    // Check if all done
                    if ((completedFiles + failedFiles) >= files.count) {
                        [self finalizeInstallation:nil toPath:destPath withDownloader:downloader];
                    }
                });
                
                dispatch_semaphore_signal(downloadSemaphore);
                dispatch_group_leave(downloadGroup);
            }
        });
    }
    
    // Set a timeout for the entire operation
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        long result = dispatch_group_wait(downloadGroup, DISPATCH_TIME_NOW);
        if (result != 0) {
            // Some downloads timed out
            dispatch_async(dispatch_get_main_queue(), ^{
                // Force progress completion
                NSProgress *modsProgress = [downloader.progressList lastObject];
                modsProgress.completedUnitCount = modsProgress.totalUnitCount;
                
                // Finalize anyway
                [self finalizeInstallation:nil toPath:destPath withDownloader:downloader];
            });
        }
    });
}

- (void)finalizeInstallation:(NSDictionary *)manifest toPath:(NSString *)destPath withDownloader:(MinecraftResourceDownloadTask *)downloader {
    // Prepare profile setup UI
    dispatch_async(dispatch_get_main_queue(), ^{
        [downloader.fileList addObject:@"Setting up profile"];
        
        NSProgress *setupProgress = [NSProgress progressWithTotalUnitCount:2]; // Two steps: JSON download and profile creation
        setupProgress.kind = NSProgressKindFile;
        [downloader.progressList addObject:setupProgress];
        [downloader.progress addChild:setupProgress withPendingUnitCount:2];
    });
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Load the index file from disk if manifest wasn't provided
        if (!manifest) {
            NSString *indexPath = [destPath stringByAppendingPathComponent:@"modrinth.index.json"];
            NSData *indexData = [NSData dataWithContentsOfFile:indexPath];
            
            if (indexData) {
                NSError *error = nil;
                manifest = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&error];
                
                if (error) {
                    NSLog(@"[ModrinthAPI] Error loading index file: %@", error);
                    // Continue with nil manifest
                }
            }
        }
        
        // Get mod loader information
        NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:manifest[@"dependencies"]];
        
        if (depInfo[@"json"]) {
            NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
            
            // Create directory structure for the JSON file
            [NSFileManager.defaultManager createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent] 
                                    withIntermediateDirectories:YES attributes:nil error:nil];
                              
            // Download JSON file
            NSURLSessionDownloadTask *jsonTask = [downloader createDownloadTask:depInfo[@"json"] 
                                                                         size:0 
                                                                          sha:nil 
                                                                      altName:nil 
                                                                       toPath:jsonPath 
                                                                      success:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSProgress *setupProgress = downloader.progressList.lastObject;
                    setupProgress.completedUnitCount = 1; // First step complete
                });
                
                // Create profile after JSON download
                [self createProfileFromManifest:manifest depInfo:depInfo destPath:destPath downloader:downloader];
            }];
            
            if (jsonTask) {
                [jsonTask resume];
            } else {
                // JSON download failed, still create profile
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSProgress *setupProgress = downloader.progressList.lastObject;
                    setupProgress.completedUnitCount = 1; // Skip first step
                });
                
                [self createProfileFromManifest:manifest depInfo:depInfo destPath:destPath downloader:downloader];
            }
        } else {
            // No JSON to download
            dispatch_async(dispatch_get_main_queue(), ^{
                NSProgress *setupProgress = downloader.progressList.lastObject;
                setupProgress.completedUnitCount = 1; // Skip first step
            });
            
            [self createProfileFromManifest:manifest depInfo:depInfo destPath:destPath downloader:downloader];
        }
    });
}

- (void)createProfileFromManifest:(NSDictionary *)manifest depInfo:(NSDictionary *)depInfo destPath:(NSString *)destPath downloader:(MinecraftResourceDownloadTask *)downloader {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Get profile name from manifest or use default
        NSString *profileName = manifest[@"name"] ?: @"Modrinth Modpack";
        NSString *safeProfileName = [profileName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
        safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@":" withString:@"_"];
        
        // Create a unique game directory path
        NSString *gameDir = [NSString stringWithFormat:@"./profiles/%@", destPath.lastPathComponent];
        
        // Get the icon URL from the modpack data
        NSString *iconUrl = manifest[@"icon"];
        
        // Create/update profile
        PLProfiles.current.profiles[safeProfileName] = @{
            @"gameDir": gameDir,
            @"name": profileName,
            @"lastVersionId": depInfo[@"id"] ?: @"latest-release",
            @"icon": iconUrl ?: @""
        }.mutableCopy;
        
        PLProfiles.current.selectedProfileName = safeProfileName;
        [PLProfiles.current save];
        
        // Create a log file
        NSString *logContent = [NSString stringWithFormat:@"Modrinth modpack installation completed\n"
                              "Profile: %@\n"
                              "Directory: %@\n"
                              "Game Version: %@\n"
                              "Mod Loader: %@\n"
                              "Date: %@",
                              profileName, 
                              destPath, 
                              depInfo[@"mcVersion"] ?: @"unknown",
                              depInfo[@"loader"] ?: @"unknown",
                              [NSDate date]];
        
        [logContent writeToFile:[destPath stringByAppendingPathComponent:@"modrinth_install.log"]
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:nil];

        // Mark setup as complete
        NSProgress *setupProgress = downloader.progressList.lastObject;
        setupProgress.completedUnitCount = setupProgress.totalUnitCount;
        
        // Add completion marker
        [downloader.fileList addObject:@"Complete"];
        NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
        completeProgress.completedUnitCount = 1;
        [downloader.progressList addObject:completeProgress];
        [downloader.progress addChild:completeProgress withPendingUnitCount:1];
        
        // Mark task as completed
        [downloader markAsCompleted];
        
        NSLog(@"[ModrinthAPI] Modpack installation fully completed");
    });
}

@end
