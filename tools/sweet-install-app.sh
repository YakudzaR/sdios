#!/bin/bash
# Put an .app (zipped, or an .ipa, e.g. StressTest.app.zip from the stress-app CI build, branch builds-stress) into /Applications on the
# iOS root on the SD card.
#   sudo bash tools/sweet-install-app.sh /dev/sdX1 PATH/TO/App.app.zip     (the 0xAF partition, NOT the disk)
# fsck.hfsplus, mount read-write, unzip into /Applications (root:wheel, dirs 0755, files 0644, the binary 0755),
# unmount, fsck again. Nothing else is touched. Take a backup of the partition first:
#   sudo dd if=/dev/sdX1 of=card-root-backup.img bs=4M status=progress
set -euo pipefail
PART=${1:?partition, e.g. /dev/sdb1}
ZIP=${2:?path to the .app.zip}
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
case "$PART" in *[0-9]) ;; *) echo "$PART does not look like a partition"; exit 1;; esac
[ -s "$ZIP" ] || { echo "missing $ZIP"; exit 1; }
command -v fsck.hfsplus >/dev/null || { echo "install hfsprogs (sudo apt install hfsprogs)"; exit 1; }
command -v unzip >/dev/null || { echo "install unzip (sudo apt install unzip)"; exit 1; }
T=$(mktemp -d)
unzip -q "$ZIP" -d "$T"
# an .ipa has the app in Payload/: use it from there
if [ -d "$T/Payload" ]; then mv "$T"/Payload/*.app "$T"/ 2>/dev/null || true; fi
APPS=$(cd "$T" && ls -d *.app 2>/dev/null || true)
[ -n "$APPS" ] || { echo "no .app inside $ZIP"; exit 1; }
echo "app(s): $APPS"
umount "$PART" 2>/dev/null || true
fsck.hfsplus -fy "$PART"
M=$(mktemp -d)
mount -t hfsplus -o rw,force "$PART" "$M"
trap 'umount "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true; rm -rf "$T"' EXIT
[ -d "$M/Applications" ] || { echo "no /Applications on this partition: is it the iOS root?"; exit 1; }
for a in $APPS; do
  rm -rf "$M/Applications/$a"
  cp -R "$T/$a" "$M/Applications/$a"
  find "$M/Applications/$a" -type d -exec chmod 755 {} +
  find "$M/Applications/$a" -type f -exec chmod 644 {} +
  exe=$(/usr/bin/python3 -c "import plistlib,sys;print(plistlib.load(open('$T/$a/Info.plist','rb'))['CFBundleExecutable'])")
  chmod 755 "$M/Applications/$a/$exe"
  # every other program in the bundle (frameworks, dylibs, helper executables) must be executable too: find them by Mach-O magic
  /usr/bin/python3 - "$M/Applications/$a" <<'PYEOF'
import os, sys
magic = (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf")
n = 0
for root, _, files in os.walk(sys.argv[1]):
    for f in files:
        p = os.path.join(root, f)
        if os.path.islink(p):
            continue
        try:
            with open(p, "rb") as fh:
                if fh.read(4) in magic:
                    os.chmod(p, 0o755)
                    n += 1
        except OSError:
            pass
print("made %d Mach-O files executable" % n)
PYEOF
  chown -R 0:0 "$M/Applications/$a"
  ls -l "$M/Applications/$a"
done
sync
umount "$M"; trap - EXIT; rmdir "$M"; rm -rf "$T"
fsck.hfsplus -fy "$PART"
echo "installed"
