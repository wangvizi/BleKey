#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
analyze_original.py -- 定向分析已解包的原客户端，抽取「登录 API + 数字钥匙接口 + BLE 协议」证据。

与 extract_ipa.py 的分工：
  extract_ipa.py     通用体检（域名频次、路径分组、ObjC 符号、framework 清单）
  analyze_original.py 在 __cstring 的**原始顺序**上做上下文分析，把「域名 / 路径 / 字段名 /
                      UUID / 指令常量」的相邻关系留作证据，避免启发式把视频 CDN 当成 API。

输入: 已解包的 .app 目录（extract_ipa.py 的 <out>/_unpacked/Payload/*.app），或直接给 ipa
输出: <out>/original_api.json   结构化证据
      <out>/original_api.txt    可读上下文报告

复杂度: O(文件字节数)，常量级正则；无网络请求，Windows / Linux / macOS 均可运行。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_ipa as E  # noqa: E402  复用 Mach-O 解析

# 数字钥匙协议栈：单独抽 __cstring，避免被主程序的上万条字符串淹没
PROTOCOL_FRAMEWORKS = (
    "Keystone.framework",
    "HKMC_DK2_FrameworkLibrary.framework",
    "PepsPacket.framework",
    "CryptoSwift.framework",
)

# 上下文检索的关键词 -> 输出标题
CONTEXT_QUERIES = {
    "gateway": (
        r"nble-gw-[hk]\.hmgmobility\.com\.cn",
        r"oaas-[hk]\.hmgmobility\.com\.cn",
        r"uars-[hk]\.hmgmobility\.com\.cn",
        r"prd-nccw-[hk]\.hyundaibluelink\.com\.cn",
        r"cn-ccapi",
    ),
    "auth": (
        r"/v1/user/signin",
        r"/user/oauth2/token",
        r"/join/sms/loginInit\.do",
        r"/sbs-sps/login/ccsp",
        r"smsCode|verifyCode|authCode|mobileNo|phoneNo|loginId|userId",
    ),
    "digital_key_api": (
        r"/apps/dkc2/",
        r"requestOwnerDigitalKeyInformation",
        r"sendDigitalKeyRegistrationMessage",
        r"requestDigitalKeyLibVer",
        r"/sbs-sps/auth/certReq",
    ),
    "ble_uuid": (
        r"CBUUID|serviceUUID|ServiceUuid|characteristicUUID|CharacteristicUuid",
        r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        r"\bFFF[0-9A-Fa-f]\b|\bFE[0-9A-Fa-f]{2}\b|18F0",
    ),
    "ble_command": (
        r"(?i)door(un)?lock|unlock|trunk|engine(start|stop)|remoteStart|findCar|horn|light",
        r"(?i)challenge|auth(entication)?|sessionKey|keyId|vehicleId|vin",
        r"(?i)frame|packet|payload|commandId|cmdId|sequence|crc",
    ),
}

# 结构化抽取
URL_RE = re.compile(r"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%\-]{6,180}")
UUID_RE = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
                     r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
PATH_RE = re.compile(r"/[A-Za-z0-9_./{}$\-]{4,150}")
SHORT_UUID_RE = re.compile(r"\b(?:FFF[0-9A-Fa-f]|FE[0-9A-Fa-f]{2}|18F0)\b", re.I)

# 车厂第一方域名（用于给候选域名分级，不是硬编码接口值）
FIRST_PARTY_MARKERS = ("hmgmobility", "hyundaibluelink", "hyundai.com.cn",
                       "jiayudata", "gokuaidian", "fleetingpower", "kiauvo")
# 排除明显不属于 HTTP API 的路径（编译期路径、资源路径）
BAD_PATH = ("/Volumes/", "/Users/", "/Build/", "/Objects-normal/",
            "/IntermediateBuildFilesPath/", ".png", ".jpg", ".nib",
            ".m", ".h", ".swift", ".plist", ".json", ".html", ".css")


def cstrings_of_macho(path: Path) -> list[str]:
    """按 Mach-O __cstring 段的原始顺序取字符串（保留顺序 = 保留证据上下文）。"""
    raw = path.read_bytes()
    sliced, _arch = E.pick_arm64_slice(raw)
    macho = E.parse_macho(sliced)
    out: list[str] = []
    for blob in macho["sections"].get("__cstring", []):
        for part in blob.split(b"\x00"):
            if not part:
                continue
            s = part.decode("utf-8", "replace")
            if 2 <= len(s) <= 512:
                out.append(s)
    return out


def collect(app_dir: Path) -> dict[str, list[str]]:
    exe = None
    info = app_dir / "Info.plist"
    if info.is_file():
        import plistlib
        name = plistlib.loads(info.read_bytes()).get("CFBundleExecutable", "")
        if name and (app_dir / name).is_file():
            exe = app_dir / name
    groups: dict[str, list[str]] = {}
    if exe:
        groups["main"] = cstrings_of_macho(exe)
    fwroot = app_dir / "Frameworks"
    for fw in PROTOCOL_FRAMEWORKS:
        binary = fwroot / fw / fw[:-10]
        if binary.is_file():
            groups[fw[:-10]] = cstrings_of_macho(binary)
    # 资源文件里的字符串也补进来（plist / json / strings）
    res: list[str] = []
    for p in sorted(app_dir.rglob("*")):
        if not p.is_file() or p.suffix.lower() not in (".plist", ".json", ".strings", ".txt"):
            continue
        try:
            if p.stat().st_size > 2 * 1024 * 1024:
                continue
            res.extend(E.printable_strings(p.read_bytes(), 5))
        except OSError:
            continue
    groups["resources"] = res
    return groups


def context(items: list[str], pattern: str, before: int = 5, after: int = 9) -> list[dict]:
    rx = re.compile(pattern)
    hits = []
    for i, s in enumerate(items):
        if rx.search(s):
            lo, hi = max(0, i - before), min(len(items), i + after + 1)
            hits.append({
                "index": i,
                "match": s[:200],
                "window": [items[k][:200] for k in range(lo, hi)],
            })
        if len(hits) >= 12:
            break
    return hits


def classify(groups: dict[str, list[str]]) -> dict:
    all_items = [s for v in groups.values() for s in v]
    text = "\n".join(all_items)

    urls = sorted({m.rstrip(".,;'\"") for m in URL_RE.findall(text)})
    hosts = sorted({re.split(r"[/:?#]", u.split("://", 1)[1], maxsplit=1)[0].lower()
                    for u in urls if "://" in u})
    first_party = [h for h in hosts if any(k in h for k in FIRST_PARTY_MARKERS)]
    paths = sorted({m for m in PATH_RE.findall(text)
                    if not any(b in m for b in BAD_PATH)})
    key_paths = sorted({p for p in paths if "/apps/dkc2/" in p or "digitalkey" in p.lower()
                        or "blekey" in p.lower()})
    auth_paths = sorted({p for p in paths if any(k in p.lower() for k in
                        ("signin", "login", "oauth", "token", "sms", "certreq", "join/"))})
    uuids = sorted({m.upper() for m in UUID_RE.findall(text)})
    short_uuids = sorted({m.upper() for m in SHORT_UUID_RE.findall(text)})

    # 字段名：JSON / 表单键常见拼写
    field_rx = re.compile(r"^[a-z][A-Za-z0-9_]{2,40}$")
    fields = sorted({s for s in all_items if field_rx.match(s) and any(
        k in s.lower() for k in ("phone", "mobile", "code", "token", "vin", "vehicleid",
                                 "keyid", "userid", "loginid", "password", "sms", "auth"))})

    ctx: dict[str, dict] = {}
    for group, patterns in CONTEXT_QUERIES.items():
        for src, items in groups.items():
            for pat in patterns:
                hits = context(items, pat)
                if hits:
                    ctx.setdefault(group, {}).setdefault(src, []).append(
                        {"pattern": pat, "hits": hits})

    return {
        "hosts_all": hosts,
        "hosts_first_party": first_party,
        "urls_first_party": [u for u in urls if any(k in u for k in FIRST_PARTY_MARKERS)],
        "key_paths": key_paths,
        "auth_paths": auth_paths,
        "uuids_128": uuids,
        "uuids_16bit": short_uuids,
        "field_names": fields,
        "contexts": ctx,
        "counts": {k: len(v) for k, v in groups.items()},
    }


def write_report(data: dict, out: Path) -> None:
    lines = []
    for key in ("hosts_first_party", "urls_first_party", "key_paths", "auth_paths",
                "uuids_16bit", "field_names"):
        lines.append("=== %s (%d) ===" % (key, len(data[key])))
        lines.extend("  " + x for x in data[key][:120])
        lines.append("")
    lines.append("=== uuids_128 (%d, 前 60) ===" % len(data["uuids_128"]))
    lines.extend("  " + x for x in data["uuids_128"][:60])
    lines.append("")
    for group, bysrc in data["contexts"].items():
        lines.append("########## CONTEXT %s ##########" % group)
        for src, entries in bysrc.items():
            for ent in entries:
                lines.append("--- [%s] pattern=%s (%d hits) ---" %
                             (src, ent["pattern"], len(ent["hits"])))
                for h in ent["hits"]:
                    lines.append("  @%d  match: %s" % (h["index"], h["match"]))
                    for w in h["window"]:
                        lines.append("        | " + w)
                lines.append("")
    (out / "original_api.txt").write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="定向分析原客户端登录接口与数字钥匙协议")
    ap.add_argument("source", help="已解包的 .app 目录，或原包 .ipa")
    ap.add_argument("--out", default="Generated", help="输出目录")
    ap.add_argument("--temp", default="", help="ipa 解包临时目录（默认 <out>/_analyze_unpack）")
    args = ap.parse_args()

    src = Path(args.source)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    app_dir = src
    if src.is_file() and src.suffix.lower() == ".ipa":
        tmp = Path(args.temp) if args.temp else out / "_analyze_unpack"
        tmp.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(src) as zf:
            zf.extractall(tmp)
        payload = tmp / "Payload"
        apps = [p for p in payload.iterdir() if p.suffix == ".app"] if payload.is_dir() else []
        if not apps:
            print("ERROR: ipa 内没有 Payload/*.app", file=sys.stderr)
            return 2
        app_dir = apps[0]
    if not app_dir.is_dir():
        print("ERROR: 源不是目录也不是 ipa: %s" % app_dir, file=sys.stderr)
        return 2

    groups = collect(app_dir)
    data = classify(groups)
    data["source"] = str(app_dir)
    (out / "original_api.json").write_text(
        json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    write_report(data, out)

    print("[*] 源           : %s" % app_dir)
    print("[*] cstring 分组 : %s" % data["counts"])
    print("[*] 第一方域名   : %d" % len(data["hosts_first_party"]))
    for h in data["hosts_first_party"]:
        print("      %s" % h)
    print("[*] 数字钥匙路径 : %d" % len(data["key_paths"]))
    for p in data["key_paths"][:25]:
        print("      %s" % p)
    print("[*] 认证路径     : %d" % len(data["auth_paths"]))
    for p in data["auth_paths"][:25]:
        print("      %s" % p)
    print("[*] 16bit UUID   : %s" % data["uuids_16bit"])
    print("[*] 128bit UUID  : %d" % len(data["uuids_128"]))
    print("[+] 证据 JSON    : %s" % (out / "original_api.json"))
    print("[+] 上下文报告   : %s" % (out / "original_api.txt"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
