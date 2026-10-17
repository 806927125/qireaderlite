#!/bin/bash
# 本地出免签 IPA。用法：./scripts/build-ipa.sh
# 需要 macOS + Xcode 16 以上
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname)" != "Darwin" ]]; then
  echo "❌ 只能在 macOS 上编译（.ipa 本质是 Xcode 归档 + 签名的产物）"
  echo "   实在没有 Mac：把仓库推到 GitHub 后跑 Actions，产物在 Artifacts 里。"
  exit 1
fi

SCHEME="QiReaderLite"
APP_NAME="QingYue"

echo "▶ Xcode: $(xcodebuild -version | head -1)"

echo "▶ 编译 Release…"
xcodebuild \
  -project QiReaderLite.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/dd \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_BITCODE=NO \
  build | tail -20

APP="build/dd/Build/Products/Release-iphoneos/${APP_NAME}.app"
if [[ ! -d "$APP" ]]; then
  echo "❌ 没找到 $APP"
  exit 1
fi

echo "▶ 组装 IPA…"
rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/

# 免签包里塞一份空描述文件，装的时候才不会因为缺 embedded.mobileprovision 报错
printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' \
  > "build/ipa/Payload/${APP_NAME}.app/embedded.mobileprovision"

OUT="build/${APP_NAME}-$(date +%Y%m%d).ipa"
(cd build/ipa && zip -qry "../$(basename "$OUT")" Payload)

echo ""
echo "✅ 产物: $OUT"
echo ""
echo "装到自己手机上（需要 AltStore / Sideloadly / 爱思 / 巨魔 之类的工具）："
echo "  1. 先用自己的 Apple ID 在 Xcode 里跑一次，把 App 装到手机上"
echo "  2. 之后每 7 天重签一次；或直接用免费账号重签工具"
echo "  3. 改 bundle id 再签，可以和你手机上的其它 App 共存"
