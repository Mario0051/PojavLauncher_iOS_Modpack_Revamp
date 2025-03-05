#import "LauncherViewController.h"
#import <Foundation/Foundation.h>
#import <stdio.h>
#import <sys/wait.h>

@implementation LauncherViewController

// Static array of instance directory names corresponding to InstanceType
static NSArray<NSString*> *instanceDirectories = nil;

+ (void)initialize {
    if (self == [LauncherViewController class]) {
        // Map InstanceType indices to folder names
        instanceDirectories = @[
            @"minecraft_vanilla",
            @"minecraft_fabric",
            @"minecraft_forge",
            @"minecraft_quilt",
            @"minecraft_neoforge"
        ];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Optionally, set default segment (e.g., Vanilla) if needed
    if (self.instanceSelector.selectedSegmentIndex < 0) {
        self.instanceSelector.selectedSegmentIndex = InstanceTypeVanilla;
    }
}

// Save the selected version ID to the config_ver.txt of the current instance
- (void)saveSelectedVersion:(NSString *)version {
    if (version == nil) return;
    NSInteger idx = self.instanceSelector.selectedSegmentIndex;
    NSString *documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *instanceFolder = instanceDirectories[idx];
    NSString *instancePath = [documentsDir stringByAppendingPathComponent:instanceFolder];
    NSString *configPath = [instancePath stringByAppendingPathComponent:@"config_ver.txt"];
    // Write the version string to config_ver.txt (overwrite existing)
    NSError *error = nil;
    BOOL success = [version writeToFile:configPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!success || error) {
        NSLog(@"Failed to save selected version to %@: %@", configPath, error);
    }
}

// Launch the Minecraft game for the currently selected instance
- (IBAction)launchGame:(id)sender {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger idx = self.instanceSelector.selectedSegmentIndex;
    NSString *documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *instanceFolder = instanceDirectories[idx];
    NSString *instancePath = [documentsDir stringByAppendingPathComponent:instanceFolder];

    // Ensure the instance directory exists (should already exist from AppDelegate setup)
    if (![fm fileExistsAtPath:instancePath]) {
        NSError *dirError = nil;
        [fm createDirectoryAtPath:instancePath withIntermediateDirectories:YES attributes:nil error:&dirError];
        if (dirError) {
            NSLog(@"Error: Instance directory %@ could not be created: %@", instancePath, dirError);
        }
    }
    // Change working directory to the instance directory
    if (![fm changeCurrentDirectoryPath:instancePath]) {
        NSLog(@"Error: Failed to change working directory to %@", instancePath);
    }

    // Prepare to capture game output in a log file within the instance directory
    NSString *logFile = [instancePath stringByAppendingPathComponent:@"latestlog.txt"];
    freopen([logFile fileSystemRepresentation], "w+", stdout);  // create/clear log file for stdout
    freopen([logFile fileSystemRepresentation], "a+", stderr);  // append stderr to the same log

    // Read the selected Minecraft version from the instance's config_ver.txt
    NSString *configPath = [instancePath stringByAppendingPathComponent:@"config_ver.txt"];
    NSString *versionID = nil;
    if ([fm fileExistsAtPath:configPath]) {
        NSError *readError = nil;
        versionID = [NSString stringWithContentsOfFile:configPath encoding:NSUTF8StringEncoding error:&readError];
        if (readError) {
            NSLog(@"Error reading config_ver.txt: %@", readError);
        }
        // Trim whitespace/newline from version string
        if (versionID) {
            versionID = [versionID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    if (versionID == nil || [versionID length] == 0) {
        // No version selected for this instance – cannot launch
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Version Selected"
                                                                           message:@"Please select a Minecraft version for this instance before launching."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
        // Restore working directory to Documents and return
        [fm changeCurrentDirectoryPath:documentsDir];
        return;
    }

    // Ensure essential subdirectories exist in instance (e.g., assets and libraries)
    NSString *assetsDir = [instancePath stringByAppendingPathComponent:@"assets"];
    if (![fm fileExistsAtPath:assetsDir]) {
        [fm createDirectoryAtPath:assetsDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *librariesDir = [instancePath stringByAppendingPathComponent:@"libraries"];
    if (![fm fileExistsAtPath:librariesDir]) {
        [fm createDirectoryAtPath:librariesDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *nativesDir = [instancePath stringByAppendingPathComponent:@"natives"];
    if (![fm fileExistsAtPath:nativesDir]) {
        [fm createDirectoryAtPath:nativesDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // Construct the Java launch command with proper classpath and arguments
    NSString *javaPath = @"/usr/bin/java";  // Path to Java executable (requires OpenJDK installed on device)
    NSString *javaOptions = @"-Xmx1024m";   // Heap size or other JVM options (adjust as needed)
    NSString *nativesOption = [NSString stringWithFormat:@"-Djava.library.path=%@/natives", instancePath];
    NSString *classpathOption = [NSString stringWithFormat:@"-cp %@/libraries/*:%@/versions/%@/%@.jar", instancePath, instancePath, versionID, versionID];
    NSString *mainClass = @"net.minecraft.client.main.Main";
    // Use a placeholder or stored username for launching; default to "Player" if not logged in
    NSString *username = @"Player";
    // Build game arguments (assets directory and game directory)
    NSString *gameArguments = [NSString stringWithFormat:@"--username %@ --version %@ --gameDir %@ --assetsDir %@", username, versionID, instancePath, assetsDir];
    // Final command string
    NSString *launchCmd = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@",
                           javaPath, javaOptions, nativesOption, classpathOption, mainClass, gameArguments];

    NSLog(@"Launching Minecraft with command: %@", launchCmd);
    // Execute the launch command
    int launchStatus = system([launchCmd UTF8String]);
    int exitCode = WEXITSTATUS(launchStatus);

    // Restore working directory back to Documents
    [fm changeCurrentDirectoryPath:documentsDir];

    if (exitCode != 0) {
        // Notify user if the game exited with an error code
        NSString *msg = [NSString stringWithFormat:@"Game exited with code %d. Check latestlog.txt for details.", exitCode];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Minecraft Exit"
                                                                           message:msg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    }
}

// Install the appropriate mod loader (Fabric/Forge/Quilt/NeoForge) for the selected instance
- (IBAction)installModLoader:(id)sender {
    NSInteger idx = self.instanceSelector.selectedSegmentIndex;
    // If Vanilla is selected, there's no mod loader to install
    if (idx == InstanceTypeVanilla) {
        NSLog(@"No mod loader to install for Vanilla.");
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *instanceFolder = instanceDirectories[idx];
    NSString *instancePath = [documentsDir stringByAppendingPathComponent:instanceFolder];
    // Ensure the instance directory exists
    if (![fm fileExistsAtPath:instancePath]) {
        [fm createDirectoryAtPath:instancePath withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // Determine the base Minecraft version to install the mod loader for.
    // We use the Vanilla instance's selected version as the base version.
    NSString *baseVersion = nil;
    NSString *vanillaConfig = [documentsDir stringByAppendingPathComponent:@"minecraft_vanilla/config_ver.txt"];
    if ([fm fileExistsAtPath:vanillaConfig]) {
        baseVersion = [[NSString stringWithContentsOfFile:vanillaConfig encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (baseVersion == nil || [baseVersion length] == 0) {
        // If we couldn't get a base version, notify user and abort installation
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Base Version"
                                                                           message:@"Please select a Vanilla Minecraft version to install the mod loader for."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
        return;
    }

    // Paths to installer JARs (assume they are already downloaded into Documents directory or bundle)
    NSString *javaPath = @"/usr/bin/java";
    NSString *installerJar = nil;
    NSString *installCmd = nil;
    int installStatus = 0;
    int exitCode = 0;

    switch (idx) {
        case InstanceTypeFabric: {
            // Fabric installer JAR (ensure it's downloaded to Documents or a known location)
            installerJar = [documentsDir stringByAppendingPathComponent:@"fabric-installer.jar"];
            // Command: java -jar fabric-installer.jar client -dir <instancePath> -mcversion <baseVersion>
            installCmd = [NSString stringWithFormat:@"\"%@\" -jar \"%@\" client -dir \"%@\" -mcversion %@", javaPath, installerJar, instancePath, baseVersion];
            break;
        }
        case InstanceTypeForge: {
            // Forge installer JAR
            installerJar = [documentsDir stringByAppendingPathComponent:@"forge-installer.jar"];
            // Command: java -jar forge-installer.jar --installClient --installPath <instancePath>
            installCmd = [NSString stringWithFormat:@"\"%@\" -jar \"%@\" --installClient --installPath \"%@\"", javaPath, installerJar, instancePath];
            break;
        }
        case InstanceTypeQuilt: {
            // Quilt installer JAR
            installerJar = [documentsDir stringByAppendingPathComponent:@"quilt-installer.jar"];
            // Command: java -jar quilt-installer.jar install client -dir <instancePath> -minecraft <baseVersion>
            installCmd = [NSString stringWithFormat:@"\"%@\" -jar \"%@\" install client -dir \"%@\" -minecraft %@", javaPath, installerJar, instancePath, baseVersion];
            break;
        }
        case InstanceTypeNeoForge: {
            // NeoForge can use Forge's installer or its own if available
            installerJar = [documentsDir stringByAppendingPathComponent:@"neoforge-installer.jar"];
            // Command: java -jar neoforge-installer.jar --installClient --installPath <instancePath>
            installCmd = [NSString stringWithFormat:@"\"%@\" -jar \"%@\" --installClient --installPath \"%@\"", javaPath, installerJar, instancePath];
            break;
        }
        default:
            break;
    }

    if (installCmd == nil || installerJar == nil) {
        NSLog(@"No installer command constructed for index %ld", (long)idx);
        return;
    }

    NSLog(@"Running mod loader installer: %@", installCmd);
    installStatus = system([installCmd UTF8String]);
    exitCode = WEXITSTATUS(installStatus);

    if (exitCode != 0) {
        // Installation failed; alert the user
        NSString *msg = [NSString stringWithFormat:@"Mod loader installation exited with code %d.", exitCode];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Installation Failed"
                                                                           message:msg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
        return;
    }

    // If installation succeeded, update the instance's config_ver.txt to the new mod loader version ID
    NSString *versionsDir = [instancePath stringByAppendingPathComponent:@"versions"];
    NSString *newVersionID = nil;
    NSArray *versionDirs = [fm contentsOfDirectoryAtPath:versionsDir error:nil];
    if (versionDirs) {
        // Determine the newly installed version folder by looking for known loader identifiers
        for (NSString *folder in versionDirs) {
            if ((idx == InstanceTypeFabric && [folder containsString:@"fabric"]) ||
                (idx == InstanceTypeForge && [folder containsString:@"forge"]) ||
                (idx == InstanceTypeQuilt && [folder containsString:@"quilt"]) ||
                (idx == InstanceTypeNeoForge && ([folder localizedCaseInsensitiveContainsString:@"neoforge"] || [folder localizedCaseInsensitiveContainsString:@"forge"]))) {
                newVersionID = folder;
                break;
            }
        }
    }
    if (newVersionID != nil) {
        NSString *configPath = [instancePath stringByAppendingPathComponent:@"config_ver.txt"];
        BOOL wrote = [newVersionID writeToFile:configPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (wrote) {
            NSLog(@"Updated %@ with new version ID %@", configPath, newVersionID);
        } else {
            NSLog(@"Failed to update config_ver.txt for new version %@", newVersionID);
        }
    }

    // Optionally, immediately switch to the mod loader instance and update UI (if not already on it)
    // (In this implementation, we assume instanceSelector is already on the correct mod loader)
}

@end
