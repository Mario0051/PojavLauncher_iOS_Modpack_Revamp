#import <Foundation/Foundation.h>

@interface PLProfiles : NSObject

@property(nonatomic) NSString *profilePath;
@property(nonatomic) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *> *profileDict;

+ (PLProfiles *)current;
+ (void)updateCurrent;

//+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key;
+ (NSString *)resolveKeyForCurrentProfile:(id)key;

// New methods for profile isolation
+ (NSString *)uniqueGameDirForProfileName:(NSString *)profileName;
+ (NSString *)fullPathForProfileWithName:(NSString *)profileName gameDir:(NSString *)gameDir;
+ (BOOL)ensureProfileDirectoryExists:(NSString *)profileName gameDir:(NSString *)gameDir;
+ (BOOL)renameProfileDirectory:(NSString *)oldProfileName to:(NSString *)newProfileName gameDir:(NSString *)oldGameDir;

- (id)initWithCurrentInstance;
- (NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *)profiles;

- (NSMutableDictionary<NSString *, NSString *> *)selectedProfile;
- (NSString *)selectedProfileName;
- (void)setSelectedProfileName:(NSString *)name;
- (void)save;

@end
