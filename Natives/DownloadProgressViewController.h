#import <UIKit/UIKit.h>
#import "MinecraftResourceDownloadTask.h"
#import "DownloadProgressManager.h"

// Define task types for better UI presentation
typedef NS_ENUM(NSInteger, DownloadTaskType) {
    DownloadTaskTypeFile = 0,
    DownloadTaskTypeExtraction = 1,
    DownloadTaskTypeSetup = 2,
    DownloadTaskTypeComplete = 3
};

@interface DownloadProgressViewController : UITableViewController
@property MinecraftResourceDownloadTask* task;
@property (nonatomic, assign) BOOL needsFullTableReload; // Flag for tracking when full reload is needed

- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task;

/**
 * Closes the view controller. If a download is in progress,
 * shows a confirmation dialog before dismissing.
 */
- (void)actionClose;

/**
 * Removes all progress observers to prevent memory leaks
 */
- (void)removeAllProgressObservers;

/**
 * Removes a specific progress observer
 * @param progress The progress object to stop observing
 */
- (void)removeProgressObserver:(NSProgress *)progress;

/**
 * Refreshes the UI with current progress information
 */
- (void)refreshProgressUI;

@end
