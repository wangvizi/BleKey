#!/bin/bash
# 在 macOS 上编译出 TrollStore（巨魔）可直接安装的 ipa。
# 免开发者账号：xcodebuild 关闭签名 -> 注入配置/framework -> ldid 伪签 -> Payload 打包。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/output}"
SDK="${SDK:-iphoneos}"
APP_NAME="BleKey"
ENTITLEMENTS="$ROOT/App/BleKey.entitlements"

echo "==> [1/7] 环境检查"
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: 编译 iOS app 需要 macOS + Xcode；当前是 $(uname -s)。请用 GitHub Actions 的 macos runner。" >&2
  exit 3
fi
command -v xcodebuild >/dev/null || { echo "ERROR: 缺少 Xcode" >&2; exit 3; }
echo "    Xcode: $(xcodebuild -version | head -1)"

if ! command -v xcodegen >/dev/null; then
  echo "    xcodegen 未安装，执行 brew install xcodegen"
  brew install xcodegen
fi

HAS_LDID=0
if command -v ldid >/dev/null; then
  HAS_LDID=1
else
  echo "    ldid 未安装，尝试 brew install ldid（失败则回退 codesign ad-hoc）"
  if brew install ldid 2>/dev/null; then HAS_LDID=1; fi
fi
echo "    ldid: $HAS_LDID"

echo "==> [2/7] 生成 Xcode 工程"
xcodegen generate --spec "$ROOT/project.yml"

echo "==> [3/7] 编译（iOS 16.0 / arm64 / 免签名）"
DERIVED="$ROOT/.build"
xcodebuild \
  -project "$ROOT/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -sdk "$SDK" \
  -derivedDataPath "$DERIVED" \
  IPHONEOS_DEPLOYMENT_TARGET=16.0 \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  clean build

APP="$DERIVED/Build/Products/$CONFIGURATION-$SDK/$APP_NAME.app"
if [ ! -d "$APP" ]; then
  echo "ERROR: 未找到编译产物 $APP" >&2
  find "$DERIVED/Build/Products" -maxdepth 3 -name "*.app" -print >&2 || true
  exit 4
fi
echo "    .app: $APP"

echo "==> [4/7] 注入配置文件与原包 framework"
cp "$ROOT/Generated/BridgeConfig.json" "$APP/BridgeConfig.json"
if [ -d "$ROOT/Generated/Vendor/Frameworks" ]; then
  mkdir -p "$APP/Frameworks"
  # -R 保留 framework 内部符号链接，dlopen 依赖这些链接
  cp -R "$ROOT/Generated/Vendor/Frameworks/." "$APP/Frameworks/"
  echo "    frameworks: $(find "$APP/Frameworks" -maxdepth 1 -name '*.framework' | wc -l | tr -d ' ')"
fi
# 清掉 Xcode 可能带进来的签名材料，交给下一步统一伪签
rm -rf "$APP/_CodeSignature" "$APP/embedded.mobileprovision" "$APP/ProvisioningProfile"

echo "==> [5/7] 伪签名（TrollStore / CoreTrust）"
if [ "$HAS_LDID" = "1" ]; then
  # ldid 签的是 Mach-O 文件本体，不是 .app 目录；目录交给 codesign 分支。
  ldid -S"$ENTITLEMENTS" "$APP/$APP_NAME"
  # 注入的原包动态 framework 也要伪签，否则 TrollStore 装完 dlopen 会失败
  if [ -d "$APP/Frameworks" ]; then
    for fw in "$APP"/Frameworks/*.framework; do
      [ -d "$fw" ] || continue
      fwbin="$fw/$(basename "${fw%.framework}")"
      [ -f "$fwbin" ] && ldid -S "$fwbin" || true
    done
  fi
  echo "    ldid -S 完成，entitlements:"
  ldid -e "$APP/$APP_NAME" | sed 's/^/      /' || true
else
  echo "    回退 codesign ad-hoc"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
  codesign -d --entitlements - "$APP" 2>/dev/null | sed 's/^/      /' || true
fi

echo "==> [6/7] 验证"
[ -f "$APP/$APP_NAME" ] || { echo "ERROR: .app 里缺少可执行文件" >&2; exit 5; }
[ -f "$APP/BridgeConfig.json" ] || { echo "ERROR: .app 里缺少 BridgeConfig.json" >&2; exit 5; }
/usr/bin/plutil -lint "$APP/Info.plist" >/dev/null || { echo "ERROR: Info.plist 非法" >&2; exit 5; }
file "$APP/$APP_NAME" | sed 's/^/    /'
echo "    minimumOS: $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP/Info.plist" 2>/dev/null || echo '由 LC_BUILD_VERSION / 编译设置决定')"

echo "==> [7/7] 打 ipa"
rm -rf "$OUTPUT_DIR/Payload" "$OUTPUT_DIR/$APP_NAME-TrollStore.ipa"
mkdir -p "$OUTPUT_DIR/Payload"
cp -R "$APP" "$OUTPUT_DIR/Payload/"
(cd "$OUTPUT_DIR" && zip -qry "$APP_NAME-TrollStore.ipa" Payload)

IPA="$OUTPUT_DIR/$APP_NAME-TrollStore.ipa"
echo "==> 完成"
echo "    ipa    : $IPA"
echo "    大小   : $(stat -f%z "$IPA") bytes"
echo "    sha256 : $(shasum -a 256 "$IPA" | awk '{print $1}')"
echo "    安装   : 用 TrollStore 打开该 ipa（iOS 16.0-16.6.1 / 16.7.x 需确认 CoreTrust 漏洞覆盖范围）"
