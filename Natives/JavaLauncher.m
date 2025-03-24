#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "utils.h"

#import "ios_uikit_bridge.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"

#define fm NSFileManager.defaultManager

extern char **environ;

// Enhanced logging macro
#define LAUNCH_LOG(fmt, ...) NSLog((@"[JavaLauncher] " fmt), ##__VA_ARGS__)

// Validation function for JAR files
static BOOL validateJARFile(NSString *jarPath) {
    NSError *error = nil;
    
    // Check file existence
    if (![fm fileExistsAtPath:jarPath]) {
        LAUNCH_LOG(@"Error: JAR file does not exist at path %@", jarPath);
        return NO;
    }
    
    // Get file attributes
    NSDictionary *attributes = [fm attributesOfItemAtPath:jarPath error:&error];
    if (error) {
        LAUNCH_LOG(@"Error getting file attributes: %@", error.localizedDescription);
        return NO;
    }
    
    // File size validation
    unsigned long long fileSize = [attributes fileSize];
    if (fileSize == 0 || fileSize > 1024 * 1024 * 500) { // 500MB max
        LAUNCH_LOG(@"Invalid file size: %llu bytes", fileSize);
        return NO;
    }
    
    // Basic JAR file signature check - read first 4 bytes
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:jarPath];
    if (!fileHandle) {
        LAUNCH_LOG(@"Error: Could not open file for reading");
        return NO;
    }
    
    NSData *headerData = [fileHandle readDataOfLength:4];
    [fileHandle closeFile];
    
    if (headerData.length < 4) {
        LAUNCH_LOG(@"Error: Could not read file header");
        return NO;
    }
    
    const char *bytes = [headerData bytes];
    if (!bytes || headerData.length < 4 || bytes[0] != 'P' || bytes[1] != 'K') {
        LAUNCH_LOG(@"Invalid JAR file signature");
        return NO;
    }
    
    return YES;
}

void init_loadDefaultEnv() {
    LAUNCH_LOG(@"Initializing default environment variables");

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
}

void init_loadCustomEnv() {
    NSString *envvars = getPrefObject(@"java.env_variables");
    if (envvars == nil) return;
    
    LAUNCH_LOG(@"Loading custom environment variables");
    for (NSString *line in [envvars componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (![line containsString:@"="]) {
            LAUNCH_LOG(@"Warning: skipped empty value custom env variable: %@", line);
            continue;
        }
        NSRange range = [line rangeOfString:@"="];
        NSString *key = [line substringToIndex:range.location];
        NSString *value = [line substringFromIndex:range.location+range.length];
        setenv(key.UTF8String, value.UTF8String, 1);
        LAUNCH_LOG(@"Added custom env variable: %@", line);
    }
}

void init_loadCustomJvmFlags(int* argc, const char** argv) {
    NSString *jvmargs = [PLProfiles resolveKeyForCurrentProfile:@"javaArgs"];
    if (jvmargs == nil) return;
    
    // Make the separator happy
    jvmargs = [jvmargs stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    jvmargs = [@" " stringByAppendingString:jvmargs];

    LAUNCH_LOG(@"Reading custom JVM flags");
    NSArray *argsToPurge = @[@"Xms", @"Xmx", @"d32", @"d64"];
    for (NSString *arg in [jvmargs componentsSeparatedByString:@" -"]) {
        NSString *jvmarg = [arg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (jvmarg.length == 0) continue;
        
        BOOL ignore = NO;
        for (NSString *argToPurge in argsToPurge) {
            if ([jvmarg hasPrefix:argToPurge]) {
                LAUNCH_LOG(@"Ignored JVM flag: -%@", jvmarg);
                ignore = YES;
                break;
            }
        }
        if (ignore) continue;

        ++*argc;
        argv[*argc] = [@"-" stringByAppendingString:jvmarg].UTF8String;

        LAUNCH_LOG(@"Added custom JVM flag: %s", argv[*argc]);
    }
}

int launchJVM(NSString *username, id launchTarget, int width, int height, int minVersion) {
    LAUNCH_LOG(@"Beginning JVM launch process");
    LAUNCH_LOG(@"Launch Target: %@", launchTarget);
    LAUNCH_LOG(@"Minimum Java Version: %d", minVersion);
    
    // Comprehensive pre-launch validation
    if ([launchTarget isKindOfClass:NSString.class]) {
        if (!validateJARFile(launchTarget)) {
            LAUNCH_LOG(@"JAR file validation failed");
            UIKit_returnToSplitView();
            showDialog(localize(@"Error", nil), 
                [NSString stringWithFormat:@"Invalid JAR file: %@", [launchTarget lastPathComponent]]);
            return 1;
        }
    }

    if (NSBundle.mainBundle.infoDictionary[@"LCDataUUID"]) {
        LAUNCH_LOG(@"Running in LiveContainer, skipping dyld patch");
    } else {
        // Activate Library Validation bypass for external runtime and dylibs (JNA, etc)
        init_bypassDyldLibValidation();
    }

    init_loadDefaultEnv();
    init_loadCustomEnv();

    BOOL launchJar = NO;
    NSString *gameDir;
    NSString *defaultJRETag;
    
    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        // Java version selection logic
        int preferredJavaVersion = [PLProfiles resolveKeyForCurrentProfile:@"javaVersion"].intValue;
        if (preferredJavaVersion > 0) {
            if (minVersion > preferredJavaVersion) {
                LAUNCH_LOG(@"Profile's preferred Java version (%d) does not meet the minimum version (%d)", preferredJavaVersion, minVersion);
            } else {
                LAUNCH_LOG(@"Applying profile's Java version");
                minVersion = preferredJavaVersion;
            }
        }
        
        // JRE tag selection
        defaultJRETag = minVersion <= 8 ? @"1_16_5_older" : @"1_17_newer";

        // Renderer setup
        NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        LAUNCH_LOG(@"RENDERER is set to %@", renderer);
        setenv("POJAV_RENDERER", renderer.UTF8String, 1);
        
        // Game directory setup
        gameDir = [NSString stringWithFormat:@"%s/instances/%@/%@",
            getenv("POJAV_HOME"), getPrefObject(@"general.game_directory"),
            [PLProfiles resolveKeyForCurrentProfile:@"gameDir"]]
            .stringByStandardizingPath;
    } else {
        defaultJRETag = @"execute_jar";
        gameDir = @(getenv("POJAV_GAME_DIR"));
        launchJar = YES;
    }
    
    LAUNCH_LOG(@"Looking for Java %d or later", minVersion);
    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minVersion);

    if (javaHome == nil) {
        LAUNCH_LOG(@"No suitable Java runtime found");
        UIKit_returnToSplitView();
        BOOL isExecuteJar = [defaultJRETag isEqualToString:@"execute_jar"];
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil),
            isExecuteJar ? [launchTarget lastPathComponent] : PLProfiles.current.selectedProfile[@"lastVersionId"], minVersion]);
        return 1;
    }
    
    // Symlink libawt_xawt.dylib for custom Java runtimes
    if ([javaHome hasPrefix:@(getenv("POJAV_HOME"))]) {
        NSString *dest = [NSString stringWithFormat:@"%@/lib/libawt_xawt.dylib", javaHome];
        NSString *source = [NSString stringWithFormat:@"%@/Frameworks/libawt_xawt.dylib", NSBundle.mainBundle.bundlePath];
        NSError *error;
        [fm createSymbolicLinkAtPath:dest withDestinationPath:source error:&error];
        if (error) {
            LAUNCH_LOG(@"Symlink libawt_xawt.dylib failed: %@", error.localizedDescription);
        }
    }

    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    LAUNCH_LOG(@"JAVA_HOME set to %@", javaHome);

    // RAM allocation logic
    int allocmem;
    if (getPrefBool(@"java.auto_ram")) {
        CGFloat autoRatio = getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25;
        allocmem = roundf((NSProcessInfo.processInfo.physicalMemory / 1048576) * autoRatio);
    } else {
        allocmem = getPrefInt(@"java.allocated_memory");
    }
    LAUNCH_LOG(@"Max RAM allocation set to %d MB", allocmem);

    // Create array of arguments with proper capacity
    int margc = -1;
    const char *margv[1000];
    
    // Core JVM arguments
    margv[++margc] = [NSString stringWithFormat:@"%@/bin/java", javaHome].UTF8String;
    margv[++margc] = "-XstartOnFirstThread";
    
    if (!launchJar) {
        margv[++margc] = "-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader";
    }
    
    // Memory settings
    margv[++margc] = "-Xms128M";
    margv[++margc] = [NSString stringWithFormat:@"-Xmx%dM", allocmem].UTF8String;
    
    // Path and environment settings
    margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@/Frameworks", NSBundle.mainBundle.bundlePath].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.dir=%@", gameDir].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.home=%s", getenv("POJAV_HOME")].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-DUIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond].UTF8String;
    
    // LWJGL settings
    margv[++margc] = "-Dorg.lwjgl.glfw.checkThread0=false";
    margv[++margc] = "-Dorg.lwjgl.system.allocator=system";
    
    // Security settings
    margv[++margc] = "-Dlog4j2.formatMsgNoLookups=true";
    
    // Preset OpenGL libname
    const char *glLibName = getenv("POJAV_RENDERER");
    if (glLibName) {
        if (!strcmp(glLibName, "auto")) {
            // workaround only applies to 1.20.2+
            glLibName = RENDERER_NAME_MTL_ANGLE;
        }
        margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.opengl.libname=%s", glLibName].UTF8String;
    }
    
    // Java agents
    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/patchjna_agent.jar=", librariesPath].UTF8String;
    
    if (getPrefBool(@"general.cosmetica")) {
        margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/arc_dns_injector.jar=23.95.137.176", librariesPath].UTF8String;
    }
    
    // Workaround for stack guard allocation crashes
    margv[++margc] = "-XX:+UnlockExperimentalVMOptions";
    margv[++margc] = "-XX:+DisablePrimordialThreadGuardPages";
    
    // Disable Forge 1.16.x early progress window
    margv[++margc] = "-Dfml.earlyprogresswindow=false";
    
    // Load java
    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome]; // java 8
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome]; // java 11+
    BOOL isJava8 = [fm fileExistsAtPath:libjlipath8];
    setenv("INTERNAL_JLI_PATH", (isJava8 ? libjlipath8 : libjlipath11).UTF8String, 1);
    void* libjli = dlopen(getenv("INTERNAL_JLI_PATH"), RTLD_GLOBAL);

    if (!libjli) {
        const char *error = dlerror();
        LAUNCH_LOG(@"JLI lib = NULL: %s", error);
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
    
    if (isJava8) {
        // Setup Caciocavallo for Java 8
        margv[++margc] = "-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit";
        margv[++margc] = "-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment";
    } else {
        // Required by Cosmetica to inject DNS
        margv[++margc] = "--add-opens=java.base/java.net=ALL-UNNAMED";

        // Setup Caciocavallo for Java 11+
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
    }

    // Add Caciocavallo bootclasspath
    NSString *cacio_classpath = [NSString stringWithFormat:@"-Xbootclasspath/%s", isJava8 ? "p" : "a"];
    NSString *cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo%s", NSBundle.mainBundle.bundlePath, isJava8 ? "" : "17"];
    NSArray *files = [fm contentsOfDirectoryAtPath:cacio_libs_path error:nil];
    for(NSString *file in files) {
        if ([file hasSuffix:@".jar"]) {
            cacio_classpath = [NSString stringWithFormat:@"%@:%@/%@", cacio_classpath, cacio_libs_path, file];
        }
    }
    margv[++margc] = cacio_classpath.UTF8String;

    if (!getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")) {
        // In jailed environment, where extended virtual addressing entitlement isn't
        // present (for free dev account), allocating compressed space fails.
        // FIXME: does extended VA allow allocating compressed class space?
        margv[++margc] = "-XX:-UseCompressedClassPointers";
    }

    // Add forge/mod JVM arguments if available
    if ([launchTarget isKindOfClass:NSDictionary.class] && launchTarget[@"arguments"][@"jvm_processed"]) {
        NSArray *processedJvmArgs = launchTarget[@"arguments"][@"jvm_processed"];
        for (NSString *arg in processedJvmArgs) {
            margv[++margc] = arg.UTF8String;
        }
    }

    // Add custom JVM flags from profile
    init_loadCustomJvmFlags(&margc, (const char **)margv);

    // Set classpath
    NSString *classpath = [NSString stringWithFormat:@"%@/*", librariesPath];
    if (launchJar) {
        classpath = [classpath stringByAppendingFormat:@":%@", launchTarget];
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
        LAUNCH_LOG(@"JLI_Launch = NULL");
        return -2;
    }

    LAUNCH_LOG(@"Calling JLI_Launch with %d arguments", margc + 1);

    // Cr4shed known issue: exit after crash dump,
    // reset signal handler so that JVM can catch them
    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);

    // Free split VC
    tmpRootVC = nil;

    return pJLI_Launch(margc + 1, margv,
                   0, NULL, // sizeof(const_jargs) / sizeof(char *), const_jargs,
                   0, NULL, // sizeof(const_appclasspath) / sizeof(char *), const_appclasspath,
                   "1.8.0-internal",
                   "1.8",
                   "java", "openjdk",
                   /* (const_jargs != NULL) ? JNI_TRUE : */ JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
}
