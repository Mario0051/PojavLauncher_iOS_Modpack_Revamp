#import <UIKit/UIKit.h>
#import "MinecraftResourceDownloadTask.h"

/**
 * View controller for displaying download progress
 * Provides detailed information about ongoing downloads
 */
@interface DownloadProgressViewController : UITableViewController

/**
 * The download task being monitored
 */
@property MinecraftResourceDownloadTask* task;

/**
 * Initializes a new download progress view controller with the specified task
 * @param task The download task to display progress for
 * @return An initialized DownloadProgressViewController instance
 */
- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task;

/**
 * Closes the progress view controller
 * Shows a confirmation dialog if download is in progress
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
 * Called periodically to update display
 */
- (void)refreshProgressUI;

@end
