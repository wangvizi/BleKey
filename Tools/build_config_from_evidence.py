#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_config_from_evidence.py -- 把 extract_ipa.py / analyze_original.py 的实测证据
合并成独立 app 可直接使用的 BridgeConfig.json 与 RealEndpoints.json。

与通用启发式 build_config() 的区别：
  - 域名按「网关用途」归类（oauth / uars / ble / telematics / ccapi），不再按出现频次，
    避免把视频 CDN video.hyundaibluelink.com.cn 当成 API。
  - 每个接口路径都写成绝对 URL，指向它真正所属的那台网关；ORIGConfig.urlForPathKey:
    支持绝对 URL（见 App/ORIGConfig.m:172-182）。
  - 每个值都带 evidence 出处（__cstring 索引 / 报告字段），便于逐条复核。
  - 仍无法静态确定的项（BLE 挑战应答帧、指令码、响应 JSON 路径）明确列进
    defaults_applied / needs_review，不伪装成实测值。

输入: Generated/report.json + Generated/original_api.json（+ 可选模板配置）
输出: Generated/BridgeConfig.json, Generated/RealEndpoints.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

# 网关用途识别规则：host 前缀 -> 用途键。brand 由 --brand 决定（h=现代 / k=起亚）
GATEWAY_RULES = (
    ("oauth", r"^oaas-{b}\.hmgmobility\.com\.cn$"),
    ("uars", r"^uars-{b}\.hmgmobility\.com\.cn$"),
    ("ble", r"^nble-gw-{b}\.hmgmobility\.com\.cn$"),
    ("telematics", r"^prd-nccw-{b}\.hyundaibluelink\.com\.cn$"),
    ("ccapi", r"^prd\.cn-ccapi\.hyundai\.com$"),
    ("hmc", r"^hmc\.hyundaibluelink\.com\.cn$"),
    ("auth", r"^auth\.hyundai\.com\.cn$"),
    ("channel", r"^appchannelapi\.hyundai\.jiayudata\.com$"),
    ("open", r"^open\.hyundai\.jiayudata\.com$"),
)

# 路径用途：精确优先，正则兜底
PATH_RULES = {
    "sms_login": (r"^/join/sms/loginInit\.do$",),
    "account_login": (r"^/join/account/loginInit\.do$",),
    "oneclick_login": (r"^/join/oneclick/loginInit\.do$",),
    "wechat_login": (r"^/join/wechat/loginInit\.do$",),
    "web_signin": (r"^/?web/v1/user/signin$", r"v1/user/signin"),
    "oauth_authorize": (r"^/user/oauth2/authorize",),
    "oauth_redirect": (r"^/user/oauth2/redirect$",),
    "oauth_token": (r"^/user/oauth2/token$",),
    "ccsp_login": (r"^/sbs-sps/login/ccsp$",),
    "ccsp_cert": (r"^/sbs-sps/auth/certReq/ccsp$",),
    "refresh_token": (r"^/join/common/refreshToken\.do$",),
    "nccw_main": (r"^/api/v1/nccw/main\.do", r"^/nccw/main\.do"),
    "dkc2_key_list": (r"/apps/dkc2/.*/requestOwnerDigitalKeyInformation$",),
    "dkc2_pairing_password": (r"/apps/dkc2/.*/requestPairingPassword$",),
    "dkc2_registration": (r"/apps/dkc2/.*/sendDigitalKeyRegistrationMessage$",),
    "dkc2_lib_ver": (r"/apps/dkc2/.*/requestDigitalKeyLibVer$",),
    "dkc2_unpair": (r"/apps/dkc2/.*/requestAppUnpairing$",),
    "dkc_share_sms": (r"^/apps/dkc/dkcsa/(reg|res)/slave/auth/sms$",),
    "dkc_device": (r"^/apps/dkc/dkcsa/mod/noti/device$",),
}

# 字段名优先级：从原包 __cstring 实测字段名里挑
FIELD_RULES = {
    "field_phone": ("mobileNo", "phoneNo", "phoneNumber", "mobile", "phone", "carDriverPhoneNum"),
    "field_code": ("smsCode", "verifyCode", "authCode", "authcode", "smsCertNo", "code"),
    "field_password": ("password", "passwd", "pwd"),
    "token_json_path": ("accessToken", "access_token", "ccspUserAccessToken"),
}

# 数字钥匙 SDK 的入口 framework（最小闭包由 pack_vendor.py 展开）
SDK_SEEDS = ("Keystone.framework", "HKMC_DK2_FrameworkLibrary.framework",
             "PepsPacket.framework")

SDK_CLASS_RULES = {
    "class_ble": ("_TtC8Keystone19DigitalKeyOpManager", "_TtC8Keystone16BleDeviceService",
                  "_TtC8Keystone20CommunicationManager"),
    "class_login": ("_TtC8Keystone11UserManager", "_TtC8Keystone6Config"),
    "class_config": ("_TtC8Keystone21KeystoneConfiguration", "_TtC8Keystone16BleConfiguration"),
    "class_dk2": ("_TtC25HKMC_DK2_FrameworkLibrary25DigitalKeyFrameworkCompat",
                  "_TtC25HKMC_DK2_FrameworkLibrary28DigitalKeyFrameworkCompatRKE"),
}

UUID_PREFIX = "10991775-2510-4741-8212-"


def load(path: Path) -> dict:
    if not path.is_file():
        raise SystemExit("ERROR: 缺少证据文件 %s，请先运行 extract_ipa.py / analyze_original.py" % path)
    return json.loads(path.read_text(encoding="utf-8"))


def load_objc_names(path: Path) -> tuple[list[str], list[str]]:
    """objc_names.txt 里是未被报告截断的完整类名/selector 清单。"""
    if not path.is_file():
        return [], []
    text = path.read_text(encoding="utf-8", errors="replace")
    m_cls = re.search(r"=== CLASSES \(\d+\) ===\n(.*?)(?=\n\n=== SELECTORS)", text, re.S)
    m_sel = re.search(r"=== SELECTORS \(\d+\) ===\n(.*)$", text, re.S)
    classes = [x for x in (m_cls.group(1).splitlines() if m_cls else []) if x.strip()]
    selectors = [x for x in (m_sel.group(1).splitlines() if m_sel else []) if x.strip()]
    return classes, selectors


def pick_host(hosts: list[str], brand: str) -> dict[str, str]:
    out = {}
    for key, rule in GATEWAY_RULES:
        rx = re.compile(rule.format(b=re.escape(brand)), re.I)
        hit = next((h for h in hosts if rx.match(h)), "")
        if hit:
            out[key] = "https://" + hit
    return out


def context_paths(data: dict) -> list[str]:
    """上下文窗口里的路径也是实测值（如 /api/v1/nccw/main.do?vin=）。"""
    rx = re.compile(r"/[A-Za-z0-9_./{}$\-]{4,150}")
    out = []
    for bysrc in data.get("contexts", {}).values():
        for entries in bysrc.values():
            for ent in entries:
                for hit in ent.get("hits", []):
                    for w in hit.get("window", []):
                        for m in rx.findall(w):
                            if not any(b in m for b in ("/Users/", "/builds/", ".swift", ".png")):
                                out.append(m.split("?")[0])
    return out


def pick_paths(data: dict, extra: list[str] | tuple[str, ...] = ()) -> dict[str, str]:
    # 报告里的 path_groups 含 nccw / dkc 等非登录类端点，一并纳入候选池
    pool = sorted(set(data.get("key_paths", []) + data.get("auth_paths", []) + list(extra)))
    out = {}
    for key, rules in PATH_RULES.items():
        hit = ""
        for rx in rules:
            r = re.compile(rx, re.I)
            hit = next((p for p in pool if r.search(p)), "")
            if hit:
                break
        if hit and not hit.startswith("/"):
            hit = "/" + hit
        out[key] = hit.split("?")[0]
    return out


def pick_fields(data: dict) -> dict[str, str]:
    names = set(data.get("field_names", []))
    out = {}
    for key, candidates in FIELD_RULES.items():
        out[key] = next((c for c in candidates if c in names), candidates[-1])
    return out


def context_values(data: dict, group: str, src: str, rx: str) -> list[str]:
    """从上下文窗口里取符合 rx 的实测值（client_id / appId / header 等）。"""
    r = re.compile(rx)
    vals = []
    for ent in data.get("contexts", {}).get(group, {}).get(src, []):
        for hit in ent.get("hits", []):
            for w in hit.get("window", []):
                if r.fullmatch(w.strip()) and w.strip() not in vals:
                    vals.append(w.strip())
    return vals


def pick_classes(classes: list[str]) -> dict[str, str]:
    s = set(classes)
    out = {}
    for key, candidates in SDK_CLASS_RULES.items():
        out[key] = next((c for c in candidates if c in s), "")
    return out


def pick_selectors(selectors: list[str]) -> dict[str, str]:
    rules = {
        "selector_connect": ("initWithConfiguration:delegate:", "connect", "enableBLE"),
        "selector_write": ("processPEPSPacketWithChannelID:", "write", "send"),
        "selector_login": ("getDigitalKeyId", "login", "authorize"),
    }
    out = {}
    for key, kws in rules.items():
        hit = ""
        for kw in kws:
            hit = next((s for s in selectors if kw.lower() in s.lower()), "")
            if hit:
                break
        out[key] = hit
    return out


def build(report: dict, analysis: dict, template: dict, ipa: Path, brand: str,
          objc_names: tuple[list[str], list[str]] = ((), ())) -> tuple[dict, dict]:
    hosts = analysis.get("hosts_first_party", [])
    gateways = pick_host(hosts, brand)
    extra_paths = ([p for group in report.get("path_groups", {}).values() for p in group] +
                   context_paths(analysis))
    paths = pick_paths(analysis, extra_paths)
    fields = pick_fields(analysis)
    all_classes = list(objc_names[0]) or (report.get("ble_class_candidates", []) +
                                          report.get("auth_class_candidates", []))
    all_selectors = list(objc_names[1]) or report.get("ble_selector_candidates", [])
    classes = pick_classes(all_classes)
    selectors = pick_selectors(all_selectors)

    oauth_ids = context_values(analysis, "gateway", "main",
                               r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
    app_ids = context_values(analysis, "auth", "main", r"[a-z0-9]{32}")

    def url(gw: str, path: str) -> str:
        return (gateways.get(gw, "") + path) if gateways.get(gw) and path else ""

    def abs_or(base_key: str, path_key: str) -> str:
        v = url(base_key, paths.get(path_key, ""))
        return v or paths.get(path_key, "")

    # BLE UUID：Keystone 广播 service UUID 前缀最可信，其它为同族候选
    uuids = [u.upper() for u in analysis.get("uuids_128", [])]
    keystone_uuids = [u for u in uuids if u.startswith(UUID_PREFIX)]
    service = next((u for u in keystone_uuids if u.endswith("-000000000000")),
                   keystone_uuids[0] if keystone_uuids else "")
    others = [u for u in keystone_uuids if u != service]
    ble_manager_uuids = [u for u in uuids if u.startswith(("8AC32D3F-", "5E9BF2A8-"))]
    write = others[0] if others else (ble_manager_uuids[0] if ble_manager_uuids else "")
    notify = ble_manager_uuids[0] if ble_manager_uuids else (others[1] if len(others) > 1 else "")

    ble_tpl = template.get("ble", {})
    api_tpl = template.get("api", {})
    app_tpl = template.get("app", {})

    # 原包登录是 OAuth2 + WebView（UARS/CPW），不是单一 JSON 表单；
    # 这里把每个端点都指向真实网关，登录页表单仍可用，OAuth 全流程参数单列在 api.oauth。
    oauth = {
        "authorize_url": url("oauth", paths.get("oauth_authorize", "")) +
                         ("?response_type=code&client_id=" + oauth_ids[0]
                          if oauth_ids and url("oauth", paths.get("oauth_authorize", "")) else ""),
        "authorize_path": paths.get("oauth_authorize", ""),
        "token_url": url("oauth", paths.get("oauth_token", "")),
        "redirect_path": paths.get("oauth_redirect", ""),
        "client_ids": oauth_ids,
        "app_ids": app_ids,
        "signin_path": paths.get("web_signin", ""),
        "grant_type_hint": "authorization_code",
        "evidence": "original_api.txt / CONTEXT gateway + CONTEXT auth",
    }

    endpoints = {
        "sms_login": abs_or("uars", "sms_login"),
        "account_login": abs_or("uars", "account_login"),
        "oneclick_login": abs_or("uars", "oneclick_login"),
        "wechat_login": abs_or("uars", "wechat_login"),
        "refresh_token": abs_or("uars", "refresh_token"),
        "oauth_token": oauth["token_url"],
        "ccsp_login": abs_or("uars", "ccsp_login"),
        "ccsp_cert": abs_or("uars", "ccsp_cert"),
        "nccw_main": abs_or("telematics", "nccw_main"),
        "dkc2_key_list": abs_or("ble", "dkc2_key_list"),
        "dkc2_pairing_password": abs_or("ble", "dkc2_pairing_password"),
        "dkc2_registration": abs_or("ble", "dkc2_registration"),
        "dkc2_lib_ver": abs_or("ble", "dkc2_lib_ver"),
        "dkc2_unpair": abs_or("ble", "dkc2_unpair"),
        "dkc_share_sms": abs_or("ble", "dkc_share_sms"),
        "dkc_device": abs_or("ble", "dkc_device"),
    }
    endpoints = {k: v for k, v in endpoints.items() if v}

    cfg = {
        "schema": 2,
        "generated_from": os.path.basename(str(ipa)),
        "source_ipa_sha256": report.get("ipa_sha256", ""),
        "source_bundle_id": report.get("info_plist", {}).get("CFBundleIdentifier", ""),
        "source_version": report.get("info_plist", {}).get("CFBundleShortVersionString", ""),
        "source_crypted": report.get("executable", {}).get("crypted", False),
        "bridge_mode": "http",
        "api_base_selection": "static-evidence-by-gateway-role",
        "gateways": dict(gateways, all_first_party=hosts),
        "app": app_tpl or {
            "bundle_id": "com.blekey.standalone", "display_name": "蓝牙钥匙", "min_os": "16.0",
        },
        "api": {
            "base": gateways.get("uars", ""),
            "login_path": endpoints.get("oauth_token", "") or api_tpl.get("login_path", ""),
            "sms_path": endpoints.get("sms_login", "") or api_tpl.get("sms_path", ""),
            "key_path": endpoints.get("dkc2_key_list", "") or api_tpl.get("key_path", ""),
            "vehicle_path": endpoints.get("nccw_main", "") or api_tpl.get("vehicle_path", ""),
            "control_path": endpoints.get("nccw_main", "") or api_tpl.get("control_path", ""),
            "method": "POST",
            "headers": dict(api_tpl.get("headers", {})) or {
                "Content-Type": "application/json", "Accept": "application/json",
            },
            "extra_body": api_tpl.get("extra_body", {}),
            "field_phone": fields["field_phone"],
            "field_code": fields["field_code"],
            "field_password": fields["field_password"],
            "login_type": "sms",
            "token_json_path": fields["token_json_path"],
            "key_json_path": api_tpl.get("key_json_path", "data"),
            "oauth": oauth,
            "endpoints": endpoints,
        },
        "ble": {
            "service_uuid": service,
            "write_uuid": write,
            "notify_uuid": notify,
            "uuid_candidates_keystone": keystone_uuids,
            "uuid_candidates_ble_manager": ble_manager_uuids,
            "scan_name_prefix": ble_tpl.get("scan_name_prefix", ""),
            "rssi_threshold": ble_tpl.get("rssi_threshold", -85),
            "scan_timeout_sec": ble_tpl.get("scan_timeout_sec", 12.0),
            "connect_timeout_sec": ble_tpl.get("connect_timeout_sec", 10.0),
            "command_timeout_sec": ble_tpl.get("command_timeout_sec", 6.0),
            "mtu": ble_tpl.get("mtu", 20),
            "protocol": "keystone-challenge-response",
            "protocol_note": ("Keystone.framework 的 __cstring 实测含 session request / auth challenge / "
                              "ownerRegistration / passive action challenge；BLE 报文为加密挑战应答，"
                              "不能由静态字符串还原出固定指令码，需调用原包 SDK。"),
            "sdk_frameworks": list(SDK_SEEDS) + ["TrustKit.framework"],
            "sdk_action_strings": sorted(set(
                h["match"][:100]
                for e in analysis.get("contexts", {}).get("ble_command", {}).get("Keystone", [])
                for h in e.get("hits", [])
            ))[:60],
            "commands": ble_tpl.get("commands", {}),
            "command_labels": ble_tpl.get("command_labels", {}),
            "frame": ble_tpl.get("frame", {}),
        },
        "runtime": {
            "enabled": False,
            "reason": "SDK 为 Swift 类（_TtC8Keystone*），NSInvocation 不能直接调 Swift 方法；"
                      "framework 已随包注入，供 Swift 胶水层调用",
            "framework": "Keystone.framework",
            "class_login": classes["class_login"],
            "class_ble": classes["class_ble"],
            "class_config": classes["class_config"],
            "class_dk2": classes["class_dk2"],
            "selector_login": selectors["selector_login"],
            "selector_connect": selectors["selector_connect"],
            "selector_write": selectors["selector_write"],
            "auth_class_candidates": report.get("auth_class_candidates", [])[:30],
            "framework_candidates": report.get("framework_candidates", []),
        },
        "candidates": {
            "hosts": hosts,
            "uuids": uuids[:50],
            "login_paths": [p for p in analysis.get("auth_paths", []) if p.startswith("/")][:40],
            "key_paths": analysis.get("key_paths", [])[:30],
            "ble_classes": report.get("ble_class_candidates", [])[:50],
            "auth_classes": report.get("auth_class_candidates", [])[:50],
            "ble_selectors": report.get("ble_selector_candidates", [])[:80],
        },
        "defaults_applied": [
            "ble.commands.*", "ble.frame.*", "api.token_json_path",
            "api.key_json_path", "api.extra_body", "ble.scan_*",
        ],
        "needs_review": [
            "api.token_json_path（OAuth/CCSP 响应的实际嵌套层级）",
            "api.oauth.client_ids 与 app_ids 的用途归属",
            "ble.write_uuid / ble.notify_uuid（Keystone 特征 UUID 未在字符串中出现）",
            "ble.commands.*（Keystone 加密挑战应答，静态不可还原）",
            "ble.frame.*（同上）",
            "runtime.*（Swift SDK 需 Swift 胶水层）",
        ],
        "evidence": {
            "report": "Generated/report.json",
            "analysis": "Generated/original_api.json",
            "contexts": "Generated/original_api.txt",
            "gateway_hosts": gateways,
            "oauth_client_ids_at": "original_api.txt / CONTEXT gateway @1271-1274",
            "dkc2_paths_at": "original_api.txt / CONTEXT digital_key_api @1124-1169",
            "ble_uuids_at": "original_api.txt / CONTEXT ble_uuid @2984-2985, Keystone @489",
            "sdk_classes_at": "Generated/objc_names.txt",
        },
    }

    real = {
        "source": {
            "ipa": os.path.basename(str(ipa)),
            "sha256": report.get("ipa_sha256", ""),
            "bundle_id": cfg["source_bundle_id"],
            "version": cfg["source_version"],
            "crypted": cfg["source_crypted"],
            "executable": report.get("executable", {}).get("name", ""),
            "objc_classes": report.get("objc_class_count", 0),
            "objc_selectors": report.get("objc_selector_count", 0),
            "dynamic_frameworks": [f["name"] for f in report.get("frameworks", [])],
        },
        "gateways": gateways,
        "oauth": oauth,
        "endpoints": endpoints,
        "paths_raw": paths,
        "field_names": fields,
        "ble": {
            "service_uuid": service, "write_uuid": write, "notify_uuid": notify,
            "keystone_uuids": keystone_uuids, "ble_manager_uuids": ble_manager_uuids,
            "protocol": cfg["ble"]["protocol"],
            "sdk_frameworks": cfg["ble"]["sdk_frameworks"],
            "sdk_classes": classes,
            "sdk_selectors": selectors,
        },
        "pinned_cert_domains": [
            k for k in report.get("info_plist", {}).get("NSAppTransportSecurity", {})
            if isinstance(k, str)
        ],
        "all_first_party_hosts": hosts,
    }
    return cfg, real


def main() -> int:
    ap = argparse.ArgumentParser(description="把原包静态证据合并成真实 BridgeConfig.json")
    ap.add_argument("--report", default="Generated/report.json")
    ap.add_argument("--analysis", default="Generated/original_api.json")
    ap.add_argument("--template", default="Generated/BridgeConfig.template.json",
                    help="保留命令码/UI 文案/帧格式的模板配置；不存在则用内置缺省")
    ap.add_argument("--ipa", default="", help="原包 ipa 路径（写进 generated_from / sha256）")
    ap.add_argument("--out", default="Generated")
    ap.add_argument("--objc-names", default="Generated/objc_names.txt",
                    help="完整类名/selector 清单，优先于报告里的截断候选")
    ap.add_argument("--brand", choices=("h", "k"), default="h", help="h=现代 Bluelink，k=起亚 UVO")
    args = ap.parse_args()

    report = load(Path(args.report))
    analysis = load(Path(args.analysis))
    names = load_objc_names(Path(args.objc_names))
    tpl_path = Path(args.template)
    template = json.loads(tpl_path.read_text(encoding="utf-8")) if tpl_path.is_file() else {}

    ipa = Path(args.ipa) if args.ipa else Path(report.get("ipa", ""))
    if ipa.is_file() and not report.get("ipa_sha256"):
        report["ipa_sha256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()

    cfg, real = build(report, analysis, template, ipa, args.brand, names)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "BridgeConfig.json").write_text(
        json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out / "RealEndpoints.json").write_text(
        json.dumps(real, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("[*] 原包       : %s %s" % (cfg["source_bundle_id"], cfg["source_version"]))
    print("[*] 网关       : %s" % json.dumps({k: v for k, v in cfg["gateways"].items()
                                          if k != "all_first_party"}, ensure_ascii=False))
    print("[*] OAuth ID   : %s" % (cfg["api"]["oauth"]["client_ids"],))
    print("[*] 端点数     : %d" % len(cfg["api"]["endpoints"]))
    for k, v in cfg["api"]["endpoints"].items():
        print("      %-24s %s" % (k, v))
    print("[*] BLE service: %s" % cfg["ble"]["service_uuid"])
    print("[*] SDK 类     : %s" % json.dumps(
        {k: v for k, v in cfg["runtime"].items() if k.startswith("class_")}, ensure_ascii=False))
    print("[+] 配置       : %s" % (out / "BridgeConfig.json"))
    print("[+] 接口清单   : %s" % (out / "RealEndpoints.json"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
