#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_repo.py -- 在无 Xcode 的机器上做的静态自检（Windows / Linux / macOS 可跑）。
检查: import 的头文件是否齐全、配置 JSON 结构、目录树、括号粗平衡、脚本语法。
它不替代 xcodebuild，编译只能在 macOS runner 上做。
"""
from __future__ import annotations

import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
APP = os.path.join(ROOT, "App")

REQUIRED_FILES = [
    "project.yml", "App/Info.plist", "App/BleKey.entitlements", "App/main.m",
    "App/AppDelegate.h", "App/AppDelegate.m", "App/ORIGTypes.h",
    "App/ORIGConfig.h", "App/ORIGConfig.m", "App/ORIGSession.h", "App/ORIGSession.m",
    "App/ORIGAuthService.h", "App/ORIGAuthService.m",
    "App/ORIGRuntimeBridge.h", "App/ORIGRuntimeBridge.m",
    "App/ORIGFrameCodec.h", "App/ORIGFrameCodec.m",
    "App/ORIGBleKeyManager.h", "App/ORIGBleKeyManager.m",
    "App/LoginViewController.h", "App/LoginViewController.m",
    "App/CarViewController.h", "App/CarViewController.m",
    "Tools/extract_ipa.py", "Tools/check_repo.py", "Tools/gh_api.py",
    "Tools/analyze_original.py", "Tools/build_config_from_evidence.py",
    "Tools/pack_vendor.py",
    "Scripts/build_trollstore.sh", "Scripts/push_repo.sh", "Scripts/build_remote.sh",
    ".github/workflows/build-ipa.yml",
    "Generated/BridgeConfig.json",
]

REQUIRED_CONFIG_KEYS = [
    "generated_from", "bridge_mode", "api.base", "api.login_path", "api.sms_path",
    "api.key_path", "api.field_phone", "api.token_json_path",
    "ble.service_uuid", "ble.write_uuid", "ble.notify_uuid", "ble.commands",
    "ble.command_labels", "ble.frame", "runtime", "candidates",
]


def has_dot_path(obj, path):
    cur = obj
    for p in path.split("."):
        if not isinstance(cur, dict) or p not in cur:
            return False
        cur = cur[p]
    return True


def main():
    errors, warnings = [], []

    for rel in REQUIRED_FILES:
        if not os.path.isfile(os.path.join(ROOT, rel)):
            errors.append("缺少文件: " + rel)

    # 头文件引用
    headers = {n for n in os.listdir(APP) if n.endswith(".h")} if os.path.isdir(APP) else set()
    mfiles = sorted(n for n in os.listdir(APP) if n.endswith(".m")) if os.path.isdir(APP) else []
    import_count = 0
    for m in mfiles:
        text = open(os.path.join(APP, m), encoding="utf-8").read()
        for inc in re.findall(r'#import\s+"([^"]+)"', text):
            import_count += 1
            if inc not in headers:
                errors.append("%s 引用了不存在的头文件 %s" % (m, inc))
        # 括号粗平衡（字符串里的括号会造成偏差，仅作提示）
        for op, cl, label in (("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")):
            d = text.count(op) - text.count(cl)
            if d != 0:
                warnings.append("%s %s计数差 %+d（含字符串/字面量时的粗检，非必然错误）" % (m, label, d))

    # 配置结构
    cfg_path = os.path.join(ROOT, "Generated", "BridgeConfig.json")
    if os.path.isfile(cfg_path):
        try:
            cfg = json.load(open(cfg_path, encoding="utf-8"))
        except Exception as e:
            errors.append("BridgeConfig.json 解析失败: %s" % e)
            cfg = {}
        for k in REQUIRED_CONFIG_KEYS:
            if not has_dot_path(cfg, k):
                errors.append("BridgeConfig.json 缺少键: " + k)
        if isinstance(cfg.get("ble", {}).get("commands"), dict):
            cmds = cfg["ble"]["commands"]
            if "auth" not in cmds:
                errors.append("ble.commands 缺少 auth（连接后鉴权帧需要）")
            labels = cfg.get("ble", {}).get("command_labels", {})
            for c in cmds:
                if c != "auth" and c not in labels:
                    warnings.append("ble.command_labels 缺少 %s，UI 将显示键名" % c)
        print("[*] 配置来源   : %s" % cfg.get("generated_from"))
        print("[*] api.base   : %s" % cfg.get("api", {}).get("base"))
        print("[*] 已配置标记 : %s" % ("是" if cfg.get("source_bundle_id") else "否（模板）"))
        print("[*] 真实端点   : %d" % len(cfg.get("api", {}).get("endpoints", {})))
        print("[*] 网关       : %d" % len([k for k in cfg.get("gateways", {}) if k != "all_first_party"]))
    else:
        errors.append("缺少 Generated/BridgeConfig.json")

    # shell 脚本语法（bash -n 在 Windows 上可能没有，改用基本检查）
    for rel in ("Scripts/build_trollstore.sh", "Scripts/push_repo.sh"):
        p = os.path.join(ROOT, rel)
        if os.path.isfile(p):
            t = open(p, encoding="utf-8").read()
            if not t.startswith("#!"):
                errors.append("%s 缺少 shebang" % rel)

    # Python 语法（只编译不落盘，避免污染仓库）
    for rel in ("Tools/extract_ipa.py", "Tools/check_repo.py", "Tools/gh_api.py",
                "Tools/analyze_original.py", "Tools/build_config_from_evidence.py",
                "Tools/pack_vendor.py"):
        p = os.path.join(ROOT, rel)
        if os.path.isfile(p):
            try:
                compile(open(p, encoding="utf-8").read(), p, "exec")
            except SyntaxError as e:
                errors.append("Python 语法错误 %s:%s: %s" % (rel, e.lineno, e.msg))

    # SDK zip 与 manifest 一致性：推送前先确认没损坏，runner 解压才不会缺 framework
    zip_path = os.path.join(ROOT, "Generated", "VendorFrameworks.zip")
    man_path = os.path.join(ROOT, "Generated", "VendorManifest.json")
    if os.path.isfile(zip_path) and os.path.isfile(man_path):
        import hashlib
        import zipfile
        man = json.load(open(man_path, encoding="utf-8"))
        digest = hashlib.sha256(open(zip_path, "rb").read()).hexdigest()
        if digest != man.get("zip_sha256"):
            errors.append("VendorFrameworks.zip 与 VendorManifest.json 的 sha256 不一致")
        with zipfile.ZipFile(zip_path) as zf:
            if zf.testzip() is not None:
                errors.append("VendorFrameworks.zip 内部校验失败")
            names = {n.split("/", 1)[0] for n in zf.namelist() if "/" in n}
        missing = [f for f in man.get("closure", []) if f not in names]
        if missing:
            errors.append("SDK zip 缺少 framework: %s" % ", ".join(missing))
        print("[*] SDK 闭包    : %d 个 framework / zip %d bytes" %
              (len(names), os.path.getsize(zip_path)))
    elif os.path.isfile(zip_path) != os.path.isfile(man_path):
        errors.append("VendorFrameworks.zip 与 VendorManifest.json 必须同时存在")

    print("[*] ObjC 源文件 : %d 个 .m / %d 个 .h / %d 处本地 import" %
          (len(mfiles), len(headers), import_count))
    print("[*] 警告         : %d" % len(warnings))
    for w in warnings[:20]:
        print("    ! " + w)
    print("[*] 错误         : %d" % len(errors))
    for e in errors:
        print("    x " + e)
    print("[+] 结论         : %s" % ("静态自检通过（编译仍需在 macOS 上执行）" if not errors
                                     else "静态自检未通过，先修上面错误"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
