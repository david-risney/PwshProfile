param(
    [string]$ImagePath,
    [int]$alphathreshold = 50,
    [int]$COLUMNS = 35,
    [switch] $ascii
)

function GifBitmapToAscii {
    param(
        $RawImage,
        [int]$alphathreshold,
        [int]$COLUMNS,
        [switch] $ascii
    );

    $e = [char]0x1B;

    # Divide scaled height by 2.2 to compensate for ASCII characters being taller than they are wide
    [int]$ROWS = $RawImage.Height / $RawImage.Width * $COLUMNS / $(if ($ascii) { 2.2 } else { 1 })
    $ScaledImage = New-Object System.Drawing.Bitmap @($RawImage, [Drawing.Size]"$COLUMNS,$ROWS")

    if ($ascii) {
        $chars = ' .,:;+iIH$@'
        for ($i = 0; $i -lt $ScaledImage.Height; $i++) {
          $currline = ""
          for ($j = 0; $j -lt $ScaledImage.Width; $j++) {
            $p = $ScaledImage.GetPixel($j, $i)
            $currline += "$e[38;2;$($p.R);$($p.G);$($p.B)m$($chars[[math]::Floor($p.GetBrightness() * $chars.Length)])$e[0m"
          }
          $currline
        }
    } else {
        for ($i = 0; $i -lt $ScaledImage.Height; $i += 2) {
            $currline = ""
            for ($j = 0; $j -lt $ScaledImage.Width; $j++) {
                $pixel1 = $ScaledImage.GetPixel($j, $i)
                $char = [char]0x2580
                if ($i -ge $ScaledImage.Height - 1) {
                    if ($pixel1.A -lt $alphathreshold) {
                        $char = [char]0x2800
                        $ansi = "$e[49m"
                    } else {
                        $ansi = "$e[38;2;$($pixel1.R);$($pixel1.G);$($pixel1.B)m"
                    }
                } else {
                    $pixel2 = $ScaledImage.GetPixel($j, $i + 1)
                    if ($pixel1.A -lt $alphathreshold -or $pixel2.A -lt $alphathreshold) {
                        if ($pixel1.A -lt $alphathreshold -and $pixel2.A -lt $alphathreshold) {
                            $char = [char]0x2800
                            $ansi = "$e[49m"
                        } elseif ($pixel1.A -lt $alphathreshold) {
                            $char = [char]0x2584
                            $ansi = "$e[49;38;2;$($pixel2.R);$($pixel2.G);$($pixel2.B)m"
                        } else {
                            $ansi = "$e[49;38;2;$($pixel1.R);$($pixel1.G);$($pixel1.B)m"
                        }
                    } else {
                        $ansi = "$e[38;2;$($pixel1.R);$($pixel1.G);$($pixel1.B);48;2;$($pixel2.R);$($pixel2.G);$($pixel2.B)m"
                    }
                }
                $currline += "$ansi$char$e[0m"
            }
            $currline
        }
    }

    $ScaledImage.Dispose()
    $RawImage.Dispose()
}

function GifToAscii {
    param(
        [string]$ImagePath,
        [int]$alphathreshold,
        [int]$COLUMNS,
        [switch] $ascii
    );

    Add-Type -AssemblyName 'System.Drawing'
    $RawImage = if (Test-Path $image -PathType Leaf) {
        [Drawing.Bitmap]::FromFile((Resolve-Path $ImagePath))
    } else {
        throw "Unsupported ImagePath type: $image";
    }

    $frameDimension = New-Object System.Drawing.Imaging.FrameDimension($RawImage.FrameDimensionsList[0]);
    $frameCount = $RawImage.GetFrameCount($frameDimension);

    # Save cursor position at start of writing image
    # "$e[s";

    for ($i = 0; $i -lt $frameCount; $i++) {
        # Restore cursor position before writing image
        # "$e[u";
        if ($i -gt 0) {
            # Move back to the start of the previous frame to overwrite it.
            "$e[${heightInLines}F$e[0G";
        }
        [void]$RawImage.SelectActiveFrame($frameDimension, $i);

        $propertyItem = $RawImage.GetPropertyItem(0x5100);
        $delay = ($propertyItem.Value[0] + $propertyItem.Value[1] * 256) / 100;
        # $delay = [System.BitConverter]::ToUInt16($RawImage.GetPropertyItem(0x5100).Value, $i * 4) / 1000;
        $clone = $RawImage.Clone();
        $asciiText = GifBitmapToAscii -RawImage $clone -alphathreshold $alphathreshold -COLUMNS $COLUMNS -ascii:$ascii;
        $asciiText ;
        $heightInLines = $asciiText.length + 1;

        # Get the pause time for the current animation frame
        # Pause for the delay time
        Start-Sleep -Seconds $delay;
    }

    # Save cursor position at end of writing image so we don't overwrite it anymore
    # "$e[s";
}

GifToAscii -ImagePath $ImagePath -alphathreshold $alphathreshold -COLUMNS $COLUMNS -ascii:$ascii
