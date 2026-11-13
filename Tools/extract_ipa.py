#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_ipa.py -- 从原客户端 ipa 中抽取「登录接口 + 蓝牙钥匙协议」所需的事实数据。

输入: 一个 ipa（App Store 加密包或已砸壳包均可）
输出:
  <out>/BridgeConfig.json        独立 app 的运行时配置（参数全外置，代码里不写死任何域名/UUID）
  <out>/report.json              原包完整体检报告（真实解析结果，不做推测）
  <out>/objc_names.txt           ObjC 类名 / selector 清单（供确认原包接口用）
  <out>/strings_candidates.txt   URL / 路径 / UUID / 关键字候选
  <out>/Vendor/Frameworks/       原包自带的动态 framework（可直接链进独立 app）

只做静态解析，不联网、不调用任何 macOS 专有工具，Windows / Linux / macOS 都能跑。
复杂度: 主循环 O(文件大小)，字符串正则 O(文件大小)；百 MB 级 ipa 约数秒。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
import sys
import zipfile
from collections import Counter

# ---------------------------------------------------------------- Mach-O 常量
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
MH_MAGIC = 0xFEEDFACE
MH_CIGAM = 0xCEFAEDFE

CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPE_ARM64_32 = 0x0200000C

LC_SEGMENT_64 = 0x19
LC_SEGMENT = 0x1
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_ENCRYPTION_INFO = 0x21
LC_ENCRYPTION_INFO_64 = 0x2C
LC_UUID = 0x1B

FILETYPE_NAMES = {
    1: "MH_OBJECT", 2: "MH_EXECUTE", 3: "MH_FVMLIB", 4: "MH_CORE",
    5: "MH_PRELOAD", 6: "MH_DYLIB", 7: "MH_DYLINKER", 8: "MH_BUNDLE",
    9: "MH_DYLIB_STUB", 10: "MH_DS", 11: "MH_KEXT_BUNDLE", 12: "MH_FILESET",
}

INTERESTING_SECTIONS = {b"__cstring", b"__objc_classname", b"__objc_methname"}

# 第三方 SDK 域名：这些不是车厂后端，挑 api_base 时必须排除
THIRD_PARTY_HOST_MARKERS = (
    "apple.com", "icloud", "itunes", "appsflyer", "umeng", "umtrack", "bugly",
    "qq.com", "weixin", "wechat", "tencent", "alipay", "aliyun", "alicdn",
    "amap", "baidu", "google", "gstatic", "firebase", "crashlytics",
    "facebook", "sentry", "jpush", "getui", "xiaomi", "huawei", "oppo",
    "vivo", "meizu", "microsoft", "office", "doubleclick", "flurry",
    "talkingdata", "sensorsdata", "zhuge", "mob.com", "bugtags", "testin",
    "amazonaws", "cloudfront", "akamai", "w3.org", "schema.org", "openssl",
    "github.com", "cocoapods", "localhost", "example.com", "127.0.0.1",
    "microsoft.com", "office.com", "office365", "live.com", "weibo", "sina.com",
    "curl.se", "share2dlink", "sharesdk", "snssdk", "byteimg", "douyin",
    "crl.apple.com", "ocsp.apple.com", "www.apple.com",
)

# 编译期绝对路径 / 资源路径，不是 HTTP 接口
BAD_PATH_PARTS = ("/Volumes/", "/Users/", "/workspace/", "/Build/", "/src/",
                  "/Library/", "/Applications/", "/Pods/", ".m", ".h", ".swift",
                  ".png", ".jpg", ".plist", ".json", ".css", ".js", ".html")

# 格式化串 / 证书吊销点 / DTD，不是可用接口
BAD_URL_PARTS = ("%@", "%ld", "%d", "%s", "{", "}", "crl.", "ocsp.",
                 "/DTD", ".dtd", "schema.org", "localhost")

PATH_KEYWORDS = {
    "login": ("login", "signin", "sign_in", "authenticate", "oauth", "passport"),
    "sms": ("sms", "verifycode", "verify_code", "vcode", "sendcode", "captcha", "code"),
    "key": ("blekey", "ble_key", "digitalkey", "digital_key", "carkey", "car_key",
            "vehiclekey", "keyinfo", "key_info", "key/list", "certificate", "cert"),
    "vehicle": ("vehicle", "car/list", "carlist", "bindcar", "car/info"),
    "control": ("control", "command", "cmd", "unlock", "lock", "remote"),
}

def looks_ble_class(name: str) -> bool:
    """避免 'Reachable' / 'Available' 里含 ble 造成误报：只认驼峰 BLE 或明确复合词。"""
    low = name.lower()
    tokens = ("bluetooth", "digitalkey", "carkey", "vehiclekey", "blekey",
              "bluetoothkit", "blemanager", "blekit", "pke", "rke")
    if any(t in low for t in tokens):
        return True
    return "BLE" in name or low.startswith("ble")


# ---------------------------------------------------------------- 工具函数
def u32(data: bytes, off: int, endian: str = "<") -> int:
    return struct.unpack_from(endian + "I", data, off)[0]


def read_cstring(data: bytes, off: int, limit: int = 4096) -> str:
    end = data.find(b"\x00", off, min(off + limit, len(data)))
    if end < 0:
        end = min(off + limit, len(data))
    return data[off:end].decode("utf-8", "replace")


def printable_strings(blob: bytes, minlen: int = 4):
    for m in re.finditer(rb"[\x20-\x7e]{%d,}" % minlen, blob):
        yield m.group().decode("ascii", "replace")


# ---------------------------------------------------------------- Mach-O 解析
def pick_arm64_slice(data: bytes) -> tuple[bytes, str]:
    """fat 文件里取 arm64 分片；已是薄 Mach-O 则原样返回。"""
    if len(data) < 8:
        return data, "unknown"
    magic = u32(data, 0, ">")
    if magic in (FAT_MAGIC, FAT_CIGAM):
        endian = ">" if magic == FAT_MAGIC else "<"
        nfat = u32(data, 4, endian)
        best = None
        for i in range(min(nfat, 64)):
            off = 8 + i * 20
            if off + 20 > len(data):
                break
            cputype, cpusubtype, sl_off, sl_size, _align = struct.unpack_from(
                endian + "iiIII", data, off)
            if cputype in (CPU_TYPE_ARM64, CPU_TYPE_ARM64_32):
                best = (sl_off, sl_size, "arm64")
                break
            if best is None:
                best = (sl_off, sl_size, "cpu_%d" % cputype)
        if best:
            sl_off, sl_size, arch = best
            return data[sl_off:sl_off + sl_size], arch
        return b"", "fat-no-slice"
    return data, "arm64" if len(data) >= 8 else "unknown"


def parse_macho(data: bytes) -> dict:
    """返回结构/段/节/依赖库/加密位。不依赖 class-dump 或 otool。"""
    result = {
        "magic": "", "cputype": 0, "filetype": 0, "filetype_name": "",
        "uuid": "", "crypted": None, "cryptid": None, "cryptoff": None,
        "cryptsize": None, "dylibs": [], "sections": {}, "section_names": [],
    }
    if len(data) < 32:
        return result

    magic = u32(data, 0, "<")
    if magic in (MH_CIGAM_64, MH_CIGAM, FAT_CIGAM, FAT_MAGIC):
        # 大端 fat / 大端 Mach-O：本工具面向 iOS arm64（小端），交给 pick_arm64_slice 处理
        sliced, _ = pick_arm64_slice(data)
        if sliced and sliced is not data:
            return parse_macho(sliced)
        return result

    is64 = magic == MH_MAGIC_64
    if not is64 and magic != MH_MAGIC:
        return result
    result["magic"] = "MH_MAGIC_64" if is64 else "MH_MAGIC"

    hdr = "<IiiIIIII" if is64 else "<IiiIIII"
    try:
        _magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, *rest = \
            struct.unpack_from(hdr, data, 0)
    except struct.error:
        return result
    result["cputype"] = cputype
    result["filetype"] = filetype
    result["filetype_name"] = FILETYPE_NAMES.get(filetype, "UNKNOWN_%d" % filetype)

    off = 32 if is64 else 28
    ncmds = min(ncmds, 100000)
    for _ in range(ncmds):
        if off + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize < 8 or off + cmdsize > len(data):
            break

        if cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64) and cmdsize >= 20:
            cryptoff, cryptsize, cryptid = struct.unpack_from("<III", data, off + 8)
            result.update(cryptoff=cryptoff, cryptsize=cryptsize,
                          cryptid=cryptid, crypted=(cryptid != 0))

        elif cmd == LC_UUID and cmdsize >= 24:
            result["uuid"] = data[off + 8:off + 24].hex().upper()

        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            name_off = u32(data, off + 8)
            if 0 < name_off < cmdsize:
                result["dylibs"].append(read_cstring(data, off + name_off, cmdsize - name_off))

        elif cmd == LC_SEGMENT_64 and cmdsize >= 72:
            segname = data[off + 8:off + 24].rstrip(b"\x00").decode("ascii", "replace")
            _vmaddr, _vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, off + 24)
            nsects = u32(data, off + 64)
            sec_off = off + 72
            for si in range(min(nsects, 20000)):
                so = sec_off + si * 80
                if so + 80 > len(data) or so + 80 > off + cmdsize:
                    break
                sectname = data[so:so + 16].rstrip(b"\x00")
                addr, size = struct.unpack_from("<QQ", data, so + 32)
                s_offset = u32(data, so + 48)
                key = sectname.decode("ascii", "replace")
                result["section_names"].append("%s,%s" % (segname, key))
                if sectname in INTERESTING_SECTIONS:
                    # __TEXT 段的节偏移是相对本 Mach-O 分片起点的文件偏移
                    start = s_offset
                    end = min(start + size, len(data))
                    if start < end:
                        result["sections"].setdefault(key, []).append(data[start:end])
            _ = fileoff, filesize

        elif cmd == LC_SEGMENT and cmdsize >= 56:
            nsects = u32(data, off + 48)
            sec_off = off + 56
            for si in range(min(nsects, 20000)):
                so = sec_off + si * 68
                if so + 68 > len(data):
                    break
                sectname = data[so:so + 16].rstrip(b"\x00")
                _addr, size = struct.unpack_from("<II", data, so + 32)
                s_offset = u32(data, so + 40)
                key = sectname.decode("ascii", "replace")
                result["section_names"].append("%s" % key)
                if sectname in INTERESTING_SECTIONS and s_offset + size <= len(data):
                    result["sections"].setdefault(key, []).append(
                        data[s_offset:s_offset + size])

        off += cmdsize
    return result


def section_strings(macho: dict, key: str) -> list[str]:
    out = []
    for blob in macho["sections"].get(key, []):
        for raw in blob.split(b"\x00"):
            if not raw:
                continue
            try:
                s = raw.decode("ascii")
            except UnicodeDecodeError:
                continue
            if len(s) >= 2 and all(c == "\n" or c == "\t" or 32 <= ord(c) < 127 for c in s):
                out.append(s)
    seen = set()
    return [s for s in out if not (s in seen or seen.add(s))]


# ---------------------------------------------------------------- ipa 解包与体检
def parse_mobileprovision(path: str) -> dict:
    try:
        raw = open(path, "rb").read()
    except OSError:
        return {}
    # CMS 内部是明文 plist，直接搜 XML 段，不依赖 security/cms 命令
    m = re.search(rb"<\?xml.*?</plist>", raw, re.S)
    if not m:
        return {}
    try:
        p = plistlib.loads(m.group())
    except Exception:
        return {}
    ent = p.get("Entitlements", {}) or {}
    return {
        "app_id": p.get("AppIDName", ""),
        "team_id": (p.get("ApplicationIdentifierPrefix") or [""])[0],
        "creation_date": str(p.get("CreationDate", "")),
        "expiration_date": str(p.get("ExpirationDate", "")),
        "entitlements": {str(k): v for k, v in ent.items()},
        "provisioned_devices": len(p.get("ProvisionedDevices", []) or []),
    }


def inspect_ipa(ipa_path: str, out_dir: str, copy_vendor: bool = True) -> dict:
    unpack = os.path.join(out_dir, "_unpacked")
    # 增量跳过：同一 ipa 已解包过就直接复用，避免千级文件的全量删除
    marker = os.path.join(unpack, ".extracted_sha256")
    ipa_sha = ""
    h = hashlib.sha256()
    with open(ipa_path, "rb") as fh:
        for chunk in iter(lambda: fh.read(4 * 1024 * 1024), b""):
            h.update(chunk)
    ipa_sha = h.hexdigest()
    if os.path.isfile(marker) and os.path.isdir(unpack):
        if open(marker, encoding="utf-8").read().strip() == ipa_sha:
            print("    _unpacked 与当前 ipa 一致，复用已有解包目录")
            app_dir = _find_app_dir(unpack)
            return _inspect_app(app_dir, unpack, ipa_path, out_dir, copy_vendor)
    if os.path.isdir(unpack):
        shutil.rmtree(unpack)
    os.makedirs(unpack, exist_ok=True)
    with zipfile.ZipFile(ipa_path, "r") as zf:
        zf.extractall(unpack)
    with open(marker, "w", encoding="utf-8") as fh:
        fh.write(ipa_sha)
    return _inspect_app(_find_app_dir(unpack), unpack, ipa_path, out_dir, copy_vendor)


def _find_app_dir(unpack: str) -> str:
    payload = os.path.join(unpack, "Payload")
    apps = []
    if os.path.isdir(payload):
        apps = [os.path.join(payload, n) for n in os.listdir(payload)
                if n.endswith(".app") and os.path.isdir(os.path.join(payload, n))]
    if not apps:
        raise RuntimeError("Payload/*.app 不存在：这不是标准 ipa，或解包结构异常")
    return apps[0]


def _inspect_app(app_dir: str, unpack: str, ipa_path: str, out_dir: str, copy_vendor: bool = True) -> dict:
    info_path = os.path.join(app_dir, "Info.plist")
    info = {}
    if os.path.isfile(info_path):
        with open(info_path, "rb") as f:
            info = plistlib.load(f)

    exe_name = info.get("CFBundleExecutable", "")
    exe_path = os.path.join(app_dir, exe_name) if exe_name else ""
    macho = {"section_names": [], "sections": {}, "dylibs": [], "crypted": None}
    exe_sha256 = ""
    exe_size = 0
    all_strings: list[str] = []
    if exe_path and os.path.isfile(exe_path):
        raw = open(exe_path, "rb").read()
        exe_sha256 = hashlib.sha256(raw).hexdigest()
        exe_size = len(raw)
        sliced, _arch = pick_arm64_slice(raw)
        macho = parse_macho(sliced)
        # 加密包：__TEXT 被加密，扫出来是乱码；仍保留结果并在报告里标明
        all_strings = list(printable_strings(sliced))

    # 其他 Mach-O（framework 里的动态库）也扫，很多车厂把蓝牙 SDK 放这里
    fw_machos = []
    frameworks = []
    fw_root = os.path.join(app_dir, "Frameworks")
    if os.path.isdir(fw_root):
        for name in sorted(os.listdir(fw_root)):
            p = os.path.join(fw_root, name)
            if not name.endswith(".framework") or not os.path.isdir(p):
                continue
            binary = os.path.join(p, name[:-10])
            if not os.path.isfile(binary):
                continue
            frameworks.append(name)
            fraw = open(binary, "rb").read()
            fslice, _ = pick_arm64_slice(fraw)
            fm = parse_macho(fslice)
            fw_machos.append({"name": name, "filetype": fm["filetype_name"],
                              "crypted": fm["crypted"],
                              "dylibs": fm["dylibs"][:40],
                              "sha256": hashlib.sha256(fraw).hexdigest()})
            all_strings.extend(printable_strings(fslice))

    # 资源里的字符串（plist / json / txt）也是接口线索
    resource_strings = []
    for root, _dirs, files in os.walk(app_dir):
        for fn in files:
            if not fn.lower().endswith((".plist", ".json", ".strings", ".txt", ".pem", ".cer")):
                continue
            fp = os.path.join(root, fn)
            try:
                if os.path.getsize(fp) > 4 * 1024 * 1024:
                    continue
                blob = open(fp, "rb").read()
            except OSError:
                continue
            resource_strings.extend(printable_strings(blob, 5))

    merged = all_strings + resource_strings
    text_blob = "\n".join(merged)

    url_re = re.compile(r"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%\-]{4,200}")
    uuid_re = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
                         r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
    path_re = re.compile(r"/[A-Za-z0-9_./{}$\-]{3,120}")

    urls = sorted(set(
        m.rstrip(".,;'\"") for m in url_re.findall(text_blob)
        if not any(b in m for b in BAD_URL_PARTS)
    ))
    uuids = sorted(set(
        m.upper() for m in uuid_re.findall(text_blob)
        if len(set(m.replace("-", ""))) > 2  # 排除 00000000-... 之类的占位 UUID
    ))
    paths = sorted(set(
        m for m in path_re.findall(text_blob)
        if not m.startswith(("//", "/usr/", "/System/", "/Library/",
                             "/var/", "/private/", "/dev/"))
        and not any(b in m for b in BAD_PATH_PARTS)
    ))

    hosts = Counter()
    for u in urls:
        try:
            host = re.split(r"[/:?#]", u.split("://", 1)[1], maxsplit=1)[0].lower()
        except (IndexError, ValueError):
            continue
        if host and "." in host and not any(k in host for k in THIRD_PARTY_HOST_MARKERS):
            hosts[host] += 1
    ats_domains = []
    ats = info.get("NSAppTransportSecurity", {}) or {}
    for d in (ats.get("NSExceptionDomains", {}) or {}):
        ats_domains.append(str(d))
    for d in ats_domains:
        if not any(k in d.lower() for k in THIRD_PARTY_HOST_MARKERS):
            hosts[d.lower()] += 3  # ATS 白名单是第一方域名的强证据

    # ObjC 类名 / selector：定位原包登录类和蓝牙类
    classnames = section_strings(macho, "__objc_classname")
    selectors = section_strings(macho, "__objc_methname")
    # 动态 framework 里的 ObjC 符号单独补扫，车厂常把蓝牙 SDK 放在这里
    fw_scan_root = fw_root if os.path.isdir(fw_root) else None
    for root, _dirs, files in (os.walk(fw_scan_root) if fw_scan_root else []):
        for fn in files:
            if "." in fn or not os.path.isfile(os.path.join(root, fn)):
                continue
            try:
                fr = open(os.path.join(root, fn), "rb").read()
            except OSError:
                continue
            if len(fr) > 120 * 1024 * 1024:
                continue
            fsl, _ = pick_arm64_slice(fr)
            fm = parse_macho(fsl)
            classnames += section_strings(fm, "__objc_classname")
            selectors += section_strings(fm, "__objc_methname")
    classnames = list(dict.fromkeys(classnames))
    selectors = list(dict.fromkeys(selectors))

    ble_classes = [c for c in classnames if looks_ble_class(c)]
    auth_classes = [c for c in classnames
                    if any(k in c.lower() for k in ("login", "auth", "account", "user", "token"))]
    ble_selectors = [s for s in selectors
                     if any(k in s.lower() for k in ("unlock", "lock", "connect", "writevalue",
                                                     "command", "auth", "challenge", "blekey"))]
    fw_candidates = [f for f in frameworks
                     if any(k in f.lower() for k in ("ble", "bluetooth", "key", "vehicle",
                                                     "car", "sdk", "auth", "network"))]

    # 按关键字给接口路径分组
    path_groups = {}
    for group, kws in PATH_KEYWORDS.items():
        hits = [p for p in paths if any(k in p.lower() for k in kws)]
        path_groups[group] = sorted(set(hits))[:60]

    keyword_lines = []
    for s in merged:
        low = s.lower()
        if any(k in low for k in ("blekey", "digitalkey", "bluetooth", "serviceuuid",
                                  "characteristic", "unlock", "challenge", "aes", "token",
                                  "login", "smscode", "verifycode", "vehicleid", "vin")):
            if 4 <= len(s) <= 160:
                keyword_lines.append(s)
    keyword_lines = list(dict.fromkeys(keyword_lines))[:4000]

    prov = parse_mobileprovision(os.path.join(app_dir, "embedded.mobileprovision"))

    # 抽出可链接的 framework（仅动态库，静态库不能直接 dlopen）
    vendor_dir = os.path.join(out_dir, "Vendor", "Frameworks")
    linked = []
    if copy_vendor and os.path.isdir(fw_root):
        os.makedirs(vendor_dir, exist_ok=True)
        for fm in fw_machos:
            if fm["filetype"] != "MH_DYLIB":
                continue
            name = fm["name"]
            src = os.path.join(fw_root, name)
            dst = os.path.join(vendor_dir, name)
            if os.path.isdir(dst):
                # 同一 ipa 反复抽取时直接复用，避免大目录全量删除
                linked.append(name)
                continue
            shutil.copytree(src, dst)
            linked.append(name)

    report = {
        "ipa": os.path.abspath(ipa_path),
        "ipa_sha256": hashlib.sha256(open(ipa_path, "rb").read()).hexdigest(),
        "app_bundle_dir": os.path.relpath(app_dir, unpack),
        "info_plist": {
            "CFBundleIdentifier": info.get("CFBundleIdentifier", ""),
            "CFBundleName": info.get("CFBundleName", ""),
            "CFBundleDisplayName": info.get("CFBundleDisplayName", ""),
            "CFBundleShortVersionString": info.get("CFBundleShortVersionString", ""),
            "CFBundleVersion": info.get("CFBundleVersion", ""),
            "MinimumOSVersion": info.get("MinimumOSVersion", ""),
            "CFBundleURLTypes": info.get("CFBundleURLTypes", []),
            "UIBackgroundModes": info.get("UIBackgroundModes", []),
            "NSBluetoothAlwaysUsageDescription": info.get("NSBluetoothAlwaysUsageDescription", ""),
            "NSAppTransportSecurity": ats,
        },
        "executable": {
            "name": exe_name, "size": exe_size, "sha256": exe_sha256,
            "filetype": macho["filetype_name"], "uuid": macho.get("uuid", ""),
            "crypted": macho["crypted"], "cryptid": macho.get("cryptid"),
            "cryptoff": macho.get("cryptoff"), "cryptsize": macho.get("cryptsize"),
            "load_dylibs": macho["dylibs"][:200],
            "sections": macho["section_names"][:400],
        },
        "mobileprovision": prov,
        "frameworks": fw_machos,
        "linked_dynamic_frameworks": linked,
        "candidate_first_party_hosts": hosts.most_common(30),
        "urls": urls[:800],
        "static_only_note": "以上全部为静态解析实测值；动态抓包与真机联调不在本脚本范围内",
        "uuids": uuids[:300],
        "path_groups": path_groups,
        "objc_class_count": len(classnames),
        "objc_selector_count": len(selectors),
        "ble_class_candidates": ble_classes[:120],
        "auth_class_candidates": auth_classes[:120],
        "ble_selector_candidates": ble_selectors[:200],
        "framework_candidates": fw_candidates,
        "string_count": len(merged),
        "note": ("cryptid != 0 表示 App Store 加密壳未脱，__TEXT 字符串不可读；"
                 "需要先砸壳后重新运行本脚本，否则接口/UUID 抽取结果不完整。"),
    }

    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    with open(os.path.join(out_dir, "objc_names.txt"), "w", encoding="utf-8") as f:
        f.write("=== CLASSES (%d) ===\n" % len(classnames))
        f.write("\n".join(classnames))
        f.write("\n\n=== SELECTORS (%d) ===\n" % len(selectors))
        f.write("\n".join(selectors))
    with open(os.path.join(out_dir, "strings_candidates.txt"), "w", encoding="utf-8") as f:
        f.write("=== URLS ===\n" + "\n".join(urls[:800]))
        f.write("\n\n=== UUIDS ===\n" + "\n".join(uuids[:300]))
        f.write("\n\n=== PATH GROUPS ===\n")
        for k, v in path_groups.items():
            f.write("[%s]\n%s\n" % (k, "\n".join(v)))
        f.write("\n\n=== KEYWORD LINES ===\n" + "\n".join(keyword_lines))

    return {"report": report, "hosts": hosts, "uuids": uuids,
            "path_groups": path_groups, "ble_classes": ble_classes,
            "auth_classes": auth_classes, "ble_selectors": ble_selectors,
            "frameworks": linked, "fw_candidates": fw_candidates,
            "info": info, "crypted": macho["crypted"]}


# ---------------------------------------------------------------- 生成 BridgeConfig
def build_config(ctx: dict, ipa_path: str) -> dict:
    report = ctx["report"]
    info = ctx["info"]
    hosts = ctx["hosts"]
    pg = ctx["path_groups"]

    def first(seq, default=""):
        return seq[0] if seq else default

    base_host = first(hosts.most_common(10), ("", 0))[0] if hosts else ""
    api_base = ("https://" + base_host) if base_host else "https://api.example.invalid"

    def pick_path(group, fallback):
        hits = [p for p in pg.get(group, []) if not p.endswith((".png", ".jpg", ".js", ".css"))]
        return first(hits, fallback)

    uuids = ctx["uuids"]
    service_uuid = first(uuids, "0000FFF0-0000-1000-8000-00805F9B34FB")
    write_uuid = uuids[1] if len(uuids) > 1 else "0000FFF1-0000-1000-8000-00805F9B34FB"
    notify_uuid = uuids[2] if len(uuids) > 2 else "0000FFF2-0000-1000-8000-00805F9B34FB"

    defaults = ["ble.commands.*", "ble.frame.*", "api.headers", "api.*_field"]
    if not base_host:
        defaults.append("api.base")
    if not pg.get("login"):
        defaults.append("api.login_path")
    if not uuids:
        defaults += ["ble.service_uuid", "ble.write_uuid", "ble.notify_uuid"]

    # 启发式挑出的域名/路径只是候选，不是证实过的接口，必须人工用 candidates 核对
    needs_review = [
        "api.base", "api.login_path", "api.sms_path", "api.key_path",
        "api.token_json_path", "ble.service_uuid", "ble.write_uuid",
        "ble.notify_uuid", "ble.commands.*", "ble.frame.*", "runtime.*",
    ]

    cfg = {
        "schema": 1,
        "generated_from": os.path.basename(ipa_path),
        "source_ipa_sha256": report["ipa_sha256"],
        "source_bundle_id": info.get("CFBundleIdentifier", ""),
        "source_version": info.get("CFBundleShortVersionString", ""),
        "source_crypted": ctx["crypted"],
        "defaults_applied": defaults,
        "needs_review": needs_review,
        "api_base_selection": "heuristic-from-host-frequency",
        "bridge_mode": "http",
        "app": {
            "bundle_id": "com.blekey.standalone",
            "display_name": "蓝牙钥匙",
            "min_os": "16.0",
        },
        "api": {
            "base": api_base,
            "login_path": pick_path("login", "/api/v1/auth/login"),
            "sms_path": pick_path("sms", "/api/v1/auth/sms"),
            "key_path": pick_path("key", "/api/v1/blekey/list"),
            "vehicle_path": pick_path("vehicle", "/api/v1/vehicle/list"),
            "control_path": pick_path("control", "/api/v1/vehicle/control"),
            "method": "POST",
            "headers": {"Content-Type": "application/json", "Accept": "application/json"},
            "field_phone": "mobile",
            "field_code": "code",
            "field_password": "password",
            "login_type": "sms",
            "token_json_path": "data.accessToken",
            "key_json_path": "data",
        },
        "ble": {
            "service_uuid": service_uuid.upper(),
            "write_uuid": write_uuid.upper(),
            "notify_uuid": notify_uuid.upper(),
            "scan_name_prefix": "",
            "rssi_threshold": -85,
            "scan_timeout_sec": 12.0,
            "connect_timeout_sec": 10.0,
            "command_timeout_sec": 6.0,
            "mtu": 20,
            "commands": {
                "auth": "00",
                "unlock": "01", "lock": "02", "trunk": "03",
                "find_car": "04", "engine_start": "05", "engine_stop": "06",
                "window_up": "07", "window_down": "08",
            },
            "command_labels": {
                "unlock": "解锁", "lock": "上锁", "trunk": "后备箱",
                "find_car": "寻车", "engine_start": "启动", "engine_stop": "熄火",
                "window_up": "升窗", "window_down": "降窗",
            },
            "frame": {
                "header_hex": "5AA5",
                "has_length_byte": True,
                "seq_bytes": 2,
                "crc": "xor8",
                "trailer_hex": "",
                "crypto": "none",
                "key_hex": "",
                "iv_hex": "00000000000000000000000000000000",
            },
        },
        "runtime": {
            "enabled": False,
            "framework": first(ctx["frameworks"], ""),
            "class_login": first(ctx["auth_classes"], ""),
            "class_ble": first(ctx["ble_classes"], ""),
            "selector_login": first([s for s in ctx["ble_selectors"] if "login" in s.lower()], ""),
            "selector_connect": first([s for s in ctx["ble_selectors"] if "connect" in s.lower()], ""),
            "selector_write": first([s for s in ctx["ble_selectors"] if "write" in s.lower()], ""),
            "auth_class_candidates": ctx["auth_classes"][:30],
            "framework_candidates": ctx["fw_candidates"],
        },
        "candidates": {
            "hosts": [h for h, _ in hosts.most_common(20)],
            "uuids": uuids[:50],
            "login_paths": pg.get("login", [])[:30],
            "sms_paths": pg.get("sms", [])[:30],
            "key_paths": pg.get("key", [])[:30],
            "ble_classes": ctx["ble_classes"][:50],
            "auth_classes": ctx["auth_classes"][:50],
            "ble_selectors": ctx["ble_selectors"][:80],
        },
    }
    return cfg


def main() -> int:
    ap = argparse.ArgumentParser(description="从原客户端 ipa 抽取登录接口与蓝牙钥匙协议配置")
    ap.add_argument("ipa", help="原包 ipa 路径")
    ap.add_argument("--out", default="Generated", help="输出目录，默认 ./Generated")
    ap.add_argument("--no-vendor", action="store_true", help="不复制 framework 二进制")
    ap.add_argument("--report-only", action="store_true", help="只出体检报告，不覆盖 BridgeConfig.json")
    args = ap.parse_args()

    if not os.path.isfile(args.ipa):
        print("ERROR: ipa 不存在: %s" % args.ipa, file=sys.stderr)
        return 2
    os.makedirs(args.out, exist_ok=True)

    ctx = inspect_ipa(args.ipa, args.out, copy_vendor=not args.no_vendor)
    r = ctx["report"]
    print("[*] ipa        : %s" % r["ipa"])
    print("[*] sha256     : %s" % r["ipa_sha256"])
    print("[*] bundle id  : %s" % r["info_plist"]["CFBundleIdentifier"])
    print("[*] version    : %s" % r["info_plist"]["CFBundleShortVersionString"])
    print("[*] Mach-O     : %s  %d bytes" % (r["executable"]["filetype"], r["executable"]["size"]))
    print("[*] crypted    : %s (cryptid=%s)" % (r["executable"]["crypted"], r["executable"]["cryptid"]))
    print("[*] frameworks : %d (dynamic linked: %d)" %
          (len(r["frameworks"]), len(r["linked_dynamic_frameworks"])))
    print("[*] ObjC       : %d classes / %d selectors" %
          (r["objc_class_count"], r["objc_selector_count"]))
    print("[*] hosts      : %s" % (r["candidate_first_party_hosts"][:5],))
    print("[*] UUIDs      : %d" % len(r["uuids"]))
    print("[*] BLE class  : %s" % (r["ble_class_candidates"][:6],))
    if r["executable"]["crypted"]:
        print("[!] 该包 __TEXT 仍加密，字符串抽取不完整：请砸壳后重跑。")

    if not args.report_only:
        cfg = build_config(ctx, args.ipa)
        cfg_path = os.path.join(args.out, "BridgeConfig.json")
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        print("[+] 配置       : %s" % cfg_path)
        print("[+] 默认值字段 : %s" % (cfg["defaults_applied"] or "无，全部由原包解析所得"))
    print("[+] 报告       : %s" % os.path.join(args.out, "report.json"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
