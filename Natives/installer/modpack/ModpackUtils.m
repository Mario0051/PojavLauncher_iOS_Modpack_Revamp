#import "installer/FabricUtils.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"
#import "utils.h"

NSString * const ModpackUtilsErrorDomain = @"ModpackUtilsErrorDomain";

@implementation ModpackUtils

#pragma mark - Error Handling

+ (NSError *)errorWithCode:(ModpackUtilsErrorCode)code message:(NSString *)message underlyingError:(nullable NSError *)underlyingError {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message;
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:ModpackUtilsErrorDomain code:code userInfo:userInfo];
}

#pragma mark - Archive Extraction

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError **)error {
    if (!archive || !dir || !path) {
        if (error) {
            *error = [self errorWithCode:ModpackUtilsErrorCodeInvalidParameters 
                                 message:@"Invalid parameters for extraction" 
                         underlyingError:nil];
        }
        return;
    }
    
    __block NSError *extractError = nil;
    
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        // Skip files that are not in the specified directory
        if (![fileInfo.filename hasPrefix:dir] || fileInfo.filename.length <= dir.length) {
            return;
        }
        
        // Get relative path within the directory
        NSString *fileName = [fileInfo.filename substringFromIndex:dir.length+1];
        NSString *destItemPath = [path stringByAppendingPathComponent:fileName];
        NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
        
        // Create destination directory
        NSError *dirError = nil;
        BOOL createdDir = [[NSFileManager defaultManager] createDirectoryAtPath:destDirPath 
                                                    withIntermediateDirectories:YES 
                                                                     attributes:nil 
                                                                          error:&dirError];
        if (!createdDir) {
            extractError = dirError;
            *stop = YES;
            return;
        } else if (fileInfo.isDirectory) {
            return;
        }
        
        // Extract file data
        NSError *dataError = nil;
        NSData *data = [archive extractData:fileInfo error:&dataError];
        if (!data) {
            extractError = dataError;
            *stop = YES;
            return;
        }
        
        // Write data to destination
        NSError *writeError = nil;
        BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:&writeError];
        if (!written) {
            extractError = writeError;
            *stop = YES;
            return;
        }
        
        NSLog(@"[ModpackUtils] Extracted %@", fileInfo.filename);
    } error:error];
    
    // If we encountered an error during extraction, pass it back
    if (extractError && error && !*error) {
        *error = extractError;
    }
}

#pragma mark - Dependency Parsing

+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency {
    if (!dependency) {
        return @{};
    }
    
    NSMutableDictionary *info = [NSMutableDictionary new];
    NSString *minecraftVersion = dependency[@"minecraft"];
    
    if (!minecraftVersion) {
        return info;
    }
    
    if (dependency[@"forge"]) {
        info[@"id"] = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, dependency[@"forge"]];
        info[@"loader"] = @"forge";
        info[@"loaderVersion"] = dependency[@"forge"];
    } else if (dependency[@"fabric-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"fabric-loader-%@-%@", dependency[@"fabric-loader"], minecraftVersion];
        info[@"loader"] = @"fabric";
        info[@"loaderVersion"] = dependency[@"fabric-loader"];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], minecraftVersion, dependency[@"fabric-loader"]];
    } else if (dependency[@"quilt-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", dependency[@"quilt-loader"], minecraftVersion];
        info[@"loader"] = @"quilt";
        info[@"loaderVersion"] = dependency[@"quilt-loader"];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], minecraftVersion, dependency[@"quilt-loader"]];
    } else if (dependency[@"neoforge"]) {
        info[@"id"] = [NSString stringWithFormat:@"%@-neoforge-%@", minecraftVersion, dependency[@"neoforge"]];
        info[@"loader"] = @"neoforge";
        info[@"loaderVersion"] = dependency[@"neoforge"];
    }
    
    info[@"mcVersion"] = minecraftVersion;
    
    return info;
}

#pragma mark - Version String Parsing

+ (NSDictionary *)parseVersionString:(NSString *)versionString {
    if (!versionString || versionString.length == 0) {
        return @{};
    }
    
    NSString *trimmed = [[versionString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSArray *components = [trimmed componentsSeparatedByString:@"-"];
    NSMutableDictionary *result = [NSMutableDictionary new];
    
    if (components.count >= 2) {
        // First identify the pattern
        if (components.count == 4 && 
            ([components[0] isEqualToString:@"fabric"] || [components[0] isEqualToString:@"quilt"]) && 
            [components[1] isEqualToString:@"loader"]) {
            // Fabric/Quilt format: "fabric-loader-0.16.10-1.21.4" or "quilt-loader-0.16.10-1.21.4"
            result[@"loader"] = components[0];
            result[@"loaderVersion"] = components[2];
            result[@"mcVersion"] = components[3];
        } else if (components.count == 3) {
            // Standard format: "1.20-forge-46.0.14" or "1.20-neoforge-46.0.14"
            result[@"mcVersion"] = components[0];
            result[@"loader"] = components[1]; // Expected to be "forge", "neoforge", or "quilt"
            result[@"loaderVersion"] = components[2];
        } else {
            // Try to make a best guess 
            if ([components[0] isEqualToString:@"fabric"] || 
                [components[0] isEqualToString:@"forge"] || 
                [components[0] isEqualToString:@"neoforge"] || 
                [components[0] isEqualToString:@"quilt"]) {
                
                result[@"loader"] = components[0];
                
                // Extract other components as best we can
                if (components.count > 1) {
                    // Likely a loader version or MC version next
                    if ([components[1] hasPrefix:@"1."] || [components[1] hasPrefix:@"0."]) {
                        if ([components[1] hasPrefix:@"1."]) {
                            result[@"mcVersion"] = components[1];
                            if (components.count > 2) {
                                result[@"loaderVersion"] = components[2];
                            }
                        } else {
                            result[@"loaderVersion"] = components[1];
                            if (components.count > 2) {
                                result[@"mcVersion"] = components[2];
                            }
                        }
                    }
                }
            } else if ([components[0] hasPrefix:@"1."]) {
                // Starts with Minecraft version
                result[@"mcVersion"] = components[0];
                if (components.count > 1) {
                    result[@"loader"] = components[1];
                    if (components.count > 2) {
                        result[@"loaderVersion"] = [[components subarrayWithRange:NSMakeRange(2, components.count - 2)] componentsJoinedByString:@"-"];
                    }
                }
            }
        }
    }
    
    return result;
}

#pragma mark - JSON Creation Methods

+ (BOOL)createForgeJSON:(NSString *)vanillaVer loaderVersion:(NSString *)forgeVer error:(NSError **)error {
    if (!vanillaVer.length || !forgeVer.length) {
        if (error) {
            *error = [self errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                 message:@"Missing version information for Forge JSON creation"
                         underlyingError:nil];
        }
        return NO;
    }
    
    NSString *finalId = [NSString stringWithFormat:@"%@-forge-%@", vanillaVer, forgeVer];
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", 
                         [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], finalId, finalId];
    
    // Create directory structure
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent] 
                                withIntermediateDirectories:YES 
                                                 attributes:nil 
                                                      error:&dirError];
    if (dirError) {
        if (error) {
            *error = [self errorWithCode:ModpackUtilsErrorCodeJsonCreationFailed
                                 message:[NSString stringWithFormat:@"Failed to create directory structure: %@", dirError.localizedDescription]
                         underlyingError:dirError];
        }
        return NO;
    }
    
    // Create JSON content
    NSDictionary *forgeDict = @{
        @"id": finalId,
        @"type": @"custom",
        @"minecraft": vanillaVer,
        @"loader": @"forge",
        @"loaderVersion": forgeVer
    };
    
    NSError *writeError = saveJSONToFile(forgeDict, jsonPath);
    if (writeError) {
        if (error) {
            *error = [self errorWithCode:ModpackUtilsErrorCodeJsonCreationFailed
                                 message:[NSString stringWithFormat:@"Failed to write Forge JSON: %@", writeError.localizedDescription]
                         underlyingError:writeError];
        }
        return NO;
    }
    
    NSLog(@"[ModpackUtils] Successfully created Forge JSON at %@", jsonPath);
    return YES;
}

+ (BOOL)createFabricJSON:(NSString *)fabricString error:(NSError **)error {
    if (!fabricString.length) {
        if (error) {
            *error = [self errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                 message:@"Missing fabric version string"
                         underlyingError:nil];
        }
        return NO;
    }
    
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", 
                         [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], fabricString, fabricString];
    
    // Create directory structure
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent] 
                                withIntermediateDirectories:YES 
                                                 attributes:nil 
                                                      error:&dirError];
    if (dirError) {
        if (error) {
            *error = [self errorWithCode:ModpackUtilsErrorCodeJsonCreationFailed
                                 message:[NSString stringWithFormat:@"Failed to create directory structure: %@", dirError.localizedDescription]
                         underlyingError:dirError];
        }
        return NO;
    }
    
    // Extract Minecraft version from the fabricString if possible
    NSArray *components = [fabricString componentsSeparatedByString:@"-"];
    NSString *mcVersion = @"";
    
    if ([fabricString hasPrefix:@"fabric-loader"] && components.count >= 3) {
        // Format: fabric-loader-0.14.22-1.20.1
        mcVersion = components.lastObject;
    }
    
    // Create JSON content
    NSDictionary *fabricDict = @{
        @"id": fabricString,
        @"type": @"custom",
        @"loader": @"fabric",
        @"loaderVersion": fabricString,
        @"minecraft": mcVersion.length > 0 ? mcVersion : @""
    };
    
    NSError *writeError = saveJSONToFile(fabricDict, jsonPath);
    if (writeError) {
        if (error) {
            *error = [self errorWithCode:ModpackUtilsErrorCodeJsonCreationFailed
                                 message:[NSString stringWithFormat:@"Failed to write Fabric JSON: %@", writeError.localizedDescription]
                         underlyingError:writeError];
        }
        return NO;
    }
    
    NSLog(@"[ModpackUtils] Successfully created Fabric JSON at %@", jsonPath);
    return YES;
}

+ (BOOL)createNeoForgeJSON:(NSString *)vanillaVer loaderVersion:(NSString *)neoforgeVer error:(NSError **)error {
    if (!vanillaVer.length || !neoforgeVer.length) {
        if (error) {
            *error = [self errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                 message:@"Missing version information for NeoForge JSON creation"
                         underlyingError:nil];
        }
        return NO;
    }
    
    NSString *finalId = [NSString stringWithFormat:@"%@-neoforge-%@", vanillaVer, neoforgeVer];
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", 
                         [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], finalId, finalId];
    
    // Create directory structure
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent] 
                                withIntermediateDirectories:YES 
                                                 attributes:nil 
                                                      error:&dirError];
    if (dirError) {
        if (error) {
            *error = [self errorWithCode:ModpackUtilsErrorCodeJsonCreationFailed
                                 message:[NSString stringWithFormat:@"Failed to create directory structure: %@", dirError.localizedDescription]
                         underlyingError:dirError];
        }
        return NO;
    }
    
    // Create JSON content
    NSDictionary *neoforgeDict = @{
        @"id": finalId,
        @"type": @"custom",
        @"minecraft": vanillaVer,
        @"loader": @"neoforge",
        @"loaderVersion": neoforgeVer
    };
    
    NSError *writeError = saveJSONToFile(neoforgeDict, jsonPath);
    if (writeError) {
        if (error) {
            *error = [self errorWithCode:ModpackUtilsErrorCodeJsonCreationFailed
                                 message:[NSString stringWithFormat:@"Failed to write NeoForge JSON: %@", writeError.localizedDescription]
                         underlyingError:writeError];
        }
        return NO;
    }
    
    NSLog(@"[ModpackUtils] Successfully created NeoForge JSON at %@", jsonPath);
    return YES;
}

#pragma mark - Profile Setup

+ (NSString *)setupProfileWithManifest:(NSDictionary *)manifestDict destPath:(NSString *)destPath finalVersionString:(NSString *)finalVersionString {
    // Verify manifest is valid
    NSError *verifyError = nil;
    if (![self verifyManifest:manifestDict error:&verifyError]) {
        NSLog(@"[ModpackUtils] Invalid manifest: %@", verifyError.localizedDescription);
        return nil;
    }
    
    // Create a profile for this modpack
    NSString *profileName = manifestDict[@"name"] ?: @"Unknown Modpack";
    if (profileName.length == 0) {
        NSLog(@"[ModpackUtils] Invalid profile name");
        return nil;
    }
    
    // Create a unique gameDir for this profile
    NSString *safeProfileName = [profileName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
    safeProfileName = [safeProfileName stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    
    NSString *gameDir = [NSString stringWithFormat:@"./profiles/%@", safeProfileName];
    
    // Create profile with icon
    NSString *iconBase64 = @"";
    NSString *iconPath = [destPath stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:iconPath];
    if (iconData) {
        iconBase64 = [iconData base64EncodedStringWithOptions:0];
    }
    
    NSDictionary *profileInfo = @{
        @"gameDir": gameDir,
        @"name": profileName,
        @"lastVersionId": finalVersionString,
        @"icon": iconBase64.length > 0 ? [NSString stringWithFormat:@"data:image/png;base64,%@", iconBase64] : @""
    };
    
    // Ensure the profile directory exists
    BOOL success = [PLProfiles ensureProfileDirectoryExists:safeProfileName gameDir:gameDir];
    if (!success) {
        NSLog(@"[ModpackUtils] Failed to create profile directory");
        return nil;
    }
    
    // Update the profile
    dispatch_async(dispatch_get_main_queue(), ^{
        PLProfiles.current.profiles[safeProfileName] = [profileInfo mutableCopy];
        PLProfiles.current.selectedProfileName = safeProfileName;
        [PLProfiles.current save];
    });
    
    // Create installation log
    NSString *logContent = [NSString stringWithFormat:@"Modpack installation completed\n"
                          "Name: %@\n"
                          "Version: %@\n"
                          "Directory: %@\n"
                          "Profile ID: %@\n"
                          "Date: %@",
                          profileName,
                          manifestDict[@"version"] ?: @"Unknown",
                          destPath,
                          finalVersionString,
                          [NSDate date]];
    
    [logContent writeToFile:[destPath stringByAppendingPathComponent:@"modpack_install.log"]
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:nil];
    
    return safeProfileName;
}

#pragma mark - Manifest Verification

+ (BOOL)verifyManifest:(NSDictionary *)manifest error:(NSError **)error {
    // Check basic structure
    if (![manifest isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [self errorWithCode:ModpackUtilsErrorCodeInvalidManifest
                                 message:@"Manifest is not a valid dictionary"
                         underlyingError:nil];
        }
        return NO;
    }
    
    // Check for name
    if (!manifest[@"name"] || ![manifest[@"name"] isKindOfClass:[NSString class]]) {
        if (error) {
            *error = [self errorWithCode:ModpackUtilsErrorCodeInvalidManifest
                                 message:@"Manifest is missing a valid name"
                         underlyingError:nil];
        }
        return NO;
    }
    
    // For CurseForge style manifests
    if (manifest[@"manifestType"]) {
        if (![manifest[@"manifestType"] isEqualToString:@"minecraftModpack"]) {
            if (error) {
                *error = [self errorWithCode:ModpackUtilsErrorCodeInvalidManifest
                                     message:[NSString stringWithFormat:@"Invalid manifestType: %@", manifest[@"manifestType"]]
                             underlyingError:nil];
            }
            return NO;
        }
        
        if (![manifest[@"manifestVersion"] isEqual:@(1)]) {
            if (error) {
                *error = [self errorWithCode:ModpackUtilsErrorCodeInvalidManifest
                                     message:[NSString stringWithFormat:@"Unsupported manifestVersion: %@", manifest[@"manifestVersion"]]
                             underlyingError:nil];
            }
            return NO;
        }
        
        if (!manifest[@"minecraft"] || ![manifest[@"minecraft"] isKindOfClass:[NSDictionary class]]) {
            if (error) {
                *error = [self errorWithCode:ModpackUtilsErrorCodeInvalidManifest
                                     message:@"Missing minecraft key"
                             underlyingError:nil];
            }
            return NO;
        }
        
        NSDictionary *minecraft = manifest[@"minecraft"];
        if (!minecraft[@"version"] || ![minecraft[@"version"] isKindOfClass:[NSString class]]) {
            if (error) {
                *error = [self errorWithCode:ModpackUtilsErrorCodeInvalidManifest
                                     message:@"Missing minecraft.version"
                             underlyingError:nil];
            }
            return NO;
        }
    }
    
    // For Modrinth style manifests
    else if (manifest[@"dependencies"]) {
        if (!manifest[@"dependencies"][@"minecraft"]) {
            if (error) {
                *error = [self errorWithCode:ModpackUtilsErrorCodeInvalidManifest
                                     message:@"Missing dependencies.minecraft"
                             underlyingError:nil];
            }
            return NO;
        }
    }
    // At least one must be true - either CurseForge or Modrinth style
    else {
        if (error) {
            *error = [self errorWithCode:ModpackUtilsErrorCodeInvalidManifest
                                 message:@"Manifest doesn't match any known format"
                         underlyingError:nil];
        }
        return NO;
    }
    
    return YES;
}

@end
