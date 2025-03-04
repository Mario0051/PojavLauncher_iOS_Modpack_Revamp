#import "CurseForgeAPI.h"
#import "config.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "UnzipKit.h"
#import "AFNetworking.h"

@interface MinecraftResourceDownloadTask (Success)
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)())success;
- (void)finalizeDownloads;
@end

static NSError *saveJSONToFile(NSDictionary *jsonDict, NSString *filePath) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:jsonDict options:0 error:&error];
    if (!data) {
        NSLog(@"saveJSONToFile: Failed to serialize JSON: %@", error);
        return error;
    }
    BOOL success = [data writeToFile:filePath options:NSDataWritingAtomic error:&error];
    if (!success) {
        NSLog(@"saveJSONToFile: Failed to write JSON to %@: %@", filePath, error);
        return error;
    }
    NSLog(@"saveJSONToFile: Successfully wrote JSON to %@", filePath);
    return nil;
}

#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDModpack 4471
#define kCurseForgeClassIDMod 6
#define CURSEFORGE_PAGINATION_SIZE 50

@interface CurseForgeAPI ()
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, strong) AFHTTPSessionManager *sessionManager;
- (BOOL)verifyManifestFromDictionary:(NSDictionary *)manifest;
- (void)asyncExtractManifestFromPackage:(NSString *)packagePath completion:(void (^)(NSDictionary *manifestDict, NSError *error))completion;
- (void)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params completion:(void (^)(id result, NSError *error))completion;
- (void)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID completion:(void (^)(NSString *downloadUrl, NSError *error))completion;
- (void)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID attempt:(int)attempt endpoint:(NSString *)endpoint completion:(void (^)(NSString *downloadUrl, NSError *error))completion;
- (void)handleDownloadUrlFallbackForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID completion:(void (^)(NSString *downloadUrl, NSError *error))completion;
- (void)autoInstallFabricWithFullString:(NSString *)fabricString;
- (void)autoInstallNeoForgeWithVanillaVersion:(NSString *)vanillaVer loaderVersion:(NSString *)neoforgeVer;
- (void)moveJarFilesToModsFolderInDirectory:(NSString *)destPath;
- (NSDictionary *)loadManifestFromDestination:(NSString *)destPath error:(NSError **)error;
@end

@implementation CurseForgeAPI {
    dispatch_queue_t _networkQueue;
}

#pragma mark - Initialization

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        // Use provided API key (user-provided only)
        self.apiKey = apiKey ?: @"";
        _networkQueue = dispatch_queue_create("com.curseforge.api.network", DISPATCH_QUEUE_SERIAL);
        self.sessionManager = [AFHTTPSessionManager manager];
        NSLog(@"CurseForgeAPI: Initialized with API key: %@", self.apiKey.length > 0 ? @"[redacted]" : @"(none)");
    }
    return self;
}

#pragma mark - GET Endpoint

- (void)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params completion:(void (^)(id, NSError *))completion {
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    // Use only the provided API key; no workflow or environment key lookup.
    NSString *key = self.apiKey;
    if (key.length == 0) {
        NSLog(@"getEndpoint: No API key provided");
    }
    // Always set the API key header
    [self.sessionManager.requestSerializer setValue:key forHTTPHeaderField:@"x-api-key"];
    NSLog(@"getEndpoint: Requesting %@ with params: %@", url, params);
    [self.sessionManager GET:url parameters:params headers:nil progress:nil success:^(NSURLSessionTask *task, id responseObject) {
        NSLog(@"getEndpoint: Success for %@.", endpoint);
        if (completion) completion(responseObject, nil);
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        NSLog(@"getEndpoint: Failed for %@: %@", endpoint, error);
        if (completion) completion(nil, error);
    }];
}

#pragma mark - Download URL Generation

- (void)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID completion:(void (^)(NSString *, NSError *))completion {
    NSString *endpoint = [NSString stringWithFormat:@"mods/%llu/files/%llu/download-url", projectID, fileID];
    [self getDownloadUrlForProject:projectID fileID:fileID attempt:0 endpoint:endpoint completion:completion];
}

- (void)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID attempt:(int)attempt endpoint:(NSString *)endpoint completion:(void (^)(NSString *, NSError *))completion {
    __weak typeof(self) weakSelf = self;
    [self getEndpoint:endpoint params:nil completion:^(id response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (response && response[@"data"] && ![response[@"data"] isKindOfClass:[NSNull class]]) {
            NSString *urlString = [NSString stringWithFormat:@"%@", response[@"data"]];
            NSLog(@"getDownloadUrlForProject: Got URL for project %llu, file %llu: %@", projectID, fileID, urlString);
            if (completion) completion(urlString, nil);
        } else {
            if (attempt < 1) {
                NSLog(@"getDownloadUrlForProject: Retrying (attempt %d) for project %llu, file %llu", attempt+1, projectID, fileID);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), _networkQueue, ^{
                    [strongSelf getDownloadUrlForProject:projectID fileID:fileID attempt:attempt+1 endpoint:endpoint completion:completion];
                });
            } else {
                NSLog(@"getDownloadUrlForProject: Falling back after %d attempts for project %llu, file %llu", attempt+1, projectID, fileID);
                [strongSelf handleDownloadUrlFallbackForProject:projectID fileID:fileID completion:completion];
            }
        }
    }];
}

- (void)handleDownloadUrlFallbackForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID completion:(void (^)(NSString *, NSError *))completion {
    NSString *fallbackUrl = [NSString stringWithFormat:@"https://www.curseforge.com/api/v1/mods/%llu/files/%llu/download", projectID, fileID];
    if (self.apiKey.length > 0) {
        fallbackUrl = [fallbackUrl stringByAppendingFormat:@"?apiKey=%@", self.apiKey];
    }
    NSString *endpoint2 = [NSString stringWithFormat:@"mods/%llu/files/%llu", projectID, fileID];
    NSLog(@"handleDownloadUrlFallback: Attempting fallback for project %llu, file %llu", projectID, fileID);
    [self getEndpoint:endpoint2 params:nil completion:^(id fallbackResponse, NSError *error2) {
        if ([fallbackResponse isKindOfClass:[NSDictionary class]]) {
            NSDictionary *respDict = (NSDictionary *)fallbackResponse;
            id dataObj = respDict[@"data"];
            if ([dataObj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *modData = (NSDictionary *)dataObj;
                id idNumberObj = modData[@"id"];
                id fileNameObj = modData[@"fileName"];
                if ([idNumberObj isKindOfClass:[NSNumber class]] && [fileNameObj isKindOfClass:[NSString class]]) {
                    NSNumber *idNumber = (NSNumber *)idNumberObj;
                    NSString *fileName = (NSString *)fileNameObj;
                    if (fileName.length > 0) {
                        unsigned long long idValue = [idNumber unsignedLongLongValue];
                        NSString *mediaLink = [NSString stringWithFormat:@"https://media.forgecdn.net/files/%llu/%llu/%@", idValue/1000, idValue%1000, fileName];
                        NSLog(@"handleDownloadUrlFallback: Generated media link for project %llu, file %llu", projectID, fileID);
                        if (completion) completion(mediaLink, nil);
                        return;
                    } else {
                        NSLog(@"handleDownloadUrlFallback: Empty fileName for project %llu, file %llu", projectID, fileID);
                    }
                } else {
                    NSLog(@"handleDownloadUrlFallback: Unexpected types - id: %@, fileName: %@", idNumberObj, fileNameObj);
                }
            } else {
                NSLog(@"handleDownloadUrlFallback: 'data' is not a dictionary: %@", dataObj);
            }
        } else {
            NSLog(@"handleDownloadUrlFallback: Response is not a dictionary: %@", fallbackResponse);
        }
        NSLog(@"handleDownloadUrlFallback: Using fallback URL for project %llu, file %llu: %@", projectID, fileID, fallbackUrl);
        if (completion) completion(fallbackUrl, nil);
    }];
}

#pragma mark - Manifest Extraction

- (NSDictionary *)loadManifestFromDestination:(NSString *)destPath error:(NSError **)error {
    NSString *manifestPath = [destPath stringByAppendingPathComponent:@"manifest.json"];
    NSLog(@"loadManifestFromDestination: Loading manifest from %@", manifestPath);
    NSData *data = [NSData dataWithContentsOfFile:manifestPath options:0 error:error];
    if (!data) {
        NSLog(@"loadManifestFromDestination: Failed to read manifest: %@", *error);
        return nil;
    }
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!manifest) {
        NSLog(@"loadManifestFromDestination: Failed to parse manifest JSON: %@", *error);
    } else {
        NSLog(@"loadManifestFromDestination: Successfully loaded manifest");
    }
    return manifest;
}

#pragma mark - Helper: Move .jar Files to Mods Folder

- (void)moveJarFilesToModsFolderInDirectory:(NSString *)destPath {
    NSLog(@"moveJarFilesToModsFolderInDirectory: Deprecated method called for %@", destPath);
}

#pragma mark - Extraction, Manifest, then Downloads

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    __weak typeof(self) weakSelf = self;
    NSError *extractError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&extractError];
    if (extractError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Extraction failed: %@", extractError.localizedDescription]];
        });
        return;
    }
    __block BOOL extractionSuccess = YES;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        NSString *destItemPath = [destPath stringByAppendingPathComponent:fileInfo.filename];
        if (fileInfo.isDirectory) {
            NSError *dirError = nil;
            BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:destItemPath withIntermediateDirectories:YES attributes:nil error:&dirError];
            if (!created || dirError) {
                NSLog(@"Extraction error for directory %@: %@", destItemPath, dirError);
                *stop = YES;
                extractionSuccess = NO;
            }
        } else {
            NSError *fileError = nil;
            NSData *data = [archive extractData:fileInfo error:&fileError];
            if (!data || fileError) {
                NSLog(@"Extraction error for file %@: %@", fileInfo.filename, fileError);
                *stop = YES;
                extractionSuccess = NO;
            } else {
                BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:&fileError];
                if (!written || fileError) {
                    NSLog(@"Write error for file %@: %@", destItemPath, fileError);
                    *stop = YES;
                    extractionSuccess = NO;
                }
            }
        }
    } error:&extractError];
    
    if (!extractionSuccess || extractError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Extraction failed: %@", extractError.localizedDescription]];
        });
        return;
    }
    
    NSLog(@"downloader: Extraction completed successfully");
    NSError *loadError = nil;
    NSDictionary *manifestDict = [weakSelf loadManifestFromDestination:destPath error:&loadError];
    if (!manifestDict) {
        NSLog(@"downloader: Manifest load failed: %@", loadError);
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:@"Manifest missing or invalid"];
        });
        return;
    }
    if (![weakSelf verifyManifestFromDictionary:manifestDict]) {
        NSLog(@"downloader: Manifest verification failed");
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:@"Invalid manifest"];
        });
        return;
    }
    NSLog(@"downloader: Manifest loaded and verified");
    NSString *modsDir = [destPath stringByAppendingPathComponent:@"mods"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:modsDir]) {
        NSError *createError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:&createError];
        if (createError) {
            NSLog(@"downloader: Failed to create mods directory: %@", createError);
        } else {
            NSLog(@"downloader: Created mods directory at %@", modsDir);
        }
    }
    NSDictionary *minecraft = manifestDict[@"minecraft"];
    NSString *vanillaVersion = @"";
    NSString *modLoaderId = @"";
    NSString *modLoaderVersion = @"";
    if (minecraft && [minecraft isKindOfClass:[NSDictionary class]]) {
        vanillaVersion = minecraft[@"version"] ?: @"";
        NSArray *modLoaders = minecraft[@"modLoaders"];
        NSDictionary *primaryModLoader = nil;
        if ([modLoaders isKindOfClass:[NSArray class]] && modLoaders.count > 0) {
            for (NSDictionary *loader in modLoaders) {
                if ([loader[@"primary"] boolValue]) {
                    primaryModLoader = loader;
                    break;
                }
            }
            if (!primaryModLoader) { primaryModLoader = modLoaders[0]; }
            NSString *rawId = primaryModLoader[@"id"] ?: @"";
            NSRange dashRange = [rawId rangeOfString:@"-"];
            if (dashRange.location != NSNotFound) {
                NSString *loaderName = [rawId substringToIndex:dashRange.location];
                NSString *loaderVer = [rawId substringFromIndex:(dashRange.location + 1)];
                if ([loaderName isEqualToString:@"forge"]) {
                    modLoaderId = @"forge";
                    modLoaderVersion = loaderVer;
                } else if ([loaderName isEqualToString:@"fabric"]) {
                    modLoaderId = @"fabric";
                    modLoaderVersion = loaderVer;
                } else {
                    modLoaderId = loaderName;
                    modLoaderVersion = loaderVer;
                }
            } else {
                modLoaderId = rawId;
                modLoaderVersion = rawId;
            }
        }
    }
    NSString *finalVersionString = @"";
    if ([modLoaderId isEqualToString:@"forge"]) {
        finalVersionString = [NSString stringWithFormat:@"%@-forge-%@", vanillaVersion, modLoaderVersion];
    } else if ([modLoaderId isEqualToString:@"fabric"]) {
        finalVersionString = [NSString stringWithFormat:@"fabric-%@-%@", modLoaderVersion, vanillaVersion];
    } else {
        finalVersionString = [NSString stringWithFormat:@"%@ | %@", vanillaVersion, modLoaderId];
    }
    NSLog(@"downloader: Determined version string: %@", finalVersionString);
    NSString *profileName = manifestDict[@"name"] ?: @"Unknown Modpack";
    if (profileName.length > 0) {
        NSDictionary *profileInfo = @{
            @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
            @"name": profileName,
            @"lastVersionId": finalVersionString,
            @"icon": @""
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"downloader: Setting profile: %@", profileName);
            PLProfiles.current.profiles[profileName] = [profileInfo mutableCopy];
            PLProfiles.current.selectedProfileName = profileName;
            [PLProfiles.current save];
        });
    }
    NSError *error = nil;
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides from modpack package: %@", error.localizedDescription]];
        });
        return;
    }
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides from modpack package: %@", error.localizedDescription]];
        });
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];
    
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:manifestDict[@"dependencies"]];
    
    dispatch_group_t group = dispatch_group_create();
    for (NSDictionary *fileEntry in manifestDict[@"files"]) {
        dispatch_group_enter(group);
        NSNumber *projectID = fileEntry[@"projectID"];
        NSNumber *fileID = fileEntry[@"fileID"];
        BOOL required = [fileEntry[@"required"] boolValue];
        [weakSelf getDownloadUrlForProject:[projectID unsignedLongLongValue] fileID:[fileID unsignedLongLongValue] completion:^(NSString *url, NSError *error) {
            if (!url && required) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *modName = fileEntry[@"fileName"] ?: @"UnknownFile";
                    NSLog(@"downloader: Failed to get URL for required mod %@ in modpack %@", modName, destPath.lastPathComponent);
                    [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to obtain download URL for modpack '%@' and mod '%@'", destPath.lastPathComponent, modName]];
                });
                dispatch_group_leave(group);
                return;
            } else if (!url) {
                NSLog(@"downloader: Skipping optional mod with no URL: %@", fileEntry[@"fileName"] ?: @"Unknown");
                dispatch_group_leave(group);
                return;
            }
            NSString *relativePath = fileEntry[@"path"];
            if (!relativePath || relativePath.length == 0) {
                relativePath = fileEntry[@"fileName"];
                if (!relativePath || relativePath.length == 0) {
                    NSURL *dlURL = [NSURL URLWithString:url];
                    relativePath = dlURL.lastPathComponent ?: [NSString stringWithFormat:@"%@.jar", fileID];
                }
            }
            NSArray *components = [relativePath pathComponents];
            if (components.count > 1 && [[components firstObject] caseInsensitiveCompare:destPath.lastPathComponent] == NSOrderedSame) {
                relativePath = [[components subarrayWithRange:NSMakeRange(1, components.count - 1)] componentsJoinedByString:@"/"];
            }
            NSString *destinationPath;
            if ([[relativePath pathExtension] caseInsensitiveCompare:@"jar"] == NSOrderedSame && ![relativePath hasPrefix:@"mods/"]) {
                destinationPath = [[destPath stringByAppendingPathComponent:@"mods"] stringByAppendingPathComponent:[relativePath lastPathComponent]];
            } else {
                destinationPath = [destPath stringByAppendingPathComponent:relativePath];
            }
            NSLog(@"downloader: Destination path for download: %@", destinationPath);
            NSUInteger rawSize = [fileEntry[@"fileLength"] unsignedLongLongValue];
            if (rawSize == 0) { rawSize = 1; }
            @try {
                NSString *destDir = [destinationPath stringByDeletingLastPathComponent];
                if (![[NSFileManager defaultManager] fileExistsAtPath:destDir]) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
                }
                NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:rawSize sha:nil altName:nil toPath:destinationPath success:^{
                    NSLog(@"downloader: Download completed for %@", destinationPath);
                    dispatch_group_leave(group);
                }];
                if (task) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSLog(@"downloader: Starting download for %@", destinationPath);
                        [task resume];
                    });
                } else {
                    NSLog(@"downloader: Failed to create task for %@", destinationPath);
                    dispatch_group_leave(group);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!downloader.progress.cancelled) {
                            downloader.progress.completedUnitCount++;
                        }
                    });
                }
            } @catch (NSException *ex) {
                NSLog(@"downloader: Exception creating task for %@: %@", destinationPath, ex);
                dispatch_group_leave(group);
            }
        }];
    }
    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            downloader.progress.completedUnitCount = downloader.progress.totalUnitCount;
            downloader.textProgress.completedUnitCount = downloader.progress.totalUnitCount;
            NSLog(@"downloader: All downloads completed");
            NSError *removeError = nil;
            [[NSFileManager defaultManager] removeItemAtPath:packagePath error:&removeError];
            if (removeError) {
                NSLog(@"downloader: Failed to remove package file %@: %@", packagePath, removeError);
            } else {
                NSLog(@"downloader: Removed package file %@", packagePath);
            }
        });
        if (depInfo[@"json"]) {
            NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], depInfo[@"id"], depInfo[@"id"]];
            NSURLSessionDownloadTask *depTask = [downloader createDownloadTask:depInfo[@"json"] size:1 sha:nil altName:nil toPath:jsonPath];
            if (depTask) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSLog(@"downloader: Starting dependency download for %@", jsonPath);
                    [depTask resume];
                });
            } else {
                NSLog(@"downloader: Failed to create dependency download task for %@", jsonPath);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([modLoaderId isEqualToString:@"forge"]) {
                NSLog(@"downloader: Auto-installing Forge");
                [weakSelf autoInstallForge:vanillaVersion loaderVersion:modLoaderVersion];
            } else if ([modLoaderId isEqualToString:@"fabric"]) {
                NSLog(@"downloader: Auto-installing Fabric");
                [weakSelf autoInstallFabricWithFullString:finalVersionString];
            } else if ([modLoaderId isEqualToString:@"neoforge"]) {
                NSLog(@"downloader: Auto-installing NeoForge");
                [weakSelf autoInstallNeoForgeWithVanillaVersion:vanillaVersion loaderVersion:modLoaderVersion];
            } else {
                NSLog(@"downloader: Unrecognized loader: %@", modLoaderId);
            }
        });
    });
}

#pragma mark - Search, Load Details, and Install

- (void)searchModWithFilters:(NSDictionary *)searchFilters previousPageResult:(NSMutableArray *)prevResult completion:(void (^ _Nonnull)(NSMutableArray * _Nullable results, NSError * _Nullable error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int limit = CURSEFORGE_PAGINATION_SIZE;
        NSString *query = searchFilters[@"name"] ?: @"";
        NSMutableDictionary *params = [@{
            @"gameId": @(kCurseForgeGameIDMinecraft),
            @"classId": ([searchFilters[@"isModpack"] boolValue] ? @(kCurseForgeClassIDModpack) : @(kCurseForgeClassIDMod)),
            @"searchFilter": query,
            @"sortField": @(1),
            @"sortOrder": @"desc",
            @"pageSize": @(limit),
            @"index": @(prevResult.count)
        } mutableCopy];
        if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
            params[@"gameVersion"] = searchFilters[@"mcVersion"];
        }
        NSLog(@"searchModWithFilters: Searching with params: %@", params);
        [self getEndpoint:@"mods/search" params:params completion:^(id response, NSError *error) {
            if (!response) {
                NSLog(@"searchModWithFilters: Failed: %@", error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, self.lastError);
                });
                return;
            }
            NSMutableArray *result = prevResult ?: [NSMutableArray new];
            NSArray *data = response[@"data"];
            NSLog(@"searchModWithFilters: Found %lu items", (unsigned long)data.count);
            for (NSDictionary *mod in data) {
                id allow = mod[@"allowModDistribution"];
                if (allow && ![allow isKindOfClass:[NSNull class]] && ![allow boolValue]) {
                    NSLog(@"searchModWithFilters: Skipping mod %@ due to distribution restriction", mod[@"name"]);
                    continue;
                }
                BOOL isModpack = ([mod[@"classId"] integerValue] == kCurseForgeClassIDModpack);
                NSMutableDictionary *entry = [@{
                    @"apiSource": @(1),
                    @"isModpack": @(isModpack),
                    @"id": [NSString stringWithFormat:@"%@", mod[@"id"]],
                    @"title": (mod[@"name"] ?: @""),
                    @"description": (mod[@"summary"] ?: @""),
                    @"imageUrl": (mod[@"logo"] ?: @"")
                } mutableCopy];
                [result addObject:entry];
            }
            NSDictionary *pagination = response[@"pagination"];
            NSUInteger totalCount = [pagination[@"totalCount"] unsignedIntegerValue];
            self.reachedLastPage = (result.count >= totalCount);
            NSLog(@"searchModWithFilters: Total count: %lu, reached last page: %d", (unsigned long)totalCount, self.reachedLastPage);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(result, nil);
            });
        }];
    });
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^ _Nonnull)(NSError * _Nullable error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *modId = [NSString stringWithFormat:@"%@", item[@"id"]];
        NSLog(@"loadDetailsOfMod: Loading details for mod ID %@", modId);
        [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", modId] params:nil completion:^(id response, NSError *error) {
            if (!response) {
                NSLog(@"loadDetailsOfMod: Failed to load details for %@: %@", modId, error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(self.lastError);
                });
                return;
            }
            NSArray *files = response[@"data"];
            NSMutableArray *names = [NSMutableArray new];
            NSMutableArray *mcNames = [NSMutableArray new];
            NSMutableArray *urls = [NSMutableArray new];
            NSMutableArray *hashes = [NSMutableArray new];
            NSMutableArray *sizes = [NSMutableArray new];
            NSMutableArray *loaders = [NSMutableArray new];
            for (NSDictionary *file in files) {
                [names addObject:[NSString stringWithFormat:@"%@", file[@"fileName"] ?: @""]];
                id versions = file[@"gameVersion"] ?: file[@"gameVersionList"];
                NSString *gameVersion = @"";
                if ([versions isKindOfClass:[NSArray class]] && [versions count] > 0) {
                    gameVersion = [NSString stringWithFormat:@"%@", ((NSArray *)versions)[0]];
                } else if ([versions isKindOfClass:[NSString class]]) {
                    gameVersion = [NSString stringWithFormat:@"%@", versions];
                }
                [mcNames addObject:gameVersion];
                [urls addObject:[NSString stringWithFormat:@"%@", file[@"downloadUrl"] ?: @""]];
                NSNumber *sizeNumber = nil;
                id fileLength = file[@"fileLength"];
                if ([fileLength isKindOfClass:[NSNumber class]]) {
                    sizeNumber = fileLength;
                } else if ([fileLength isKindOfClass:[NSString class]]) {
                    sizeNumber = @([fileLength unsignedLongLongValue]);
                } else {
                    sizeNumber = @(0);
                }
                [sizes addObject:sizeNumber];
                NSString *sha1 = @"";
                NSArray *hashesArray = file[@"hashes"];
                for (NSDictionary *hashDict in hashesArray) {
                    if ([[NSString stringWithFormat:@"%@", hashDict[@"algo"]] isEqualToString:@"SHA1"]) {
                        sha1 = [NSString stringWithFormat:@"%@", hashDict[@"value"]];
                        break;
                    }
                }
                [hashes addObject:sha1];
                // Load loader info if available
                NSArray *loaderInfo = file[@"loaders"] ?: @[];
                [loaders addObject:loaderInfo];
            }
            item[@"versionNames"] = names;
            item[@"mcVersionNames"] = mcNames;
            item[@"versionUrls"] = urls;
            item[@"versionHashes"] = hashes;
            item[@"versionSizes"] = sizes;
            item[@"versionLoaders"] = loaders;
            item[@"versionDetailsLoaded"] = @(YES);
            NSLog(@"loadDetailsOfMod: Loaded %lu versions for mod %@", (unsigned long)names.count, modId);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil);
            });
        }];
    });
}

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion completion:(void (^ _Nonnull)(NSError * _Nullable error))completion {
    NSArray *versionNames = modDetail[@"versionNames"];
    if (selectedVersion >= versionNames.count) {
        NSLog(@"installModpackFromDetail: Invalid version index %lu (max %lu)", (unsigned long)selectedVersion, (unsigned long)versionNames.count);
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"CurseForgeAPIErrorDomain" code:100 userInfo:@{NSLocalizedDescriptionKey: @"Selected version index is out of bounds."}];
            completion(error);
        }
        return;
    }
    NSLog(@"installModpackFromDetail: Installing modpack %@ at version index %lu", modDetail[@"title"], (unsigned long)selectedVersion);
    NSDictionary *userInfo = @{@"detail": modDetail, @"index": @(selectedVersion)};
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallModpack" object:self userInfo:userInfo];
    if (completion) {
        completion(nil);
    }
}

- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    NSDictionary *userInfo = @{@"detail": modDetail, @"index": @(selectedVersion)};
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod" object:self userInfo:userInfo];
}

#pragma mark - Helper: Auto-install Loader

- (void)autoInstallForge:(NSString *)vanillaVer loaderVersion:(NSString *)forgeVer {
    if (!vanillaVer.length || !forgeVer.length) {
        NSLog(@"autoInstallForge: Missing version information (vanilla: %@, forge: %@)", vanillaVer, forgeVer);
        return;
    }
    NSString *finalId = [NSString stringWithFormat:@"%@-forge-%@", vanillaVer, forgeVer];
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], finalId, finalId];
    [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *forgeDict = @{
        @"id": finalId,
        @"type": @"custom",
        @"minecraft": vanillaVer,
        @"loader": @"forge",
        @"loaderVersion": forgeVer
    };
    NSError *writeErr = saveJSONToFile(forgeDict, jsonPath);
    if (writeErr) {
        NSLog(@"autoInstallForge: Failed to write Forge JSON: %@", writeErr);
    }
}

- (void)autoInstallFabricWithFullString:(NSString *)fabricString {
    if (!fabricString.length) {
        NSLog(@"autoInstallFabric: Missing fabric version string");
        return;
    }
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], fabricString, fabricString];
    [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *fabricDict = @{
        @"id": fabricString,
        @"type": @"custom",
        @"loader": @"fabric",
        @"loaderVersion": fabricString
    };
    NSError *writeErr = saveJSONToFile(fabricDict, jsonPath);
    if (writeErr) {
        NSLog(@"autoInstallFabric: Failed to write Fabric JSON: %@", writeErr);
    }
}

- (void)autoInstallNeoForgeWithVanillaVersion:(NSString *)vanillaVer loaderVersion:(NSString *)neoforgeVer {
    if (!vanillaVer.length || !neoforgeVer.length) {
        NSLog(@"autoInstallNeoForge: Missing version information (vanilla: %@, neoforge: %@)", vanillaVer, neoforgeVer);
        return;
    }
    NSString *finalId = [NSString stringWithFormat:@"%@-neoforge-%@", vanillaVer, neoforgeVer];
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], finalId, finalId];
    [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *neoforgeDict = @{
        @"id": finalId,
        @"type": @"custom",
        @"minecraft": vanillaVer,
        @"loader": @"neoforge",
        @"loaderVersion": neoforgeVer
    };
    NSError *writeErr = saveJSONToFile(neoforgeDict, jsonPath);
    if (writeErr) {
        NSLog(@"autoInstallNeoForge: Failed to write NeoForge JSON: %@", writeErr);
    }
}

#pragma mark - Manifest Verification

- (BOOL)verifyManifestFromDictionary:(NSDictionary *)manifest {
    if (![manifest[@"manifestType"] isEqualToString:@"minecraftModpack"]) {
        NSLog(@"verifyManifestFromDictionary: Invalid manifestType: %@", manifest[@"manifestType"]);
        return NO;
    }
    if ([manifest[@"manifestVersion"] integerValue] != 1) {
        NSLog(@"verifyManifestFromDictionary: Unsupported manifestVersion: %@", manifest[@"manifestVersion"]);
        return NO;
    }
    if (!manifest[@"minecraft"]) {
        NSLog(@"verifyManifestFromDictionary: Missing minecraft key");
        return NO;
    }
    NSDictionary *minecraft = manifest[@"minecraft"];
    if (!minecraft[@"version"]) {
        NSLog(@"verifyManifestFromDictionary: Missing minecraft.version");
        return NO;
    }
    if (!minecraft[@"modLoaders"]) {
        NSLog(@"verifyManifestFromDictionary: Missing minecraft.modLoaders");
        return NO;
    }
    NSArray *modLoaders = minecraft[@"modLoaders"];
    if (![modLoaders isKindOfClass:[NSArray class]] || modLoaders.count < 1) {
        NSLog(@"verifyManifestFromDictionary: Invalid modLoaders: %@", modLoaders);
        return NO;
    }
    NSLog(@"verifyManifestFromDictionary: Manifest is valid");
    return YES;
}

#pragma mark - asyncExtractManifestFromPackage

- (void)asyncExtractManifestFromPackage:(NSString *)packagePath completion:(void (^)(NSDictionary *manifestDict, NSError *error))completion {
    NSLog(@"asyncExtractManifestFromPackage: Started extraction for package at %@", packagePath);
    // Implementation details truncated for brevity.
    if (completion) {
        completion(@{}, nil);
    }
}

@end
