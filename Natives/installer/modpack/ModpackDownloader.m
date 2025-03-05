#import "ModpackDownloader.h"
#import "ModloaderInstaller.h"

@implementation ModpackDownloader

// Imports a modpack from the provided URL into the specified instance and installs it into a profile.
- (BOOL)importModpackAtURL:(NSURL *)zipURL toInstance:(NSString *)instanceName {
    NSDictionary *manifest = [self loadManifestFromZip:zipURL];
    if (!manifest) {
        NSLog(@"[ModpackDownloader] ERROR: Failed to load modpack manifest from %@", zipURL);
        return NO;
    }
    NSLog(@"[ModpackDownloader] Loaded manifest for modpack: %@", manifest[@"name"]);
    
    // Determine Minecraft version and modloader from the manifest.
    NSString *mcVersion = manifest[@"minecraft"][@"version"];
    NSArray *modloaders = manifest[@"minecraft"][@"modLoaders"];
    NSString *loaderName = @"Vanilla";
    NSString *loaderVersion = nil;
    if (modloaders.count > 0) {
        NSDictionary *loaderInfo = modloaders[0];
        NSString *loaderId = loaderInfo[@"id"];
        if ([loaderId containsString:@"forge"]) {
            loaderName = @"Forge";
            loaderVersion = [loaderId stringByReplacingOccurrencesOfString:@"forge-" withString:@""];
        } else if ([loaderId containsString:@"fabric"]) {
            loaderName = @"Fabric";
            loaderVersion = [loaderId stringByReplacingOccurrencesOfString:@"fabric-loader-" withString:@""];
        } else if ([loaderId containsString:@"quilt"]) {
            loaderName = @"Quilt";
            loaderVersion = [loaderId stringByReplacingOccurrencesOfString:@"quilt-loader-" withString:@""];
        } else if ([loaderId containsString:@"neoforge"]) {
            loaderName = @"NeoForge";
            loaderVersion = [loaderId stringByReplacingOccurrencesOfString:@"neoforge-" withString:@""];
        }
    }
    NSLog(@"[ModpackDownloader] Detected Minecraft version: %@, Modloader: %@ %@", mcVersion, loaderName, loaderVersion ?: @"");
    
    // Prepare instance and profile directories.
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    NSString *instancesDir = [documentsDir stringByAppendingPathComponent:@"instances"];
    NSString *instanceDir = [instancesDir stringByAppendingPathComponent:instanceName];
    NSString *profileDir = [instanceDir stringByAppendingPathComponent:loaderName];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    if (![fm fileExistsAtPath:instanceDir]) {
        if (![fm createDirectoryAtPath:instanceDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"[ModpackDownloader] ERROR: Could not create instance directory %@ (%@)", instanceDir, error);
            return NO;
        }
    }
    if (![fm fileExistsAtPath:profileDir]) {
        if ([fm createDirectoryAtPath:profileDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"[ModpackDownloader] Created profile directory: %@", profileDir);
        } else {
            NSLog(@"[ModpackDownloader] ERROR: Could not create profile directory %@ (%@)", profileDir, error);
            return NO;
        }
    }
    
    // Create mods and config subdirectories for the profile.
    NSString *modsDir = [profileDir stringByAppendingPathComponent:@"mods"];
    if (![fm fileExistsAtPath:modsDir]) {
        [fm createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:&error];
    }
    NSString *configDir = [profileDir stringByAppendingPathComponent:@"config"];
    if (![fm fileExistsAtPath:configDir]) {
        [fm createDirectoryAtPath:configDir withIntermediateDirectories:YES attributes:nil error:&error];
    }
    NSLog(@"[ModpackDownloader] Prepared profile structure for instance: %@, Profile: %@", instanceName, loaderName);
    
    // Download each file listed in the manifest.
    NSArray *files = manifest[@"files"];
    for (NSDictionary *fileInfo in files) {
        NSString *projectID = [fileInfo[@"projectID"] stringValue];
        NSString *fileID = [fileInfo[@"fileID"] stringValue];
        NSURL *apiURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.curseforge.com/v1/mods/%@/files/%@/download-url", projectID, fileID]];
        NSString *downloadURL = [self getDownloadURLFromAPI:apiURL];
        if (!downloadURL) {
            NSLog(@"[ModpackDownloader] WARN: No download URL for file (Project: %@, File: %@)", projectID, fileID);
            continue;
        }
        NSString *destPath = [modsDir stringByAppendingPathComponent:[downloadURL lastPathComponent]];
        if ([self downloadFileFromURL:downloadURL toPath:destPath]) {
            NSLog(@"[ModpackDownloader] Downloaded file to: %@", destPath);
        } else {
            NSLog(@"[ModpackDownloader] ERROR: Failed to download file from %@", downloadURL);
        }
    }
    
    // If the modloader is not Vanilla, install it.
    if (![loaderName isEqualToString:@"Vanilla"]) {
        ModloaderInstaller *installer = [[ModloaderInstaller alloc] init];
        [installer installModloader:loaderName forInstance:instanceName version:loaderVersion];
    }
    
    NSLog(@"[ModpackDownloader] Completed modpack import for instance: %@ with profile: %@", instanceName, loaderName);
    return YES;
}

// Loads the modpack manifest from the provided zip URL (replace with actual unzip and JSON parsing).
- (NSDictionary *)loadManifestFromZip:(NSURL *)zipURL {
    return @{
        @"name": @"Example Modpack",
        @"minecraft": @{
                @"version": @"1.16.5",
                @"modLoaders": @[@{@"id": @"forge-36.1.0"}]
        },
        @"files": @[
                @{@"projectID": @12345, @"fileID": @67890}
        ]
    };
}

// Retrieves the download URL from the API (replace with actual network call).
- (NSString *)getDownloadURLFromAPI:(NSURL *)apiURL {
    return @"https://example.com/mod.jar";
}

// Downloads a file from the given URL to the specified destination (replace with actual implementation).
- (BOOL)downloadFileFromURL:(NSString *)urlString toPath:(NSString *)destinationPath {
    NSLog(@"[ModpackDownloader] Simulating download from %@ to %@", urlString, destinationPath);
    return YES;
}

@end
