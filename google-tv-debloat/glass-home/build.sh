#!/usr/bin/env bash
# Builds GlassHome.apk without Gradle, using only the Android SDK tools.
#
#   ANDROID_HOME=/path/to/android-sdk ./build.sh
#
# Needs: a JDK (11+), and in the SDK: platforms;android-34 and build-tools;35.0.0
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
: "${ANDROID_HOME:?Set ANDROID_HOME to your Android SDK folder}"

VERSION_CODE=5
VERSION_NAME=1.4
MIN_SDK=26
TARGET_SDK=34

BT="$ANDROID_HOME/build-tools/35.0.0"
PLATFORM="$ANDROID_HOME/platforms/android-34/android.jar"
OUT="$HERE/build"
APK="$HERE/../GlassHome.apk"

# Fixed signing key so every build can update the one already on the TV.
# It only identifies this hobby app; it protects nothing.
KEYSTORE="$HERE/signing.keystore"
KEY_PASS=glasshome

rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/classes" "$OUT/dex"

"$BT/aapt2" compile --dir "$HERE/res" -o "$OUT/res.zip"
"$BT/aapt2" link -o "$OUT/unsigned.apk" -I "$PLATFORM" \
    --manifest "$HERE/AndroidManifest.xml" --java "$OUT/gen" \
    --min-sdk-version "$MIN_SDK" --target-sdk-version "$TARGET_SDK" \
    --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" \
    "$OUT/res.zip"

find "$HERE/src" "$OUT/gen" -name '*.java' > "$OUT/sources.txt"
javac -source 11 -target 11 -XDstringConcat=inline -Xlint:-options \
    -classpath "$PLATFORM" -d "$OUT/classes" @"$OUT/sources.txt"

find "$OUT/classes" -name '*.class' > "$OUT/classes.txt"
"$BT/d8" --release --min-api "$MIN_SDK" --lib "$PLATFORM" --output "$OUT/dex" @"$OUT/classes.txt"

(cd "$OUT/dex" && zip -q -j "$OUT/unsigned.apk" classes.dex)
"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

if [ ! -f "$KEYSTORE" ]; then
    keytool -genkeypair -keystore "$KEYSTORE" -storepass "$KEY_PASS" -keypass "$KEY_PASS" \
        -alias glasshome -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Glass Home" >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass "pass:$KEY_PASS" --key-pass "pass:$KEY_PASS" \
    --out "$APK" "$OUT/aligned.apk"
rm -f "$APK.idsig"
"$BT/apksigner" verify "$APK"

echo "Built $APK"
