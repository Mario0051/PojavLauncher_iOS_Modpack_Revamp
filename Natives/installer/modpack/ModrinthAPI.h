#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

@interface ModrinthAPI : ModpackAPI

@property(nonatomic, strong) NSString *userAgent;
@property(nonatomic, strong) NSURLSession *session;

@end
