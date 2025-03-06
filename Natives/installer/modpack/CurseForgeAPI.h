#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * CurseForge API implementation for accessing mods and modpacks from CurseForge
 */
@interface CurseForgeAPI : ModpackAPI

/**
 * Initializes the API with the provided API key
 * @param apiKey The CurseForge API key
 * @return An initialized CurseForgeAPI instance
 */
- (instancetype)initWithAPIKey:(NSString *)apiKey NS_DESIGNATED_INITIALIZER;

/**
 * Auto-installs Forge for a Minecraft version
 * @param vanillaVer The Minecraft version
 * @param forgeVer The Forge version
 * @param completion Block to call when the installation completes
 */
- (void)autoInstallForge:(NSString *)vanillaVer 
           loaderVersion:(NSString *)forgeVer
              completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/**
 * Gets a download URL for a CurseForge project file
 * @param projectID The CurseForge project ID
 * @param fileID The file ID
 * @param completion Block to call with the URL or error
 */
- (void)getDownloadUrlForProject:(unsigned long long)projectID 
                          fileID:(unsigned long long)fileID 
                      completion:(void (^)(NSString * _Nullable downloadUrl, NSError * _Nullable error))completion;

/**
 * Parent view controller for displaying alerts
 */
@property (nonatomic, weak, nullable) UIViewController *parentViewController;

// Unavailable initializers
- (instancetype)initWithURL:(NSString *)url NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
