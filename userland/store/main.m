/*
 * Store: shows what the on-device IPA installer (userland/installer, watcher in libtopaz-fix.dylib) has done.
 *   - Installed apps: every app in /Applications whose bundle id is not com.apple.* (tap = open, swipe = uninstall).
 *   - Waiting: .ipa files found in the watched folders; tap one to install it (nothing installs on its own).
 *   - Install log: the end of /var/mobile/Media/Install/status.log, newest first (INSTALLED / FAILED / WARNING).
 * Install and uninstall are request files (/var/mobile/Media/Install/install-<id>.req holds the ipa path). Uninstall is a request file (/var/mobile/Media/Install/uninstall-<bundle id>.req containing the app path): the watcher
 * in SpringBoard unregisters the app and the setuid helper deletes it, about 20 s later. The app itself needs no root.
 */
#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <unistd.h>

static NSString *const kDir = @"/var/mobile/Media/Install";

@interface AppEntry : NSObject
@property (nonatomic, copy) NSString *name, *bid, *version, *path;
@property (nonatomic) unsigned long long size;
@end
@implementation AppEntry
@end

@interface StoreVC : UITableViewController
@property (nonatomic, strong) NSArray<AppEntry *> *apps;
@property (nonatomic, strong) NSArray<NSDictionary *> *pending;
@property (nonatomic, strong) NSArray<NSAttributedString *> *logLines;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *sizes;
@property (nonatomic, strong) NSTimer *timer;
@end

static NSString *human(unsigned long long b)
{
	if (b == 0) {
		return @"…";
	}
	if (b < 1024 * 1024) {
		return [NSString stringWithFormat:@"%.0f KB", b / 1024.0];
	}
	return [NSString stringWithFormat:@"%.1f MB", b / 1048576.0];
}

@implementation StoreVC

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Store";
	self.sizes = [NSMutableDictionary dictionary];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Refresh" style:UIBarButtonItemStylePlain
	    target:self action:@selector(reload)];
	[self reload];
	self.timer = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(reload) userInfo:nil repeats:YES];
}

- (void)reload
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSMutableArray *apps = [NSMutableArray array];
	for (NSString *n in [fm contentsOfDirectoryAtPath:@"/Applications" error:nil]) {
		if (![n hasSuffix:@".app"]) {
			continue;
		}
		NSString *p = [@"/Applications" stringByAppendingPathComponent:n];
		NSDictionary *i = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Info.plist"]];
		NSString *bid = i[@"CFBundleIdentifier"];
		if (bid == nil || [bid hasPrefix:@"com.apple."]) {
			continue;
		}
		AppEntry *e = [AppEntry new];
		e.path = p;
		e.bid = bid;
		e.name = i[@"CFBundleDisplayName"] ?: (i[@"CFBundleName"] ?: [n stringByDeletingPathExtension]);
		e.version = i[@"CFBundleShortVersionString"] ?: @"?";
		e.size = [self.sizes[p] unsignedLongLongValue];
		[apps addObject:e];
		if (self.sizes[p] == nil) {
			self.sizes[p] = @0;
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
				unsigned long long total = 0;
				for (NSString *f in [[NSFileManager defaultManager] enumeratorAtPath:p]) {
					NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:[p stringByAppendingPathComponent:f] error:nil];
					total += [a fileSize];
				}
				dispatch_async(dispatch_get_main_queue(), ^{
					self.sizes[p] = @(total);
					[self reload];
				});
			});
		}
	}
	[apps sortUsingComparator:^NSComparisonResult(AppEntry *a, AppEntry *b) {
		return [a.name caseInsensitiveCompare:b.name];
	}];
	self.apps = apps;

	NSMutableArray *pend = [NSMutableArray array];
	NSMutableArray *dirs = [NSMutableArray arrayWithObjects:kDir, @"/var/mobile/Media/Downloads", nil];
	NSString *root = @"/var/mobile/Containers/Data/Application";
	for (NSString *u in [fm contentsOfDirectoryAtPath:root error:nil]) {
		NSString *dl = [[root stringByAppendingPathComponent:u] stringByAppendingPathComponent:@"Library/Safari/Downloads"];
		for (NSString *s in [fm contentsOfDirectoryAtPath:dl error:nil]) {
			[dirs addObject:[dl stringByAppendingPathComponent:s]];
		}
	}
	for (NSString *d in dirs) {
		for (NSString *n in [fm contentsOfDirectoryAtPath:d error:nil]) {
			if ([[n pathExtension] caseInsensitiveCompare:@"ipa"] == NSOrderedSame) {
				unsigned long long sz = [[fm attributesOfItemAtPath:[d stringByAppendingPathComponent:n] error:nil] fileSize];
				NSString *full = [d stringByAppendingPathComponent:n];
				NSString *req = [kDir stringByAppendingPathComponent:[NSString stringWithFormat:@"install-%lx.req", (unsigned long)[full hash]]];
				[pend addObject:@{@"name": n, @"path": full, @"size": @(sz), @"req": req,
				    @"requested": @([fm fileExistsAtPath:req])}];
			}
		}
	}
	self.pending = pend;

	NSString *log = [NSString stringWithContentsOfFile:[kDir stringByAppendingPathComponent:@"status.log"] encoding:NSUTF8StringEncoding error:nil];
	NSMutableArray *lines = [NSMutableArray array];
	NSArray *all = [log componentsSeparatedByString:@"\n"];
	NSDateFormatter *df = [NSDateFormatter new];
	df.dateFormat = @"MM-dd HH:mm:ss";
	for (NSInteger i = (NSInteger)all.count - 1; i >= 0 && lines.count < 40; i--) {
		NSString *l = all[(NSUInteger)i];
		if (l.length == 0) {
			continue;
		}
		NSRange sp = [l rangeOfString:@" "];
		NSString *text = l;
		if (sp.location != NSNotFound && sp.location > 5) {
			NSTimeInterval ts = [[l substringToIndex:sp.location] doubleValue];
			if (ts > 1e9) {
				text = [NSString stringWithFormat:@"%@  %@", [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]], [l substringFromIndex:sp.location + 1]];
			}
		}
		UIColor *c = [UIColor labelColor];
		if ([l containsString:@"FAILED"]) {
			c = [UIColor systemRedColor];
		} else if ([l containsString:@"WARNING"]) {
			c = [UIColor systemOrangeColor];
		} else if ([l containsString:@"INSTALLED"]) {
			c = [UIColor systemGreenColor];
		}
		[lines addObject:[[NSAttributedString alloc] initWithString:text attributes:@{NSForegroundColorAttributeName: c,
		    NSFontAttributeName: [UIFont systemFontOfSize:12]}]];
	}
	self.logLines = lines;
	[self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv
{
	return 3;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
	NSUInteger n = s == 0 ? self.apps.count : (s == 1 ? self.pending.count : self.logLines.count);
	return n == 0 ? 1 : (NSInteger)n;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s
{
	return s == 0 ? @"Installed apps" : (s == 1 ? @"Waiting to install" : @"Install log (newest first)");
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s
{
	if (s == 0) {
		BOOL ok = access("/topaz/bin/topaz-install", X_OK) == 0;
		return [NSString stringWithFormat:@"Installer helper: %@. Tap an app to open it, swipe left to uninstall.",
		    ok ? @"ready" : @"MISSING (/topaz/bin/topaz-install)"];
	}
	if (s == 1) {
		return [NSString stringWithFormat:@"Download an .ipa in Safari or drop it in %@. It appears here; tap it to install (about 20-40 s). Wait until the download has finished.", kDir];
	}
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
	UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
	if (c == nil) {
		c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
	}
	c.accessoryType = UITableViewCellAccessoryNone;
	c.detailTextLabel.text = nil;
	c.textLabel.attributedText = nil;
	c.textLabel.numberOfLines = 0;
	c.textLabel.font = [UIFont systemFontOfSize:16];
	c.textLabel.textColor = [UIColor labelColor];
	if (ip.section == 0) {
		if (self.apps.count == 0) {
			c.textLabel.text = @"No apps installed yet";
			c.textLabel.textColor = [UIColor secondaryLabelColor];
			return c;
		}
		AppEntry *e = self.apps[(NSUInteger)ip.row];
		c.textLabel.text = e.name;
		c.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  v%@  ·  %@", e.bid, e.version, human([self.sizes[e.path] unsignedLongLongValue])];
	} else if (ip.section == 1) {
		if (self.pending.count == 0) {
			c.textLabel.text = @"Nothing waiting";
			c.textLabel.textColor = [UIColor secondaryLabelColor];
		} else {
			NSDictionary *p = self.pending[(NSUInteger)ip.row];
			c.textLabel.text = p[@"name"];
			c.detailTextLabel.text = [p[@"requested"] boolValue] ? [NSString stringWithFormat:@"%@  ·  installing…", human([p[@"size"] unsignedLongLongValue])]
			    : [NSString stringWithFormat:@"%@  ·  tap to install", human([p[@"size"] unsignedLongLongValue])];
			c.accessoryType = [p[@"requested"] boolValue] ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
		}
	} else {
		if (self.logLines.count == 0) {
			c.textLabel.text = @"No installs yet";
			c.textLabel.textColor = [UIColor secondaryLabelColor];
		} else {
			c.textLabel.attributedText = self.logLines[(NSUInteger)ip.row];
		}
	}
	return c;
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip
{
	return ip.section == 0 && self.apps.count > 0 && ![self.apps[(NSUInteger)ip.row].bid isEqualToString:@"com.topaz.store"];
}

- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip
{
	return @"Uninstall";
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip
{
	if (st != UITableViewCellEditingStyleDelete || ip.section != 0) {
		return;
	}
	AppEntry *e = self.apps[(NSUInteger)ip.row];
	UIAlertController *a = [UIAlertController alertControllerWithTitle:[@"Uninstall " stringByAppendingString:e.name]
	    message:@"The app and its files are deleted in about 20 seconds." preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { [self.tableView reloadData]; }]];
	[a addAction:[UIAlertAction actionWithTitle:@"Uninstall" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
		NSString *req = [kDir stringByAppendingPathComponent:[NSString stringWithFormat:@"uninstall-%@.req", e.bid]];
		NSError *err = nil;
		if (![e.path writeToFile:req atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
			[self say:@"Cannot write the request" text:err.localizedDescription ?: req];
		} else {
			[self say:@"Requested" text:@"It disappears in about 20 seconds."];
		}
		[self.tableView reloadData];
	}]];
	[self presentViewController:a animated:YES completion:nil];
}

- (void)say:(NSString *)title text:(NSString *)text
{
	UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
	[tv deselectRowAtIndexPath:ip animated:YES];
	if (ip.section == 1 && self.pending.count > 0) {
		NSDictionary *p = self.pending[(NSUInteger)ip.row];
		if ([p[@"requested"] boolValue]) {
			return;
		}
		UIAlertController *a = [UIAlertController alertControllerWithTitle:[@"Install " stringByAppendingString:p[@"name"]]
		    message:[NSString stringWithFormat:@"%@. Make sure the download has finished.", human([p[@"size"] unsignedLongLongValue])]
		    preferredStyle:UIAlertControllerStyleAlert];
		[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
		[a addAction:[UIAlertAction actionWithTitle:@"Install" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
			NSError *err = nil;
			if (![p[@"path"] writeToFile:p[@"req"] atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
				[self say:@"Cannot write the request" text:err.localizedDescription ?: p[@"req"]];
			}
			[self reload];
		}]];
		[self presentViewController:a animated:YES completion:nil];
		return;
	}
	if (ip.section != 0 || self.apps.count == 0) {
		return;
	}
	AppEntry *e = self.apps[(NSUInteger)ip.row];
	dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
	Class wc = NSClassFromString(@"LSApplicationWorkspace");
	id w = wc ? ((id (*)(id, SEL))objc_msgSend)((id)wc, NSSelectorFromString(@"defaultWorkspace")) : nil;
	BOOL ok = w ? ((BOOL (*)(id, SEL, id))objc_msgSend)(w, NSSelectorFromString(@"openApplicationWithBundleID:"), e.bid) : NO;
	if (!ok) {
		[self say:@"Could not open" text:e.bid];
	}
}

@end

@interface StoreApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation StoreApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o
{
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	StoreVC *vc = [[StoreVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
	self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:vc];
	[self.window makeKeyAndVisible];
	return YES;
}
@end

int main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([StoreApp class]));
	}
}
