#import <UIKit/UIKit.h>

@class ModpackAPI;

typedef NS_ENUM(NSInteger, DownloadPhase) {
    DownloadPhaseNone = 0,
    DownloadPhasePreparation,
    DownloadPhaseVersionMetadata,
    DownloadPhaseAssetMetadata,
    DownloadPhaseLibraries,
    DownloadPhaseAssets,
    DownloadPhaseModpackDownload,
    DownloadPhaseModpackExtraction,
    DownloadPhaseModpackSetup,
    DownloadPhaseComplete
};

@interface MinecraftResourceDownloadTask : NSObject
@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary* metadata;
@property(nonatomic, copy) void(^handleError)(void);
@property(nonatomic, assign) DownloadPhase currentPhase;
@property(nonatomic, copy) NSString *phaseDescription;
@property(nonatomic, assign) NSInteger currentPhaseItemsTotal;
@property(nonatomic, assign) NSInteger currentPhaseItemsCompleted;

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path;
- (void)finishDownloadWithErrorString:(NSString *)error;

- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

// method to update phase description based on current state
- (void)updatePhaseDescription;

@end
