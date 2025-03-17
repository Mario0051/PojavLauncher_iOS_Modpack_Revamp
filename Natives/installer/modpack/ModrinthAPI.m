#import "AFNetworking.h"
#import "installer/ForgeInstallViewController.h"
#import "JavaGUIViewController.h"
#import "LauncherNavigationController.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "ModpackUtils.h"
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

    // Store the destination path in metadata for later use
    if (!downloader.metadata) {
        downloader.metadata = [NSMutableDictionary dictionary];
    }
    downloader.metadata[@"destPath"] = destPath;

    // Get files and create a more unique display name for each file
    NSArray *files = indexDict[@"files"];
    if (!files || ![files isKindOfClass:[NSArray class]] || files.count == 0) {
        [downloader finishDownloadWithErrorString:@"No mod files found in modpack index"];
        return;
    }
    
    // Set up tracking for retries
    downloader.metadata[@"retryMap"] = [NSMutableDictionary dictionary];
    
    // Store the modpack dependencies for later use in Forge/NeoForge installation
    downloader.metadata[@"modpackDependencies"] = indexDict[@"dependencies"];
    
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
        
        // Ensure the path is correctly constructed relative to the destPath
        NSString *relativePath = indexFile[@"path"];
        NSString *path = [destPath stringByAppendingPathComponent:relativePath];
        
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        
        // Create directory structure if needed
        NSString *dirPath = [path stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dirPath 
                                 withIntermediateDirectories:YES 
                                                  attributes:nil 
                                                       error:nil];
        
        // Create a display name that includes more path information
        NSString *displayName = [NSString stringWithFormat:@"Downloading %@", relativePath];
        NSLog(@"[ModrinthAPI] Preparing to download: %@ to %@", displayName, path);
        
        // Create unique ID for tracking retries
        NSString *downloadID = [NSString stringWithFormat:@"%@_%@", path.lastPathComponent, sha ?: @"nohash"];
        
        // Create success callback that decrements pending downloads and checks for completion
        void(^fileSuccess)(void) = ^{
            pendingDownloads--;
            NSLog(@"[ModrinthAPI] Download completed: %@", relativePath);
            
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
                NSLog(@"[ModrinthAPI] Retrying download for %@ after failure: %@", relativePath, error.localizedDescription);
                
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
                    NSLog(@"[ModrinthAPI] Retry failed for %@: %@", relativePath, retryError.localizedDescription);
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
    
    NSLog(@"[ModrinthAPI] Beginning extraction of modpack to %@", destPath);
    
    // Extract overrides directory - this is the main content directory
    [self extractDirectoryFromArchive:archive directory:@"overrides" toPath:destPath progress:extractionProgress];
    extractionProgress.completedUnitCount = 50;
    
    // Extract client-overrides directory if it exists
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
                                                                altName:@"Downloading dependency JSON..."
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
    NSLog(@"[ModrinthAPI] Extracting %@ directory to %@", directoryName, destPath);
    
    [ModpackUtils archive:archive extractDirectory:directoryName toPath:destPath error:&error];
    
    if (error) {
        NSLog(@"[ModrinthAPI] Error extracting %@ directory: %@", directoryName, error.localizedDescription);
    } else {
        NSLog(@"[ModrinthAPI] Successfully extracted %@ directory to %@", directoryName, destPath);
    }
}

- (void)finalizeModpackInstallation:(MinecraftResourceDownloadTask *)downloader 
                          indexDict:(NSDictionary *)indexDict
                            depInfo:(NSDictionary *)depInfo
                           destPath:(NSString *)destPath {
    // Get the profile name from indexDict, or use the directory name if not available
    NSString *profileName = indexDict[@"name"];
    if (!profileName || [profileName length] == 0) {
        profileName = [destPath lastPathComponent];
    }
    
    // Calculate the relative gameDir from the absolute destPath
    NSString *gameDir;
    NSString *instancesPath = [NSString stringWithFormat:@"%s/instances/%@", 
                              getenv("POJAV_HOME"), 
                              getPrefObject(@"general.game_directory")];
    
    // If destPath starts with instancesPath, extract the relative part
    if ([destPath hasPrefix:instancesPath]) {
        gameDir = [destPath substringFromIndex:instancesPath.length];
        // Remove leading slash if present
        if ([gameDir hasPrefix:@"/"]) {
            gameDir = [gameDir substringFromIndex:1];
        }
    } else {
        // Fallback to default gameDir path (should not normally happen)
        gameDir = [PLProfiles uniqueGameDirForProfileName:profileName];
        NSLog(@"[ModrinthAPI] Warning: Could not determine relative gameDir from destPath. Using: %@", gameDir);
    }
    
    NSLog(@"[ModrinthAPI] Creating profile: %@ with gameDir: %@", profileName, gameDir);
    
    // Create the profile with the properly aligned gameDir
    NSMutableDictionary *newProfile = [@{
        @"gameDir": gameDir,
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
    
    // Check for Forge immediately
    [self checkAndInstallForge:downloader 
             withDependencies:indexDict[@"dependencies"] 
                  profileName:profileName];
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
            message:[NSString stringWithFormat:@"This modpack requires %@ %@, which is not yet installed. Would you like to install it now?", vendor, fullVersion]
            preferredStyle:UIAlertControllerStyleAlert];
            
        [alert addAction:[UIAlertAction 
            actionWithTitle:@"Yes" 
            style:UIAlertActionStyleDefault 
            handler:^(UIAlertAction * _Nonnull action) {
                // Get the correct endpoint info based on vendor type
                NSDictionary *endpoints;
                
                if ([vendor isEqualToString:@"Forge"]) {
                    endpoints = @{
                        @"installer": @"https://maven.minecraftforge.net/net/minecraftforge/forge/%1$@/forge-%1$@-installer.jar",
                        @"metadata": @"https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml"
                    };
                } else { // NeoForge
                    endpoints = @{
                        @"installer": @"https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@/neoforge-%1$@-installer.jar",
                        @"metadata": @"https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
                    };
                }
                
                // Download the installer
                NSString *installerUrl = [NSString stringWithFormat:endpoints[@"installer"], fullVersion];
                NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"forge-installer.jar"];
                NSLog(@"[ModrinthAPI] Downloading %@ installer from: %@", vendor, installerUrl);
                
                // Create download manager
                NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
                AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
                
                // Setup UI for download
                UIViewController *currentVC = nil;
                UISplitViewController *splitVC = nil;
                
                // Find the root view controller - proper way to get the current UI
                NSArray<UIWindow *> *windows = nil;
                if (@available(iOS 13.0, *)) {
                    UIWindowScene *windowScene = nil;
                    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                        if ([scene isKindOfClass:[UIWindowScene class]] && 
                            ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
                            windowScene = (UIWindowScene *)scene;
                            break;
                        }
                    }
                    windows = windowScene.windows;
                } else {
                    windows = UIApplication.sharedApplication.windows;
                }
                
                UIWindow *mainWindow = nil;
                for (UIWindow *window in windows) {
                    if (window.isKeyWindow) {
                        mainWindow = window;
                        break;
                    }
                }
                
                if (mainWindow) {
                    currentVC = mainWindow.rootViewController;
                    if ([currentVC isKindOfClass:[UISplitViewController class]]) {
                        splitVC = (UISplitViewController *)currentVC;
                    }
                }
                
                // Get the navigation controller for progress updates
                LauncherNavigationController *navVC = nil;
                if (splitVC && splitVC.viewControllers.count > 1) {
                    navVC = (LauncherNavigationController *)splitVC.viewControllers[1];
                    [navVC setInteractionEnabled:NO forDownloading:YES];
                    navVC.progressText.text = [NSString stringWithFormat:@"Downloading %@ installer...", vendor];
                    navVC.progressViewMain.hidden = NO;
                }
                
                // Create download request
                NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:installerUrl]];
                NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull progress) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (navVC) {
                            navVC.progressViewMain.progress = progress.fractionCompleted;
                        }
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
                        
                        // Reset UI 
                        if (navVC) {
                            [navVC setInteractionEnabled:YES forDownloading:NO];
                            navVC.progressViewMain.hidden = YES;
                            navVC.progressText.text = nil;
                            
                            // Show a simple notification and launch the installer
                            showDialog(@"Installing Forge", 
                                      [NSString stringWithFormat:@"%@ installer will now run. After installation completes, please restart the app.", vendor]);
                            
                            // Use the exact same method as ForgeInstallViewController
                            // This is the critical line that launches the JAR
                            [navVC enterModInstallerWithPath:outPath hitEnterAfterWindowShown:YES];
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
        
        // Present the alert - find the current view controller
        UIViewController *currentVC = nil;
        
        // Find the root view controller - proper way to get the current UI
        NSArray<UIWindow *> *windows = nil;
        if (@available(iOS 13.0, *)) {
            UIWindowScene *windowScene = nil;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] && 
                    ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
                    windowScene = (UIWindowScene *)scene;
                    break;
                }
            }
            windows = windowScene.windows;
        } else {
            windows = UIApplication.sharedApplication.windows;
        }
        
        UIWindow *mainWindow = nil;
        for (UIWindow *window in windows) {
            if (window.isKeyWindow) {
                mainWindow = window;
                break;
            }
        }
        
        if (mainWindow) {
            currentVC = mainWindow.rootViewController;
            // Find the topmost presented view controller
            while (currentVC.presentedViewController) {
                currentVC = currentVC.presentedViewController;
            }
            [currentVC presentViewController:alert animated:YES completion:nil];
        }
    });
}

@end
