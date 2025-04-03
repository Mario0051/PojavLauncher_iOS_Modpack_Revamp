// Natives/JavaLauncher.m

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

    // Silent Caciocavallo NPE error in locating Android-only lib
    setenv("LD_LIBRARY_PATH", "", 1);

    // Ignore mipmap for performance(?) seems does not affect iOS
    //setenv("LIBGL_MIPMAP", "3", 1);

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
    if (envvars == nil || [envvars length] == 0) return; // Check for empty string too
    NSLog(@"[JavaLauncher] Reading custom environment variables");
    // Use componentsSeparatedByCharactersInSet to handle multiple spaces/newlines
    NSCharacterSet *separators = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *line in [envvars componentsSeparatedByCharactersInSet:separators]) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:separators];
        if (trimmedLine.length == 0 || ![trimmedLine containsString:@"="]) {
            // Skip empty lines or lines without '='
            continue;
        }
        NSRange range = [trimmedLine rangeOfString:@"="];
        NSString *key = [trimmedLine substringToIndex:range.location];
        NSString *value = [trimmedLine substringFromIndex:range.location + range.length];
        // Trim key and value just in case
        key = [key stringByTrimmingCharactersInSet:separators];
        value = [value stringByTrimmingCharactersInSet:separators];
        if (key.length == 0) { // Ensure key is not empty
             NSLog(@"[JavaLauncher] Warning: skipped custom env variable with empty key: %@", trimmedLine);
             continue;
        }
        setenv(key.UTF8String, value.UTF8String, 1);
        NSLog(@"[JavaLauncher] Added custom env variable: %@=%@", key, value);
    }
}

void init_loadCustomJvmFlags(int* argc, const char** argv) {
    NSString *jvmargs = [PLProfiles resolveKeyForCurrentProfile:@"javaArgs"];
    if (jvmargs == nil || [jvmargs length] == 0) return; // Check for nil or empty

    NSLog(@"[JavaLauncher] Reading custom JVM flags: %@", jvmargs);
    NSArray *argsToPurge = @[@"Xms", @"Xmx", @"d32", @"d64"]; // Flags to ignore

    // Split arguments robustly, respecting quotes if necessary (though simple split often suffices)
    // For now, using componentsSeparatedByString which is simple but might break with quoted args.
    // Consider a more robust parser if complex arguments with spaces are needed.
    NSArray *potentialArgs = [jvmargs componentsSeparatedByString:@" "];

    for (NSString *potentialArg in potentialArgs) {
        NSString *jvmarg = [potentialArg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (jvmarg.length == 0) continue;

        BOOL ignore = NO;
        // Check if the argument starts with any of the prefixes to purge
        for (NSString *argToPurge in argsToPurge) {
            // Check for both "-Xms..." and "Xms..." (without leading dash)
             if ([jvmarg hasPrefix:[@"-" stringByAppendingString:argToPurge]] || [jvmarg hasPrefix:argToPurge]) {
                 NSLog(@"[JavaLauncher] Ignored JVM flag: %@", jvmarg);
                 ignore = YES;
                 break;
             }
        }
        if (ignore) continue;

        // Prepend '-' if it's missing (common user error)
        if (![jvmarg hasPrefix:@"-"]) {
            jvmarg = [@"-" stringByAppendingString:jvmarg];
        }

        // Ensure we don't overflow the argv buffer
        if (*argc < 999) { // Leave one space buffer before the limit
             ++(*argc);
             // IMPORTANT: We need to retain the string data.
             // Create a C string that will persist for the duration of the launch.
             // A simple way is to copy it. Ensure the buffer `margv` points to is large enough.
             // Since margv is stack-allocated in launchJVM, using strdup is safer
             // if the NSString might be released. However, for command-line args,
             // just getting UTF8String *should* be okay as long as the NSString exists.
             // Let's be safer and potentially leak a small amount if needed, or manage lifetime.
             // For now, assume the NSString lives long enough.
             argv[*argc] = [jvmarg UTF8String];
             NSLog(@"[JavaLauncher] Added custom JVM flag: %s", argv[*argc]);
        } else {
             NSLog(@"[JavaLauncher] Warning: Too many JVM arguments, skipping: %@", jvmarg);
             break; // Stop adding args if buffer is full
        }
    }
}

// --- End of Helper Function Definitions ---


int launchJVM(NSString *username, id launchTarget, int width, int height, int minVersion) {
    NSLog(@"[JavaLauncher] Beginning JVM launch");

    if (NSBundle.mainBundle.infoDictionary[@"LCDataUUID"]) {
        NSDebugLog(@"[JavaLauncher] Running in LiveContainer, skipping dyld patch");
    } else {
        // Activate Library Validation bypass for external runtime and dylibs (JNA, etc)
        init_bypassDyldLibValidation();
    }

    // Load environment variables
    init_loadDefaultEnv();
    init_loadCustomEnv();

    BOOL launchJar = NO; // Flag to indicate if we are launching a JAR
    NSString *gameDir;
    NSString *defaultJRETag;

    // Determine if we are launching Minecraft (via profile dictionary) or a JAR (via NSString path)
    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        // --- Minecraft Launch Setup ---
        launchJar = NO;

        // Get preferred Java version from current profile
        int preferredJavaVersion = [PLProfiles resolveKeyForCurrentProfile:@"javaVersion"].intValue;
        if (preferredJavaVersion > 0) {
            if (minVersion > preferredJavaVersion) {
                NSLog(@"[JavaLauncher] Profile's preferred Java version (%d) does not meet the minimum version (%d), dropping request", preferredJavaVersion, minVersion);
            } else {
                NSDebugLog(@"[PLProfiles] Applying preferred javaVersion %d", preferredJavaVersion);
                minVersion = preferredJavaVersion; // Use profile's preference if valid
            }
        }
        // Determine JRE tag based on required version
        if (minVersion <= 8) {
            defaultJRETag = @"1_16_5_older";
        } else {
            defaultJRETag = @"1_17_newer";
        }

        // Setup POJAV_RENDERER from profile
        NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        NSLog(@"[JavaLauncher] RENDERER is set to %@\n", renderer);
        setenv("POJAV_RENDERER", renderer.UTF8String, 1);

        // Setup gameDir relative to the instance directory
        gameDir = [PLProfiles fullPathForProfileWithName:PLProfiles.current.selectedProfileName
                                                 gameDir:[PLProfiles resolveKeyForCurrentProfile:@"gameDir"]];
    } else if ([launchTarget isKindOfClass:NSString.class]) {
        // --- JAR Launch Setup ---
        launchJar = YES;
        defaultJRETag = @"execute_jar"; // Use JRE designated for JARs
        gameDir = @(getenv("POJAV_GAME_DIR")); // Use the base game directory
        minVersion = MAX(minVersion, 8); // Default to at least Java 8 for JARs unless specified higher
    } else {
        // Invalid launch target
        showDialog(localize(@"Error", nil), @"Invalid launch target provided.");
        return 1;
    }

    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);
    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minVersion);

    // Handle missing Java runtime
    if (javaHome == nil) {
        UIKit_returnToSplitView();
        BOOL isExecuteJar = [defaultJRETag isEqualToString:@"execute_jar"];
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil),
            isExecuteJar ? [launchTarget lastPathComponent] : PLProfiles.current.selectedProfile[@"lastVersionId"], minVersion]);
        return 1;
    } else if ([javaHome hasPrefix:@(getenv("POJAV_HOME"))]) {
        // Symlink libawt_xawt.dylib for external JREs
        NSString *dest = [NSString stringWithFormat:@"%@/lib/libawt_xawt.dylib", javaHome];
        NSString *source = [NSString stringWithFormat:@"%@/Frameworks/libawt_xawt.dylib", NSBundle.mainBundle.bundlePath];
        NSError *error;
        [fm removeItemAtPath:dest error:nil]; // Remove existing link first
        [fm createSymbolicLinkAtPath:dest withDestinationPath:source error:&error];
        if (error) {
            NSLog(@"[JavaLauncher] Symlink libawt_xawt.dylib failed: %@", error.localizedDescription);
        }
    }

    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    NSLog(@"[JavaLauncher] JAVA_HOME has been set to %@", javaHome);

    // Determine memory allocation
    int allocmem;
    if (getPrefBool(@"java.auto_ram")) {
        CGFloat autoRatio = getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25;
        allocmem = roundf((NSProcessInfo.processInfo.physicalMemory / 1048576) * autoRatio);
    } else {
        allocmem = getPrefInt(@"java.allocated_memory");
    }
    NSLog(@"[JavaLauncher] Max RAM allocation is set to %d MB", allocmem);

    // --- Start Building JVM Arguments ---
    int margc = -1;
    const char *margv[1000]; // Argument array

    // 0: Path to java executable
    margv[++margc] = [NSString stringWithFormat:@"%@/bin/java", javaHome].UTF8String;

    // 1: Force execution on first thread (macOS/iOS specific)
    margv[++margc] = "-XstartOnFirstThread";

    // 2: Add PojavClassLoader only if launching Minecraft (not a generic JAR)
    if (!launchJar) {
        margv[++margc] = "-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader";
    }

    // Common memory and path arguments
    margv[++margc] = "-Xms128M"; // Initial heap size
    margv[++margc] = [NSString stringWithFormat:@"-Xmx%dM", allocmem].UTF8String; // Max heap size
    margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@/Frameworks", NSBundle.mainBundle.bundlePath].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.dir=%@", gameDir].UTF8String; // Working directory
    margv[++margc] = [NSString stringWithFormat:@"-Duser.home=%s", getenv("POJAV_HOME")].UTF8String; // User home
    margv[++margc] = [NSString stringWithFormat:@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name].UTF8String; // Timezone

    // iOS Specific/LWJGL arguments
    margv[++margc] = [NSString stringWithFormat:@"-DUIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond].UTF8String;
    margv[++margc] = "-Dorg.lwjgl.glfw.checkThread0=false"; // LWJGL thread check
    margv[++margc] = "-Dorg.lwjgl.system.allocator=system"; // Use system allocator
    margv[++margc] = "-Dlog4j2.formatMsgNoLookups=true"; // Log4j vulnerability fix

    // Set OpenGL library based on renderer preference
    const char *glLibName = getenv("POJAV_RENDERER");
    if (glLibName) {
        if (!strcmp(glLibName, "auto")) { // Resolve 'auto' if needed
            glLibName = RENDERER_NAME_MTL_ANGLE; // Default to ANGLE if auto
        }
        margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.opengl.libname=%s", glLibName].UTF8String;
    }

    // Java Agents
    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/patchjna_agent.jar=", librariesPath].UTF8String; // JNA Patch Agent
    if(getPrefBool(@"general.cosmetica")) {
        margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/arc_dns_injector.jar=23.95.137.176", librariesPath].UTF8String; // Cosmetica DNS Agent
    }

    // Experimental VM Options
    margv[++margc] = "-XX:+UnlockExperimentalVMOptions";
    margv[++margc] = "-XX:+DisablePrimordialThreadGuardPages"; // Workaround stack guard crashes

    // Forge specific argument
    margv[++margc] = "-Dfml.earlyprogresswindow=false";

    // Load JLI library
    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome]; // Java 8 path
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome]; // Java 11+ path
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

    // Setup Caciocavallo AWT Headless GUI Arguments
    margv[++margc] = "-Djava.awt.headless=false";
    margv[++margc] = "-Dcacio.font.fontmanager=sun.awt.X11FontManager";
    margv[++margc] = "-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler";
    margv[++margc] = [NSString stringWithFormat:@"-Dcacio.managed.screensize=%dx%d", width, height].UTF8String;
    margv[++margc] = "-Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel";
    if (isJava8) {
        margv[++margc] = "-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit";
        margv[++margc] = "-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment";
    } else {
        // Java 17+ specific arguments for Cacio/module access
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
        margv[++margc] = "--add-exports=cpw.mods.bootstraplauncher/cpw.mods.bootstraplauncher=ALL-UNNAMED"; // Forge specific?
    }

    // Caciocavallo Boot Classpath
    NSString *cacio_classpath = [NSString stringWithFormat:@"-Xbootclasspath/%s", isJava8 ? "p" : "a"];
    NSString *cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo%s", NSBundle.mainBundle.bundlePath, isJava8 ? "" : "17"];
    NSArray *files = [fm contentsOfDirectoryAtPath:cacio_libs_path error:nil];
    for(NSString *file in files) {
        if ([file hasSuffix:@".jar"]) {
            cacio_classpath = [NSString stringWithFormat:@"%@:%@/%@", cacio_classpath, cacio_libs_path, file];
        }
    }
    margv[++margc] = cacio_classpath.UTF8String;

    // Compressed Oops/Class Pointers (disable if no extended VA entitlement)
    if (!getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")) {
        margv[++margc] = "-XX:-UseCompressedClassPointers";
    }

    // Add profile-specific JVM args (only for Minecraft launches)
    if (!launchJar && [launchTarget isKindOfClass:NSDictionary.class]) {
        NSDictionary *arguments = launchTarget[@"arguments"];
        if (arguments && [arguments isKindOfClass:[NSDictionary class]]) {
             NSArray *jvmProcessedArgs = arguments[@"jvm_processed"];
             if (jvmProcessedArgs && [jvmProcessedArgs isKindOfClass:[NSArray class]]) {
                 for (NSString *arg in jvmProcessedArgs) {
                     if ([arg isKindOfClass:[NSString class]]) { // Ensure it's a string
                         margv[++margc] = arg.UTF8String;
                     }
                 }
             }
        }
    }

    // Add user-defined custom JVM flags (from preferences)
    init_loadCustomJvmFlags(&margc, (const char **)margv);
    NSLog(@"[Init] Found JLI lib");

    // --- Classpath and Main Class/JAR Argument ---
    NSString *classpath = [NSString stringWithFormat:@"%@/*", librariesPath]; // Base classpath
    if (launchJar) {
        // Append the JAR itself to the classpath for -jar execution
        classpath = [classpath stringByAppendingFormat:@":%@", launchTarget];
    }
    margv[++margc] = "-cp";
    margv[++margc] = classpath.UTF8String;

    // Conditionally add main class OR -jar argument
    if (launchJar) {
        // For JAR launch: add -jar <path_to_jar>
        margv[++margc] = "-jar";
        margv[++margc] = [launchTarget UTF8String]; // launchTarget is the NSString path
    } else {
        // For Minecraft launch: add main class and its arguments
        margv[++margc] = "net.kdt.pojavlaunch.PojavLauncher";
        margv[++margc] = username.UTF8String; // Minecraft username
        if ([launchTarget isKindOfClass:NSDictionary.class] && launchTarget[@"id"]) {
             margv[++margc] = [launchTarget[@"id"] UTF8String]; // Minecraft version ID
        } else {
             margv[++margc] = "unknown-version"; // Fallback
             NSLog(@"[JavaLauncher] Warning: Could not determine version ID for Minecraft launch.");
        }
    }
    // Resolve JLI_Launch function pointer
    pJLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");

    if (NULL == pJLI_Launch) {
        NSLog(@"[Init] JLI_Launch = NULL");
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), @"Failed to find JLI_Launch symbol in Java runtime.");
        dlclose(libjli); // Close the library handle
        return -2;
    }

    NSLog(@"[Init] Calling JLI_Launch");

    // Reset signal handlers for JVM stability
    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);

    // Free split VC reference if it exists
    tmpRootVC = nil;

    // Log the final arguments being passed
    NSLog(@"[JavaLauncher] Final JVM Arguments (%d):", margc + 1);
    for (int i = 0; i <= margc; i++) {
        // Use %s for C strings, check for NULL pointers
        NSLog(@"[JavaLauncher] argv[%d]: %s", i, margv[i] ? margv[i] : "(null)");
    }

    // Execute the JVM
    // The JLI_Launch function signature parameters are:
    // 1. argc: Total argument count (including the java command itself).
    // 2. argv: Array of argument strings.
    // 3. jargc: Count of arguments for the main Java class (not used with -jar or standard main).
    // 4. jargv: Arguments for the main Java class.
    // 5. appclassc: Count of application classpath entries (usually 0, handled by -cp).
    // 6. appclassv: Application classpath entries.
    // 7. fullversion: Full Java version string.
    // 8. dotversion: Dotted Java version string.
    // 9. pname: Program name (usually "java").
    // 10. lname: Launcher name (e.g., "openjdk").
    // 11. javaargs: Boolean indicating if JAVA_ARGS environment variable should be used (usually false).
    // 12. cpwildcard: Boolean indicating if classpath wildcard (*) is supported (usually true).
    // 13. javaw: Boolean for Windows-specific javaw behavior (always false).
    // 14. ergo: Ergonomics class policy (often 0).
    int result = pJLI_Launch(++margc, margv, // Argument count (margc is index, so count is margc+1)
                   0, NULL,       // jargc, jargv
                   0, NULL,       // appclassc, appclassv
                   // These values are ignored in Java 17+, so keep it anyways
                   "1.8.0-internal",
                   "1.8",
                   "java",        // pname
                   "openjdk",     // lname
                   JNI_FALSE,     // javaargs
                   JNI_TRUE,      // cpwildcard
                   JNI_FALSE,     // javaw
                   0);            // ergo

    // Close the JLI library handle after launch attempt
    dlclose(libjli);

    return result;
}
