# Pictures for a question to the owner (PLAYBOOK-pictures.md): puts PNG or JPEG files on the branch
# shots-t<ticket>, never on the ticket's branch or main, and prints a markdown line for each, to paste into the question.
# GitHub and the queue app show them. Run in the worker's clone, with the path of the Scriptorium folder:
#   powershell -NoProfile -File <Scriptorium>/shots.ps1 -Ticket 12 shots/header-a.png shots/header-b.png
# Each goes up as a small copy (Get-SmallShot), often a .jpg for a .png. A file with the name of one already there
# replaces it. Plumbing with a temporary index, so the clone's checkout, index
# and branch stay as they are.
param(
    [Parameter(Mandatory)] [int] $Ticket,
    [Parameter(Mandatory, ValueFromRemainingArguments)] [string[]] $Files
)
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    $out = & git @args
    if ($LASTEXITCODE) {
        throw "git $($args -join ' ') failed"
    }
    return $out
}

# shortcut: System.Drawing draws on Windows only (.NET 7 and later), so macOS and Linux upload the originals; use sips or
# ImageMagick there if the page loads slowly.
$canShrink = $env:OS -eq 'Windows_NT'
if ($canShrink) {
    Add-Type -AssemblyName System.Drawing
}

# A small copy of the picture in $dir, so the page loads it fast: its long side at most 1280 px for the banner (a strip
# on the page) and 1600 px for the others (whole in the viewer), and a JPEG unless it has see-through parts. The
# original when the copy would only be bigger.
function Get-SmallShot([string] $path, [string] $dir) {
    if (-not $canShrink) {
        return $path
    }
    $name = Split-Path $path -Leaf
    $max = if ($name -like 'banner*') { 1280 } else { 1600 }
    $resize = {
        param($from, [int] $width, [int] $height)
        $to = New-Object System.Drawing.Bitmap $width, $height
        $graphics = [System.Drawing.Graphics]::FromImage($to)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        # Without it GDI+ fades the edges to see-through.
        $wrap = New-Object System.Drawing.Imaging.ImageAttributes
        $wrap.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
        $graphics.DrawImage($from, (New-Object System.Drawing.Rectangle 0, 0, $width, $height), 0, 0, $from.Width, $from.Height, [System.Drawing.GraphicsUnit]::Pixel, $wrap)
        $wrap.Dispose()
        $graphics.Dispose()
        $to
    }
    $image = [System.Drawing.Image]::FromFile($path)
    try {
        $scale = [Math]::Min(1.0, $max / [Math]::Max($image.Width, $image.Height))
        $small = & $resize $image ([Math]::Max(1, [int]($image.Width * $scale))) ([Math]::Max(1, [int]($image.Height * $scale)))
        $alpha = [System.Drawing.Image]::IsAlphaPixelFormat($image.PixelFormat)
    } finally {
        $image.Dispose()
    }
    try {
        $opaque = $true
        if ($alpha) {
            # shortcut: tests a 64x64 copy (GetPixel on every pixel is slow here), so a see-through speck may turn black.
            $thumb = & $resize $small 64 64
            for ($i = 0; $i -lt 4096 -and $opaque; $i++) {
                $opaque = $thumb.GetPixel($i % 64, [Math]::Floor($i / 64)).A -eq 255
            }
            $thumb.Dispose()
        }
        $base = Join-Path $dir ([System.IO.Path]::GetFileNameWithoutExtension($name))
        if ($opaque) {
            $out = "$base.jpg"
            $jpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
            $quality = New-Object System.Drawing.Imaging.EncoderParameters 1
            $quality.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]85)
            $small.Save($out, $jpeg, $quality)
        } else {
            $out = "$base.png"
            $small.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
        }
    } finally {
        $small.Dispose()
    }
    if ($scale -eq 1 -and (Get-Item $out).Length -ge (Get-Item $path).Length) {
        return $path
    }
    return $out
}

$branch = "shots-t$Ticket"
$small = Join-Path ([System.IO.Path]::GetTempPath()) "shots-$Ticket-$PID"
New-Item -ItemType Directory -Force $small | Out-Null
$paths = foreach ($file in $Files) {
    $path = (Resolve-Path $file).Path
    $name = Split-Path $path -Leaf
    # The queue app serves only these names (app/server.ps1, /api/shot).
    if ($name -notmatch '^[\w.-]+\.(png|jpe?g)$') {
        throw "$name`: use a PNG or JPEG named with letters, digits, '.', '-' and '_' only"
    }
    Get-SmallShot $path $small
}
# The clone the run works in: the current folder's repo, never the Scriptorium folder.
Set-Location (Invoke-Git rev-parse --show-toplevel)
$slug = & gh repo view --json nameWithOwner -q .nameWithOwner
$index = Join-Path ([System.IO.Path]::GetTempPath()) "shots-$Ticket-$PID.index"
$oldIndex = $env:GIT_INDEX_FILE
$env:GIT_INDEX_FILE = $index
try {
    # No such branch yet is no fault. Windows PowerShell turns a program's error text into a stop when it is redirected.
    $ErrorActionPreference = 'Continue'
    & git fetch -q origin "+refs/heads/${branch}:refs/remotes/origin/$branch" 2>$null
    $fetched = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    $parent = @()
    if ($fetched) {
        Invoke-Git read-tree "origin/$branch" | Out-Null
        $parent = @('-p', "origin/$branch")
    }
    foreach ($path in $paths) {
        # The picture itself, not a Git LFS pointer: .gitattributes may put PNG and JPEG in LFS, which GitHub's API
        # and its pages then show as the pointer's text.
        $blob = Invoke-Git hash-object -w --no-filters -- $path
        Invoke-Git update-index --add --cacheinfo "100644,$blob,$(Split-Path $path -Leaf)" | Out-Null
    }
    $tree = Invoke-Git write-tree
    $commit = Invoke-Git commit-tree $tree @parent -m "Pictures for #$Ticket"
    Invoke-Git push -q origin "${commit}:refs/heads/$branch" | Out-Null
} finally {
    $env:GIT_INDEX_FILE = $oldIndex
    Remove-Item $index -ErrorAction SilentlyContinue
    Remove-Item -Recurse $small -ErrorAction SilentlyContinue
}
foreach ($path in $paths) {
    $name = Split-Path $path -Leaf
    "![$([System.IO.Path]::GetFileNameWithoutExtension($name))](https://github.com/$slug/blob/$branch/${name}?raw=true)"
}
