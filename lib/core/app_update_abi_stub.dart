/// Lets the shared UI compile on Web, where native installation is unavailable.
/// Native builds import dart:ffi instead and keep its actual process ABI checks.
enum Abi {
  androidArm64,
  androidX64,
  windowsX64,
  linuxX64;

  static Abi current() => throw UnsupportedError('Native ABI is unavailable');
}
