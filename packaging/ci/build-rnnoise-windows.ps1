# Builds a static rnnoise.lib with MSVC for the Windows client build.
# rnnoise has no vcpkg Windows port (the port is marked !windows), so we
# compile the xiph v0.2 library sources plus the downloaded model directly.
# /MT matches Odin's static-CRT linking (same as vendor/miniaudio/build.bat).
# Must run inside an MSVC dev environment (cl.exe / lib.exe on PATH).
# Usage: build-rnnoise-windows.ps1 <out-dir>
param([Parameter(Mandatory = $true)][string]$OutDir)
$ErrorActionPreference = "Stop"

$work = Join-Path $env:RUNNER_TEMP "rnnoise-build"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force -Path $work | Out-Null
Set-Location $work

# Source tarball for the tag the Linux/macOS CI also pins.
Invoke-WebRequest -Uri "https://github.com/xiph/rnnoise/archive/refs/tags/v0.2.tar.gz" -OutFile "rnnoise.tar.gz"
tar xf rnnoise.tar.gz
Set-Location "rnnoise-0.2"

# The 0.2 tag ships no model weights — autogen.sh normally downloads them.
# Mirror download_model.sh: fetch the pinned model and extract into src/.
$modelVersion = (Get-Content "model_version" -Raw).Trim()
$model = "rnnoise_data-$modelVersion.tar.gz"
Invoke-WebRequest -Uri "https://media.xiph.org/rnnoise/models/$model" -OutFile $model
tar xf $model

# Library sources only (scalar path; no x86 RTCD, so no CPU dispatch/map
# files needed). Excludes the demo/dump programs that carry their own main().
$sources = @(
    "src/denoise.c", "src/rnn.c", "src/pitch.c", "src/kiss_fft.c",
    "src/celt_lpc.c", "src/nnet.c", "src/nnet_default.c",
    "src/parse_lpcnet_weights.c", "src/rnnoise_data.c", "src/rnnoise_tables.c"
)
& cl /nologo /MT /O2 /I include /I src /c @sources
if ($LASTEXITCODE -ne 0) { throw "cl compile failed ($LASTEXITCODE)" }

$objs = $sources | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) + ".obj" }
& lib /nologo /out:rnnoise.lib @objs
if ($LASTEXITCODE -ne 0) { throw "lib failed ($LASTEXITCODE)" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Copy-Item "rnnoise.lib" (Join-Path $OutDir "rnnoise.lib") -Force
Write-Host "rnnoise.lib -> $OutDir"
