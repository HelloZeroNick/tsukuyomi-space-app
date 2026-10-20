"""Run the desktop probe and preserve the actual Flutter-composited screen."""
import pathlib
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
target = sys.argv[1]
output = pathlib.Path("artifacts/native-gpu", target).resolve()
output.mkdir(parents=True, exist_ok=True)
metrics = output / "metrics.json"
metrics.unlink(missing_ok=True)  # A stale successful run must not pass this one.


def capture():
    path = output / "flutter-composition.png"
    if target == "linux":
        command = ["scrot", str(path)]
    elif target == "windows":
        destination = str(path).replace("'", "''")
        command = ["powershell", "-NoProfile", "-Command", f"""
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {{
  $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
  $bitmap.Save('{destination}', [System.Drawing.Imaging.ImageFormat]::Png)
}} finally {{ $graphics.Dispose(); $bitmap.Dispose() }}
"""]
    else:
        return
    try:
        subprocess.run(command, check=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as error:
        # Some Windows service sessions have no capturable desktop. Keep the
        # render probe result, but make the missing composition evidence explicit.
        print(f"COMPOSITION_CAPTURE_UNAVAILABLE: {error}", flush=True)


command = [
    shutil.which("flutter") or "flutter", "run", "--no-pub", "-d", target,
    "-t", "tool/probe_native_gpu.dart",
    f"--dart-define=NATIVE_GPU_QA_DIR={output}",
]
passed = False
with (output / "probe.log").open("w", encoding="utf-8") as log:
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace", bufsize=1,
    )
    for line in process.stdout:
        print(line, end="", flush=True)
        log.write(line)
        if "TSUKUYOMI_GPU_CAPTURE_READY" in line:
            capture()
        passed |= "TSUKUYOMI_LIVE2D_GPU_OK" in line
    code = process.wait()
if code or not passed or not metrics.exists():
    if target == "linux" and shutil.which("gdb"):
        binary = pathlib.Path("build/linux/x64/debug/bundle/tsukuyomi_space_app").resolve()
        if binary.exists():
            with (output / "native-backtrace.log").open("w", encoding="utf-8") as log:
                try:
                    subprocess.run([
                        "gdb", "--batch", "-ex", "set env GDK_SYNCHRONIZE 1",
                        "-ex", "run", "-ex", "thread apply all bt",
                        "--args", str(binary),
                    ], stdout=log, stderr=subprocess.STDOUT, timeout=90)
                except subprocess.TimeoutExpired:
                    print("Native diagnostic run timed out", flush=True)
    raise SystemExit(f"Native {target} GPU probe failed (exit {code})")
