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
