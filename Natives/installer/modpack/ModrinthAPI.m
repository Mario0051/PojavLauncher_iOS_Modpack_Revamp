#import "AFNetworking.h"
#import "ForgeInstallViewController.h"
#import "JavaGUIViewController.h"
#import "LauncherNavigationController.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"
#import "UIKit+hook.h"
#import "utils.h"

// External functions from utils.h
extern void showDialog(NSString *title, NSString *message);

@implementation ModrinthAPI

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;

    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", searchFilters[@"isModpack"].boolValue ? @"modpack" : @"mod"];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"],
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        return nil;
    }

    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1), // Constant MODRINTH
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"],
            @"title": hit[@"title"],
            @"description": hit[@"description"],
            @"imageUrl": hit[@"icon_url"]
        }.mutableCopy];
    }
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) {
        return;
    }
    NSArray<NSString *> *names = [response valueForKey:@"name"];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSString *> *sizes = [NSMutableArray new];
    [response enumerateObjectsUsingBlock:
  ^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        NSDictionary *file = [version[@"files"] firstObject];
        mcNames[i] = [version[@"game_versions"] firstObject];
        sizes[i] = file[@"size"];
        urls[i] = file[@"url"];
        NSDictionary *hashesMap = file[@"hashes"];
        hashes[i] = hashesMap[@"sha1"] ?: [NSNull null];
    }];
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }

    NSLog(@"[ModrinthAPI] Opening modpack archive: %@", packagePath);
    NSLog(@"[ModrinthAPI] Destination path: %@", destPath);

    // Make sure the destination directory exists
    [[NSFileManager defaultManager] createDirectoryAtPath:destPath 
                             withIntermediateDirectories:YES 
                                              attributes:nil 
                                                   error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create destination directory: %@", error.localizedDescription]];
        return;
    }

    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    if (!indexData) {
        // Try mrpack format (newer Modrinth format)
        indexData = [archive extractDataFromFile:@"index.json" error:&error];
    }
    
    if (!indexData) {
        [downloader finishDownloadWithErrorString:@"Failed to find index.json in modpack"];
        return;
    }
    
    NSDictionary* indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modpack index: %@", error.localizedDescription]];
        return;
    }

    NSLog(@"[ModrinthAPI] Modpack index parsed successfully");

    // Get files and create a more unique display name for each file
    NSArray *files = indexDict[@"files"];
    if (!files || ![files isKindOfClass:[NSArray class]] || files.count == 0) {
        [downloader finishDownloadWithErrorString:@"No mod files found in modpack index"];
        return;
    }
    
    // Set up tracking for retries
    if (!downloader.metadata) {
        downloader.metadata = [NSMutableDictionary dictionary];
    }
    downloader.metadata[@"retryMap"] = [NSMutableDictionary dictionary];
    
    downloader.progress.totalUnitCount = [files count];
    
    // Track pending downloads to ensure we complete properly
    __block NSInteger pendingDownloads = files.count;
    
    for (NSDictionary *indexFile in files) {
        if (![indexFile isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[ModrinthAPI] Skipping invalid file entry");
            pendingDownloads--;
            downloader.progress.completedUnitCount++;
            continue;
        }
        
        NSArray *downloadURLs = indexFile[@"downloads"];
        if (!downloadURLs || ![downloadURLs isKindOfClass:[NSArray class]] || downloadURLs.count == 0) {
            NSLog(@"[ModrinthAPI] File has no download URLs: %@", indexFile[@"path"]);
            pendingDownloads--;
            downloader.progress.completedUnitCount++;
            continue;
        }
        
        NSString *url = [downloadURLs firstObject];
        NSString *sha = indexFile[@"hashes"][@"sha1"];
        NSString *path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        
        // Create directory structure if needed
        NSString *dirPath = [path stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dirPath 
                                 withIntermediateDirectories:YES 
                                                  attributes:nil 
                                                       error:nil];
        
        // Create a display name that includes more path information
        NSString *displayName = indexFile[@"path"];
        NSLog(@"[ModrinthAPI] Preparing to download: %@ to %@", displayName, path);
        
        // Create unique ID for tracking retries
        NSString *downloadID = [NSString stringWithFormat:@"%@_%@", path.lastPathComponent, sha ?: @"nohash"];
        
        // Create success callback that decrements pending downloads and checks for completion
        void(^fileSuccess)(void) = ^{
            pendingDownloads--;
            NSLog(@"[ModrinthAPI] Download completed: %@", displayName);
            
            // If all downloads are complete, proceed to extraction
            if (pendingDownloads == 0) {
                [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];
            }
        };
        
        // Create failure callback that will retry the download once
        void(^fileFailure)(NSError *error) = ^(NSError *error) {
            // Check if this file has already been retried
            NSMutableDictionary *retryMap = downloader.metadata[@"retryMap"];
            NSNumber *retryCount = retryMap[downloadID];
            
            if (!retryCount || retryCount.intValue < 1) {
                // Log retry attempt
                NSLog(@"[ModrinthAPI] Retrying download for %@ after failure: %@", displayName, error.localizedDescription);
                
                // Mark this file as retried
                retryMap[downloadID] = @(retryCount ? retryCount.intValue + 1 : 1);
                
                // Create a new download task with the same parameters
                NSURLSessionDownloadTask *retryTask = [downloader createDownloadTask:url 
                                                                               size:size 
                                                                                sha:sha 
                                                                            altName:[NSString stringWithFormat:@"%@ (retry)", displayName]
                                                                             toPath:path 
                                                                            success:fileSuccess
                                                                            failure:^(NSError *retryError) {
                    // If retry also fails, decrement pending count
                    NSLog(@"[ModrinthAPI] Retry failed for %@: %@", displayName, retryError.localizedDescription);
                    pendingDownloads--;
                    
                    // If all downloads are complete (including failures), proceed
                    if (pendingDownloads == 0) {
                        [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];
                    }
                }];
                
                if (retryTask) {
                    [retryTask resume];
                } else {
                    // If task creation fails, decrement pending count
                    pendingDownloads--;
                    
                    // If all downloads are complete, proceed to extraction
                    if (pendingDownloads == 0) {
                        [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];
                    }
                }
            } else {
                // Already retried, decrement pending count
                pendingDownloads--;
                
                // If all downloads are complete, proceed to extraction
                if (pendingDownloads == 0) {
                    [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];
                }
            }
        };
        
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url 
                                                                   size:size 
                                                                    sha:sha 
                                                                altName:displayName 
                                                                 toPath:path 
                                                                success:fileSuccess
                                                                failure:fileFailure];
        
        if (task) {
            // Add to file list with the unique display name
            [downloader.fileList addObject:displayName];
            [task resume];
        } else if (!downloader.progress.cancelled) {
            pendingDownloads--;
            downloader.progress.completedUnitCount++;
            
            // If all downloads are complete, proceed to extraction
            if (pendingDownloads == 0) {
                [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];
            }
        } else {
            return; // cancelled
        }
    }
    
    // If there were no downloads to process, proceed directly to extraction
    if (pendingDownloads == 0) {
        [self extractAndFinalizeModpack:downloader archive:archive indexDict:indexDict destPath:destPath packagePath:packagePath];
    }
}

- (void)extractAndFinalizeModpack:(MinecraftResourceDownloadTask *)downloader 
                          archive:(UZKArchive *)archive
                        indexDict:(NSDictionary *)indexDict
                         destPath:(NSString *)destPath
                      packagePath:(NSString *)packagePath {
    NSError *error;
    
    // Add extraction filename to track progress
    [downloader.fileList addObject:@"Extracting modpack..."];
    NSProgress *extractionProgress = [NSProgress progressWithTotalUnitCount:100];
    [downloader.progressList addObject:extractionProgress];
    
    NSLog(@"[ModrinthAPI] Beginning extraction of modpack");
    
    // Extract overrides directory
    [self extractDirectoryFromArchive:archive directory:@"overrides" toPath:destPath progress:extractionProgress];
    extractionProgress.completedUnitCount = 50;
    
    // Extract client-overrides directory
    [self extractDirectoryFromArchive:archive directory:@"client-overrides" toPath:destPath progress:extractionProgress];
    extractionProgress.completedUnitCount = 75;
    
    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    // Update extraction progress
    extractionProgress.completedUnitCount = 90;

    // Download dependency client json (if available)
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        
        // Create directories for JSON
        [[NSFileManager defaultManager] createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent] 
                                withIntermediateDirectories:YES 
                                                 attributes:nil 
                                                      error:nil];
        
        // Create a success callback that will run after JSON download completes
        void(^jsonSuccess)(void) = ^{
            // Mark extraction as complete
            extractionProgress.completedUnitCount = 100;
            
            // Only create profile and mark as complete after JSON download
            [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
        };
        
        // Use the version with success callback to wait for completion
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] 
                                                                   size:0 
                                                                    sha:nil 
                                                                altName:nil 
                                                                 toPath:jsonPath 
                                                                success:jsonSuccess
                                                                failure:^(NSError *jsonError) {
            NSLog(@"[ModrinthAPI] Failed to download JSON: %@", jsonError.localizedDescription);
            
            // Still mark extraction as complete and finalize
            extractionProgress.completedUnitCount = 100;
            [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
        }];
        
        if (task) {
            [task resume];
        } else {
            // If task couldn't be created but file exists, still finalize
            extractionProgress.completedUnitCount = 100;
            [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
        }
    } else {
        // No JSON to download, so we can finalize immediately
        extractionProgress.completedUnitCount = 100;
        [self finalizeModpackInstallation:downloader indexDict:indexDict depInfo:depInfo destPath:destPath];
    }
}

- (void)extractDirectoryFromArchive:(UZKArchive *)archive directory:(NSString *)directoryName toPath:(NSString *)destPath progress:(NSProgress *)progress {
    NSError *error;
    NSLog(@"[ModrinthAPI] Attempting to extract %@ directory", directoryName);
    
    // Get list of files in the archive
    NSArray<NSString *> *fileList = [archive listFilenames:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Error listing files in archive: %@", error.localizedDescription);
        return;
    }
    
    // Filter list to only include files in the specified directory
    NSString *directoryPrefix = [directoryName stringByAppendingString:@"/"];
    NSMutableArray<NSString *> *filesToExtract = [NSMutableArray array];
    
    for (NSString *filename in fileList) {
        if ([filename hasPrefix:directoryPrefix]) {
            [filesToExtract addObject:filename];
        }
    }
    
    if (filesToExtract.count == 0) {
        NSLog(@"[ModrinthAPI] No files found in %@ directory", directoryName);
        return;
    }
    
    NSLog(@"[ModrinthAPI] Found %lu files in %@ directory", (unsigned long)filesToExtract.count, directoryName);
    
    // Extract each file
    for (NSString *filename in filesToExtract) {
        NSString *relativePath = [filename substringFromIndex:directoryPrefix.length];
        NSString *targetPath = [destPath stringByAppendingPathComponent:relativePath];
        
        // Create target directory if needed
        NSString *targetDir = [targetPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:targetDir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&error];
        if (error) {
            NSLog(@"[ModrinthAPI] Error creating directory %@: %@", targetDir, error.localizedDescription);
            continue;
        }
        
        // Extract file
        NSData *fileData = [archive extractDataFromFile:filename error:&error];
        if (error) {
            NSLog(@"[ModrinthAPI] Error extracting %@: %@", filename, error.localizedDescription);
            continue;
        }
        
        // Write file
        [fileData writeToFile:targetPath options:NSDataWritingAtomic error:&error];
        if (error) {
            NSLog(@"[ModrinthAPI] Error writing %@: %@", targetPath, error.localizedDescription);
            continue;
        }
        
        NSLog(@"[ModrinthAPI] Extracted %@ to %@", filename, targetPath);
    }
}

- (void)finalizeModpackInstallation:(MinecraftResourceDownloadTask *)downloader 
                          indexDict:(NSDictionary *)indexDict
                            depInfo:(NSDictionary *)depInfo
                           destPath:(NSString *)destPath {
    // Create a mutable dictionary for the new profile
    NSString *profileName = indexDict[@"name"];
    if (!profileName || [profileName length] == 0) {
        profileName = [destPath lastPathComponent];
    }
    
    NSMutableDictionary *newProfile = [@{
        @"gameDir": [PLProfiles uniqueGameDirForProfileName:profileName],
        @"name": profileName,
        @"lastVersionId": depInfo[@"id"] ?: @"latest-release"
    } mutableCopy];
    
    // Safely handle the icon data
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    if (iconData && iconData.length > 0) {
        // Only add icon if valid data exists
        newProfile[@"icon"] = [NSString stringWithFormat:@"data:image/png;base64,%@",
                              [iconData base64EncodedStringWithOptions:0]];
    }
    
    NSLog(@"[ModrinthAPI] Creating profile: %@ with gameDir: %@", profileName, newProfile[@"gameDir"]);
    
    // Add the profile to the profiles list
    PLProfiles.current.profiles[profileName] = newProfile;
    
    // Set this as the selected profile
    PLProfiles.current.selectedProfileName = profileName;
    
    // Save the profile changes to disk
    [PLProfiles.current save];
    
    // Ensure metadata reflects completion and marks this as a modpack install
    if (!downloader.metadata) {
        downloader.metadata = [NSMutableDictionary dictionary];
    }
    downloader.metadata[@"isModpackInstall"] = @YES;
    downloader.metadata[@"allTasksComplete"] = @YES;
    downloader.metadata[@"forgeDependencies"] = indexDict[@"dependencies"]; // Store for later use
    downloader.metadata[@"profileName"] = profileName;
    
    // Ensure progress is marked as complete
    downloader.progress.completedUnitCount = downloader.progress.totalUnitCount;
    
    // Add completion marker
    [downloader.fileList addObject:@"Complete"];
    NSProgress *completeProgress = [NSProgress progressWithTotalUnitCount:1];
    completeProgress.completedUnitCount = 1;
    [downloader.progressList addObject:completeProgress];
    
    // Log completion
    NSLog(@"[ModrinthAPI] Modpack installation complete: %@", profileName);
    
    // Check for Forge after a short delay to ensure the UI has updated
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Now check if Forge is required and needs to be installed
        [self checkAndInstallForge:downloader withDependencies:indexDict[@"dependencies"] profileName:profileName];
    });
}

- (void)checkAndInstallForge:(MinecraftResourceDownloadTask *)downloader 
            withDependencies:(NSDictionary *)dependencies 
                 profileName:(NSString *)profileName {
    // Check if the modpack requires Forge/NeoForge
    NSString *forgeVersion = dependencies[@"forge"];
    NSString *neoForgeVersion = dependencies[@"neoforge"];
    NSString *minecraftVersion = dependencies[@"minecraft"];
    
    if (!forgeVersion && !neoForgeVersion) {
        // No Forge dependency, nothing to install
        return;
    }
    
    NSString *vendor = forgeVersion ? @"Forge" : @"NeoForge";
    NSString *version = forgeVersion ?: neoForgeVersion;
    NSString *fullVersion = [NSString stringWithFormat:@"%@-%@", minecraftVersion, version];
    
    // Check if this Forge version is already installed
    NSString *versionPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), fullVersion];
    if ([NSFileManager.defaultManager fileExistsAtPath:versionPath]) {
        NSLog(@"[ModrinthAPI] %@ version %@ is already installed", vendor, fullVersion);
        return;
    }
    
    // Need to present this on the main thread after the download is complete
    dispatch_async(dispatch_get_main_queue(), ^{
        // Show alert to user
        UIAlertController *alert = [UIAlertController 
            alertControllerWithTitle:[NSString stringWithFormat:@"%@ Installation Required", vendor]
            message:[NSString stringWithFormat:@"This modpack requires %@ %@, which is not yet installed. Installing it will require you to restart the app after it is finished. Would you like to install it now?", vendor, fullVersion]
            preferredStyle:UIAlertControllerStyleAlert];
            
        [alert addAction:[UIAlertAction 
            actionWithTitle:@"Yes" 
            style:UIAlertActionStyleDefault 
            handler:^(UIAlertAction * _Nonnull action) {
                // Get the correct endpoint info
                NSDictionary *endpoints = @{
                    @"Forge": @{
                        @"installer": @"https://maven.minecraftforge.net/net/minecraftforge/forge/%1$@/forge-%1$@-installer.jar",
                        @"metadata": @"https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
                    },
                    @"NeoForge": @{
                        @"installer": @"https://maven.neoforged.net/net/neoforged/forge/%1$@/forge-%1$@-installer.jar",
                        @"metadata": @"https://maven.neoforged.net/releases/net/neoforged/forge/maven-metadata.xml"
                    }
                };
                
                // Download the installer
                NSString *installerUrl = [NSString stringWithFormat:endpoints[vendor][@"installer"], fullVersion];
                NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"forge-installer.jar"];
                NSLog(@"[ModrinthAPI] Downloading %@ installer from: %@", vendor, installerUrl);
                
                // Create download manager
                NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
                AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
                
                // Setup UI for download - find the root view controller without using keyWindow
                UIViewController *currentVC = nil;
                if (@available(iOS 13.0, *)) {
                    NSSet<UIScene *> *connectedScenes = UIApplication.sharedApplication.connectedScenes;
                    for (UIScene *scene in connectedScenes) {
                        if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                            UIWindowScene *windowScene = (UIWindowScene *)scene;
                            currentVC = windowScene.windows.firstObject.rootViewController;
                            break;
                        }
                    }
                } else {
                    // Fallback for iOS 12 and earlier
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    currentVC = UIApplication.sharedApplication.keyWindow.rootViewController;
                    #pragma clang diagnostic pop
                }
                
                // Find the topmost presented view controller
                while (currentVC.presentedViewController) {
                    currentVC = currentVC.presentedViewController;
                }
                
                // Add progress indicator
                LauncherNavigationController *navVC = nil;
                if ([currentVC isKindOfClass:UISplitViewController.class]) {
                    navVC = (LauncherNavigationController *)((UISplitViewController *)currentVC).viewControllers[1];
                    [navVC setInteractionEnabled:NO forDownloading:YES];
                    navVC.progressText.text = [NSString stringWithFormat:@"Downloading %@ installer...", vendor];
                    navVC.progressViewMain.hidden = NO;
                }
                
                // Create download request
                NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:installerUrl]];
                NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull progress) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        navVC.progressViewMain.progress = progress.fractionCompleted;
                    });
                } destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
                    [NSFileManager.defaultManager removeItemAtPath:outPath error:nil];
                    return [NSURL fileURLWithPath:outPath];
                } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (error) {
                            if (navVC) {
                                [navVC setInteractionEnabled:YES forDownloading:NO];
                            }
                            showDialog(@"Error", [NSString stringWithFormat:@"Failed to download %@ installer: %@", vendor, error.localizedDescription]);
                            return;
                        }
                        
                        // Launch the installer - no need to create JavaGUIViewController directly
                        // We'll use the navigation controller's method instead
                        
                        // Hide navigation UI
                        if (navVC) {
                            [navVC setInteractionEnabled:YES forDownloading:NO];
                            navVC.progressViewMain.hidden = YES;
                            navVC.progressText.text = nil;
                            
                            // Show a message that the app will need to be restarted
                            UIAlertController *restartAlert = [UIAlertController 
                                alertControllerWithTitle:@"Restart Required"
                                message:[NSString stringWithFormat:@"After %@ installation completes, please restart the app to finalize the installation.", vendor]
                                preferredStyle:UIAlertControllerStyleAlert];
                            
                            [restartAlert addAction:[UIAlertAction 
                                actionWithTitle:@"OK" 
                                style:UIAlertActionStyleDefault 
                                handler:^(UIAlertAction * _Nonnull action) {
                                    // Use the LauncherNavigationController's method to launch the JAR file
                                    // This ensures proper JIT enablement and Java environment setup
                                    [navVC enterModInstallerWithPath:outPath hitEnterAfterWindowShown:YES];
                                }]];
                            
                            [currentVC presentViewController:restartAlert animated:YES completion:nil];
                        } else {
                            // Fallback if we couldn't get the navigation controller
                            showDialog(@"Error", @"Could not locate navigation controller for installer launch");
                        }
                    });
                }];
                
                [downloadTask resume];
            }]];
            
        [alert addAction:[UIAlertAction 
            actionWithTitle:@"No" 
            style:UIAlertActionStyleCancel 
            handler:nil]];
        
        // Present the alert - find the root view controller without using keyWindow
        UIViewController *currentVC = nil;
        if (@available(iOS 13.0, *)) {
            NSSet<UIScene *> *connectedScenes = UIApplication.sharedApplication.connectedScenes;
            for (UIScene *scene in connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    currentVC = windowScene.windows.firstObject.rootViewController;
                    break;
                }
            }
        } else {
            // Fallback for iOS 12 and earlier
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            currentVC = UIApplication.sharedApplication.keyWindow.rootViewController;
            #pragma clang diagnostic pop
        }
        
        // Find the topmost presented view controller
        while (currentVC.presentedViewController) {
            currentVC = currentVC.presentedViewController;
        }
        [currentVC presentViewController:alert animated:YES completion:nil];
    });
}

@end
