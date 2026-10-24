import 'dart:io';

/// Whether this build runs on HarmonyOS.
///
/// The check reads the operating system identifier instead of `Platform.isOhos`
/// or `TargetPlatform.ohos`: those members only exist in the HarmonyOS Flutter
/// fork, so referencing them would fail to compile for Android, iOS, Windows,
/// macOS and Linux. `Platform.operatingSystem` is part of `dart:io` on every
/// SDK and reports `ohos` on HarmonyOS devices.
bool get isOhosPlatform => Platform.operatingSystem == 'ohos';
