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

void init_loadDefaultEnv() {
    /* Define default env */
    setenv("LD_LIBRARY_PATH", "", 1);
    setenv("LIBGL_NOINTOVLHACK", "1", 1);
    setenv("LIBGL_NORMALIZE", "1", 1);
    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);
}

void init_loadCustomEnv() {
    NSString *envvars = getPrefObject(@"java.env_variables");
    if (envvars == nil || [envvars length] == 0) return;
    NSLog(@"[JavaLauncher] Reading custom environment variables");
    NSCharacterSet *separators = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *line in [envvars componentsSeparatedByCharactersInSet:separators]) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:separators];
        if (trimmedLine.length == 0 || ![trimmedLine containsString:@"="]) {
            continue;
        }
        NSRange range = [trimmedLine rangeOfString:@"="];
        NSString *key = [trimmedLine substringToIndex:range.location];
        NSString *value = [trimmedLine substringFromIndex:range.location + range.length];
        key = [key stringByTrimmingCharactersInSet:separators];
        value = [value stringByTrimmingCharactersInSet:separators];
        if (key.length == 0) {
             NSLog(@"[JavaLauncher] Warning: skipped custom env variable with empty key: %@", trimmedLine);
             continue;
        }
        setenv(key.UTF8String, value.UTF8String, 1);
        NSLog(@"[JavaLauncher] Added custom env variable: %@=%@", key, value);
    }
}

void init_loadCustomJvmFlags(int* argc, const char** argv) {
    NSString *jvmargs = [PLProfiles resolveKeyForCurrentProfile:@"javaArgs"];
    if (jvmargs == nil || [jvmargs length] == 0) return;

    NSLog(@"[JavaLauncher] Reading custom JVM flags: %@", jvmargs);
    NSArray *argsToPurge = @[@"Xms", @"Xmx", @"d32", @"d64"];
    NSArray *potentialArgs = [jvmargs componentsSeparatedByString:@" "];

    for (NSString *potentialArg in potentialArgs) {
        NSString *jvmarg = [potentialArg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (jvmarg.length == 0) continue;

        BOOL ignore = NO;
        for (NSString *argToPurge in argsToPurge) {
             if ([jvmarg hasPrefix:[@"-" stringByAppendingString:argToPurge]] || [jvmarg hasPrefix:argToPurge]) {
                 NSLog(@"[JavaLauncher] Ignored JVM flag: %@", jvmarg);
                 ignore = YES;
                 break;
             }
        }
        if (ignore) continue;

        if (![jvmarg hasPrefix:@"-"]) {
            jvmarg = [@"-" stringByAppendingString:jvmarg];
        }

        if (*argc < 999) {
             ++(*argc);
             argv[*argc] = [jvmarg UTF8String];
             NSLog(@"[JavaLauncher] Added custom JVM flag: %s", argv[*argc]);
        } else {
             NSLog(@"[JavaLauncher] Warning: Too many JVM arguments, skipping: %@", jvmarg);
             break;
        }
    }
}

// --- End of Helper Function Definitions ---


int launchJVM(NSString *username, id launchTarget, int width, int height, int minVersion) {
    NSLog(@"[JavaLauncher] Beginning JVM launch");

    if (NSBundle.mainBundle.infoDictionary[@"LCDataUUID"]) {
        NSDebugLog(@"[JavaLauncher] Running in LiveContainer, skipping dyld patch");
    } else {
        init_bypassDyldLibValidation();
    }

    init_loadDefaultEnv();
    init_loadCustomEnv();

    BOOL launchJar = NO;
    NSString *gameDir;
    NSString *defaultJRETag;

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        launchJar = NO;
        int preferredJavaVersion = [PLProfiles resolveKeyForCurrentProfile:@"javaVersion"].intValue;
        if (preferredJavaVersion > 0) {
            if (minVersion > preferredJavaVersion) {
                NSLog(@"[JavaLauncher] Profile's preferred Java version (%d) does not meet the minimum version (%d), dropping request", preferredJavaVersion, minVersion);
            } else {
                NSDebugLog(@"[PLProfiles] Applying preferred javaVersion %d", preferredJavaVersion);
                minVersion = preferredJavaVersion;
            }
        }
        defaultJRETag = (minVersion <= 8) ? @"1_16_5_older" : @"1_17_newer";
        NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        NSLog(@"[JavaLauncher] RENDERER is set to %@\n", renderer);
        setenv("POJAV_RENDERER", renderer.UTF8String, 1);
        gameDir = [PLProfiles fullPathForProfileWithName:PLProfiles.current.selectedProfileName
                                                 gameDir:[PLProfiles resolveKeyForCurrentProfile:@"gameDir"]];
    } else if ([launchTarget isKindOfClass:NSString.class]) {
        launchJar = YES;
        defaultJRETag = @"execute_jar";
        gameDir = @(getenv("POJAV_GAME_DIR"));
        minVersion = MAX(minVersion, 8);
    } else {
        showDialog(localize(@"Error", nil), @"Invalid launch target provided.");
        return 1;
    }

    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);
    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minVersion);

    if (javaHome == nil) {
        UIKit_returnToSplitView();
        BOOL isExecuteJar = [defaultJRETag isEqualToString:@"execute_jar"];
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil),
            isExecuteJar ? [launchTarget lastPathComponent] : PLProfiles.current.selectedProfile[@"lastVersionId"], minVersion]);
        return 1;
    } else if ([javaHome hasPrefix:@(getenv("POJAV_HOME"))]) {
        NSString *dest = [NSString stringWithFormat:@"%@/lib/libawt_xawt.dylib", javaHome];
        NSString *source = [NSString stringWithFormat:@"%@/Frameworks/libawt_xawt.dylib", NSBundle.mainBundle.bundlePath];
        NSError *error;
        [fm removeItemAtPath:dest error:nil];
        [fm createSymbolicLinkAtPath:dest withDestinationPath:source error:&error];
        if (error) {
            NSLog(@"[JavaLauncher] Symlink libawt_xawt.dylib failed: %@", error.localizedDescription);
        }
    }

    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    NSLog(@"[JavaLauncher] JAVA_HOME has been set to %@", javaHome);

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

    margv[++margc] = [NSString stringWithFormat:@"%@/bin/java", javaHome].UTF8String;
    margv[++margc] = "-XstartOnFirstThread";

    if (!launchJar) {
        margv[++margc] = "-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader";
    }

    margv[++margc] = "-Xms128M";
    margv[++margc] = [NSString stringWithFormat:@"-Xmx%dM", allocmem].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@/Frameworks", NSBundle.mainBundle.bundlePath].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.dir=%@", gameDir].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.home=%s", getenv("POJAV_HOME")].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-DUIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond].UTF8String;
    margv[++margc] = "-Dorg.lwjgl.glfw.checkThread0=false";
    margv[++margc] = "-Dorg.lwjgl.system.allocator=system";
    margv[++margc] = "-Dlog4j2.formatMsgNoLookups=true";

    const char *glLibName = getenv("POJAV_RENDERER");
    if (glLibName) {
        if (!strcmp(glLibName, "auto")) {
            glLibName = RENDERER_NAME_MTL_ANGLE;
        }
        margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.opengl.libname=%s", glLibName].UTF8String;
    }

    // --- Start Fix: Conditionally add Java Agents ---
    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    if (!launchJar) { // Only add agents when launching Minecraft
        margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/patchjna_agent.jar=", librariesPath].UTF8String;
        if(getPrefBool(@"general.cosmetica")) {
            margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/arc_dns_injector.jar=23.95.137.176", librariesPath].UTF8String;
        }
    }
    // --- End Fix ---

    margv[++margc] = "-XX:+UnlockExperimentalVMOptions";
    margv[++margc] = "-XX:+DisablePrimordialThreadGuardPages";

    // --- Start Fix: Increase CodeCache Size ---
    margv[++margc] = "-XX:ReservedCodeCacheSize=512M"; // Added to prevent CodeCache full errors
    // --- End Fix ---

    margv[++margc] = "-Dfml.earlyprogresswindow=false";

    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome];
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome];
    BOOL isJava8 = [fm fileExistsAtPath:libjlipath8];
    setenv("INTERNAL_JLI_PATH", (isJava8 ? libjlipath8 : libjlipath11).UTF8String, 1);
    void* libjli = dlopen(getenv("INTERNAL_JLI_PATH"), RTLD_GLOBAL);

    if (!libjli) {
        const char *error = dlerror();
        NSLog(@"[Init] JLI lib = NULL: %s", error);
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), @(error));
        return 1;
    }

    margv[++margc] = "-Djava.awt.headless=false";
    margv[++margc] = "-Dcacio.font.fontmanager=sun.awt.X11FontManager";
    margv[++margc] = "-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler";
    margv[++margc] = [NSString stringWithFormat:@"-Dcacio.managed.screensize=%dx%d", width, height].UTF8String;
    margv[++margc] = "-Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel";
    if (isJava8) {
        margv[++margc] = "-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit";
        margv[++margc] = "-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment";
    } else {
        margv[++margc] = "--add-opens=java.base/java.net=ALL-UNNAMED";
        margv[++margc] = "-Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit";
        margv[++margc] = "-Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment";
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
        margv[++margc] = "--add-exports=cpw.mods.bootstraplauncher/cpw.mods.bootstraplauncher=ALL-UNNAMED";
    }

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
        margv[++margc] = "-XX:-UseCompressedClassPointers";
    }

    if (!launchJar && [launchTarget isKindOfClass:NSDictionary.class]) {
        NSDictionary *arguments = launchTarget[@"arguments"];
        if (arguments && [arguments isKindOfClass:[NSDictionary class]]) {
             NSArray *jvmProcessedArgs = arguments[@"jvm_processed"];
             if (jvmProcessedArgs && [jvmProcessedArgs isKindOfClass:[NSArray class]]) {
                 for (NSString *arg in jvmProcessedArgs) {
                     if ([arg isKindOfClass:[NSString class]]) {
                         margv[++margc] = arg.UTF8String;
                     }
                 }
             }
        }
    }

    init_loadCustomJvmFlags(&margc, (const char **)margv);
    NSLog(@"[Init] Found JLI lib");

    NSString *classpath = [NSString stringWithFormat:@"%@/*", librariesPath];
    if (launchJar) {
        classpath = [classpath stringByAppendingFormat:@":%@", launchTarget];
    }
    margv[++margc] = "-cp";
    margv[++margc] = classpath.UTF8String;

    if (launchJar) {
        margv[++margc] = "-jar";
        margv[++margc] = [launchTarget UTF8String];
    } else {
        margv[++margc] = "net.kdt.pojavlaunch.PojavLauncher";
        margv[++margc] = username.UTF8String;
        if ([launchTarget isKindOfClass:NSDictionary.class] && launchTarget[@"id"]) {
             margv[++margc] = [launchTarget[@"id"] UTF8String];
        } else {
             margv[++margc] = "unknown-version";
             NSLog(@"[JavaLauncher] Warning: Could not determine version ID for Minecraft launch.");
        }
    }

    pJLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");

    if (NULL == pJLI_Launch) {
        NSLog(@"[Init] JLI_Launch = NULL");
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), @"Failed to find JLI_Launch symbol in Java runtime.");
        dlclose(libjli);
        return -2;
    }

    NSLog(@"[Init] Calling JLI_Launch");

    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);

    tmpRootVC = nil;

    NSLog(@"[JavaLauncher] Final JVM Arguments (%d):", margc + 1);
    for (int i = 0; i <= margc; i++) {
        NSLog(@"[JavaLauncher] argv[%d]: %s", i, margv[i] ? margv[i] : "(null)");
    }

    int result = pJLI_Launch(++margc, margv,
                   0, NULL,
                   0, NULL,
                   "1.8.0-internal", "1.8",
                   "java", "openjdk",
                   JNI_FALSE, JNI_TRUE, JNI_FALSE, 0);

    dlclose(libjli);

    return result;
}
