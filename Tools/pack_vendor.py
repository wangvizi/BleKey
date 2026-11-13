#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pack_vendor.py -- 从原包解出的 Frameworks/ 里挑出「数字钥匙 SDK 最小依赖闭包」，打成一个
可随仓库推送的 zip。远程 macOS runner 解压后由 Scripts/build_trollstore.sh 注入 .app。

为什么只挑闭包：原包 23 个动态 framework 共 73.94 MB，其中 Car3DViewSDK 一个就 46.78 MB，
与蓝牙钥匙无关；全塞进仓库和 ipa 只会拖慢推送、安装。闭包只有 4 个 / 12.68 MB。

- 依赖闭包通过 Mach-O LC_LOAD_DYLIB 里的 @rpath 递归求解，不靠猜。
- 保留 framework 内部符号链接（zip 的 Unix external_attr），dlopen 需要它们。
- 剔除 _CodeSignature：原包签名对独立 app 无效，留给 ldid 统一伪签。

输入: Generated/Vendor/Frameworks/
输出: Generated/VendorFrameworks.zip, Generated/VendorManifest.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_ipa as E  # noqa: E402

SEEDS = ("Keystone.framework", "HKMC_DK2_FrameworkLibrary.framework",
         "PepsPacket.framework")
SKIP_DIR_NAMES = {"_CodeSignature", "__MACOSX"}
SKIP_FILE_NAMES = {".DS_Store"}


def rpath_deps(framework_dir: Path) -> list[str]:
    binary = framework_dir / framework_dir.name[:-10]
    if not binary.is_file():
        return []
    raw = binary.read_bytes()
    macho = E.parse_macho(E.pick_arm64_slice(raw)[0])
    out = []
    for d in macho["dylibs"]:
        if d.startswith("@rpath/") and "/" in d[7:]:
            out.append(d[7:].split("/", 1)[0])
    return sorted(set(out))


def closure(vendor: Path, seeds: tuple[str, ...]) -> tuple[list[str], dict[str, list[str]]]:
    available = {p.name for p in vendor.iterdir() if p.is_dir() and p.name.endswith(".framework")}
    deps = {name: rpath_deps(vendor / name) for name in sorted(available)}
    need: set[str] = set()
    queue = [s for s in seeds if s in available]
    while queue:
        name = queue.pop()
        if name in need:
            continue
        need.add(name)
        for d in deps.get(name, []):
            if d in available and d not in need:
                queue.append(d)
    return sorted(need), deps


def iter_files(root: Path):
    """按相对路径产出 (文件, 相对名, 是否符号链接)；跳过签名材料。"""
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_NAMES]
        base = Path(dirpath)
        # os.walk 把符号链接目录放在 dirnames，单独作为链接项写进 zip
        for d in list(dirnames):
            p = base / d
            if p.is_symlink():
                yield p, p.relative_to(root).as_posix(), True
                dirnames.remove(d)
        for fn in filenames:
            if fn in SKIP_FILE_NAMES:
                continue
            p = base / fn
            yield p, p.relative_to(root).as_posix(), p.is_symlink()


def pack(vendor: Path, frameworks: list[str], out_zip: Path) -> dict:
    out_zip.parent.mkdir(parents=True, exist_ok=True)
    manifest = {"frameworks": {}, "zip_sha256": "", "zip_bytes": 0}
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for name in frameworks:
            fw = vendor / name
            binary = fw / name[:-10]
            entry = {
                "binary": binary.name,
                "binary_bytes": binary.stat().st_size if binary.is_file() else 0,
                "binary_sha256": (hashlib.sha256(binary.read_bytes()).hexdigest()
                                  if binary.is_file() else ""),
                "rpath_deps": rpath_deps(fw),
                "files": 0,
            }
            for p, rel, is_link in iter_files(fw):
                arc = name + "/" + rel
                info = zipfile.ZipInfo(arc)
                info.create_system = 3  # Unix，保留 mode
                if is_link:
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    info.compress_type = zipfile.ZIP_STORED
                    zf.writestr(info, os.readlink(p).encode("utf-8"))
                elif p.is_dir():
                    continue
                else:
                    mode = stat.S_IMODE(p.stat().st_mode) or 0o644
                    info.external_attr = (stat.S_IFREG | mode) << 16
                    info.compress_type = zipfile.ZIP_DEFLATED
                    zf.writestr(info, p.read_bytes())
                entry["files"] += 1
            manifest["frameworks"][name] = entry
    raw = out_zip.read_bytes()
    manifest["zip_sha256"] = hashlib.sha256(raw).hexdigest()
    manifest["zip_bytes"] = len(raw)
    return manifest


def main() -> int:
    ap = argparse.ArgumentParser(description="打包原包数字钥匙 SDK 的最小 framework 闭包")
    ap.add_argument("--vendor", default="Generated/Vendor/Frameworks")
    ap.add_argument("--out", default="Generated/VendorFrameworks.zip")
    ap.add_argument("--manifest", default="Generated/VendorManifest.json")
    args = ap.parse_args()

    vendor = Path(args.vendor)
    if not vendor.is_dir():
        print("ERROR: 找不到 %s，请先运行 extract_ipa.py（不要加 --no-vendor）" % vendor,
              file=sys.stderr)
        return 2
    frameworks, deps = closure(vendor, SEEDS)
    if not frameworks:
        print("ERROR: 闭包为空，Vendor 目录里没有数字钥匙 framework", file=sys.stderr)
        return 3

    manifest = pack(vendor, frameworks, Path(args.out))
    manifest["closure"] = frameworks
    manifest["all_rpath_deps"] = deps
    Path(args.manifest).write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("[*] 最小闭包 : %d 个 framework" % len(frameworks))
    for name in frameworks:
        e = manifest["frameworks"][name]
        print("      %-42s %7.2f MB  files=%d  deps=%s" %
              (name, e["binary_bytes"] / 1024 / 1024, e["files"],
               ",".join(e["rpath_deps"]) or "-"))
    print("[*] zip       : %s  %d bytes" % (args.out, manifest["zip_bytes"]))
    print("[*] sha256    : %s" % manifest["zip_sha256"])
    print("[+] manifest  : %s" % args.manifest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
