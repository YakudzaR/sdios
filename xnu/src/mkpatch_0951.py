#!/usr/bin/env python3
"""Regenerate xnu/patches/0951-spes-sd-root-device.patch from xnu/src/sweet_sd_frag.c.
Usage: mkpatch_0951.py UFSREC_DIR   (UFSREC_DIR/bsd/dev/sweet_ufs.c = sweet_ufs.c with patches 0028..0950 applied)"""
import os, subprocess, sys, tempfile, shutil
here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(sys.argv[1], 'bsd/dev/sweet_ufs.c')
out = os.path.join(here, '../patches/0951-spes-sd-root-device.patch')
t = tempfile.mkdtemp()
os.makedirs(t + '/bsd/dev')
shutil.copy(src, t + '/bsd/dev/sweet_ufs.c')
g = lambda *a: subprocess.run(['git', '-c', 'user.name=x', '-c', 'user.email=x@x'] + list(a), cwd=t, check=True, capture_output=True, text=True).stdout
g('init', '-q', '.'); g('add', '-A'); g('commit', '-qm', 'base')
p = t + '/bsd/dev/sweet_ufs.c'
s = open(p).read()
old = """int
sweet_ufs_rootdev(dev_t *dev)
{
	if (!su.ready) {
		int error = sweet_ufs_init();
		if (error) {
			return error;
		}
	}
	*dev = su.bdev;
	return 0;
}
#endif /* ARM64_BOARD_CONFIG_SWEET */
"""
assert s.endswith(old)
new = """int sweet_sd_rootdev(dev_t *dev);

int
sweet_ufs_rootdev(dev_t *dev)
{
	printf("SWEET: root device lookup\\n");
	if (!su.ready) {
		int error = sweet_ufs_init();
		if (error == ENXIO) {
			/* No UFS in the device tree: spes boots from its SD card (see below). */
			return sweet_sd_rootdev(dev);
		}
		if (error) {
			return error;
		}
	}
	*dev = su.bdev;
	return 0;
}

"""
frag = open(os.path.join(here, 'sweet_sd_frag.c')).read()
s = s[:-len(old)] + new + frag.rstrip('\n') + "\n#endif /* ARM64_BOARD_CONFIG_SWEET */\n"
open(p, 'w').write(s)
open(out, 'w').write(g('diff'))
print(out)
