#import "InstancesViewController.h"

@implementation InstancesViewController

// Creates a new instance and initializes a default Vanilla profile.
- (void)createNewInstanceWithName:(NSString *)instanceName {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    NSString *instancesDir = [documentsDir stringByAppendingPathComponent:@"instances"];
    NSString *instanceDir = [instancesDir stringByAppendingPathComponent:instanceName];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    
    // Create instance directory.
    if (![fm fileExistsAtPath:instanceDir]) {
        if ([fm createDirectoryAtPath:instanceDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"[Instances] Created instance directory: %@", instanceDir);
        } else {
            NSLog(@"[Instances] ERROR: Could not create instance directory %@ (%@)", instanceDir, error);
            return;
        }
    }
    
    // Create default Vanilla profile directory.
    NSString *vanillaDir = [instanceDir stringByAppendingPathComponent:@"Vanilla"];
    if (![fm fileExistsAtPath:vanillaDir]) {
        if ([fm createDirectoryAtPath:vanillaDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"[Instances] Created Vanilla profile directory: %@", vanillaDir);
        } else {
            NSLog(@"[Instances] ERROR: Could not create Vanilla profile directory %@ (%@)", vanillaDir, error);
            return;
        }
    }
    
    // Create mods and config subdirectories within the Vanilla profile.
    NSString *modsDir = [vanillaDir stringByAppendingPathComponent:@"mods"];
    if (![fm fileExistsAtPath:modsDir]) {
        [fm createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:&error];
    }
    NSString *configDir = [vanillaDir stringByAppendingPathComponent:@"config"];
    if (![fm fileExistsAtPath:configDir]) {
        [fm createDirectoryAtPath:configDir withIntermediateDirectories:YES attributes:nil error:&error];
    }
    NSLog(@"[Instances] Initialized Vanilla profile structure for instance: %@", instanceName);
}

@end
