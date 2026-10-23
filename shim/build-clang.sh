#!/bin/bash
# Same image as build.sh, but with clang + ld.lld (no aarch64-linux-gnu-gcc, cpio or AOSP mkbootimg needed)
# and tools/mkboot_v4.py (boot image v4, empty ramdisk). Usage: build-clang.sh PAYLOAD.bin [OUT.img]
set -euo pipefail
cd "$(dirname "$0")"
CC="clang --target=aarch64-none-elf"
OBJCOPY=${OBJCOPY:-llvm-objcopy}
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -fno-pie -mgeneral-regs-only -mstrict-align -fno-stack-protector -fno-jump-tables -Wall -Wextra"
mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
$CC $CFLAGS -fno-builtin -fno-tree-loop-distribute-patterns -c libc_min.c -o out/libc_min.o 2>/dev/null || $CC $CFLAGS -fno-builtin -c libc_min.c -o out/libc_min.o
abs=$(llvm-readelf -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
ld.lld -T shim.ld -nostdlib -static --build-id=none -N out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o out/libc_min.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
size=$((16#$(llvm-nm out/shim.elf | awk '$3=="_end"{print $1}')))
truncate -s "$size" out/Image
if [ -n "${1:-}" ]; then
	truncate -s $(( (size + 0xfff) & ~0xfff )) out/Image
	cat "$1" >> out/Image
	python3 -c 'import os,struct,sys; f=open(sys.argv[1],"r+b"); f.seek(16); f.write(struct.pack("<Q", os.path.getsize(sys.argv[1])))' out/Image
fi
python3 ../tools/mkboot_v4.py --kernel out/Image --version 4 --out "${2:-out/shim-boot.img}"
