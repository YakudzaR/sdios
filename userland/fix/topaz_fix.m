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
#include <spawn.h>
#include <Block.h>
#include <sys/wait.h>
extern char **environ;
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
			/* list the access-related selectors of PLPrivacy (instance and class), to find the other checks */
			for (int k = 0; k < 2; k++) {
				unsigned cnt = 0;
				Method *ml = class_copyMethodList(k == 0 ? c : object_getClass((id)c), &cnt);
				for (unsigned j = 0; j < cnt; j++) {
					const char *nm = sel_getName(method_getName(ml[j]));
					if (strcasestr(nm, "access") || strcasestr(nm, "auth") || strcasestr(nm, "tcc") || strcasestr(nm, "allowed")) {
						fprintf(stderr, "topaz-fix: PLPrivacy %c %s\n", k == 0 ? '-' : '+', nm);
					}
				}
				free(ml);
			}
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

/*
 * CoreImage's default context goes through EAGL/OpenGL ES (CI::GLContext::init), which does not exist on this GPU stack:
 * it calls a null pointer (MobileSafari crashed on a long press on an image). Ask for the CPU renderer instead.
 */
static IMP orig_ci;
static id my_ci(id cls, SEL _cmd, NSDictionary *opts)
{
	CFStringRef *key = (CFStringRef *)dlsym(RTLD_DEFAULT, "kCIContextUseSoftwareRenderer");
	if (key != NULL && *key != NULL) {
		NSMutableDictionary *m = opts != nil ? [opts mutableCopy] : [NSMutableDictionary dictionary];
		[m setObject:[NSNumber numberWithBool:YES] forKey:(NSString *)*key];
		id r = ((id (*)(id, SEL, id))orig_ci)(cls, _cmd, m);
		static int once;
		if (!once++) {
			fprintf(stderr, "topaz-fix: CIContext contextWithOptions: forced the software renderer (%p)\n", (void *)r);
		}
		return r;
	}
	return ((id (*)(id, SEL, id))orig_ci)(cls, _cmd, opts);
}

/* the shared CIContext cannot be created here (EAGL/GL missing): hand back nil instead of crashing */
static id my_single(id cls, SEL _cmd)
{
	static int once;
	if (!once++) {
		fprintf(stderr, "topaz-fix: +[CIContext _singletonContext] returns nil (no GL)\n");
	}
	return nil;
}

/*
 * Safari "Add to Photos" did nothing: PHPhotoLibrary's client-side permission (TCC photos, normally a prompt from
 * SpringBoard) is never granted here. Answer "authorized" (PHAuthorizationStatusAuthorized = 3) for the status and request
 * calls, and log what performChanges:completionHandler: ends with (success / error).
 */
static NSInteger my_ph_status(id self, SEL _cmd)
{
	static int n;
	if (n++ < 5) {
		fprintf(stderr, "topaz-fix: PHPhotoLibrary %s -> authorized\n", sel_getName(_cmd));
	}
	return 3;
}

static NSInteger my_ph_status_lvl(id self, SEL _cmd, NSInteger level)
{
	static int n;
	if (n++ < 5) {
		fprintf(stderr, "topaz-fix: PHPhotoLibrary %s(%ld) -> authorized\n", sel_getName(_cmd), (long)level);
	}
	return 3;
}

static void my_ph_request(id self, SEL _cmd, void (^handler)(NSInteger))
{
	fprintf(stderr, "topaz-fix: PHPhotoLibrary %s -> authorized\n", sel_getName(_cmd));
	if (handler != NULL) {
		handler(3);
	}
}

static void my_ph_request_lvl(id self, SEL _cmd, NSInteger level, void (^handler)(NSInteger))
{
	fprintf(stderr, "topaz-fix: PHPhotoLibrary %s(%ld) -> authorized\n", sel_getName(_cmd), (long)level);
	if (handler != NULL) {
		handler(3);
	}
}

static void (*orig_ph_perform)(id, SEL, void (^)(void), void (^)(BOOL, NSError *));
static void my_ph_perform(id self, SEL _cmd, void (^changes)(void), void (^done)(BOOL, NSError *))
{
	void (^d2)(BOOL, NSError *) = done != NULL ? Block_copy(done) : NULL;
	fprintf(stderr, "topaz-fix: PHPhotoLibrary performChanges called\n");
	orig_ph_perform(self, _cmd, changes, ^(BOOL ok, NSError *e) {
		fprintf(stderr, "topaz-fix: PHPhotoLibrary performChanges finished: ok %d error %s\n", (int)ok,
		    e != nil ? [[e description] UTF8String] : "none");
		if (d2 != NULL) {
			d2(ok, e);
			Block_release(d2);
		}
	});
}

static void *watch_phauth(void *unused)
{
	dlopen("/System/Library/Frameworks/Photos.framework/Photos", RTLD_NOW);
	for (int i = 0; i < 6000; i++) {
		Class c = objc_getClass("PHPhotoLibrary");
		if (c != Nil) {
			Class mc = object_getClass((id)c);
			Method m1 = class_getInstanceMethod(mc, sel_registerName("authorizationStatus"));
			Method m2 = class_getInstanceMethod(mc, sel_registerName("authorizationStatusForAccessLevel:"));
			Method m3 = class_getInstanceMethod(mc, sel_registerName("requestAuthorization:"));
			Method m4 = class_getInstanceMethod(mc, sel_registerName("requestAuthorizationForAccessLevel:handler:"));
			Method m5 = class_getInstanceMethod(c, sel_registerName("performChanges:completionHandler:"));
			if (m1 != NULL) {
				method_setImplementation(m1, (IMP)my_ph_status);
			}
			if (m2 != NULL) {
				method_setImplementation(m2, (IMP)my_ph_status_lvl);
			}
			if (m3 != NULL) {
				method_setImplementation(m3, (IMP)my_ph_request);
			}
			if (m4 != NULL) {
				method_setImplementation(m4, (IMP)my_ph_request_lvl);
			}
			if (m5 != NULL) {
				orig_ph_perform = (void (*)(id, SEL, void (^)(void), void (^)(BOOL, NSError *)))method_setImplementation(m5, (IMP)my_ph_perform);
			}
			fprintf(stderr, "topaz-fix: patched PHPhotoLibrary (%p %p %p %p %p)\n", (void *)m1, (void *)m2, (void *)m3, (void *)m4, (void *)m5);
			return NULL;
		}
		usleep(20000);
	}
	return NULL;
}

static void *watch_ci(void *unused)
{
	for (int i = 0; i < 6000; i++) {
		Class c = objc_getClass("CIContext");
		if (c != Nil) {
			Method m = class_getClassMethod(c, sel_registerName("contextWithOptions:"));
			if (m != NULL) {
				orig_ci = method_setImplementation(m, (IMP)my_ci);
			}
			Method sm = class_getClassMethod(c, sel_registerName("_singletonContext"));
			if (sm != NULL) {
				method_setImplementation(sm, (IMP)my_single);
			}
			fprintf(stderr, "topaz-fix: patched CIContext (%p) singleton (%p)\n", (void *)m, (void *)sm);
			return NULL;
		}
		usleep(20000);
	}
	return NULL;
}

/*
 * Photos (MobileSlideShow) aborts in -[PXZoomableInlineHeadersDataSourceManager initWithAssetsDataSourceManager:]
 * (assert numberOfSections == 1) once the library holds an asset. NSAssert just returns when the handler does not throw:
 * ignore that one assertion (and log it), let every other one through.
 */
static IMP orig_assert;
static void my_assert(id self, SEL _cmd, SEL sel, id obj, NSString *file, NSInteger line, NSString *fmt)
{
	if (file != nil && [file hasPrefix:@"PX"]) {
		/* Photos' own PhotosUI sources (PX*.m): the library data source is not shaped as they expect, carry on */
		static int n;
		if (n++ < 40) {
			fprintf(stderr, "topaz-fix: ignored assertion in %s:%ld\n", [file UTF8String], (long)line);
		}
		return;
	}
	((void (*)(id, SEL, SEL, id, NSString *, NSInteger, NSString *))orig_assert)(self, _cmd, sel, obj, file, line, fmt);
}

/*
 * -[PXSearchHistoryManager _recentSearchesFileURL] builds its path from a directory that comes back nil here and puts it in an
 * array (Search tab crash: attempt to insert nil object). Use a file in the app's temporary directory.
 */
static id my_recent_url(id self, SEL _cmd)
{
	static int once;
	NSString *dir = NSTemporaryDirectory();
	if (!once++) {
		fprintf(stderr, "topaz-fix: PXSearchHistoryManager recent searches file in %s\n", [dir UTF8String]);
	}
	return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"RecentSearches.plist"]];
}

static void *watch_search(void *unused)
{
	for (int i = 0; i < 6000; i++) {
		Class c = objc_getClass("PXSearchHistoryManager");
		if (c != Nil) {
			Method m = class_getInstanceMethod(c, sel_registerName("_recentSearchesFileURL"));
			if (m != NULL) {
				method_setImplementation(m, (IMP)my_recent_url);
			}
			fprintf(stderr, "topaz-fix: patched PXSearchHistoryManager (%p)\n", (void *)m);
			return NULL;
		}
		usleep(20000);
	}
	return NULL;
}

/*
 * syncdefaultsd: for each client it takes the process path from proc_pidpath_audittoken, makes an NSString with
 * +stringWithUTF8String: and a URL with +fileURLWithPath:isDirectory:. Here the string comes back nil (the path bytes are not
 * valid UTF-8), the URL call throws 'nil string parameter' and syncdefaultsd dies in a restart loop. Log the bytes, fall
 * back to Latin-1 for the string and to "/" for the URL.
 */
static IMP orig_utf8, orig_fileurl;
static id my_utf8(id cls, SEL _cmd, const char *cs)
{
	id r = ((id (*)(id, SEL, const char *))orig_utf8)(cls, _cmd, cs);
	if (r == nil && cs != NULL) {
		static int n;
		if (n++ < 5) {
			char hex[200];
			size_t i = 0, o = 0;
			for (; i < 48 && cs[i] != 0 && o + 3 < sizeof(hex); i++) {
				o += (size_t)snprintf(hex + o, sizeof(hex) - o, "%02x", (unsigned char)cs[i]);
			}
			hex[o] = 0;
			fprintf(stderr, "topaz-fix: stringWithUTF8String: was nil for %zu+ bytes: %s\n", i, hex);
		}
		return [[[NSString alloc] initWithCString:cs encoding:NSISOLatin1StringEncoding] autorelease];
	}
	return r;
}
static id my_fileurl(id cls, SEL _cmd, NSString *path, BOOL dir)
{
	if (path == nil) {
		static int n;
		if (n++ < 5) {
			fprintf(stderr, "topaz-fix: fileURLWithPath:isDirectory: got a nil path, using /\n");
		}
		path = @"/";
	}
	return ((id (*)(id, SEL, id, BOOL))orig_fileurl)(cls, _cmd, path, dir);
}

/*
 * PosterBoard: -[PBFHomeScreenPreviewImageBuilder _imageForView:] builds an @{} with the rendered snapshot of the
 * home screen view; without a working renderer that image is nil and NSDictionary throws (kills PosterBoard when
 * Settings > Wallpaper or the lock screen editor asks for a preview). Return nil instead of throwing.
 */
static id my_imageForView(id self, SEL _cmd, id view)
{
	static int n;
	if (n++ < 5) {
		fprintf(stderr, "topaz-fix: PosterBoard: _imageForView: skipped (no snapshot)\n");
	}
	return nil;
}

static void *watch_poster(void *unused)
{
	for (int i = 0; i < 6000; i++) {
		Class c = objc_getClass("PBFHomeScreenPreviewImageBuilder");
		if (c != Nil) {
			Method m = class_getInstanceMethod(c, sel_registerName("_imageForView:"));
			if (m != NULL) {
				method_setImplementation(m, (IMP)my_imageForView);
			}
			fprintf(stderr, "topaz-fix: PosterBoard: patched _imageForView: (%p)\n", (void *)m);
			return NULL;
		}
		usleep(20000);
	}
	return NULL;
}

/*
 * Wi-Fi auto-join helper (SpringBoard). wifid never joins a saved network by itself here (it scans and stops, and
 * the join on a tap works). A minute after start: if no network is joined, ask MobileWiFi to join the saved network
 * that was joined last (what Settings does on a tap). At most 8 tries, 20 s apart; stops once joined.
 */
typedef void *WFRef;
static WFRef (*wf_mgr_create)(CFAllocatorRef, CFOptionFlags);
static CFArrayRef (*wf_mgr_devices)(WFRef);
static CFArrayRef (*wf_mgr_networks)(WFRef);
static void (*wf_mgr_schedule)(WFRef, CFRunLoopRef, CFStringRef);
static WFRef (*wf_dev_current)(WFRef);
static int (*wf_dev_assoc)(WFRef, WFRef, void *, void *);
static CFStringRef (*wf_net_ssid)(WFRef);
static CFTypeRef (*wf_net_prop)(WFRef, CFStringRef);
static WFRef wf_mgr;
static int wf_tries;

static void wf_cb(void *a, void *b, void *c, void *d, void *e)
{
	fprintf(stderr, "topaz-fix: wifi helper: join callback err/ptr %p %p\n", c, d);
}

static void wf_tick(CFRunLoopTimerRef timer, void *info)
{
	if (wf_tries >= 8) {
		fprintf(stderr, "topaz-fix: wifi helper: giving up\n");
		CFRunLoopTimerInvalidate(timer);
		return;
	}
	CFArrayRef devs = wf_mgr_devices(wf_mgr);
	if (devs == NULL || CFArrayGetCount(devs) < 1) {
		fprintf(stderr, "topaz-fix: wifi helper: no wifi device yet\n");
		return;
	}
	WFRef dev = (WFRef)CFArrayGetValueAtIndex(devs, 0);
	if (wf_dev_current(dev) != NULL) {
		fprintf(stderr, "topaz-fix: wifi helper: already joined, done\n");
		CFRunLoopTimerInvalidate(timer);
		return;
	}
	CFArrayRef nets = wf_mgr_networks(wf_mgr);
	if (nets == NULL || CFArrayGetCount(nets) < 1) {
		fprintf(stderr, "topaz-fix: wifi helper: no saved networks\n");
		return;
	}
	WFRef best = NULL;
	CFDateRef bestd = NULL;
	for (CFIndex i = 0; i < CFArrayGetCount(nets); i++) {
		WFRef n = (WFRef)CFArrayGetValueAtIndex(nets, i);
		CFTypeRef d = wf_net_prop != NULL ? wf_net_prop(n, CFSTR("lastJoined")) : NULL;
		if (best == NULL || (d != NULL && CFGetTypeID(d) == CFDateGetTypeID() &&
		    (bestd == NULL || CFDateCompare((CFDateRef)d, bestd, NULL) == kCFCompareGreaterThan))) {
			best = n;
			bestd = (d != NULL && CFGetTypeID(d) == CFDateGetTypeID()) ? (CFDateRef)d : NULL;
		}
	}
	wf_tries++;
	CFStringRef ssid = wf_net_ssid != NULL ? wf_net_ssid(best) : NULL;
	char name[64] = "?";
	if (ssid != NULL) {
		CFStringGetCString(ssid, name, sizeof(name), kCFStringEncodingUTF8);
	}
	fprintf(stderr, "topaz-fix: wifi helper: try %d, joining the saved network (%zu chars)\n", wf_tries, strlen(name));
	int r = wf_dev_assoc(dev, best, (void *)wf_cb, NULL);
	fprintf(stderr, "topaz-fix: wifi helper: AssociateAsync returned %d\n", r);
}

static void *wifi_helper(void *unused)
{
	sleep(60);
	void *h = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_NOW);
	if (h == NULL) {
		fprintf(stderr, "topaz-fix: wifi helper: no MobileWiFi\n");
		return NULL;
	}
	*(void **)&wf_mgr_create = dlsym(h, "WiFiManagerClientCreate");
	*(void **)&wf_mgr_devices = dlsym(h, "WiFiManagerClientCopyDevices");
	*(void **)&wf_mgr_networks = dlsym(h, "WiFiManagerClientCopyNetworks");
	*(void **)&wf_mgr_schedule = dlsym(h, "WiFiManagerClientScheduleWithRunLoop");
	*(void **)&wf_dev_current = dlsym(h, "WiFiDeviceClientCopyCurrentNetwork");
	*(void **)&wf_dev_assoc = dlsym(h, "WiFiDeviceClientAssociateAsync");
	*(void **)&wf_net_ssid = dlsym(h, "WiFiNetworkGetSSID");
	*(void **)&wf_net_prop = dlsym(h, "WiFiNetworkGetProperty");
	fprintf(stderr, "topaz-fix: wifi helper: symbols %p %p %p %p %p %p %p\n", (void *)wf_mgr_create, (void *)wf_mgr_devices,
	    (void *)wf_mgr_networks, (void *)wf_mgr_schedule, (void *)wf_dev_current, (void *)wf_dev_assoc, (void *)wf_net_ssid);
	if (!wf_mgr_create || !wf_mgr_devices || !wf_mgr_networks || !wf_mgr_schedule || !wf_dev_current || !wf_dev_assoc) {
		return NULL;
	}
	wf_mgr = wf_mgr_create(kCFAllocatorDefault, 0);
	if (wf_mgr == NULL) {
		fprintf(stderr, "topaz-fix: wifi helper: no manager\n");
		return NULL;
	}
	wf_mgr_schedule(wf_mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
	CFRunLoopTimerRef t = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1, 20, 0, 0, wf_tick, NULL);
	CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopDefaultMode);
	fprintf(stderr, "topaz-fix: wifi helper: running\n");
	CFRunLoopRun();
	return NULL;
}

/*
 * Registrar (SpringBoard): apps copied into /Applications from the PC (tools/sweet-install-app.sh) are unknown to
 * LaunchServices, so no icon appears. A minute after start (then every 20 s, 10 rounds) ask LaunchServices to
 * register every /Applications/*.app whose bundle id begins with "com.topaz." and is not installed yet.
 */
static void *app_registrar(void *unused)
{
	sleep(40);
	dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
	for (int round = 0; round < 10; round++) {
		@autoreleasepool {
			Class wc = objc_getClass("LSApplicationWorkspace");
			id w = wc != Nil ? ((id (*)(id, SEL))objc_msgSend)((id)wc, sel_registerName("defaultWorkspace")) : nil;
			if (w == nil) {
				fprintf(stderr, "topaz-fix: registrar: no LSApplicationWorkspace\n");
				return NULL;
			}
			for (NSString *n in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/Applications" error:nil]) {
				if (![n hasSuffix:@".app"]) {
					continue;
				}
				NSString *p = [@"/Applications" stringByAppendingPathComponent:n];
				NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Info.plist"]];
				NSString *bid = [info objectForKey:@"CFBundleIdentifier"];
				if (bid == nil || [bid hasPrefix:@"com.apple."]) {
					continue; /* Apple's own apps are the system's business; every other app in /Applications is registered */
				}
				BOOL inst = ((BOOL (*)(id, SEL, id))objc_msgSend)(w, sel_registerName("applicationIsInstalled:"), bid);
				if (inst) {
					if (round == 0) {
						fprintf(stderr, "topaz-fix: registrar: %s already registered\n", [bid UTF8String]);
					}
					continue;
				}
				BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(w, sel_registerName("registerApplication:"),
				    [NSURL fileURLWithPath:p isDirectory:YES]);
				fprintf(stderr, "topaz-fix: registrar: registerApplication %s -> %d\n", [bid UTF8String], (int)ok);
				if (!ok) {
					/* what worked in the lsreg test: registerApplicationDictionary: with Info.plist + ApplicationType + Path */
					NSMutableDictionary *d = [info mutableCopy];
					d[@"ApplicationType"] = @"System";
					d[@"Path"] = p;
					d[@"IsDeletable"] = @NO;
					SEL sd = sel_registerName("registerApplicationDictionary:");
					if ([w respondsToSelector:sd]) {
						BOOL r = ((BOOL (*)(id, SEL, id))objc_msgSend)(w, sd, d);
						ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(w, sel_registerName("applicationIsInstalled:"), bid);
						fprintf(stderr, "topaz-fix: registrar: registerApplicationDictionary %s -> %d, installed %d\n", [bid UTF8String], (int)r, (int)ok);
					}
				}
				if (!ok && access("/topaz/bin/lsreg", X_OK) == 0) {
					/* the entitled helper tries every registration API and logs what each says (stderr + /var/mobile/lsreg.log) */
					pid_t pid = 0;
					const char *av[] = {"/topaz/bin/lsreg", [p fileSystemRepresentation], NULL};
					int sp = posix_spawn(&pid, "/topaz/bin/lsreg", NULL, NULL, (char *const *)av, environ);
					int status = 0;
					if (sp == 0) {
						waitpid(pid, &status, 0);
					}
					fprintf(stderr, "topaz-fix: registrar: spawned lsreg for %s: spawn %d status 0x%x\n", [bid UTF8String], sp, status);
				}
			}
		}
		sleep(20);
	}
	return NULL;
}

/*
 * AegirPoster (Astronomy wallpaper): NUNIAegirRenderer getOrCreateUniformBufferforFrameBufferIndex: makes an MTLBuffer and
 * puts it in an array; here the buffer comes back nil, the array insert throws and the process aborts every ~5 s.
 * Call the original inside @try; on an exception log it and return nil (no uniform buffer = nothing drawn, no abort).
 */
static id (*orig_aegir_ub)(id, SEL, NSUInteger);
static id my_aegir_ub(id self, SEL _cmd, NSUInteger idx)
{
	static int n;
	@try {
		return orig_aegir_ub(self, _cmd, idx);
	} @catch (NSException *e) {
		if (n++ < 5) {
			fprintf(stderr, "topaz-fix: AegirPoster: uniform buffer %lu failed (%s), skipped\n", (unsigned long)idx, [[e reason] UTF8String]);
		}
		return nil;
	}
}

/* _renderOffscreenBackgroundWithRenderEncoder:frameBufferIndex: uses the uniform buffer straight away (null deref when it is nil):
 * skip the pass when there is no buffer. */
static void (*orig_aegir_bg)(id, SEL, id, NSUInteger);
static void my_aegir_bg(id self, SEL _cmd, id enc, NSUInteger idx)
{
	static int n;
	if (my_aegir_ub(self, sel_registerName("getOrCreateUniformBufferforFrameBufferIndex:"), idx) == nil) {
		if (n++ < 5) {
			fprintf(stderr, "topaz-fix: AegirPoster: background pass skipped (no uniform buffer)\n");
		}
		return;
	}
	orig_aegir_bg(self, _cmd, enc, idx);
}

/* The uniform buffer never comes back here, and the scene pass dereferences it: skip the render call (void return only,
 * arguments are not used so the viewport struct does not matter). The wallpaper stays blank, the process stays alive. */
static void my_aegir_render_skip(id self, SEL _cmd)
{
	static int n;
	if (n++ < 3) {
		fprintf(stderr, "topaz-fix: AegirPoster: %s skipped\n", sel_getName(_cmd));
	}
}

static void *watch_aegir(void *unused)
{
	for (int i = 0; i < 6000; i++) {
		Class c = objc_getClass("NUNIAegirRenderer");
		if (c != Nil) {
			Method m = class_getInstanceMethod(c, sel_registerName("getOrCreateUniformBufferforFrameBufferIndex:"));
			if (m != NULL) {
				orig_aegir_ub = (id (*)(id, SEL, NSUInteger))method_setImplementation(m, (IMP)my_aegir_ub);
			}
			Method m2 = class_getInstanceMethod(c, sel_registerName("_renderOffscreenBackgroundWithRenderEncoder:frameBufferIndex:"));
			if (m2 != NULL) {
				orig_aegir_bg = (void (*)(id, SEL, id, NSUInteger))method_setImplementation(m2, (IMP)my_aegir_bg);
			}
			Method m3 = class_getInstanceMethod(c, sel_registerName("renderWithScene:viewport:commandBuffer:passDescriptor:"));
			if (m3 != NULL) {
				char *rt = method_copyReturnType(m3);
				fprintf(stderr, "topaz-fix: AegirPoster: renderWithScene return type %s\n", rt);
				if (strcmp(rt, "v") == 0) {
					method_setImplementation(m3, (IMP)my_aegir_render_skip);
				}
				free(rt);
			}
			fprintf(stderr, "topaz-fix: AegirPoster: patched getOrCreateUniformBuffer (%p) background (%p)\n", (void *)m, (void *)m2);
			return NULL;
		}
		usleep(20000);
	}
	return NULL;
}

static void aegir_exc(NSException *e)
{
	fprintf(stderr, "topaz-fix: poster exception %s: %s\n", [[e name] UTF8String], [[e reason] UTF8String]);
	NSArray *st = [e callStackSymbols];
	for (NSUInteger i = 0; i < [st count] && i < 12; i++) {
		fprintf(stderr, "topaz-fix:   %s\n", [[st objectAtIndex:i] UTF8String]);
	}
	fflush(stderr);
}

__attribute__((constructor)) static void topaz_fix_init(void)
{
	const char *pn = getprogname();
	if (pn != NULL && strcmp(pn, "SpringBoard") == 0) {
		/* the probes (probe_camera, probe_camera2) crashed SpringBoard from a background thread: not started any more */
		pthread_t t7;
		if (pthread_create(&t7, NULL, wifi_helper, NULL) == 0) {
			pthread_detach(t7);
		}
		pthread_t t8;
		if (pthread_create(&t8, NULL, app_registrar, NULL) == 0) {
			pthread_detach(t8);
		}
		return;
	}
	/*
	 * The media library (MusicLibrary.framework, ML3MusicLibraryResourcesManager) takes its base path from
	 * getenv("IPHONE_SHARED_RESOURCES_DIRECTORY") + "/Media". Real iOS sets it for every app; here nothing does,
	 * so the path (and databasePath) is nil. Set it before anything asks.
	 */
	if (pn != NULL && (strcmp(pn, "AegirPoster") == 0 || strcmp(pn, "PosterBoard") == 0)) {
		NSSetUncaughtExceptionHandler(aegir_exc);
		fprintf(stderr, "topaz-fix: %s exception logger installed\n", pn);
		if (strcmp(pn, "AegirPoster") == 0) {
			pthread_t t9;
			if (pthread_create(&t9, NULL, watch_aegir, NULL) == 0) {
				pthread_detach(t9);
			}
		}
		if (strcmp(pn, "PosterBoard") == 0) {
			pthread_t t6;
			if (pthread_create(&t6, NULL, watch_poster, NULL) == 0) {
				pthread_detach(t6);
			}
		}
		return;
	}
	if (pn != NULL && strcmp(pn, "syncdefaultsd") == 0) {
		Method m1 = class_getClassMethod(objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"));
		Method m2 = class_getClassMethod(objc_getClass("NSURL"), sel_registerName("fileURLWithPath:isDirectory:"));
		if (m1 != NULL) {
			orig_utf8 = method_setImplementation(m1, (IMP)my_utf8);
		}
		if (m2 != NULL) {
			orig_fileurl = method_setImplementation(m2, (IMP)my_fileurl);
		}
		fprintf(stderr, "topaz-fix: syncdefaultsd patched (%p %p)\n", (void *)m1, (void *)m2);
		return;
	}
	if (pn != NULL && strcmp(pn, "MobileSlideShow") == 0) {
		Class ah = objc_getClass("NSAssertionHandler");
		Method am = ah != Nil ? class_getInstanceMethod(ah, sel_registerName("handleFailureInMethod:object:file:lineNumber:description:")) : NULL;
		if (am != NULL) {
			orig_assert = method_setImplementation(am, (IMP)my_assert);
		}
		fprintf(stderr, "topaz-fix: Photos: assertion handler patched (%p)\n", (void *)am);
		pthread_t t5;
		if (pthread_create(&t5, NULL, watch_search, NULL) == 0) {
			pthread_detach(t5);
		}
		return;
	}
	if (pn != NULL && strcmp(pn, "MobileSafari") == 0) {
		pthread_t t4;
		if (pthread_create(&t4, NULL, watch_ci, NULL) == 0) {
			pthread_detach(t4);
		}
		pthread_t t10;
		if (pthread_create(&t10, NULL, watch_phauth, NULL) == 0) {
			pthread_detach(t10);
		}
		pthread_t t11;
		if (pthread_create(&t11, NULL, watch_photos, NULL) == 0) {
			pthread_detach(t11);
		}
		return;
	}
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
