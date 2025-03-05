#import "AppDelegate.h"
#import <Foundation/Foundation.h>

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Initialize file manager and Documents directory path
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];

    // Define paths for .pojavlauncher (accounts) and instance directories
    NSString *pojavDir = [documentsDir stringByAppendingPathComponent:@".pojavlauncher"];
    NSString *accountsDir = [pojavDir stringByAppendingPathComponent:@"accounts"];
    NSString *vanillaDir = [documentsDir stringByAppendingPathComponent:@"minecraft_vanilla"];
    NSString *fabricDir = [documentsDir stringByAppendingPathComponent:@"minecraft_fabric"];
    NSString *forgeDir = [documentsDir stringByAppendingPathComponent:@"minecraft_forge"];
    NSString *quiltDir = [documentsDir stringByAppendingPathComponent:@"minecraft_quilt"];
    NSString *neoForgeDir = [documentsDir stringByAppendingPathComponent:@"minecraft_neoforge"];

    NSError *error = nil;
    // Ensure .pojavlauncher/accounts directory exists (for account JSON files)
    if (![fileManager fileExistsAtPath:accountsDir]) {
        if (![fileManager createDirectoryAtPath:accountsDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Error creating accounts directory: %@", error);
        }
        error = nil;
    }
    // Ensure each instance directory exists (Vanilla, Fabric, Forge, Quilt, NeoForge)
    if (![fileManager fileExistsAtPath:vanillaDir]) {
        if (![fileManager createDirectoryAtPath:vanillaDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Error creating Vanilla instance directory: %@", error);
        }
        error = nil;
    }
    if (![fileManager fileExistsAtPath:fabricDir]) {
        if (![fileManager createDirectoryAtPath:fabricDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Error creating Fabric instance directory: %@", error);
        }
        error = nil;
    }
    if (![fileManager fileExistsAtPath:forgeDir]) {
        if (![fileManager createDirectoryAtPath:forgeDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Error creating Forge instance directory: %@", error);
        }
        error = nil;
    }
    if (![fileManager fileExistsAtPath:quiltDir]) {
        if (![fileManager createDirectoryAtPath:quiltDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Error creating Quilt instance directory: %@", error);
        }
        error = nil;
    }
    if (![fileManager fileExistsAtPath:neoForgeDir]) {
        if (![fileManager createDirectoryAtPath:neoForgeDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Error creating NeoForge instance directory: %@", error);
        }
        error = nil;
    }

    //Log directory setup success
    NSLog(@"Initialized instance directories at %@", documentsDir);

    return YES;
}

@end
