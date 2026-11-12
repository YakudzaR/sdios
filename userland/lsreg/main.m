/*
 * lsreg: try to register an .app with LaunchServices, with a lot of entitlements (ad-hoc signed, the kernel AMFI shim
 * honours the entitlements of the signature). Prints what every API answers, to stderr and /var/mobile/lsreg.log.
 *   lsreg /Applications/StressTest.app
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <unistd.h>

static FILE *g_log;
static void say(const char *fmt, ...)
{
	va_list ap;
	char b[1024];
	va_start(ap, fmt);
	vsnprintf(b, sizeof b, fmt, ap);
	va_end(ap);
	fprintf(stderr, "lsreg: %s\n", b);
	if (g_log) {
		fprintf(g_log, "%s\n", b);
		fflush(g_log);
	}
}

static BOOL installed(id w, NSString *bid)
{
	return ((BOOL (*)(id, SEL, id))objc_msgSend)(w, sel_registerName("applicationIsInstalled:"), bid);
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		g_log = fopen("/var/mobile/lsreg.log", "a");
		if (argc < 2) {
			say("usage: lsreg /Applications/X.app");
			return 2;
		}
		NSString *p = [NSString stringWithUTF8String:argv[1]];
		say("uid %d euid %d path %s", getuid(), geteuid(), argv[1]);
		void *h = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
		say("CoreServices dlopen %p", h);
		Class wc = objc_getClass("LSApplicationWorkspace");
		id w = wc != Nil ? ((id (*)(id, SEL))objc_msgSend)((id)wc, sel_registerName("defaultWorkspace")) : nil;
		if (w == nil) {
			say("no LSApplicationWorkspace");
			return 1;
		}
		NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Info.plist"]];
		NSString *bid = info[@"CFBundleIdentifier"];
		say("bundle id %s, installed before: %d", bid.UTF8String, (int)installed(w, bid));

		NSURL *u = [NSURL fileURLWithPath:p isDirectory:YES];
		BOOL r1 = ((BOOL (*)(id, SEL, id))objc_msgSend)(w, sel_registerName("registerApplication:"), u);
		say("registerApplication: -> %d, installed %d", (int)r1, (int)installed(w, bid));

		NSMutableDictionary *d = [info mutableCopy];
		d[@"ApplicationType"] = @"System";
		d[@"Path"] = p;
		d[@"IsDeletable"] = @NO;
		SEL sd = sel_registerName("registerApplicationDictionary:");
		if ([w respondsToSelector:sd]) {
			BOOL r2 = ((BOOL (*)(id, SEL, id))objc_msgSend)(w, sd, d);
			say("registerApplicationDictionary: -> %d, installed %d", (int)r2, (int)installed(w, bid));
		} else {
			say("no registerApplicationDictionary:");
		}

		SEL si = sel_registerName("installApplication:withOptions:error:");
		if ([w respondsToSelector:si]) {
			NSError *err = nil;
			BOOL r3 = ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(w, si, u, @{@"PackageType": @"Placeholder"}, &err);
			say("installApplication:withOptions:error: -> %d err %s, installed %d", (int)r3, err.description.UTF8String ?: "none", (int)installed(w, bid));
		}

		int (*lsru)(CFURLRef, Boolean) = dlsym(RTLD_DEFAULT, "_LSRegisterURL");
		if (lsru) {
			int st = lsru((__bridge CFURLRef)u, true);
			say("_LSRegisterURL -> %d, installed %d", st, (int)installed(w, bid));
		} else {
			say("no _LSRegisterURL");
		}
		say("final: installed %d", (int)installed(w, bid));
	}
	return 0;
}
