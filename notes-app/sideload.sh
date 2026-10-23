APK_DIR=build/app/outputs/flutter-apk
APK=app-release.apk
PORT=${PORT:-8080}

if [ ! -f "$APK_DIR/$APK" ]; then
  echo "$APK_DIR/$APK not found, run ./android_release.sh first"
  exit 1
fi

for ip in $(hostname -I); do
  echo "http://$ip:$PORT/$APK"
done
python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$APK_DIR"
