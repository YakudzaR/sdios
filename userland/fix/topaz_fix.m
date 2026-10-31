/*
 * libtopaz-fix.dylib (private build, local only): inserted into Settings (Preferences) by the kernel
 * (boot-arg topaz_inject=...;/topaz/lib/libtopaz-fix.dylib,Preferences).
 *
 * Settings > General > About and iPhone Storage trap in PodcastsUI, which force-unwraps
 * [[MPMediaLibrary defaultMediaLibrary] databasePath]. On this device that comes back nil (the media
 * library's resource manager has no path), so the app dies. This hands back the media library's
 * well-known path when MediaPlayer has none, and logs what it saw on stderr. The cause is that
 * IPHONE_SHARED_RESOURCES_DIRECTORY is not set in the process; the constructor sets it.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#import <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <unistd.h>

static IMP orig_dbpath, orig_default;
static NSString *const kFallback = @"/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb";

static id my_dbpath(id self, SEL _cmd)
{
	id r = ((id (*)(id, SEL))orig_dbpath)(self, _cmd);
	if (r == nil) {
		fprintf(stderr, "topaz-fix: databasePath of %p was nil, using the default path\n", (void *)self);
		return kFallback;
	}
	fprintf(stderr, "topaz-fix: databasePath of %p is %s\n", (void *)self, [[r description] UTF8String]);
	return r;
}

static id my_default(id cls, SEL _cmd)
{
	id r = ((id (*)(id, SEL))orig_default)(cls, _cmd);
	fprintf(stderr, "topaz-fix: defaultMediaLibrary = %p\n", (void *)r);
	return r;
}

/*
 * assetsd (Photos) raises 'assetsd requires TCCPhotosService access' when
 * -[PLPrivacy photosAccessAllowedWithScope:] returns nonzero at start-up. Log what it returns and report 0.
 */
static IMP orig_photos;
static uintptr_t my_photos(id self, SEL _cmd, uintptr_t scope)
{
	uintptr_t r = ((uintptr_t (*)(id, SEL, uintptr_t))orig_photos)(self, _cmd, scope);
	fprintf(stderr, "topaz-fix: photosAccessAllowedWithScope:%lu was %lu, returning 0\n", (unsigned long)scope, (unsigned long)r);
	return 0;
}

static void *watch_photos(void *unused)
{
	for (int i = 0; i < 6000; i++) {
		Class c = objc_getClass("PLPrivacy");
		if (c != Nil) {
			Method m = class_getInstanceMethod(c, sel_registerName("photosAccessAllowedWithScope:"));
			if (m != NULL) {
				orig_photos = method_setImplementation(m, (IMP)my_photos);
			}
			fprintf(stderr, "topaz-fix: patched PLPrivacy (%p)\n", (void *)m);
			return NULL;
		}
		usleep(2000);
	}
	fprintf(stderr, "topaz-fix: PLPrivacy never appeared\n");
	return NULL;
}

static void *watch(void *unused)
{
	for (int i = 0; i < 6000; i++) {
		Class c = objc_getClass("MPMediaLibrary");
		if (c != Nil) {
			Method m = class_getInstanceMethod(c, sel_registerName("databasePath"));
			Method d = class_getClassMethod(c, sel_registerName("defaultMediaLibrary"));
			if (m != NULL) {
				orig_dbpath = method_setImplementation(m, (IMP)my_dbpath);
			}
			if (d != NULL) {
				orig_default = method_setImplementation(d, (IMP)my_default);
			}
			fprintf(stderr, "topaz-fix: patched MPMediaLibrary (databasePath %p, defaultMediaLibrary %p)\n", (void *)m, (void *)d);
			return NULL;
		}
		usleep(20000);
	}
	return NULL;
}

/*
 * SpringBoard hides Camera.app (SBAppTags still-camera) when MobileGestalt says there is no still camera.
 * Log what MobileGestalt answers for the camera keys and whether the device-tree nodes it reads exist.
 */
static void *probe_camera(void *unused)
{
	sleep(25);
	bool (*getbool)(CFStringRef) = (bool (*)(CFStringRef))dlsym(RTLD_DEFAULT, "MGGetBoolAnswer");
	CFTypeRef (*copy)(CFStringRef) = (CFTypeRef (*)(CFStringRef))dlsym(RTLD_DEFAULT, "MGCopyAnswer");
	fprintf(stderr, "topaz-fix: probe MGGetBoolAnswer %p MGCopyAnswer %p\n", (void *)getbool, (void *)copy);
	static const char *keys[] = {"still-camera", "camera-front", "camera-rear", "auto-focus-camera", "video-camera",
	    "camera-flash", "front-facing-camera", "rear-facing-camera", "camera-live-effects", "RearCameraCapability",
	    "FrontFacingCameraHDRCapability", "HasBaseband", "wifi", "telephony", "gps", NULL};
	for (int i = 0; keys[i] != NULL && getbool != NULL; i++) {
		CFStringRef k = CFStringCreateWithCString(NULL, keys[i], kCFStringEncodingUTF8);
		bool v = getbool(k);
		fprintf(stderr, "topaz-fix: probe %s = %d\n", keys[i], (int)v);
		CFRelease(k);
	}
	typedef unsigned int (*frompath_t)(unsigned int, const char *);
	frompath_t frompath = (frompath_t)dlsym(RTLD_DEFAULT, "IORegistryEntryFromPath");
	static const char *paths[] = {"IODeviceTree:/arm-io/isp", "IODeviceTree:/product/camera", "IODeviceTree:/product", NULL};
	for (int i = 0; paths[i] != NULL && frompath != NULL; i++) {
		fprintf(stderr, "topaz-fix: probe %s -> entry %u\n", paths[i], frompath(0, paths[i]));
	}
	return NULL;
}

__attribute__((constructor)) static void topaz_fix_init(void)
{
	const char *pn = getprogname();
	if (pn != NULL && strcmp(pn, "SpringBoard") == 0) {
		pthread_t t3;
		if (pthread_create(&t3, NULL, probe_camera, NULL) == 0) {
			pthread_detach(t3);
		}
		return;
	}
	/*
	 * The media library (MusicLibrary.framework, ML3MusicLibraryResourcesManager) takes its base path from
	 * getenv("IPHONE_SHARED_RESOURCES_DIRECTORY") + "/Media". Real iOS sets it for every app; here nothing does,
	 * so the path (and databasePath) is nil. Set it before anything asks.
	 */
	if (pn != NULL && strcmp(pn, "Preferences") != 0 && strcmp(pn, "assetsd") != 0) {
		return;
	}
	if (getenv("IPHONE_SHARED_RESOURCES_DIRECTORY") == NULL) {
		setenv("IPHONE_SHARED_RESOURCES_DIRECTORY", "/var/mobile", 0);
		fprintf(stderr, "topaz-fix: IPHONE_SHARED_RESOURCES_DIRECTORY was not set, now /var/mobile\n");
	}
	if (pn != NULL && strcmp(pn, "assetsd") == 0) {
		Class c = objc_getClass("PLPrivacy");
		if (c != Nil) {
			watch_photos(NULL);
		} else {
			pthread_t t2;
			if (pthread_create(&t2, NULL, watch_photos, NULL) == 0) {
				pthread_detach(t2);
			}
		}
		return;
	}
	if (pn != NULL && strcmp(pn, "Preferences") != 0) {
		return;		/* injected with *app: only Settings needs the media library fix */
	}
	pthread_t t;
	if (pthread_create(&t, NULL, watch, NULL) == 0) {
		pthread_detach(t);
	}
}
