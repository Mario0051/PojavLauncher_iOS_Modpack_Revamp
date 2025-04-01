#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

@interface ModrinthAPI : ModpackAPI

@property(nonatomic, strong) NSString *userAgent;
@property(nonatomic, strong) NSURLSession *session;

/**
 * Checks if the modpack requires Forge or NeoForge and handles installation if needed
 *
 * @param downloader The download task managing the modpack installation
 * @param dependencies The dependencies dictionary from the modpack index
 * @param profileName The name of the profile being created
 */
- (void)checkAndInstallForge:(MinecraftResourceDownloadTask *)downloader 
            withDependencies:(NSDictionary *)dependencies 
                 profileName:(NSString *)profileName;

@end
