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
#import <objc/message.h>
#include <strings.h>
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
static void dump_methods(const char *cn, const char *pat)
{
	Class c = objc_getClass(cn);
	if (c == Nil) {
		fprintf(stderr, "topaz-fix: probe2 class %s not found\n", cn);
		return;
	}
	for (int meta = 0; meta < 2; meta++) {
		Class k = meta ? object_getClass(c) : c;
		unsigned n = 0;
		Method *ms = class_copyMethodList(k, &n);
		for (unsigned i = 0; i < n; i++) {
			const char *nm = sel_getName(method_getName(ms[i]));
			if (strcasestr(nm, pat) != NULL) {
				fprintf(stderr, "topaz-fix: probe2 %c[%s %s]\n", meta ? '+' : '-', cn, nm);
			}
		}
		free(ms);
	}
}

static void log_obj(const char *what, id o)
{
	fprintf(stderr, "topaz-fix: probe2 %s = %s\n", what, o == nil ? "(nil)" : [[o description] UTF8String]);
}

static void probe_camera2(void)
{
	id (*send)(id, SEL, ...) = (id (*)(id, SEL, ...))objc_msgSend;
	Class lsw = objc_getClass("LSApplicationWorkspace"), lsp = objc_getClass("LSApplicationProxy");
	if (lsw != Nil) {
		id ws = send((id)lsw, sel_registerName("defaultWorkspace"));
		BOOL (*sb)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
		fprintf(stderr, "topaz-fix: probe2 LS applicationIsInstalled(com.apple.camera) = %d\n",
		    (int)sb(ws, sel_registerName("applicationIsInstalled:"), @"com.apple.camera"));
	}
	if (lsp != Nil) {
		id px = send((id)lsp, sel_registerName("applicationProxyForIdentifier:"), @"com.apple.camera");
		log_obj("LS proxy", px);
		if (px != nil && [px respondsToSelector:sel_registerName("appTags")]) {
			log_obj("LS appTags", send(px, sel_registerName("appTags")));
		}
		if (px != nil && [px respondsToSelector:sel_registerName("isLaunchProhibited")]) {
			fprintf(stderr, "topaz-fix: probe2 LS isLaunchProhibited = %d\n",
			    (int)((BOOL (*)(id, SEL))objc_msgSend)(px, sel_registerName("isLaunchProhibited")));
		}
		if (px != nil && [px respondsToSelector:sel_registerName("isRestricted")]) {
			fprintf(stderr, "topaz-fix: probe2 LS isRestricted = %d\n",
			    (int)((BOOL (*)(id, SEL))objc_msgSend)(px, sel_registerName("isRestricted")));
		}
	}
	Class sbc = objc_getClass("SBApplicationController");
	if (sbc != Nil) {
		id ctl = send((id)sbc, sel_registerName("sharedInstanceIfExists"));
		log_obj("SBApplicationController", ctl);
		if (ctl != nil) {
			id app = send(ctl, sel_registerName("applicationWithBundleIdentifier:"), @"com.apple.camera");
			log_obj("SBApplication(com.apple.camera)", app);
		}
	}
	Class sbi = objc_getClass("SBIconController");
	if (sbi != Nil) {
		id ic = send((id)sbi, sel_registerName("sharedInstance"));
		id model = (ic != nil && [ic respondsToSelector:sel_registerName("model")]) ? send(ic, sel_registerName("model")) : nil;
		log_obj("SBIconModel", model);
		if (model != nil) {
			id icon = send(model, sel_registerName("leafIconForIdentifier:"), @"com.apple.camera");
			log_obj("leafIcon(com.apple.camera)", icon);
			id vis = [model respondsToSelector:sel_registerName("visibleIconIdentifiers")] ? send(model, sel_registerName("visibleIconIdentifiers")) : nil;
			fprintf(stderr, "topaz-fix: probe2 visible icon count = %lu\n", (unsigned long)[(NSSet *)vis count]);
		}
	}
	static const char *cls[] = {"SBApplicationInfo", "SBApplication", "SBApplicationController", "SBIconModel", "SBHIconModel", "SBApplicationIcon", NULL};
	static const char *pats[] = {"tag", "hiddenapp", NULL};
	for (int i = 0; cls[i] != NULL; i++) {
		for (int j = 0; pats[j] != NULL; j++) {
			dump_methods(cls[i], pats[j]);
		}
	}
}

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
	@autoreleasepool {
		probe_camera2();
	}
	return NULL;
}

/*
 * Camera.app is hidden by SpringBoard (SBAppTags still-camera) because MobileGestalt computes still-camera = 0 here
 * (no camera driver). Replace MGGetBoolAnswer/MGCopyAnswer through dyld interposing: the camera capability keys answer yes.
 * Only the keys needed to show the icon; there is no camera behind it.
 */
extern bool MGGetBoolAnswer(CFStringRef key);
extern CFTypeRef MGCopyAnswer(CFStringRef key);
static int cam_key(CFStringRef k)
{
	return k != NULL && CFStringCompare(k, CFSTR("still-camera"), 0) == kCFCompareEqualTo;
}
static bool my_MGGetBoolAnswer(CFStringRef k)
{
	if (cam_key(k)) {
		static int once;
		if (!once++) {
			fprintf(stderr, "topaz-fix: MGGetBoolAnswer(still-camera) forced to 1\n");
		}
		return true;
	}
	return MGGetBoolAnswer(k);
}
static CFTypeRef my_MGCopyAnswer(CFStringRef k)
{
	if (cam_key(k)) {
		static int once;
		if (!once++) {
			fprintf(stderr, "topaz-fix: MGCopyAnswer(still-camera) forced to true\n");
		}
		return CFRetain(kCFBooleanTrue);
	}
	return MGCopyAnswer(k);
}
#define TOPAZ_INTERPOSE(rep, orig) \
	__attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##orig \
	__attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&rep, (const void *)(unsigned long)&orig };
TOPAZ_INTERPOSE(my_MGGetBoolAnswer, MGGetBoolAnswer)
TOPAZ_INTERPOSE(my_MGCopyAnswer, MGCopyAnswer)

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
