/*
 * topaz-install: install an .ipa into /Applications (the app is then registered by the SpringBoard registrar in
 * libtopaz-fix.dylib). Meant to be setuid root (installed by tools/sweet-install-installer.sh): it writes root-owned files.
 *   topaz-install /path/App.ipa
 * Steps: unzip Payload/ (own zip reader + zlib, crc checked) into /Applications/.topaz-work-PID, find X.app, refuse
 * com.apple.* and FairPlay-encrypted apps, warn when the main executable has no code signature, chmod/chown the tree
 * (dirs 755, Mach-O 755, other files 644, root:wheel), move it to /Applications/X.app (old one removed), rename the
 * ipa to .done / .failed. Log: stderr and /var/mobile/Media/Install/status.log.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <zlib.h>
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#endif

static FILE *g_log;
static const char *g_apps = "/Applications";

static void say(const char *fmt, ...)
{
	char b[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(b, sizeof b, fmt, ap);
	va_end(ap);
	fprintf(stderr, "topaz-install: %s\n", b);
	if (g_log) {
		fprintf(g_log, "%ld %s\n", (long)time(NULL), b);
		fflush(g_log);
	}
}

static int mkdir_p(const char *path, mode_t mode)
{
	char tmp[4096];
	size_t n = strlen(path);
	if (n >= sizeof tmp) {
		return -1;
	}
	memcpy(tmp, path, n + 1);
	for (size_t i = 1; i < n; i++) {
		if (tmp[i] == '/') {
			tmp[i] = 0;
			if (mkdir(tmp, mode) != 0 && errno != EEXIST) {
				return -1;
			}
			tmp[i] = '/';
		}
	}
	if (mkdir(tmp, mode) != 0 && errno != EEXIST) {
		return -1;
	}
	return 0;
}

static void rmtree(const char *path)
{
	struct stat st;
	if (lstat(path, &st) != 0) {
		return;
	}
	if (S_ISDIR(st.st_mode)) {
		DIR *d = opendir(path);
		if (d) {
			struct dirent *e;
			while ((e = readdir(d)) != NULL) {
				if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) {
					continue;
				}
				char p[4096];
				snprintf(p, sizeof p, "%s/%s", path, e->d_name);
				rmtree(p);
			}
			closedir(d);
		}
		rmdir(path);
	} else {
		unlink(path);
	}
}

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

/* a stored/deflated entry's bytes into fd (or into a malloc'ed buffer when fd < 0); crc checked. 0 = ok */
static int entry_data(const uint8_t *zip, size_t zlen, uint32_t lho, uint32_t method, uint32_t csize, uint32_t usize,
    uint32_t crc, int fd, uint8_t **out)
{
	if ((uint64_t)lho + 30 > zlen || rd32(zip + lho) != 0x04034b50) {
		return -1;
	}
	uint64_t doff = (uint64_t)lho + 30 + rd16(zip + lho + 26) + rd16(zip + lho + 28);
	if (doff + csize > zlen) {
		return -2;
	}
	const uint8_t *src = zip + doff;
	uint32_t c = crc32(0, Z_NULL, 0);
	uint8_t *buf = NULL;
	size_t bufpos = 0;
	if (fd < 0) {
		buf = malloc((size_t)usize + 1);
		if (!buf) {
			return -3;
		}
	}
	if (method == 0) {
		if (csize != usize) {
			free(buf);
			return -4;
		}
		c = crc32(c, src, csize);
		if (fd >= 0) {
			size_t off = 0;
			while (off < csize) {
				ssize_t w = write(fd, src + off, csize - off);
				if (w <= 0) {
					return -5;
				}
				off += (size_t)w;
			}
		} else {
			memcpy(buf, src, csize);
			bufpos = csize;
		}
	} else if (method == 8) {
		z_stream zs;
		memset(&zs, 0, sizeof zs);
		if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) {
			free(buf);
			return -6;
		}
		static uint8_t chunk[65536];
		zs.next_in = (Bytef *)src;
		zs.avail_in = csize;
		int r;
		do {
			zs.next_out = chunk;
			zs.avail_out = sizeof chunk;
			r = inflate(&zs, Z_NO_FLUSH);
			if (r != Z_OK && r != Z_STREAM_END) {
				inflateEnd(&zs);
				free(buf);
				return -7;
			}
			size_t have = sizeof chunk - zs.avail_out;
			c = crc32(c, chunk, (uInt)have);
			if (fd >= 0) {
				size_t off = 0;
				while (off < have) {
					ssize_t w = write(fd, chunk + off, have - off);
					if (w <= 0) {
						inflateEnd(&zs);
						return -5;
					}
					off += (size_t)w;
				}
			} else {
				if (bufpos + have > usize) {
					inflateEnd(&zs);
					free(buf);
					return -8;
				}
				memcpy(buf + bufpos, chunk, have);
				bufpos += have;
			}
		} while (r != Z_STREAM_END);
		uint64_t total = zs.total_out;
		inflateEnd(&zs);
		if (total != usize) {
			free(buf);
			return -9;
		}
	} else {
		free(buf);
		return -10;
	}
	if (c != crc) {
		free(buf);
		return -11;
	}
	if (buf) {
		buf[bufpos] = 0;
		*out = buf;
	}
	return 0;
}

/* extract every "Payload/..." entry into dir. returns number of files, < 0 on error */
static int unzip_payload(const char *ipa, const char *dir)
{
	int fd = open(ipa, O_RDONLY);
	if (fd < 0) {
		say("cannot open %s: %s", ipa, strerror(errno));
		return -1;
	}
	struct stat st;
	fstat(fd, &st);
	size_t zlen = (size_t)st.st_size;
	if (zlen < 22) {
		close(fd);
		say("file too small to be a zip");
		return -1;
	}
	const uint8_t *zip = mmap(NULL, zlen, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if (zip == MAP_FAILED) {
		say("mmap failed: %s", strerror(errno));
		return -1;
	}
	size_t e = zlen - 22;
	size_t lim = zlen > 65557 ? zlen - 65557 : 0;
	while (e > lim && rd32(zip + e) != 0x06054b50) {
		e--;
	}
	if (rd32(zip + e) != 0x06054b50) {
		munmap((void *)zip, zlen);
		say("no zip end record (incomplete download?)");
		return -1;
	}
	uint32_t entries = rd16(zip + e + 10), cdsize = rd32(zip + e + 12), cdoff = rd32(zip + e + 16);
	if (entries == 0xffff || cdsize == 0xffffffffu || cdoff == 0xffffffffu) {
		munmap((void *)zip, zlen);
		say("zip64 archives are not supported");
		return -1;
	}
	if ((uint64_t)cdoff + cdsize > zlen) {
		munmap((void *)zip, zlen);
		say("central directory outside the file (incomplete download?)");
		return -1;
	}
	int files = 0;
	size_t p = cdoff;
	for (uint32_t i = 0; i < entries; i++) {
		if (p + 46 > zlen || rd32(zip + p) != 0x02014b50) {
			say("bad central directory entry %u", i);
			files = -1;
			break;
		}
		uint16_t flags = rd16(zip + p + 8), method = rd16(zip + p + 10);
		uint32_t crc = rd32(zip + p + 16), csize = rd32(zip + p + 20), usize = rd32(zip + p + 24);
		uint16_t nlen = rd16(zip + p + 28), xlen = rd16(zip + p + 30), clen = rd16(zip + p + 32);
		uint32_t xattr = rd32(zip + p + 38), lho = rd32(zip + p + 42);
		char name[2048];
		if (nlen >= sizeof name || p + 46 + nlen > zlen) {
			say("bad name length");
			files = -1;
			break;
		}
		memcpy(name, zip + p + 46, nlen);
		name[nlen] = 0;
		p += 46 + nlen + xlen + clen;
		if (strncmp(name, "Payload/", 8) != 0 || strlen(name) == 8) {
			continue;
		}
		if (name[0] == '/' || strstr(name, "../") != NULL || (nlen >= 2 && !strcmp(name + nlen - 2, "..")) || (flags & 1)) {
			say("refusing unsafe or encrypted zip entry %s", name);
			files = -1;
			break;
		}
		char dest[4096];
		snprintf(dest, sizeof dest, "%s/%s", dir, name);
		if (name[nlen - 1] == '/') {
			dest[strlen(dest) - 1] = 0;
			if (mkdir_p(dest, 0755) != 0) {
				say("mkdir %s failed: %s", dest, strerror(errno));
				files = -1;
				break;
			}
			continue;
		}
		char parent[4096];
		strcpy(parent, dest);
		char *sl = strrchr(parent, '/');
		if (sl) {
			*sl = 0;
			mkdir_p(parent, 0755);
		}
		if (((xattr >> 16) & 0xF000) == 0xA000) {
			uint8_t *target = NULL;
			if (entry_data(zip, zlen, lho, method, csize, usize, crc, -1, &target) != 0) {
				say("cannot read symlink %s", name);
				files = -1;
				break;
			}
			if (target[0] == '/' || strstr((char *)target, "..") == (char *)target) {
				say("refusing symlink %s -> %s", name, target);
				free(target);
				files = -1;
				break;
			}
			symlink((char *)target, dest);
			free(target);
			continue;
		}
		int ofd = open(dest, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (ofd < 0) {
			say("cannot create %s: %s", dest, strerror(errno));
			files = -1;
			break;
		}
		int r = entry_data(zip, zlen, lho, method, csize, usize, crc, ofd, NULL);
		close(ofd);
		if (r != 0) {
			say("cannot unpack %s (error %d)", name, r);
			files = -1;
			break;
		}
		files++;
	}
	munmap((void *)zip, zlen);
	return files;
}

static int is_macho_magic(const uint8_t *m)
{
	return (m[0] == 0xcf && m[1] == 0xfa && m[2] == 0xed && m[3] == 0xfe) ||
	    (m[0] == 0xce && m[1] == 0xfa && m[2] == 0xed && m[3] == 0xfe) ||
	    (m[0] == 0xca && m[1] == 0xfe && m[2] == 0xba && m[3] == 0xbe);
}

static void fixperm(const char *path, int *nmacho)
{
	struct stat st;
	if (lstat(path, &st) != 0) {
		return;
	}
	if (S_ISLNK(st.st_mode)) {
		lchown(path, 0, 0);
		return;
	}
	if (S_ISDIR(st.st_mode)) {
		DIR *d = opendir(path);
		if (d) {
			struct dirent *e;
			while ((e = readdir(d)) != NULL) {
				if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) {
					continue;
				}
				char p[4096];
				snprintf(p, sizeof p, "%s/%s", path, e->d_name);
				fixperm(p, nmacho);
			}
			closedir(d);
		}
		chmod(path, 0755);
		chown(path, 0, 0);
		return;
	}
	uint8_t m[4] = {0, 0, 0, 0};
	int fd = open(path, O_RDONLY);
	if (fd >= 0) {
		if (read(fd, m, 4) != 4) {
			memset(m, 0, 4);
		}
		close(fd);
	}
	if (is_macho_magic(m)) {
		chmod(path, 0755);
		(*nmacho)++;
	} else {
		chmod(path, 0644);
	}
	chown(path, 0, 0);
}

/* main executable: 0 ok, 1 encrypted (FairPlay), sets *signed_ */
static int check_macho(const char *path, int *signed_)
{
	*signed_ = 0;
	FILE *f = fopen(path, "rb");
	if (!f) {
		return -1;
	}
	uint8_t hdr[32];
	long base = 0;
	if (fread(hdr, 1, 8, f) != 8) {
		fclose(f);
		return -1;
	}
	if (hdr[0] == 0xca && hdr[1] == 0xfe && hdr[2] == 0xba && hdr[3] == 0xbe) {
		uint32_t n = ((uint32_t)hdr[4] << 24) | ((uint32_t)hdr[5] << 16) | ((uint32_t)hdr[6] << 8) | hdr[7];
		int found = 0;
		for (uint32_t i = 0; i < n && i < 8; i++) {
			uint8_t a[20];
			if (fread(a, 1, 20, f) != 20) {
				break;
			}
			uint32_t cpu = ((uint32_t)a[0] << 24) | ((uint32_t)a[1] << 16) | ((uint32_t)a[2] << 8) | a[3];
			uint32_t off = ((uint32_t)a[8] << 24) | ((uint32_t)a[9] << 16) | ((uint32_t)a[10] << 8) | a[11];
			if (cpu == 0x0100000c) {
				base = off;
				found = 1;
				break;
			}
		}
		if (!found) {
			fclose(f);
			say("no arm64 slice in %s", path);
			return -1;
		}
	}
	fseek(f, base, SEEK_SET);
	if (fread(hdr, 1, 32, f) != 32 || !(hdr[0] == 0xcf && hdr[1] == 0xfa && hdr[2] == 0xed && hdr[3] == 0xfe)) {
		fclose(f);
		say("main executable is not a 64-bit Mach-O");
		return -1;
	}
	uint32_t ncmds = rd32(hdr + 16), sizeofcmds = rd32(hdr + 20);
	uint8_t *lc = malloc(sizeofcmds);
	if (!lc || fread(lc, 1, sizeofcmds, f) != sizeofcmds) {
		free(lc);
		fclose(f);
		return -1;
	}
	fclose(f);
	int enc = 0;
	uint32_t o = 0;
	for (uint32_t i = 0; i < ncmds && o + 8 <= sizeofcmds; i++) {
		uint32_t cmd = rd32(lc + o), sz = rd32(lc + o + 4);
		if (cmd == 0x1d) {
			*signed_ = 1;
		}
		if (cmd == 0x2c && o + 20 <= sizeofcmds && rd32(lc + o + 16) != 0) {
			enc = 1;
		}
		if (sz < 8) {
			break;
		}
		o += sz;
	}
	free(lc);
	return enc;
}

static char *read_file(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	if (!f) {
		return NULL;
	}
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *b = malloc((size_t)n + 1);
	if (!b || fread(b, 1, (size_t)n, f) != (size_t)n) {
		free(b);
		fclose(f);
		return NULL;
	}
	b[n] = 0;
	fclose(f);
	*len = (size_t)n;
	return b;
}

/* bundle id and executable from Info.plist */
static int read_info(const char *plist, char *bid, size_t bidsz, char *exe, size_t exesz, char *minos, size_t minsz)
{
#ifdef __APPLE__
	size_t n;
	char *b = read_file(plist, &n);
	if (!b) {
		return -1;
	}
	CFDataRef d = CFDataCreate(NULL, (const UInt8 *)b, (CFIndex)n);
	free(b);
	CFPropertyListRef pl = CFPropertyListCreateWithData(NULL, d, kCFPropertyListImmutable, NULL, NULL);
	CFRelease(d);
	if (!pl || CFGetTypeID(pl) != CFDictionaryGetTypeID()) {
		return -1;
	}
	CFStringRef v;
	bid[0] = exe[0] = minos[0] = 0;
	if ((v = CFDictionaryGetValue(pl, CFSTR("CFBundleIdentifier"))) && CFGetTypeID(v) == CFStringGetTypeID()) {
		CFStringGetCString(v, bid, (CFIndex)bidsz, kCFStringEncodingUTF8);
	}
	if ((v = CFDictionaryGetValue(pl, CFSTR("CFBundleExecutable"))) && CFGetTypeID(v) == CFStringGetTypeID()) {
		CFStringGetCString(v, exe, (CFIndex)exesz, kCFStringEncodingUTF8);
	}
	if ((v = CFDictionaryGetValue(pl, CFSTR("MinimumOSVersion"))) && CFGetTypeID(v) == CFStringGetTypeID()) {
		CFStringGetCString(v, minos, (CFIndex)minsz, kCFStringEncodingUTF8);
	}
	CFRelease(pl);
	return bid[0] ? 0 : -1;
#else
	(void)plist; (void)exe; (void)exesz; (void)minsz;
	snprintf(bid, bidsz, "test.bundle");
	snprintf(exe, exesz, "Test");
	minos[0] = 0;
	return 0;
#endif
}

static void finish_ipa(const char *ipa, int ok)
{
	char n[4096];
	snprintf(n, sizeof n, "%s.%s", ipa, ok ? "done" : "failed");
	rename(ipa, n);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: topaz-install App.ipa [applications-dir]\n");
		return 2;
	}
	if (argc > 2) {
		g_apps = argv[2];
	}
	const char *ipa = argv[1];
	mkdir_p("/var/mobile/Media/Install", 0777);
	g_log = fopen("/var/mobile/Media/Install/status.log", "a");
	if (g_log) {
		fchmod(fileno(g_log), 0666);
	}
	say("start %s (uid %d euid %d)", ipa, (int)getuid(), (int)geteuid());
	if (geteuid() != 0) {
		say("not root: the setuid bit was not honoured; cannot write %s", g_apps);
		return 3;
	}
	setuid(0);
	char work[4096];
	snprintf(work, sizeof work, "%s/.topaz-work-%d", g_apps, (int)getpid());
	rmtree(work);
	if (mkdir_p(work, 0755) != 0) {
		say("cannot create %s: %s", work, strerror(errno));
		finish_ipa(ipa, 0);
		return 4;
	}
	int n = unzip_payload(ipa, work);
	if (n <= 0) {
		say("FAILED: nothing unpacked (%d)", n);
		rmtree(work);
		finish_ipa(ipa, 0);
		return 5;
	}
	char payload[4096], app[4096] = "";
	char appname[1024] = "";
	snprintf(payload, sizeof payload, "%s/Payload", work);
	DIR *d = opendir(payload);
	if (d) {
		struct dirent *e;
		while ((e = readdir(d)) != NULL) {
			size_t l = strlen(e->d_name);
			if (l > 4 && !strcmp(e->d_name + l - 4, ".app")) {
				snprintf(app, sizeof app, "%s/%s", payload, e->d_name);
				snprintf(appname, sizeof appname, "%s", e->d_name);
				break;
			}
		}
		closedir(d);
	}
	if (!app[0]) {
		say("FAILED: no .app in Payload/");
		rmtree(work);
		finish_ipa(ipa, 0);
		return 6;
	}
	char plist[4096], bid[256], exe[256], minos[32];
	snprintf(plist, sizeof plist, "%s/Info.plist", app);
	if (read_info(plist, bid, sizeof bid, exe, sizeof exe, minos, sizeof minos) != 0) {
		say("FAILED: cannot read Info.plist");
		rmtree(work);
		finish_ipa(ipa, 0);
		return 7;
	}
	say("app %s, bundle id %s, executable %s, MinimumOSVersion %s, %d files", appname, bid, exe, minos[0] ? minos : "?", n);
	if (!strncmp(bid, "com.apple.", 10)) {
		say("FAILED: refusing com.apple.* bundle id");
		rmtree(work);
		finish_ipa(ipa, 0);
		return 8;
	}
	char exep[4096];
	snprintf(exep, sizeof exep, "%s/%s", app, exe);
	int sig = 0;
	int enc = check_macho(exep, &sig);
	if (enc == 1) {
		say("FAILED: the app is FairPlay encrypted (App Store copy); it cannot run, a decrypted copy is needed");
		rmtree(work);
		finish_ipa(ipa, 0);
		return 9;
	}
	if (enc < 0) {
		say("FAILED: main executable unusable");
		rmtree(work);
		finish_ipa(ipa, 0);
		return 10;
	}
	if (!sig) {
		say("WARNING: main executable has no code signature; the kernel may refuse to run it");
	}
	char wd[4096];
	snprintf(wd, sizeof wd, "%s/Watch", app);
	rmtree(wd);
	int nmacho = 0;
	fixperm(app, &nmacho);
	char dest[4096], old[4096];
	snprintf(dest, sizeof dest, "%s/%s", g_apps, appname);
	snprintf(old, sizeof old, "%s/.topaz-old-%d", g_apps, (int)getpid());
	struct stat st;
	int had_old = lstat(dest, &st) == 0;
	if (had_old && rename(dest, old) != 0) {
		say("FAILED: cannot move the old %s away: %s", dest, strerror(errno));
		rmtree(work);
		finish_ipa(ipa, 0);
		return 11;
	}
	if (rename(app, dest) != 0) {
		say("FAILED: cannot move into %s: %s", dest, strerror(errno));
		if (had_old) {
			rename(old, dest);
		}
		rmtree(work);
		finish_ipa(ipa, 0);
		return 12;
	}
	if (had_old) {
		rmtree(old);
	}
	rmtree(work);
	sync();
	say("INSTALLED %s -> %s (%d Mach-O files); registration follows within about 20 s", bid, dest, nmacho);
	finish_ipa(ipa, 1);
	return 0;
}
