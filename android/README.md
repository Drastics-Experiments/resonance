# Resonance for Android

The Android app requires Android Studio with the Android 16 (API 36) SDK and JDK 17.

## Build and test

From the repository root:

```bash
cd android
./gradlew lintDebug testDebugUnitTest assembleDebug
```

The debug APK is written to `android/app/build/outputs/apk/debug/app-debug.apk`.

## Install on a device or emulator

Enable USB debugging on a connected Android device, or start an Android Virtual Device in Android Studio, then run:

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n mov.unblocked.resonance/.MainActivity
```

To create an emulator, open **Tools > Device Manager** in Android Studio, create a phone using an API 36 system image, and press its Run button. The app can also be launched directly from Android Studio by opening the `android/` directory and selecting the `app` run configuration.

The debug APK is intended for development and emulator testing. It is not a signed production release.

## Direct-download updates

Production builds check the latest GitHub Release for `latest-android.json` when the app resumes, at most once every six hours. When a newer `versionCode` is available, Resonance downloads the APK, verifies its SHA-256 checksum, package ID, and signing certificate, then hands it to Android's system installer. Android may require the user to allow Resonance as an install source once and asks the user to confirm installation.

Tagged builds require a permanent release keystore. Configure these GitHub Actions secrets before publishing the first updater-compatible release:

- `RESONANCE_ANDROID_KEYSTORE_BASE64`
- `RESONANCE_ANDROID_KEYSTORE_PASSWORD`
- `RESONANCE_ANDROID_KEY_ALIAS`
- `RESONANCE_ANDROID_KEY_PASSWORD`

The tag must match `versionName`, and every update must increase `versionCode`. The Android workflow builds and verifies a signed release APK, then publishes the APK, its `.sha256` file, and `latest-android.json` to the GitHub Release.

Keep the release keystore backed up securely for the lifetime of the application. Existing debug APKs cannot normally be upgraded to the first production-signed APK because their signing certificates differ; those users need one final uninstall/reinstall before subsequent in-app updates work.
