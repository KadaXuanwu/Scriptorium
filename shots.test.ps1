# Checks Get-SmallShot in shots.ps1: powershell -NoProfile -File shots.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'
# shots.ps1 uploads when run, so only its function is loaded.
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'shots.ps1'), [ref]$null, [ref]$null)
. ([scriptblock]::Create($ast.Find({ $args[0].Name -eq 'Get-SmallShot' }, $true).Extent.Text))
$canShrink = $env:OS -eq 'Windows_NT'
if (-not $canShrink) {
    # System.Drawing draws on Windows only: elsewhere the original goes up.
    if ((Get-SmallShot 'shots/banner.png' 'out') -ne 'shots/banner.png') {
        throw 'off Windows the original goes up'
    }
    'ok'
    exit 0
}
Add-Type -AssemblyName System.Drawing

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

function New-Picture([string] $path, [int] $width, [int] $height, [System.Drawing.Imaging.PixelFormat] $format, [System.Drawing.Color] $color) {
    $bitmap = New-Object System.Drawing.Bitmap $width, $height, $format
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear($color)
    # Noise, so the PNG is big like a game screenshot.
    $random = New-Object Random 1
    for ($i = 0; $i -lt 2000; $i++) {
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($color.A, $random.Next(256), $random.Next(256), $random.Next(256)))
        $graphics.FillEllipse($brush, $random.Next($width), $random.Next($height), 40, 40)
        $brush.Dispose()
    }
    $graphics.Dispose()
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

function Get-Size([string] $path) {
    $image = [System.Drawing.Image]::FromFile($path)
    try { "$($image.Width)x$($image.Height)" } finally { $image.Dispose() }
}

$dir = Join-Path ([System.IO.Path]::GetTempPath()) "shots-test-$PID"
$out = Join-Path $dir 'out'
New-Item -ItemType Directory -Force $out | Out-Null
try {
    $argb = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    # A 4K screenshot (opaque, though its format has alpha): the banner fits 1280, a choice 1600, both as JPEG.
    New-Picture "$dir\banner.png" 3840 2160 $argb ([System.Drawing.Color]::DarkSlateBlue)
    Copy-Item "$dir\banner.png" "$dir\header-a.png"
    $banner = Get-SmallShot "$dir\banner.png" $out
    Assert-Equal (Split-Path $banner -Leaf) 'banner.jpg' 'banner becomes a JPEG'
    Assert-Equal (Get-Size $banner) '1280x720' 'banner fits 1280'
    if ((Get-Item $banner).Length -ge (Get-Item "$dir\banner.png").Length) { throw 'banner is not smaller' }
    $choice = Get-SmallShot "$dir\header-a.png" $out
    Assert-Equal "$(Split-Path $choice -Leaf) $(Get-Size $choice)" 'header-a.jpg 1600x900' 'choice fits 1600'
    # A portrait picture fits by its long side.
    New-Picture "$dir\phone.png" 1080 2400 $argb ([System.Drawing.Color]::White)
    Assert-Equal (Get-Size (Get-SmallShot "$dir\phone.png" $out)) '720x1600' 'portrait fits by height'
    # See-through parts keep a PNG.
    New-Picture "$dir\icon-a.png" 2048 2048 $argb ([System.Drawing.Color]::Transparent)
    $icon = Get-SmallShot "$dir\icon-a.png" $out
    Assert-Equal "$(Split-Path $icon -Leaf) $(Get-Size $icon)" 'icon-a.png 1600x1600' 'see-through stays PNG'
    # A small picture that a copy only makes bigger goes up as it is.
    $tiny = New-Object System.Drawing.Bitmap 4, 4
    $tiny.Save("$dir\dot.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $tiny.Dispose()
    Assert-Equal (Get-SmallShot "$dir\dot.png" $out) "$dir\dot.png" 'small original kept'
} finally {
    Remove-Item -Recurse $dir -ErrorAction SilentlyContinue
}
'ok'
