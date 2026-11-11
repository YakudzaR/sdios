/*
 * StressTest: a small app that stresses what the spes port could get wrong and prints a counter line every
 * 5 seconds (stderr, so boot-arg sweetnull=StressTest or the USB live log shows it; also appended to
 * <Documents>/stress.log). Workers: CPU hashing (result checked against the first run), memory churn (patterns
 * written and verified), file write/fsync/read-back (checksum), network download loop, and a Core Animation
 * scene with shadows and a blur (frame counter). Any "bad" counter above 0 is a real error: a wrong result from
 * the CPU, RAM, storage or a failed read-back. Nothing here is a benchmark.
 */
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h>

static atomic_ullong g_cpu_iters, g_cpu_bad, g_mem_iters, g_mem_bad, g_file_iters, g_file_bad;
static atomic_ullong g_net_ok, g_net_fail, g_net_bytes, g_frames;
static time_t g_start;
static char g_logpath[1024];
static char g_status[512];

static void slog(const char *fmt, ...)
{
	char line[600];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	fprintf(stderr, "stress: %s\n", line);
	fflush(stderr);
	if (g_logpath[0] != 0) {
		FILE *f = fopen(g_logpath, "a");
		if (f != NULL) {
			fprintf(f, "%s\n", line);
			fclose(f);
		}
	}
}

static uint64_t fnv(const uint8_t *p, size_t n, uint64_t h)
{
	for (size_t i = 0; i < n; i++) {
		h ^= p[i];
		h *= 1099511628211ull;
	}
	return h;
}

/* CPU: the same buffer hashed over and over; a different result is a wrong computation */
static void *cpu_worker(void *arg)
{
	static uint8_t buf[256 * 1024];
	for (size_t i = 0; i < sizeof(buf); i++) {
		buf[i] = (uint8_t)(i * 2654435761u >> 13);
	}
	uint64_t want = fnv(buf, sizeof(buf), 1469598103934665603ull);
	for (;;) {
		uint64_t got = fnv(buf, sizeof(buf), 1469598103934665603ull);
		if (got != want) {
			atomic_fetch_add(&g_cpu_bad, 1);
		}
		atomic_fetch_add(&g_cpu_iters, 1);
		if ((g_cpu_iters & 15) == 0) {
			usleep(2000);   /* leave the UI some time */
		}
	}
	return NULL;
}

/* memory: blocks of 1-16 MB filled with a pattern, kept for a while (up to ~64 MB), verified, freed */
#define RING 8
static void *mem_worker(void *arg)
{
	void *blk[RING] = { 0 };
	size_t len[RING] = { 0 };
	uint32_t seed[RING] = { 0 };
	uint32_t rng = 12345;
	unsigned slot = 0;
	for (;;) {
		if (blk[slot] != NULL) {
			uint32_t *w = (uint32_t *)blk[slot];
			size_t n = len[slot] / 4;
			for (size_t i = 0; i < n; i += 251) {
				if (w[i] != (seed[slot] ^ (uint32_t)i)) {
					atomic_fetch_add(&g_mem_bad, 1);
					break;
				}
			}
			free(blk[slot]);
		}
		rng = rng * 1664525u + 1013904223u;
		len[slot] = (size_t)(1 + (rng >> 8) % 16) << 20;
		blk[slot] = malloc(len[slot]);
		if (blk[slot] != NULL) {
			seed[slot] = rng;
			uint32_t *w = (uint32_t *)blk[slot];
			size_t n = len[slot] / 4;
			for (size_t i = 0; i < n; i++) {
				w[i] = seed[slot] ^ (uint32_t)i;
			}
		}
		atomic_fetch_add(&g_mem_iters, 1);
		slot = (slot + 1) % RING;
		usleep(150000);
	}
	return NULL;
}

/* storage: 1 MB written, fsync'd, read back, compared */
static void *file_worker(void *arg)
{
	char path[1100];
	snprintf(path, sizeof(path), "%s.bin", g_logpath);
	size_t n = 1 << 20;
	uint8_t *out = malloc(n), *in = malloc(n);
	uint32_t rng = 777;
	for (;;) {
		for (size_t i = 0; i < n; i += 4) {
			rng = rng * 1664525u + 1013904223u;
			*(uint32_t *)(out + i) = rng;
		}
		int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (fd >= 0) {
			ssize_t w = write(fd, out, n);
			fsync(fd);
			close(fd);
			fd = open(path, O_RDONLY);
			ssize_t r = fd >= 0 ? read(fd, in, n) : -1;
			if (fd >= 0) {
				close(fd);
			}
			if (w != (ssize_t)n || r != (ssize_t)n || memcmp(in, out, n) != 0) {
				atomic_fetch_add(&g_file_bad, 1);
			}
		} else {
			atomic_fetch_add(&g_file_bad, 1);
		}
		atomic_fetch_add(&g_file_iters, 1);
		sleep(3);
	}
	return NULL;
}

/* network: one 1 MB download every 15 s */
static void *net_worker(void *arg)
{
	@autoreleasepool {
		NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
		c.timeoutIntervalForRequest = 20;
		NSURLSession *s = [NSURLSession sessionWithConfiguration:c];
		NSURL *u = [NSURL URLWithString:@"https://speed.cloudflare.com/__down?bytes=1000000"];
		for (;;) {
			dispatch_semaphore_t sem = dispatch_semaphore_create(0);
			[[s dataTaskWithURL:u completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
				if (e == nil && d.length >= 1000000) {
					atomic_fetch_add(&g_net_ok, 1);
					atomic_fetch_add(&g_net_bytes, d.length);
				} else {
					atomic_fetch_add(&g_net_fail, 1);
				}
				dispatch_semaphore_signal(sem);
			}] resume];
			dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
			sleep(15);
		}
	}
	return NULL;
}

static unsigned long long footprint_mb(void)
{
	task_vm_info_data_t v;
	mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&v, &n) != KERN_SUCCESS) {
		return 0;
	}
	return v.phys_footprint >> 20;
}

static void *beat_worker(void *arg)
{
	unsigned long long lastframes = 0;
	for (;;) {
		sleep(5);
		unsigned long long fr = g_frames;
		long up = (long)(time(NULL) - g_start);
		snprintf(g_status, sizeof(g_status),
		    "up %lds  fps %.0f  mem %lluMB\ncpu %llu bad %llu\nmem %llu bad %llu\nfile %llu bad %llu\nnet ok %llu fail %llu (%llu KB)",
		    up, (double)(fr - lastframes) / 5.0, footprint_mb(), (unsigned long long)g_cpu_iters,
		    (unsigned long long)g_cpu_bad, (unsigned long long)g_mem_iters, (unsigned long long)g_mem_bad,
		    (unsigned long long)g_file_iters, (unsigned long long)g_file_bad, (unsigned long long)g_net_ok,
		    (unsigned long long)g_net_fail, (unsigned long long)g_net_bytes / 1024);
		slog("up=%ld fps=%.0f mem=%lluMB cpu=%llu/%llu mem=%llu/%llu file=%llu/%llu net=%llu/%llu bytes=%llu",
		    up, (double)(fr - lastframes) / 5.0, footprint_mb(), (unsigned long long)g_cpu_iters,
		    (unsigned long long)g_cpu_bad, (unsigned long long)g_mem_iters, (unsigned long long)g_mem_bad,
		    (unsigned long long)g_file_iters, (unsigned long long)g_file_bad, (unsigned long long)g_net_ok,
		    (unsigned long long)g_net_fail, (unsigned long long)g_net_bytes);
		lastframes = fr;
	}
	return NULL;
}

@interface StressVC : UIViewController
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) NSMutableArray<CALayer *> *dots;
@end

@implementation StressVC
- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.1 blue:0.25 alpha:1];
	self.dots = [NSMutableArray array];
	for (int i = 0; i < 40; i++) {
		CALayer *l = [CALayer layer];
		l.bounds = CGRectMake(0, 0, 60, 60);
		l.cornerRadius = 30;
		l.backgroundColor = [UIColor colorWithHue:i / 40.0 saturation:0.8 brightness:0.95 alpha:1].CGColor;
		l.shadowOpacity = 0.7;
		l.shadowRadius = 8;
		l.shadowOffset = CGSizeMake(0, 4);
		l.position = CGPointMake(40 + (i % 5) * 70, 200 + (i / 5) * 80);
		[self.view.layer addSublayer:l];
		[self.dots addObject:l];
		CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
		a.toValue = @(2 * M_PI);
		a.duration = 2 + (i % 7) * 0.4;
		a.repeatCount = HUGE_VALF;
		[l addAnimation:a forKey:@"spin"];
		CABasicAnimation *m = [CABasicAnimation animationWithKeyPath:@"position.x"];
		m.byValue = @(60);
		m.autoreverses = YES;
		m.duration = 1.5 + (i % 5) * 0.3;
		m.repeatCount = HUGE_VALF;
		[l addAnimation:m forKey:@"move"];
	}
	UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
	blur.frame = CGRectMake(0, 40, self.view.bounds.size.width, 150);
	blur.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[self.view addSubview:blur];
	self.label = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, self.view.bounds.size.width - 20, 150)];
	self.label.numberOfLines = 0;
	self.label.font = [UIFont fontWithName:@"Menlo" size:11];
	self.label.textColor = [UIColor whiteColor];
	self.label.text = @"StressTest starting...";
	[blur.contentView addSubview:self.label];
	CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
	[dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}
- (void)tick:(CADisplayLink *)dl
{
	unsigned long long f = atomic_fetch_add(&g_frames, 1);
	if ((f % 30) == 0 && g_status[0] != 0) {
		self.label.text = [NSString stringWithUTF8String:g_status];
	}
}
@end

@interface StressApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

static void uncaught(NSException *e)
{
	slog("UNCAUGHT %s: %s", [[e name] UTF8String], [[e reason] UTF8String]);
}

@implementation StressApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts
{
	NSSetUncaughtExceptionHandler(uncaught);
	g_start = time(NULL);
	NSArray *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *dir = d.count > 0 ? d[0] : NSTemporaryDirectory();
	[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	snprintf(g_logpath, sizeof(g_logpath), "%s/stress.log", [dir fileSystemRepresentation]);
	slog("started, log %s", g_logpath);
	pthread_t t;
	for (int i = 0; i < 2; i++) {
		pthread_create(&t, NULL, cpu_worker, NULL);
		pthread_detach(t);
	}
	pthread_create(&t, NULL, mem_worker, NULL); pthread_detach(t);
	pthread_create(&t, NULL, file_worker, NULL); pthread_detach(t);
	pthread_create(&t, NULL, net_worker, NULL); pthread_detach(t);
	pthread_create(&t, NULL, beat_worker, NULL); pthread_detach(t);
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	self.window.rootViewController = [StressVC new];
	[self.window makeKeyAndVisible];
	[UIApplication sharedApplication].idleTimerDisabled = YES;
	return YES;
}
@end

int main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([StressApp class]));
	}
}
