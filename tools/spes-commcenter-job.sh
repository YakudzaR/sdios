#!/bin/bash
# Put the CELLULAR CommCenter job back into launchd's merged job list on the iOS root on the SD card (or take it out again).
#   sudo bash tools/spes-commcenter-job.sh /dev/sdb1 dry      show what would change, writes nothing (read-only mount)
#   sudo bash tools/spes-commcenter-job.sh /dev/sdb1 add      add the job (backup: launchd.plist.before-commcenter next to it)
#   sudo bash tools/spes-commcenter-job.sh /dev/sdb1 remove   restore that backup
# The job is limited to devices whose device tree has a "baseband" node (_LimitLoadToDeviceTree), so images without
# that node keep running without CommCenter. fsck.hfsplus before and after the write. Nothing else is touched.
set -euo pipefail
PART=${1:?partition, e.g. /dev/sdb1}
MODE=${2:?dry, add or remove}
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
case "$PART" in *[0-9]) ;; *) echo "$PART does not look like a partition"; exit 1;; esac
case "$MODE" in dry|add|remove) ;; *) echo "mode must be dry, add or remove"; exit 1;; esac
command -v fsck.hfsplus >/dev/null || { echo "install hfsprogs (sudo apt install hfsprogs)"; exit 1; }
umount "$PART" 2>/dev/null || true
M=$(mktemp -d)
trap 'umount "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true' EXIT
if [ "$MODE" = dry ]; then
  mount -t hfsplus -o ro,force "$PART" "$M"
else
  fsck.hfsplus -fy "$PART"
  mount -t hfsplus -o rw,force "$PART" "$M"
fi
L="$M/System/Library/xpc/launchd.plist"
[ -f "$L" ] || { echo "missing $L"; exit 1; }
if [ "$MODE" = remove ]; then
  [ -f "$L.before-commcenter" ] || { echo "no backup $L.before-commcenter"; exit 1; }
  cp -p "$L.before-commcenter" "$L"
  echo "restored the backup"
else
  python3 -I - "$M" "$MODE" <<'PY'
import plistlib, sys, os, collections
root, mode = sys.argv[1], sys.argv[2]
lp = root + '/System/Library/xpc/launchd.plist'
src = root + '/System/Library/LaunchDaemons/com.apple.CommCenter.plist'
raw = open(lp, 'rb').read()
fmt = plistlib.FMT_BINARY if raw[:6] == b'bplist' else plistlib.FMT_XML
plist = plistlib.loads(raw)
jobs = plist['LaunchDaemons']
print('format', 'binary' if fmt == plistlib.FMT_BINARY else 'xml', ', jobs:', len(jobs))
print('sample keys:', list(jobs)[:3])
have = [k for k, j in jobs.items() if j.get('Label') == 'com.apple.CommCenter']
if have:
    print('a CommCenter job is already there:', have)
    sys.exit(0)
job = plistlib.loads(open(src, 'rb').read())
if job.get('_LimitLoadToDeviceTree') != 'baseband':
    sys.exit('com.apple.CommCenter.plist is not the cellular job: refusing')
dirs = collections.Counter(os.path.dirname(k) for k in jobs if k.startswith('/'))
base = dirs.most_common(1)[0][0] if dirs else '/System/Library/LaunchDaemons'
key = base + '/com.apple.CommCenter.plist' if dirs else 'com.apple.CommCenter.plist'
print('would add key', key, 'with', len(job), 'entries, services:', len(job.get('MachServices', {})))
if mode == 'add':
    import shutil
    shutil.copy2(lp, lp + '.before-commcenter')
    jobs[key] = job
    st = os.stat(lp)
    open(lp, 'wb').write(plistlib.dumps(plist, fmt=fmt))
    os.chown(lp, st.st_uid, st.st_gid); os.chmod(lp, st.st_mode & 0o7777)
    print('added')
PY
fi
if [ "$MODE" != dry ]; then
  sync
  umount "$M"; trap - EXIT; rmdir "$M"
  fsck.hfsplus -fy "$PART"
else
  umount "$M"; trap - EXIT; rmdir "$M"
fi
echo "done ($MODE)"
