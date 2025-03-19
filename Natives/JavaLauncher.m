#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <unistd.h>
#include <pthread.h>
#include <dispatch/dispatch.h>

#include "utils.h"

#import "ios_uikit_bridge.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"

#define fm NSFileManager.defaultManager
#define CACHE_DIR [NSString stringWithFormat:@"%s/cache", getenv("POJAV_HOME")]
#define MEMORY_POOL_SIZE (1024 * 1024) // 1MB memory pool

extern char **environ;

// Use strong references for ARC compatibility
static NSString * __strong cachedBootClasspath = nil;
static NSString * __strong cachedClasspath = nil;
static NSMutableDictionary * __strong pathCache = nil;
static NSMutableDictionary * __strong fileExistsCache = nil;
static NSMutableDictionary * __strong jreOptionsCache = nil;
static dispatch_once_t cacheInitToken;

// Memory pool for temporary allocations
static char *memoryPool = NULL;
static size_t memoryPoolOffset = 0;
static pthread_mutex_t memoryPoolMutex = PTHREAD_MUTEX_INITIALIZER;

// Forward declarations
void initCaches(void);
void *allocateFromPool(size_t size);
void resetMemoryPool(void);
void mapFileIntoMemory(const char *path, void **mapped_data, size_t *mapped_size);
void unmapFileFromMemory(void *mapped_data, size_t mapped_size);

void initCaches(void) {
    static BOOL initialized = NO;
    
    // We need to manually check to avoid calling dispatch_once repeatedly
    if (!initialized) {
        dispatch_once(&cacheInitToken, ^{
            pathCache = [[NSMutableDictionary alloc] initWithCapacity:20];
            fileExistsCache = [[NSMutableDictionary alloc] initWithCapacity:50];
            jreOptionsCache = [[NSMutableDictionary alloc] initWithCapacity:10];
            
            // Initialize memory pool
            memoryPool = malloc(MEMORY_POOL_SIZE);
            if (memoryPool) {
                memset(memoryPool, 0, MEMORY_POOL_SIZE);
            }
            
            // Create cache directory
            [fm createDirectoryAtPath:CACHE_DIR withIntermediateDirectories:YES attributes:nil error:nil];
            
            initialized = YES;
        });
    }
}

void *allocateFromPool(size_t size) {
    if (!memoryPool) return malloc(size);
    
    pthread_mutex_lock(&memoryPoolMutex);
    
    // Ensure 8-byte alignment
    memoryPoolOffset = (memoryPoolOffset + 7) & ~7;
    
    if (memoryPoolOffset + size > MEMORY_POOL_SIZE) {
        // Pool is full, fall back to regular malloc
        pthread_mutex_unlock(&memoryPoolMutex);
        return malloc(size);
    }
    
    void *result = memoryPool + memoryPoolOffset;
    memoryPoolOffset += size;
    
    pthread_mutex_unlock(&memoryPoolMutex);
    return result;
}

void resetMemoryPool(void) {
    pthread_mutex_lock(&memoryPoolMutex);
    memoryPoolOffset = 0;
    pthread_mutex_unlock(&memoryPoolMutex);
}

void mapFileIntoMemory(const char *path, void **mapped_data, size_t *mapped_size) {
    int fd = open(path, O_RDONLY);
    if (fd == -1) {
        *mapped_data = NULL;
        *mapped_size = 0;
        return;
    }
    
    struct stat st;
    if (fstat(fd, &st) == -1) {
        close(fd);
        *mapped_data = NULL;
        *mapped_size = 0;
        return;
    }
    
    void *data = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    
    if (data == MAP_FAILED) {
        *mapped_data = NULL;
        *mapped_size = 0;
        return;
    }
    
    *mapped_data = data;
    *mapped_size = st.st_size;
}

void unmapFileFromMemory(void *mapped_data, size_t mapped_size) {
    if (mapped_data && mapped_size > 0) {
        munmap(mapped_data, mapped_size);
    }
}

void init_loadDefaultEnv() {
    /* Define default env */

    // Silent Caciocavallo NPE error in locating Android-only lib
    setenv("LD_LIBRARY_PATH", "", 1);

    // Disable overloaded functions hack for Minecraft 1.17+
    setenv("LIBGL_NOINTOVLHACK", "1", 1);

    // Fix white color on banner and sheep, since GL4ES 1.1.5
    setenv("LIBGL_NORMALIZE", "1", 1);

    // Override OpenGL version to 4.1 for Zink
    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);

    // Runs JVM in a separate thread
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);
    
    // JIT compilation optimizations
    setenv("JAVA_COMPILER", "NONE", 1); // Disable JIT for startup, will be re-enabled later
}

void init_loadCustomEnv() {
    NSString *envvars = getPrefObject(@"java.env_variables");
    if (envvars == nil) return;
    NSLog(@"[JavaLauncher] Reading custom environment variables");
    
    // Pre-split for performance
    NSArray *lines = [envvars componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    
    for (NSString *line in lines) {
        if (![line containsString:@"="]) {
            NSLog(@"[JavaLauncher] Warning: skipped empty value custom env variable: %@", line);
            continue;
        }
        NSRange range = [line rangeOfString:@"="];
        NSString *key = [line substringToIndex:range.location];
        NSString *value = [line substringFromIndex:range.location+range.length];
        setenv(key.UTF8String, value.UTF8String, 1);
    }
}

void init_loadCustomJvmFlags(int* argc, const char** argv) {
    NSString *jvmargs = [PLProfiles resolveKeyForCurrentProfile:@"javaArgs"];
    if (jvmargs == nil) return;
    
    // Check cache first
    NSString *profileName = [PLProfiles current].selectedProfileName;
    NSString *cacheKey = [NSString stringWithFormat:@"%@_jvmargs", profileName];
    
    // Use cached args if available
    if (jreOptionsCache[cacheKey]) {
        NSArray *cachedArgs = jreOptionsCache[cacheKey];
        for (NSString *arg in cachedArgs) {
            ++*argc;
            argv[*argc] = arg.UTF8String;
        }
        return;
    }
    
    // Make the separator happy
    jvmargs = [jvmargs stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    jvmargs = [@" " stringByAppendingString:jvmargs];

    NSLog(@"[JavaLauncher] Reading custom JVM flags");
    NSArray *argsToPurge = @[@"Xms", @"Xmx", @"d32", @"d64"];
    
    // Pre-split for efficiency
    NSArray *allArgs = [jvmargs componentsSeparatedByString:@" -"];
    NSMutableArray *validArgs = [NSMutableArray arrayWithCapacity:allArgs.count];
    
    for (NSString *arg in allArgs) {
        NSString *jvmarg = [arg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (jvmarg.length == 0) continue;
        BOOL ignore = NO;
        for (NSString *argToPurge in argsToPurge) {
            if ([jvmarg hasPrefix:argToPurge]) {
                NSLog(@"[JavaLauncher] Ignored JVM flag: -%@", jvmarg);
                ignore = YES;
                break;
            }
        }
        if (ignore) continue;

        // Store the valid argument
        NSString *fullArg = [@"-" stringByAppendingString:jvmarg];
        [validArgs addObject:fullArg];
        
        ++*argc;
        argv[*argc] = fullArg.UTF8String;
    }
    
    // Cache the valid arguments
    jreOptionsCache[cacheKey] = validArgs;
}

BOOL checkFileExistsWithCache(NSString *path) {
    // Initialize caches if needed
    initCaches();
    
    // Check cache first
    NSNumber *cachedResult = fileExistsCache[path];
    if (cachedResult) {
        return [cachedResult boolValue];
    }
    
    // Check file system and cache result
    BOOL exists = [fm fileExistsAtPath:path];
    fileExistsCache[path] = @(exists);
    return exists;
}

NSString* buildClasspathForDirectory(NSString *dirPath) {
    // Initialize caches if needed
    initCaches();
    
    // Check path cache first
    if (pathCache[dirPath]) {
        return pathCache[dirPath];
    }
    
    // Check for cached result
    NSString *cacheKey = [NSString stringWithFormat:@"classpath_%@", dirPath.lastPathComponent];
    NSString *cachePath = [CACHE_DIR stringByAppendingPathComponent:cacheKey];
    
    // Check file modification time to validate cache
    NSError *error;
    NSDictionary *dirAttrs = [fm attributesOfItemAtPath:dirPath error:&error];
    NSDictionary *cacheAttrs = [fm attributesOfItemAtPath:cachePath error:nil];
    
    if (!error && cacheAttrs) {
        NSDate *dirModDate = dirAttrs[NSFileModificationDate];
        NSDate *cacheModDate = cacheAttrs[NSFileModificationDate];
        
        // If directory hasn't been modified since cache was created, use cache
        if ([dirModDate compare:cacheModDate] != NSOrderedDescending) {
            NSString *cachedPath = [NSString stringWithContentsOfFile:cachePath encoding:NSUTF8StringEncoding error:nil];
            if (cachedPath) {
                // Store in memory cache
                pathCache[dirPath] = cachedPath;
                return cachedPath;
            }
        }
    }
    
    // Build classpath by scanning directory
    NSMutableString *classpath = [NSMutableString string];
    
    // Use memory-mapped directory reading for better performance
    DIR *dir = opendir(dirPath.UTF8String);
    if (dir) {
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            // Fast string check for .jar extension
            char *name = entry->d_name;
            size_t len = strlen(name);
            if (len > 4 && strcmp(name + len - 4, ".jar") == 0) {
                if (classpath.length > 0) {
                    [classpath appendString:@":"];
                }
                [classpath appendFormat:@"%@/%s", dirPath, name];
            }
        }
        closedir(dir);
    }
    
    // Cache the result for future use
    [classpath writeToFile:cachePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    
    // Store in memory cache
    pathCache[dirPath] = classpath;
    return classpath;
}

int launchJVM(NSString *username, id launchTarget, int width, int height, int minVersion) {
    NSLog(@"[JavaLauncher] Beginning JVM launch");
    
    // Initialize all caches upfront
    initCaches();

    if (NSBundle.mainBundle.infoDictionary[@"LCDataUUID"]) {
        NSDebugLog(@"[JavaLauncher] Running in LiveContainer, skipping dyld patch");
    } else {
        // Activate Library Validation bypass for external runtime and dylibs (JNA, etc)
        init_bypassDyldLibValidation();
    }

    // Reset memory pool for this launch
    resetMemoryPool();

    // Start parallel initialization tasks
    dispatch_group_t initGroup = dispatch_group_create();
    
    // Task 1: Load environment variables (can be done in parallel)
    dispatch_group_async(initGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        init_loadDefaultEnv();
        init_loadCustomEnv();
    });
    
    // Continue with other initialization that doesn't depend on environment
    BOOL launchJar = NO;
    NSString *gameDir;
    NSString *defaultJRETag;
    NSString *javaHome = nil;
    
    // Determine Java version and game directory
    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        // Get preferred Java version from current profile
        int preferredJavaVersion = [PLProfiles resolveKeyForCurrentProfile:@"javaVersion"].intValue;
        if (preferredJavaVersion > 0) {
            if (minVersion > preferredJavaVersion) {
                NSLog(@"[JavaLauncher] Profile's preferred Java version (%d) does not meet the minimum version (%d), dropping request", preferredJavaVersion, minVersion);
            } else {
                NSDebugLog(@"[PLProfiles] Applying javaVersion");
                minVersion = preferredJavaVersion;
            }
        }
        if (minVersion <= 8) {
            defaultJRETag = @"1_16_5_older";
        } else {
            defaultJRETag = @"1_17_newer";
        }

        // Task 2: Setup POJAV_RENDERER (can run in parallel)
        dispatch_group_async(initGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
            NSLog(@"[JavaLauncher] RENDERER is set to %@\n", renderer);
            setenv("POJAV_RENDERER", renderer.UTF8String, 1);
        });
        
        // Setup gameDir using the profile's gameDir
        NSString *profileName = [PLProfiles current].selectedProfileName;
        NSMutableDictionary *profile = [PLProfiles current].selectedProfile;
        NSString *profileGameDir = profile[@"gameDir"];
        
        // Get the full path to the profile directory
        gameDir = [PLProfiles fullPathForProfileWithName:profileName gameDir:profileGameDir];
        
        // Task 3: Ensure the profile directory exists (can run in parallel)
        dispatch_group_async(initGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [PLProfiles ensureProfileDirectoryExists:profileName gameDir:profileGameDir];
        });
    } else {
        defaultJRETag = @"execute_jar";
        gameDir = @(getenv("POJAV_GAME_DIR"));
        launchJar = YES;
    }
    
    // Task 4: Get Java Home (depends on minVersion, which we have now)
    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);
    javaHome = getSelectedJavaHome(defaultJRETag, minVersion);

    // Wait for all initialization tasks to complete
    dispatch_group_wait(initGroup, DISPATCH_TIME_FOREVER);
    
    // Check if we have a valid Java Home
    if (javaHome == nil) {
        UIKit_returnToSplitView();
        BOOL isExecuteJar = [defaultJRETag isEqualToString:@"execute_jar"];
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil),
            isExecuteJar ? [launchTarget lastPathComponent] : PLProfiles.current.selectedProfile[@"lastVersionId"], minVersion]);
        return 1;
    } else if ([javaHome hasPrefix:@(getenv("POJAV_HOME"))]) {
        // Symlink libawt_xawt.dylib - use dispatch_once for thread safety
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            NSString *dest = [NSString stringWithFormat:@"%@/lib/libawt_xawt.dylib", javaHome];
            NSString *source = [NSString stringWithFormat:@"%@/Frameworks/libawt_xawt.dylib", NSBundle.mainBundle.bundlePath];
            
            // Only create symlink if it doesn't exist or points to wrong location
            if (!checkFileExistsWithCache(dest)) {
                NSError *error;
                [fm createSymbolicLinkAtPath:dest withDestinationPath:source error:&error];
                if (error) {
                    NSLog(@"[JavaLauncher] Symlink libawt_xawt.dylib failed: %@", error.localizedDescription);
                }
            }
        });
    }

    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    NSLog(@"[JavaLauncher] JAVA_HOME has been set to %@", javaHome);

    // Optimize memory allocation
    int allocmem;
    if (getPrefBool(@"java.auto_ram")) {
        CGFloat autoRatio = getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25;
        allocmem = roundf((NSProcessInfo.processInfo.physicalMemory / 1048576) * autoRatio);
    } else {
        allocmem = getPrefInt(@"java.allocated_memory");
    }
    NSLog(@"[JavaLauncher] Max RAM allocation is set to %d MB", allocmem);

    int margc = -1;
    const char *margv[1000];

    // Essential JVM arguments
    margv[++margc] = [NSString stringWithFormat:@"%@/bin/java", javaHome].UTF8String;
    margv[++margc] = "-XstartOnFirstThread";
    if (!launchJar) {
        margv[++margc] = "-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader";
    }
    
    // Memory settings - basic heap configuration
    margv[++margc] = "-Xms128M";
    margv[++margc] = [NSString stringWithFormat:@"-Xmx%dM", allocmem].UTF8String;
    
    // Memory management optimizations 
    // Start with experimental options unlock - MUST be before G1GC settings
    margv[++margc] = "-XX:+UnlockExperimentalVMOptions";
    // G1GC settings
    margv[++margc] = "-XX:+UseG1GC";  // Use G1 garbage collector for better performance
    margv[++margc] = "-XX:G1NewSizePercent=20";  // Allocate more space for young generation
    margv[++margc] = "-XX:G1ReservePercent=20";  // Reserve memory to avoid full GCs
    margv[++margc] = "-XX:MaxGCPauseMillis=50";  // Target maximum GC pause time
    margv[++margc] = "-XX:G1HeapRegionSize=4M";  // Optimize heap region size
    margv[++margc] = "-XX:InitiatingHeapOccupancyPercent=15";  // Start GC earlier
    margv[++margc] = "-XX:+DisableExplicitGC";  // Prevent System.gc() calls from triggering a full GC
    
    // System properties
    margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@/Frameworks", NSBundle.mainBundle.bundlePath].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.dir=%@", gameDir].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.home=%s", getenv("POJAV_HOME")].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-DUIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond].UTF8String;
    margv[++margc] = "-Dorg.lwjgl.glfw.checkThread0=false";
    margv[++margc] = "-Dorg.lwjgl.system.allocator=system";
    margv[++margc] = "-Dlog4j2.formatMsgNoLookups=true";
    
    // Class data sharing - improves startup time
    margv[++margc] = "-Xshare:auto";
    
    // String deduplication - reduces memory usage
    margv[++margc] = "-XX:+UseStringDeduplication";

    // Preset OpenGL libname
    const char *glLibName = getenv("POJAV_RENDERER");
    if (glLibName) {
        if (!strcmp(glLibName, "auto")) {
            // workaround only applies to 1.20.2+
            glLibName = RENDERER_NAME_MTL_ANGLE;
        }
        margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.opengl.libname=%s", glLibName].UTF8String;
    }

    // Build and cache libraries path
    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    if (!cachedClasspath) {
        cachedClasspath = [NSString stringWithFormat:@"%@/*", librariesPath];
    }
    
    // Java agents
    margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/patchjna_agent.jar=", librariesPath].UTF8String;
    if(getPrefBool(@"general.cosmetica")) {
        margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/arc_dns_injector.jar=23.95.137.176", librariesPath].UTF8String;
    }

    // Additional performance optimizations
    // NOTE: This flag MUST come before other experimental options
    margv[++margc] = "-XX:+UnlockExperimentalVMOptions";
    margv[++margc] = "-XX:+DisablePrimordialThreadGuardPages";
    margv[++margc] = "-XX:+UseFastAccessorMethods";  // Use faster method access
    margv[++margc] = "-XX:+OptimizeStringConcat";    // Optimize string concatenation
    
    // Thread optimizations
    margv[++margc] = "-XX:+UseParallelGC";
    margv[++margc] = "-XX:+UseThreadPriorities";
    
    // Networking optimizations
    margv[++margc] = "-Dsun.net.client.defaultConnectTimeout=10000";
    margv[++margc] = "-Dsun.net.client.defaultReadTimeout=10000";

    // Disable Forge 1.16.x early progress window
    margv[++margc] = "-Dfml.earlyprogresswindow=false";
    
    // Code cache optimization to improve JIT performance
    margv[++margc] = "-XX:ReservedCodeCacheSize=256M";
    margv[++margc] = "-XX:InitialCodeCacheSize=64M";
    
    // JIT compilation policy
    margv[++margc] = "-XX:+TieredCompilation";
    margv[++margc] = "-XX:TieredStopAtLevel=1";  // Fast startup with minimal compilation
    
    // Fast startup optimization - will be removed below for normal operation
    margv[++margc] = "-XX:CompileThreshold=10000";  // Wait longer before compiling methods

    // Load JLI library
    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome]; // java 8
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome]; // java 11+
    BOOL isJava8 = checkFileExistsWithCache(libjlipath8);
    setenv("INTERNAL_JLI_PATH", (isJava8 ? libjlipath8 : libjlipath11).UTF8String, 1);
    void* libjli = dlopen(getenv("INTERNAL_JLI_PATH"), RTLD_GLOBAL);

    if (!libjli) {
        const char *error = dlerror();
        NSLog(@"[Init] JLI lib = NULL: %s", error);
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), @(error));
        return 1;
    }

    // Setup Caciocavallo
    margv[++margc] = "-Djava.awt.headless=false";
    margv[++margc] = "-Dcacio.font.fontmanager=sun.awt.X11FontManager";
    margv[++margc] = "-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler";
    margv[++margc] = [NSString stringWithFormat:@"-Dcacio.managed.screensize=%dx%d", width, height].UTF8String;
    margv[++margc] = "-Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel";
    
    // Generate or retrieve cached bootclasspath
    if (!cachedBootClasspath) {
        if (isJava8) {
            // Setup Caciocavallo
            margv[++margc] = "-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit";
            margv[++margc] = "-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment";
            
            // Build bootclasspath
            NSString *cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo", NSBundle.mainBundle.bundlePath];
            cachedBootClasspath = buildClasspathForDirectory(cacio_libs_path);
        } else {
            // Required by Cosmetica to inject DNS
            margv[++margc] = "--add-opens=java.base/java.net=ALL-UNNAMED";

            // Setup Caciocavallo
            margv[++margc] = "-Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit";
            margv[++margc] = "-Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment";

            // Required by Caciocavallo17 to access internal API
            margv[++margc] = "--add-exports=java.desktop/java.awt=ALL-UNNAMED";
            margv[++margc] = "--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED";
            margv[++margc] = "--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED";
            margv[++margc] = "--add-exports=java.desktop/sun.java2d=ALL-UNNAMED";
            margv[++margc] = "--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED";
            margv[++margc] = "--add-exports=java.desktop/sun.awt=ALL-UNNAMED";
            margv[++margc] = "--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED";
            margv[++margc] = "--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED";
            margv[++margc] = "--add-exports=java.desktop/sun.font=ALL-UNNAMED";
            margv[++margc] = "--add-exports=java.base/sun.security.action=ALL-UNNAMED";
            margv[++margc] = "--add-opens=java.base/java.util=ALL-UNNAMED";
            margv[++margc] = "--add-opens=java.desktop/java.awt=ALL-UNNAMED";
            margv[++margc] = "--add-opens=java.desktop/sun.font=ALL-UNNAMED";
            margv[++margc] = "--add-opens=java.desktop/sun.java2d=ALL-UNNAMED";
            margv[++margc] = "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED";

            // TODO: workaround, will be removed once the startup part works without PLaunchApp
            margv[++margc] = "--add-exports=cpw.mods.bootstraplauncher/cpw.mods.bootstraplauncher=ALL-UNNAMED";
            
            // Build bootclasspath
            NSString *cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo17", NSBundle.mainBundle.bundlePath];
            cachedBootClasspath = buildClasspathForDirectory(cacio_libs_path);
        }
    }
    
    // Add the bootclasspath
    NSString *cacio_classpath = [NSString stringWithFormat:@"-Xbootclasspath/%s:%@", isJava8 ? "p" : "a", cachedBootClasspath];
    margv[++margc] = cacio_classpath.UTF8String;

    if (!getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")) {
        // In jailed environment, where extended virtual addressing entitlement isn't
        // present (for free dev account), allocating compressed space fails.
        // FIXME: does extended VA allow allocating compressed class space?
        margv[++margc] = "-XX:-UseCompressedClassPointers";
    }

    // Add custom JVM arguments from profile
    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        for (NSString *arg in launchTarget[@"arguments"][@"jvm_processed"]) {
            margv[++margc] = arg.UTF8String;
        }
    }

    // Add custom JVM flags from user settings
    init_loadCustomJvmFlags(&margc, (const char **)margv);
    NSLog(@"[Init] Found JLI lib");

    // Remove startup-only optimizations (they're only useful during init)
    for (int i = 0; i <= margc; i++) {
        if (strcmp(margv[i], "-XX:TieredStopAtLevel=1") == 0) {
            // Replace with full tiering
            margv[i] = "-XX:TieredStopAtLevel=4";
        }
        else if (strcmp(margv[i], "-XX:CompileThreshold=10000") == 0) {
            // Use default compile threshold
            margv[i] = "-XX:CompileThreshold=1500";
        }
        else if (strcmp(margv[i], "JAVA_COMPILER=NONE") == 0) {
            // Re-enable JIT compiler
            margv[i] = "";
        }
    }

    // Prepare classpath
    NSString *classpath;
    if (launchJar) {
        classpath = [NSString stringWithFormat:@"%@:%@", cachedClasspath, launchTarget];
    } else {
        classpath = cachedClasspath;
    }
    margv[++margc] = "-cp";
    margv[++margc] = classpath.UTF8String;
    margv[++margc] = "net.kdt.pojavlaunch.PojavLauncher";

    if (launchJar) {
        margv[++margc] = "-jar";
    } else {
        margv[++margc] = username.UTF8String;
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        margv[++margc] = [launchTarget[@"id"] UTF8String];
    } else {
        margv[++margc] = [launchTarget UTF8String];
    }

    pJLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");

    if (NULL == pJLI_Launch) {
        NSLog(@"[Init] JLI_Launch = NULL");
        return -2;
    }

    NSLog(@"[Init] Calling JLI_Launch");

    // Cr4shed known issue: exit after crash dump,
    // reset signal handler so that JVM can catch them
    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);

    // Free split VC and clear caches that are no longer needed
    tmpRootVC = nil;
    
    // Free memory from caches that are no longer needed
    [fileExistsCache removeAllObjects];
    
    // Prefetch some commonly used files
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        void *mappedData = NULL;
        size_t mappedSize = 0;
        
        // Prefetch main jar
        NSString *mainJarPath = nil;
        if (launchJar) {
            mainJarPath = launchTarget;
        } else if ([launchTarget isKindOfClass:NSDictionary.class]) {
            mainJarPath = [NSString stringWithFormat:@"%s/versions/%@/%@.jar", 
                           getenv("POJAV_GAME_DIR"), launchTarget[@"id"], launchTarget[@"id"]];
        }
        
        if (mainJarPath) {
            mapFileIntoMemory(mainJarPath.UTF8String, &mappedData, &mappedSize);
            if (mappedData) {
                // Keep in memory for a short time, then unmap
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 
                              dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                    unmapFileFromMemory(mappedData, mappedSize);
                });
            }
        }
    });

    // Final JVM invocation
    return pJLI_Launch(++margc, margv,
                   0, NULL, // sizeof(const_jargs) / sizeof(char *), const_jargs,
                   0, NULL, // sizeof(const_appclasspath) / sizeof(char *), const_appclasspath,
                   // These values are ignored in Java 17, so keep it anyways
                   "1.8.0-internal",
                   "1.8",

                   "java", "openjdk",
                   /* (const_jargs != NULL) ? JNI_TRUE : */ JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
}
