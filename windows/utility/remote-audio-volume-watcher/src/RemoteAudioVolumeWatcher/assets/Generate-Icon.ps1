[CmdletBinding()]
param(
    [string] $OutputPath = (Join-Path $PSScriptRoot 'remote-audio.ico'),
    [string] $PreviewPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

[xml] $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'headphones-sound-wave.svg') -Raw
$sourceGeometry = [Windows.Media.Geometry]::Parse($source.svg.path.d)
$iconSizes = 16, 20, 24, 32, 48
$images = [Collections.Generic.List[byte[]]]::new()

foreach ($size in $iconSizes) {
    $visual = [Windows.Media.DrawingVisual]::new()
    $drawing = $visual.RenderOpen()
    $drawing.PushTransform([Windows.Media.ScaleTransform]::new($size / 32, $size / 32))
    $drawing.DrawEllipse(
        [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(0, 120, 212)),
        [Windows.Media.Pen]::new(
            [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(0, 76, 134)),
            1),
        [Windows.Point]::new(16, 16),
        15,
        15)

    $iconGeometry = $sourceGeometry.Clone()
    $transforms = [Windows.Media.TransformGroup]::new()
    $transforms.Children.Add([Windows.Media.ScaleTransform]::new(0.76, 0.76))
    $transforms.Children.Add([Windows.Media.TranslateTransform]::new(4.2, 3.4))
    $iconGeometry.Transform = $transforms

    $drawing.DrawGeometry(
        [Windows.Media.Brushes]::White,
        $null,
        $iconGeometry)
    $drawing.Pop()
    $drawing.Close()

    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
        $size,
        $size,
        96,
        96,
        [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)

    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.MemoryStream]::new()

    try {
        $encoder.Save($stream)
        $images.Add($stream.ToArray())
    }
    finally {
        $stream.Dispose()
    }
}

$outputDirectory = Split-Path -Parent $OutputPath

if ($outputDirectory) {
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}

$file = [IO.File]::Create($OutputPath)
$writer = [IO.BinaryWriter]::new($file)

try {
    $writer.Write([uint16] 0)
    $writer.Write([uint16] 1)
    $writer.Write([uint16] $iconSizes.Count)

    $offset = 6 + (16 * $iconSizes.Count)

    for ($index = 0; $index -lt $iconSizes.Count; $index++) {
        $size = $iconSizes[$index]
        $image = $images[$index]

        $writer.Write([byte] $size)
        $writer.Write([byte] $size)
        $writer.Write([byte] 0)
        $writer.Write([byte] 0)
        $writer.Write([uint16] 1)
        $writer.Write([uint16] 32)
        $writer.Write([uint32] $image.Length)
        $writer.Write([uint32] $offset)
        $offset += $image.Length
    }

    foreach ($image in $images) {
        $writer.Write($image)
    }
}
finally {
    $writer.Dispose()
    $file.Dispose()
}

if ($PreviewPath) {
    [IO.File]::WriteAllBytes($PreviewPath, $images[$images.Count - 1])
}

Write-Host "Generated '$OutputPath'." -ForegroundColor Green
