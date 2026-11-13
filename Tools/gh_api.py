#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gh_api.py -- 只走 api.github.com 的远程编译编排器，不需要 git push，也不需要 gh CLI。

适用环境：本机 github.com 直连/代理 CONNECT 不通，但 api.github.com 可达。
流程：
  push   : REST Git Data API 单 commit 推送整个仓库（blob -> tree -> commit -> ref）
  dispatch: 触发 build-ipa.yml 的 workflow_dispatch
  watch  : 轮询 run 直到 completed，失败时拉日志尾部
  fetch  : 下载 artifact zip 解出 ipa；失败则回退读仓库里的 output/BleKey.ipa.b64
  all    : 上面四步串起来，最终在 output/ 落地 .ipa 并打印 sha256

token 只从环境变量 GITHUB_TOKEN 读取，不写文件、不进命令行参数、不打印。
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API = "https://api.github.com"
WORKFLOW = "build-ipa.yml"
ARTIFACT_NAME = "BleKey-TrollStore-ipa"
MIRROR_PATH = "output/BleKey.ipa.b64"

EXCLUDE_DIR_NAMES = {
    ".git", ".build", "output", "DerivedData", "__pycache__",
    "_unpacked", "_smoketest", "Vendor", ".workbuddy", "xcuserdata",
}
EXCLUDE_FILE_NAMES = {"report.json", "objc_names.txt", "strings_candidates.txt", ".DS_Store"}
MAX_BLOB_BYTES = 95 * 1024 * 1024  # GitHub blob API 单文件上限约 100MB


class GHError(RuntimeError):
    def __init__(self, status, path, body):
        self.status, self.path, self.body = status, path, body
        try:
            detail = json.loads(body).get("message", body)
        except Exception:
            detail = body
        super().__init__("GitHub API %s -> HTTP %s: %s" % (path, status, detail))


class GH:
    def __init__(self, token: str):
        self.token = token.strip()
        if not self.token:
            raise SystemExit("ERROR: 环境变量 GITHUB_TOKEN 为空")

    def req(self, method: str, path: str, body=None, raw=False,
            accept="application/vnd.github+json", timeout=90):
        url = path if path.startswith("http") else API + path
        data = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {
            "Authorization": "Bearer " + self.token,
            "Accept": accept,
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "blekey-builder/1.0",
        }
        if data is not None:
            headers["Content-Type"] = "application/json"
        r = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            # urllib 自动读取 https_proxy 环境变量，正好走本机可达的代理
            with urllib.request.urlopen(r, timeout=timeout) as resp:
                buf = resp.read()
                status = resp.status
                hdrs = dict(resp.headers)
        except urllib.error.HTTPError as e:
            raise GHError(e.code, path, e.read().decode("utf-8", "replace")) from None
        except urllib.error.URLError as e:
            raise RuntimeError("网络错误 %s %s: %s" % (method, path, e.reason)) from None
        if raw:
            return buf, status, hdrs
        return (json.loads(buf) if buf else {}), status, hdrs


# ---------------------------------------------------------------- 仓库文件收集
def repo_files(include_ipa: bool = True):
    out = []
    for p in sorted(ROOT.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(ROOT).as_posix()
        parts = rel.split("/")
        if any(x in EXCLUDE_DIR_NAMES for x in parts[:-1]):
            continue
        if p.name in EXCLUDE_FILE_NAMES:
            continue
        if p.suffix.lower() in (".pyc", ".pyo", ".xcworkspace", ".xcodeproj"):
            continue
        if rel.startswith("input/") and rel.lower().endswith(".ipa") and not include_ipa:
            continue
        size = p.stat().st_size
        if size > MAX_BLOB_BYTES:
            print("[!] 跳过超 95MB 文件: %s (%d bytes)" % (rel, size))
            continue
        mode = "100755" if (rel.startswith("Scripts/") and rel.endswith(".sh")) else "100644"
        out.append((rel, p, mode))
    return out


# ---------------------------------------------------------------- push
def ensure_repo(gh: GH, repo: str | None, repo_name: str, private: bool) -> str:
    if repo:
        info, _, _ = gh.req("GET", "/repos/" + repo)
        print("[+] 使用现有仓库: %s (private=%s, default_branch=%s)" %
              (info["full_name"], info["private"], info["default_branch"]))
        return info["full_name"]

    me, _, _ = gh.req("GET", "/user")
    login = me["login"]
    full = "%s/%s" % (login, repo_name)
    try:
        info, _, _ = gh.req("GET", "/repos/" + full)
        print("[+] 仓库已存在: %s" % info["full_name"])
        return info["full_name"]
    except GHError as e:
        if e.status != 404:
            raise
    try:
        info, _, _ = gh.req("POST", "/user/repos", {
            "name": repo_name,
            "private": private,
            "auto_init": False,
            "description": "Standalone BLE car key (TrollStore / iOS 16)",
        })
        print("[+] 已创建%s仓库: %s" % ("私有" if private else "公开", info["full_name"]))
        return info["full_name"]
    except GHError as e:
        raise SystemExit(
            "ERROR: 创建仓库失败（HTTP %s）。token 需要 repo（classic）或 "
            "Administration:write（fine-grained）权限；也可先用网页建好仓库再用 --repo OWNER/REPO 指定。\n%s"
            % (e.status, e))


def get_base(gh: GH, repo: str):
    info, _, _ = gh.req("GET", "/repos/" + repo)
    branch = info.get("default_branch") or "main"
    try:
        ref, _, _ = gh.req("GET", "/repos/%s/git/ref/heads/%s" % (repo, branch))
        base_sha = ref["object"]["sha"]
        commit, _, _ = gh.req("GET", "/repos/%s/git/commits/%s" % (repo, base_sha))
        return branch, base_sha, commit["tree"]["sha"]
    except GHError as e:
        # 404=分支不存在；409 "Git Repository is empty"=auto_init:false 的新仓库
        if e.status in (404, 409):
            return branch, None, None
        raise


def do_push(gh: GH, repo: str, include_ipa: bool) -> str:
    files = repo_files(include_ipa)
    if not files:
        raise SystemExit("ERROR: 没有可推送的文件")
    ipas = [r for r, _, _ in files if r.startswith("input/") and r.lower().endswith(".ipa")]
    print("[*] 待推送文件 %d 个%s" %
          (len(files), ("，含原包 ipa: %s" % ", ".join(ipas)) if ipas else "，未含原包 ipa"))

    branch, base_sha, base_tree = get_base(gh, repo)
    if base_sha is None:
        # auto_init:false 的全新仓库，Git Data API（blobs/trees/commits）一律 409
        # "Git Repository is empty"。Contents API 会自动创建初始 commit + 默认分支，
        # 先写第一个文件把仓库"点亮"，再继续走单 commit 的 Git Data API。
        rel0, path0, _mode0 = files[0]
        print("[*] 空仓库，用 Contents API 初始化（首文件 %s）" % rel0)
        gh.req("PUT", "/repos/%s/contents/%s" % (repo, rel0), {
            "message": "BleKey: initialize repository",
            "content": base64.b64encode(path0.read_bytes()).decode("ascii"),
        })
        branch, base_sha, base_tree = get_base(gh, repo)
        if base_sha is None:
            raise SystemExit("ERROR: 仓库初始化后仍读不到默认分支 commit")
    tree_entries = []
    for i, (rel, path, mode) in enumerate(files, 1):
        content = path.read_bytes()
        blob, _, _ = gh.req("POST", "/repos/%s/git/blobs" % repo, {
            "content": base64.b64encode(content).decode("ascii"),
            "encoding": "base64",
        })
        tree_entries.append({"path": rel, "mode": mode, "type": "blob", "sha": blob["sha"]})
        if i % 10 == 0 or i == len(files):
            print("    blob %d/%d" % (i, len(files)))

    tree_body = {"tree": tree_entries}
    if base_tree:
        tree_body["base_tree"] = base_tree
    tree, _, _ = gh.req("POST", "/repos/%s/git/trees" % repo, tree_body)
    commit, _, _ = gh.req("POST", "/repos/%s/git/commits" % repo, {
        "message": "BleKey: standalone BLE car key + TrollStore build",
        "tree": tree["sha"],
        "parents": [base_sha] if base_sha else [],
    })
    if base_sha:
        gh.req("PATCH", "/repos/%s/git/refs/heads/%s" % (repo, branch),
               {"sha": commit["sha"], "force": True})
    else:
        gh.req("POST", "/repos/%s/git/refs" % repo,
               {"ref": "refs/heads/" + branch, "sha": commit["sha"]})
    print("[+] 已推送 commit %s -> %s@%s" % (commit["sha"][:12], repo, branch))
    return branch


# ---------------------------------------------------------------- dispatch / watch
def do_dispatch(gh: GH, repo: str, branch: str, ipa_url: str, skip_extract: bool) -> int | None:
    inputs = {"skip_extract": "true" if skip_extract else "false", "ipa_url": ipa_url or ""}
    try:
        gh.req("POST", "/repos/%s/actions/workflows/%s/dispatches" % (repo, WORKFLOW),
               {"ref": branch, "inputs": inputs})
        print("[+] workflow_dispatch 已触发 (ipa_url=%s, skip_extract=%s)" %
              (ipa_url or "<仓库内 input/>", skip_extract))
    except GHError as e:
        print("[!] dispatch 返回 HTTP %s（新仓库 workflow 尚未索引时会这样），改用 push 自动触发的 run" % e.status)

    # 找到最近的 run：优先 dispatch，其次 push
    for _ in range(12):
        runs, _, _ = gh.req("GET", "/repos/%s/actions/runs?per_page=10" % repo)
        items = runs.get("workflow_runs", [])
        if items:
            rid = items[0]["id"]
            print("[+] run id=%s  event=%s  status=%s" %
                  (rid, items[0]["event"], items[0]["status"]))
            return rid
        time.sleep(5)
    print("[!] 暂未查到 run，可用 --run-id 手动指定")
    return None


def do_watch(gh: GH, repo: str, run_id: int, timeout_min: int = 50) -> bool:
    deadline = time.time() + timeout_min * 60
    last = ""
    while time.time() < deadline:
        run, _, _ = gh.req("GET", "/repos/%s/actions/runs/%d" % (repo, run_id))
        status, conclusion = run.get("status"), run.get("conclusion")
        tag = "%s/%s" % (status, conclusion)
        if tag != last:
            print("    run %s: %s  (%s)" % (run_id, tag, run.get("html_url", "")))
            last = tag
        if status == "completed":
            ok = (conclusion == "success")
            print("[+] 编译%s: conclusion=%s" % ("成功" if ok else "失败", conclusion))
            if not ok:
                dump_failed_logs(gh, repo, run_id)
            return ok
        time.sleep(15)
    print("[!] 等待超时 %d 分钟，run 可能仍在排队" % timeout_min)
    return False


def dump_failed_logs(gh: GH, repo: str, run_id: int):
    """失败时把 job 日志尾部打出来，避免只看到红叉不知道哪一步炸了。"""
    try:
        jobs, _, _ = gh.req("GET", "/repos/%s/actions/runs/%d/jobs?per_page=20" % (repo, run_id))
        for job in jobs.get("jobs", []):
            if job.get("conclusion") in (None, "success", "skipped"):
                continue
            print("---- 失败 job: %s ----" % job["name"])
            try:
                raw, _, _ = gh.req("GET", "/repos/%s/actions/jobs/%d/logs" % (repo, job["id"]),
                                   raw=True, accept="application/vnd.github+json")
                text = raw.decode("utf-8", "replace")
                print("\n".join(text.splitlines()[-60:]))
            except Exception as e:
                print("    日志拉取失败: %s" % e)
    except Exception as e:
        print("    jobs 拉取失败: %s" % e)


# ---------------------------------------------------------------- fetch
def write_ipa(data: bytes, source: str) -> Path:
    out = ROOT / "output"
    out.mkdir(exist_ok=True)
    dst = out / "BleKey-TrollStore.ipa"
    dst.write_bytes(data)
    # 校验 ipa 结构，防把 zip / 错误响应当成成品
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            names = z.namelist()
            exe = [n for n in names if n.startswith("Payload/") and n.endswith(".app/BleKey")]
            cfg = [n for n in names if n.endswith(".app/BridgeConfig.json")]
            print("[+] ipa 结构: %d 个条目, 可执行文件=%s, 配置=%s" %
                  (len(names), bool(exe), bool(cfg)))
            if not exe:
                print("[!] 警告: ipa 里没找到 Payload/*.app/BleKey")
    except zipfile.BadZipFile:
        print("[!] 警告: 下载内容不是合法 zip/ipa")
    print("[+] 来源     : %s" % source)
    print("[+] 落地     : %s" % dst)
    print("[+] 大小     : %d bytes" % len(data))
    print("[+] sha256   : %s" % hashlib.sha256(data).hexdigest())
    return dst


def do_fetch(gh: GH, repo: str, run_id: int | None) -> Path:
    # 主通道：Actions artifact
    if run_id:
        try:
            arts, _, _ = gh.req("GET", "/repos/%s/actions/runs/%d/artifacts" % (repo, run_id))
            for a in arts.get("artifacts", []):
                if a["name"] != ARTIFACT_NAME or a.get("expired"):
                    continue
                print("[*] 下载 artifact %s (id=%s, %d bytes)" %
                      (a["name"], a["id"], a.get("size_in_bytes", 0)))
                raw, _, hdrs = gh.req("GET", "/repos/%s/actions/artifacts/%d/zip" % (repo, a["id"]),
                                      raw=True, accept="application/vnd.github+json", timeout=180)
                with zipfile.ZipFile(io.BytesIO(raw)) as z:
                    for n in z.namelist():
                        if n.lower().endswith(".ipa"):
                            return write_ipa(z.read(n), "Actions artifact/" + n)
                print("[!] artifact zip 里没有 .ipa")
        except Exception as e:
            print("[!] artifact 通道失败: %s，回退 b64 镜像" % e)

    # 备通道：workflow 写回仓库的 base64 文件（只走 api.github.com，无重定向）
    try:
        obj, _, _ = gh.req("GET", "/repos/%s/contents/%s" % (repo, MIRROR_PATH))
        if isinstance(obj, dict) and obj.get("encoding") == "base64":
            data = base64.b64decode("".join(obj["content"].split()))
            return write_ipa(data, "repo contents/" + MIRROR_PATH)
    except GHError as e:
        print("[!] b64 镜像读取失败: HTTP %s" % e.status)
    raise SystemExit("ERROR: 两条下载通道都没拿到 ipa。先看上面 run 日志定位编译失败原因。")


# ---------------------------------------------------------------- CLI
def main() -> int:
    ap = argparse.ArgumentParser(description="只走 api.github.com 的远程编译编排器")
    ap.add_argument("action", choices=["push", "dispatch", "watch", "fetch", "all"])
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPO", ""), help="OWNER/REPO")
    ap.add_argument("--repo-name", default=os.environ.get("REPO_NAME", "BleKey"))
    ap.add_argument("--public", action="store_true", help="建公开仓库（macOS runner 不耗私有额度）")
    ap.add_argument("--ipa-url", default=os.environ.get("IPA_URL", ""))
    ap.add_argument("--no-ipa", action="store_true", help="不上传 input/ 下的原包 ipa")
    ap.add_argument("--skip-extract", action="store_true",
                    help="跳过抽取，直接用仓库内 Generated/BridgeConfig.json")
    ap.add_argument("--run-id", type=int, default=0)
    ap.add_argument("--wait-seconds", type=int, default=8)
    ap.add_argument("--timeout-min", type=int, default=50)
    args = ap.parse_args()

    gh = GH(os.environ.get("GITHUB_TOKEN", ""))
    repo = ensure_repo(gh, args.repo or None, args.repo_name, not args.public)
    branch = "main"

    if args.action == "push":
        do_push(gh, repo, not args.no_ipa)
        return 0
    if args.action == "dispatch":
        do_dispatch(gh, repo, branch, args.ipa_url, args.skip_extract)
        return 0

    run_id = args.run_id or None
    if args.action == "all":
        print("==> [1/4] 推送仓库")
        branch = do_push(gh, repo, not args.no_ipa)
        print("==> [2/4] 触发编译（等 %ds 让 workflow 被索引）" % args.wait_seconds)
        time.sleep(args.wait_seconds)
        run_id = do_dispatch(gh, repo, branch, args.ipa_url, args.skip_extract)
        print("==> [3/4] 等待 macOS runner")
        if run_id is None:
            print("[!] 没有 run id，请稍后用 --action watch --run-id <id> 继续")
            return 2
        ok = do_watch(gh, repo, run_id, args.timeout_min)
        if not ok:
            print("[!] 编译未成功，仍尝试下载已有产物")
        print("==> [4/4] 取回 ipa")
        do_fetch(gh, repo, run_id)
        return 0 if ok else 1
    if args.action == "watch":
        if not run_id:
            raise SystemExit("ERROR: watch 需要 --run-id")
        return 0 if do_watch(gh, repo, run_id, args.timeout_min) else 1
    if args.action == "fetch":
        do_fetch(gh, repo, run_id)
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
