param(
    [string]$ImagePath,
    [int]$alphathreshold = 50,
    [int]$COLUMNS = 35,
    [switch] $ascii,
    [switch] $resetCursorAtEnd,
    [single] $frameDelayScale = 1,
    [string][ValidateSet("console", "script")] $OutputKind = "console" # Valid values: console, script
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

function WriteOutputLine {
    param($textLine);

    if ($OutputKind -eq "console") {
        $textLine;
    } 
    else {
        $textLine -split "`n" | ForEach-Object {
            # OutputKind is script
            # Write asciiText out as a ' string with ' escaped
            $escapedString = $_ -replace "'", "''" # Escape single quotes
            "'$escapedString'"
        }
    }
}

function GifToAscii {
    param(
        [string]$ImagePath,
        [int]$alphathreshold,
        [int]$COLUMNS,
        [switch] $ascii,
        [single] $frameDelayScale,
        [switch] $resetCursorAtEnd
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

    # Hide the cursor
    WriteOutputLine "$e[?25l";

    for ($i = 0; $i -lt $frameCount; $i++) {
        # Restore cursor position before writing image
        # "$e[u";
        [void]$RawImage.SelectActiveFrame($frameDimension, $i);

        $propertyItem = $RawImage.GetPropertyItem(0x5100);
        $delay = ($propertyItem.Value[0] + $propertyItem.Value[1] * 256) / 100;
        # $delay = [System.BitConverter]::ToUInt16($RawImage.GetPropertyItem(0x5100).Value, $i * 4) / 1000;
        $delay = $delay * $frameDelayScale;
        $clone = $RawImage.Clone();
        $asciiText = GifBitmapToAscii -RawImage $clone -alphathreshold $alphathreshold -COLUMNS $COLUMNS -ascii:$ascii;
        WriteOutputLine $asciiText;

        $heightInLines = $asciiText.length + 1;

        # Get the pause time for the current animation frame
        # Pause for the delay time
        if ($OutputKind -eq "console") {
            Start-Sleep -Seconds $delay;
        } else {
            # Script output so we print out the command to sleep
            "Start-Sleep -Seconds $delay;"
        }

        if ($i -lt $frameCount - 1 -or $resetCursorAtEnd) {
            # Move back to the start of the previous frame to overwrite it.
            WriteOutputLine "$e[${heightInLines}F$e[0G";
        }
    }

    # Save cursor position at end of writing image so we don't overwrite it anymore
    # "$e[s";

    # Display the cursor
    WriteOutputLine "$e[?25h";
}

GifToAscii -ImagePath $ImagePath -alphathreshold $alphathreshold -COLUMNS $COLUMNS -ascii:$ascii -resetCursorAtEnd:$resetCursorAtEnd -frameDelayScale:$frameDelayScale;
