#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Notification names
extern NSString * const DMDownloadStageChangedNotification;
extern NSString * const DMProgressUpdatedNotification;
extern NSString * const DMFileProgressUpdatedNotification;
extern NSString * const DMDownloadCompletedNotification;

typedef NS_ENUM(NSInteger, DownloadStage) {
    DownloadStagePreparation = 0,      // Initial stage for setup
    DownloadStageMetadata = 1,         // Downloading version metadata
    DownloadStageLibraries = 2,        // Downloading libraries
    DownloadStageAssets = 3,           // Downloading assets
    DownloadStageClientJar = 4,        // Downloading client JAR
    DownloadStageExtraction = 5,       // Extracting files (mainly for modpacks)
    DownloadStageSetup = 6,            // Setting up profiles, config, etc.
    DownloadStageComplete = 7,         // All tasks complete
    DownloadStageError = 8             // Error occurred
};

// File item for tracking individual downloads
@interface DownloadFileItem : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, assign) NSUInteger size;
@property (nonatomic, assign) NSUInteger completed;
@property (nonatomic, assign) BOOL isComplete;
@property (nonatomic, assign) BOOL isWaiting;
@property (nonatomic, assign) BOOL hasError;
@property (nonatomic, strong, nullable) NSString *errorMessage;
@property (nonatomic, strong) NSProgress *progress;
@end

@interface DownloadProgressManager : NSObject

// Core properties
@property (nonatomic, readonly) DownloadStage currentStage;
@property (nonatomic, readonly) NSProgress *overallProgress;
@property (nonatomic, readonly) NSProgress *currentStageProgress;
@property (nonatomic, readonly) NSMutableArray<DownloadFileItem *> *fileItems;
@property (nonatomic, copy) NSString *statusMessage;
@property (nonatomic, assign, readonly) BOOL isComplete;
@property (nonatomic, assign, readonly) BOOL isModpackInstall;
@property (nonatomic, assign, readonly) BOOL isError;
@property (nonatomic, copy, readonly, nullable) NSString *errorMessage;

// Statistics
@property (nonatomic, assign, readonly) NSInteger successfulDownloads;
@property (nonatomic, assign, readonly) NSInteger totalDownloads;
@property (nonatomic, assign, readonly) NSUInteger totalBytes;
@property (nonatomic, assign, readonly) NSUInteger completedBytes;
@property (nonatomic, strong, readonly) NSDate *startTime;
@property (nonatomic, strong, readonly, nullable) NSDate *endTime;

// Metadata
@property (nonatomic, strong) NSMutableDictionary *metadata;

// Singleton access
+ (instancetype)sharedManager;

// Lifecycle methods
- (void)beginDownload:(BOOL)isModpack;
- (void)advanceToStage:(DownloadStage)stage withTotalItems:(NSInteger)totalItems;
- (void)completeCurrentStage;
- (void)cancelDownload;
- (void)finishDownloadWithSuccess:(BOOL)success;
- (void)failWithError:(NSString *)errorMessage;
- (void)reset;

// File tracking methods
- (DownloadFileItem *)addFileWithPath:(NSString *)path 
                          displayName:(NSString *)displayName 
                                 size:(NSUInteger)size;
- (void)updateFile:(DownloadFileItem *)item withBytesCompleted:(NSUInteger)bytes;
- (void)completeFile:(DownloadFileItem *)item;
- (void)failFile:(DownloadFileItem *)item withError:(NSString *)errorMessage;
- (DownloadFileItem *)fileItemForPath:(NSString *)path;

// Progress helpers
- (void)updateOverallProgressWithCompletedBytes:(NSUInteger)bytes;
- (void)updateStageProgress:(double)fractionCompleted;
- (NSString *)formattedOverallProgress;
- (NSString *)formattedTimeRemaining;
- (NSString *)formattedTransferRate;

@end

NS_ASSUME_NONNULL_END
