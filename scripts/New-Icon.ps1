# Deterministic icon generation using Windows' drawing library, no image service.
[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $PSScriptRoot '..\assets'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$images = @()
foreach ($size in @(16, 24, 32, 48, 64, 128, 256)) {
    $bitmap = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = 'AntiAlias'
    $g.ScaleTransform($size / 256.0, $size / 256.0)
    $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#132b3a'))
    $white = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml('#f4f8fc')), 12
    $gold = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml('#ffbf55')), 9
    $sun = New-Object System.Drawing.SolidBrush $gold.Color
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    try {
        foreach ($arc in @(@(12,12,104,104,180), @(140,12,104,104,270), @(140,140,104,104,0), @(12,140,104,104,90))) {
            $path.AddArc($arc[0],$arc[1],$arc[2],$arc[3],$arc[4],90)
        }
        $path.CloseFigure()
        $g.FillPath($bg, $path)
        $white.StartCap = $white.EndCap = 'Round'
        $gold.StartCap = $gold.EndCap = 'Round'
        $g.DrawRectangle($white, 46, 62, 164, 112)
        $g.DrawLine($white, 128, 180, 128, 200)
        $g.DrawLine($white, 100, 200, 156, 200)
        $g.FillEllipse($sun, 108, 98, 40, 40)
        foreach ($line in @(@(128,82,128,76),@(128,160,128,154),@(164,118,170,118),@(86,118,92,118),@(153,93,158,88),@(98,148,103,143),@(153,143,158,148),@(98,88,103,93))) {
            $g.DrawLine($gold,$line[0],$line[1],$line[2],$line[3])
        }
        if ($size -eq 256) { $bitmap.Save((Join-Path $OutputDirectory 'trayluma.png'), [System.Drawing.Imaging.ImageFormat]::Png) }
        $stream = New-Object System.IO.MemoryStream
        try {
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            $images += ,$stream.ToArray()
        } finally { $stream.Dispose() }
    } finally {
        $path.Dispose(); $sun.Dispose(); $gold.Dispose(); $white.Dispose(); $bg.Dispose(); $g.Dispose(); $bitmap.Dispose()
    }
}
$file = [System.IO.File]::Create((Join-Path $OutputDirectory 'trayluma.ico'))
$writer = New-Object System.IO.BinaryWriter $file
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$images.Count)
    $offset = 6 + 16 * $images.Count
    $sizes = @(16,24,32,48,64,128,256)
    for ($i = 0; $i -lt $images.Count; $i++) {
        $dimension = if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$images[$i].Length); $writer.Write([uint32]$offset)
        $offset += $images[$i].Length
    }
    foreach ($image in $images) { $writer.Write([byte[]]$image) }
} finally { $writer.Dispose(); $file.Dispose() }
Get-Item (Join-Path $OutputDirectory 'trayluma.ico') | Select-Object FullName,Length
