#import "AFNetworking.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModpackAPI.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"
#import "utils.h"

@implementation ModpackAPI

#pragma mark - Initialization

- (instancetype)initWithURL:(NSString *)url {
    if (self = [super init]) {
        _baseURL = [url copy];
        _reachedLastPage = NO;
    }
    return self;
}

#pragma mark - Network requests

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    if (!endpoint) {
        return nil;
    }
    
    __block id result = nil;
    __block NSError *requestError = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    
    [manager GET:url parameters:params headers:nil progress:nil success:^(NSURLSessionTask *task, id responseObject) {
        result = responseObject;
        dispatch_group_leave(group);
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        requestError = error;
        self.lastError = error;
        dispatch_group_leave(group);
    }];
    
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    
    if (requestError) {
        NSLog(@"[ModpackAPI] GET request to %@ failed: %@", endpoint, requestError);
    }
    
    return result;
}

- (void)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params completion:(void (^)(id, NSError *))completion {
    if (!endpoint) {
        if (completion) {
            NSError *error = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                                 message:@"Invalid endpoint"
                                         underlyingError:nil];
            completion(nil, error);
        }
        return;
    }
    
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    
    [manager GET:url parameters:params headers:nil progress:nil success:^(NSURLSessionTask *task, id responseObject) {
        if (completion) {
            completion(responseObject, nil);
        }
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        NSLog(@"[ModpackAPI] Async GET request to %@ failed: %@", endpoint, error);
        
        // Determine the type of error
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)operation.response;
        ModpackUtilsErrorCode errorCode = ModpackUtilsErrorCodeNetworkError;
        NSString *errorMessage = @"A network error occurred";
        
        if (httpResponse) {
            if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) {
                errorCode = ModpackUtilsErrorCodeAuthenticationFailed;
                errorMessage = @"Authentication failed";
            } else if (httpResponse.statusCode == 404) {
                errorCode = ModpackUtilsErrorCodeInvalidParameters;
                errorMessage = @"The requested resource was not found";
            } else if (httpResponse.statusCode >= 500) {
                errorCode = ModpackUtilsErrorCodeNetworkError;
                errorMessage = @"A server error occurred";
            }
        }
        
        NSError *wrappedError = [ModpackUtils errorWithCode:errorCode 
                                                    message:errorMessage 
                                            underlyingError:error];
        
        if (completion) {
            completion(nil, wrappedError);
        }
    }];
}

#pragma mark - Abstract methods

- (void)searchModWithFilters:(NSDictionary *)filters previousPageResult:(NSMutableArray *)prevResult completion:(void (^)(NSMutableArray *, NSError *))completion {
    // Abstract method - subclasses must implement
    NSError *error = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                         message:@"Subclasses must override searchModWithFilters method"
                                 underlyingError:nil];
    if (completion) {
        completion(nil, error);
    }
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError *))completion {
    // Abstract method - subclasses must implement
    NSError *error = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                         message:@"Subclasses must override loadDetailsOfMod method"
                                 underlyingError:nil];
    if (completion) {
        completion(error);
    }
}

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion completion:(void (^)(NSError *))completion {
    if (!modDetail) {
        NSError *error = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                            message:@"Cannot install modpack: nil modDetail"
                                    underlyingError:nil];
        if (completion) {
            completion(error);
        }
        return;
    }
    
    NSDictionary *userInfo = @{
        @"detail": modDetail,
        @"index": @(selectedVersion)
    };
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"InstallModpack" 
                                                         object:self 
                                                       userInfo:userInfo];
        if (completion) {
            completion(nil);
        }
    });
}

- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion completion:(void (^)(NSError *))completion {
    if (!modDetail) {
        NSError *error = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                            message:@"Cannot install mod: nil modDetail"
                                    underlyingError:nil];
        if (completion) {
            completion(error);
        }
        return;
    }
    
    // Handle the fact that different API implementations might use different URL formats
    NSArray *versionUrls = modDetail[@"versionUrls"];
    if (!versionUrls || selectedVersion >= versionUrls.count) {
        NSError *error = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                            message:@"Invalid version index for mod installation"
                                    underlyingError:nil];
        if (completion) {
            completion(error);
        }
        return;
    }
    
    // Post the notification for mod installation
    // This notification is expected to be handled by the app's controllers
    NSDictionary *userInfo = @{
        @"detail": modDetail,
        @"index": @(selectedVersion)
    };
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"InstallMod" 
                                                         object:self 
                                                       userInfo:userInfo];
        if (completion) {
            completion(nil);
        }
    });
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath completion:(void (^)(NSError *))completion {
    // Abstract method - subclasses must implement
    NSError *error = [ModpackUtils errorWithCode:ModpackUtilsErrorCodeInvalidParameters
                                         message:@"Subclasses must override submitDownloadTasksFromPackage method"
                                 underlyingError:nil];
    if (completion) {
        completion(error);
    }
}

@end
