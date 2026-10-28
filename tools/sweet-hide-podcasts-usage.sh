#!/bin/bash
# Settings > General > About / iPhone Storage trap inside PodcastsUI (loaded by the Podcasts storage plugin).
# This renames that one plugin bundle so Settings skips it; nothing else on the card changes.
#   sudo bash tools/sweet-hide-podcasts-usage.sh /dev/sdX1            hide it
#   sudo bash tools/sweet-hide-podcasts-usage.sh /dev/sdX1 --restore  put the name back
# (the 16 GiB 0xAF partition, NOT the disk). fsck.hfsplus runs before and after. Take a backup first:
#   sudo dd if=/dev/sdX1 of=card-root-backup.img bs=4M status=progress
set -euo pipefail
PART=${1:?partition, e.g. /dev/sdb1}
MODE=${2:-hide}
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
case "$PART" in *[0-9]) ;; *) echo "$PART does not look like a partition"; exit 1;; esac
command -v fsck.hfsplus >/dev/null || { echo "install hfsprogs (sudo apt install hfsprogs)"; exit 1; }
umount "$PART" 2>/dev/null || true
fsck.hfsplus -fy "$PART"
M=$(mktemp -d)
mount -t hfsplus -o rw,force "$PART" "$M"
trap 'umount "$M" 2>/dev/null || true; rmdir "$M" 2>/dev/null || true' EXIT
D="$M/System/Library/PreferenceBundles/StoragePlugins"
echo "StoragePlugins:"; ls -l "$D"
if [ "$MODE" = "--restore" ]; then
	[ -e "$D/PodcastsUsagePlugin.bundle.off" ] || { echo "nothing to restore"; exit 1; }
	mv "$D/PodcastsUsagePlugin.bundle.off" "$D/PodcastsUsagePlugin.bundle"
else
	[ -e "$D/PodcastsUsagePlugin.bundle" ] || { echo "PodcastsUsagePlugin.bundle not found (already hidden?)"; exit 1; }
	mv "$D/PodcastsUsagePlugin.bundle" "$D/PodcastsUsagePlugin.bundle.off"
fi
ls -l "$D"
sync
umount "$M"; trap - EXIT; rmdir "$M"
fsck.hfsplus -fy "$PART"
echo "done"
