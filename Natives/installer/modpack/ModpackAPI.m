#import "AFNetworking.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModpackAPI.h"
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

#pragma mark - Abstract methods

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSAssert(NO, @"Subclasses must override -loadDetailsOfMod:");
    [self doesNotRecognizeSelector:_cmd];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary *)searchFilters previousPageResult:(NSMutableArray *)prevResult {
    NSAssert(NO, @"Subclasses must override -searchModWithFilters:previousPageResult:");
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSAssert(NO, @"Subclasses must override -downloader:submitDownloadTasksFromPackage:toPath:");
    [self doesNotRecognizeSelector:_cmd];
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
            NSError *error = [NSError errorWithDomain:@"ModpackAPIErrorDomain" 
                                                 code:100 
                                             userInfo:@{NSLocalizedDescriptionKey: @"Invalid endpoint"}];
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
        if (completion) {
            completion(nil, error);
        }
    }];
}

#pragma mark - Modpack installation

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    if (!modDetail) {
        NSLog(@"[ModpackAPI] Cannot install modpack: nil modDetail");
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
    });
}

@end
