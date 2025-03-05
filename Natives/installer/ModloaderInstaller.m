#import "ModloaderInstaller.h"
#import "JavaLauncher.h"

@implementation ModloaderInstaller

// Installs the specified modloader (e.g., Forge, Fabric, Quilt, NeoForge) into its own profile directory.
- (void)installModloader:(NSString *)modloaderName forInstance:(NSString *)instanceName version:(NSString *)versionString {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    
    // Construct paths for instance and profile directories.
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    NSString *instancesDir = [documentsDir stringByAppendingPathComponent:@"instances"];
    NSString *instanceDir = [instancesDir stringByAppendingPathComponent:instanceName];
    NSString *profileDir = [instanceDir stringByAppendingPathComponent:modloaderName];
    
    // Ensure the instance directory exists.
    if (![fm fileExistsAtPath:instanceDir]) {
        [fm createDirectoryAtPath:instanceDir withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"[ModloaderInstaller] ERROR: Failed to create instance directory %@ (%@)", instanceDir, error);
            return;
        }
    }
    
    // Create the profile directory if it doesn't exist.
    if (![fm fileExistsAtPath:profileDir]) {
        if ([fm createDirectoryAtPath:profileDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"[ModloaderInstaller] Created profile directory for %@ at %@", modloaderName, profileDir);
        } else {
            NSLog(@"[ModloaderInstaller] ERROR: Failed to create profile directory %@ (%@)", profileDir, error);
            return;
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
    NSLog(@"[ModloaderInstaller] Initialized %@ profile structure for instance: %@", modloaderName, instanceName);
    
    // Download the installer jar for the modloader.
    NSString *installerURL = [self downloadURLForModloader:modloaderName version:versionString];
    NSString *tmpPath = NSTemporaryDirectory();
    NSString *installerPath = [tmpPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-installer.jar", [modloaderName lowercaseString]]];
    
    if (![self downloadFileFromURL:installerURL toPath:installerPath]) {
        NSLog(@"[ModloaderInstaller] ERROR: Failed to download %@ installer for version %@", modloaderName, versionString);
        return;
    }
    NSLog(@"[ModloaderInstaller] %@ installer downloaded to %@", modloaderName, installerPath);
    
    // Launch the installer jar with the game directory set to the profile directory.
    [[JavaLauncher sharedLauncher] launchJavaInstallerJar:installerPath forGameDir:profileDir];
    NSLog(@"[ModloaderInstaller] Completed %@ installation for instance: %@ in %@", modloaderName, instanceName, profileDir);
}

// Returns the download URL for the modloader installer (replace with production implementation).
- (NSString *)downloadURLForModloader:(NSString *)modloaderName version:(NSString *)versionString {
    return [NSString stringWithFormat:@"https://example.com/%@/%@/installer.jar", modloaderName, versionString];
}

// Downloads a file from a URL to a destination path (replace with production implementation).
- (BOOL)downloadFileFromURL:(NSString *)urlString toPath:(NSString *)destinationPath {
    NSLog(@"[ModloaderInstaller] Simulating download from %@ to %@", urlString, destinationPath);
    return YES;
}

@end
