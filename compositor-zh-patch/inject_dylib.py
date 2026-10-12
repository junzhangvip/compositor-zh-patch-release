#!/usr/bin/env python3
"""向 arm64 Mach-O 注入 LC_LOAD_DYLIB，使其启动时加载翻译 dylib。
用法: inject_dylib.py <可执行文件> <dylib安装名>
"""
import struct, sys, shutil

LC_LOAD_DYLIB = 0xC
MH_MAGIC_64 = 0xFEEDFACF

def main(bin_path, install_name):
    data = bytearray(open(bin_path, "rb").read())
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, resv = \
        struct.unpack_from("<IiiIIIII", data, 0)
    assert magic == MH_MAGIC_64, f"not arm64 MH_MAGIC_64: {hex(magic)}"

    # 若已注入则跳过
    if install_name.encode() in bytes(data[: 32 + sizeofcmds]):
        print(f"SKIP: 已包含 {install_name}")
        return

    # 构造 LC_LOAD_DYLIB
    name_b = install_name.encode() + b"\x00"
    off = 24  # load_command(8) + dylib(16)
    cmdsize = (off + len(name_b) + 7) & ~7
    lc = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize,
                     off, 1, 0x00010000, 0x00010000) + name_b
    lc += b"\x00" * (cmdsize - len(lc))

    # 覆写点：现有 load commands 之后的零填充区（不改变文件布局，避免 section 位移）
    # 找到第一个 section 的 fileoff 作为边界
    first_off = None
    pos = 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", data, pos)
        if cmd in (0x19, 0x1A):  # LC_SEGMENT / LC_SEGMENT_64
            nsects = struct.unpack_from("<I", data, pos + 64)[0]
            for s in range(nsects):
                soff = struct.unpack_from("<I", data, pos + 72 + s * 80 + 48)[0]
                if soff and (first_off is None or soff < first_off):
                    first_off = soff
        pos += sz
    insert_at = 32 + sizeofcmds
    assert first_off and insert_at + cmdsize <= first_off, \
        f"填充区不足: 需 {insert_at + cmdsize}, 第一个 section @ {first_off}"
    if any(data[insert_at: insert_at + cmdsize]):
        raise SystemExit("填充区非全零，放弃注入（避免破坏数据）")

    data[insert_at: insert_at + cmdsize] = lc
    # 头部布局: magic(0) cputype(4) cpusub(8) filetype(12) ncmds(16) sizeofcmds(20)
    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)

    open(bin_path, "wb").write(bytes(data))
    print(f"OK: 注入 {install_name} @ file offset {insert_at}, ncmds {ncmds}->{ncmds+1}")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
