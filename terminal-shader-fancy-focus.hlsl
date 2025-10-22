// This pixel shader provides some different effects based on the color in the terminal:
// - The color ce5efe (purple), is replaced with an animated rainbow effect
// - The color fffa6a (yellow), is replaced with a glowing yellow effect
// - The color ff7092 (light red) has a digital glitch effect

// The terminal graphics as a texture
Texture2D shaderTexture;
SamplerState samplerState;

// Terminal settings such as the resolution of the texture
cbuffer PixelShaderSettings {
  // The number of seconds since the pixel shader was enabled
  float  Time;
  // UI Scale
  float  Scale;
  // Resolution of the shaderTexture
  float2 Resolution;
  // Background color as rgba
  float4 Background;
};

// Named color constants for effect triggers - renamed for their effects rather than colors
static const float3 RAINBOW_TRIGGER_COLOR = float3(0.808, 0.369, 0.996); // ce5efe (purple) triggers rainbow effect
static const float3 GLOW_TRIGGER_COLOR = float3(1.000, 0.980, 0.416); // fffa6a (yellow) triggers glow effect
static const float3 GLITCH_TRIGGER_COLOR = float3(1.000, 0.439, 0.573); // ff7092 (light red) triggers glitch effect
static const float COLOR_TOLERANCE = 0.15; // Tolerance for color matching

// Helper function to check if two colors are similar within tolerance
bool isColorMatch(float3 color1, float3 color2, float tolerance) {
    float3 diff = abs(color1 - color2);
    return all(diff <= tolerance);
}

// Convert RGB to HSV color space
// The float3 hsv uses
// hsv.r = hue [0, 1], where 0 = red, 1/3 = green, 2/3 = blue
// hsv.g = saturation [0, 1], where 0 = gray, 1 = full color
// hsv.b = value (brightness) [0, 1], where 0 = black, 1 = full brightness
float3 rgbToHsv(float3 rgb) {
    float maxVal = max(max(rgb.r, rgb.g), rgb.b);
    float minVal = min(min(rgb.r, rgb.g), rgb.b);
    float delta = maxVal - minVal;
    
    float3 hsv = float3(0, 0, maxVal); // Initialize H, S, V
    
    // Calculate saturation
    if (maxVal > 0.0) {
        hsv.g = delta / maxVal; // Saturation
    }
    
    // Calculate hue
    if (delta > 0.0) {
        if (maxVal == rgb.r) {
            hsv.r = ((rgb.g - rgb.b) / delta) / 6.0;
        } else if (maxVal == rgb.g) {
            hsv.r = (2.0 + (rgb.b - rgb.r) / delta) / 6.0;
        } else {
            hsv.r = (4.0 + (rgb.r - rgb.g) / delta) / 6.0;
        }
        
        // Ensure hue is in [0, 1] range
        if (hsv.r < 0.0) hsv.r += 1.0;
    }
    
    return hsv;
}

// Convert HSV to RGB color space
float3 hsvToRgb(float3 hsv) {
    float h = hsv.r * 6.0; // Convert hue to [0, 6] range
    float s = hsv.g;
    float v = hsv.b;
    
    float c = v * s;
    float x = c * (1.0 - abs(fmod(h, 2.0) - 1.0));
    float m = v - c;
    
    float3 rgb = float3(0, 0, 0);
    
    if (h < 1.0) {
        rgb = float3(c, x, 0);
    } else if (h < 2.0) {
        rgb = float3(x, c, 0);
    } else if (h < 3.0) {
        rgb = float3(0, c, x);
    } else if (h < 4.0) {
        rgb = float3(0, x, c);
    } else if (h < 5.0) {
        rgb = float3(x, 0, c);
    } else {
        rgb = float3(c, 0, x);
    }
    
    return rgb + m;
}

// A pixel shader is a program that given a texture coordinate (tex) produces a color.
// tex is an x,y tuple that ranges from 0,0 (top left) to 1,1 (bottom right).
// Just ignore the pos parameter.
float4 main(float4 pos : SV_POSITION, float2 tex : TEXCOORD) : SV_TARGET
{
    // Read the color value at the current texture coordinate (tex)
    //  float4 is tuple of 4 floats, rgba
    float4 color = shaderTexture.Sample(samplerState, tex);

    // Example of inverting color:
    // color.xyz = 1.0 - color.xyz;

    // Pick the correct effect based on the color using effect-named color variables
    if (isColorMatch(color.rgb, RAINBOW_TRIGGER_COLOR, COLOR_TOLERANCE)) {
        // Rainbow effect (triggered by ce5efe purple) - animated diagonal rainbow effect preserving original luminance and saturation
        float speed = 0.1; // Speed of the rainbow animation
        float bandWidth = 1600.0; // Width of color bands in pixels (larger = wider bands)
        float phase = Time * speed;
        
        // Create diagonal bands by combining x and y coordinates
        float diagonal = (tex.x * Resolution.x + tex.y * Resolution.y);
        
        // Convert original color to HSV to preserve saturation and value (luminance)
        float3 hsv = rgbToHsv(color.rgb);
        
        // Calculate hue for smooth full-spectrum cycling with wide bands
        float huePhase = (diagonal / bandWidth) + phase;
        hsv.r = frac(huePhase); // This creates smooth 0-1 hue cycling without abrupt jumps
        
        hsv.b -= 0.4; // Slightly reduce brightness so white text on top of rainbow is visible
        
        // Convert back to RGB, preserving original saturation and brightness
        color.rgb = hsvToRgb(hsv);
    } else if (isColorMatch(color.rgb, GLOW_TRIGGER_COLOR, COLOR_TOLERANCE)) {
        // Glow effect (triggered by fffa6a yellow) - glowing effect
        float glowIntensity = 0.3; // Intensity of the glow
        float glowSpeed = 2.0; // Speed of the glow animation
        float glow = glowIntensity * (0.5 + 0.5 * sin(glowSpeed * Time));

        color.r = min(color.r + glow, 1.0);
        color.g = min(color.g + glow, 1.0);
        color.b = min(color.b + glow, 1.0);
    } else if (isColorMatch(color.rgb, GLITCH_TRIGGER_COLOR, COLOR_TOLERANCE)) {
        // Glitch effect (triggered by ff7092 light red) - digital corruption effect
        float2 pixelSize = 1.0 / Resolution;
        
        // Create random glitch timing
        float glitchTime = floor(Time * 8.0); // Change glitch pattern ~8 times per second
        float random1 = frac(sin(glitchTime * 12.9898 + tex.y * 78.233) * 43758.5453);
        float random2 = frac(sin(glitchTime * 93.9898 + tex.x * 67.283) * 28001.8384);
        
        // Horizontal displacement glitch
        float horizontalGlitch = 0.0;
        if (random1 > 0.95) { // 5% chance of strong horizontal glitch
            horizontalGlitch = (random2 - 0.5) * 0.02; // Shift up to 2% of screen width
        } else if (random1 > 0.85) { // 10% chance of medium glitch
            horizontalGlitch = (random2 - 0.5) * 0.005; // Shift up to 0.5% of screen width
        }
        
        // Sample displaced position
        float2 glitchedCoord = tex + float2(horizontalGlitch, 0);
        float4 glitchedColor = shaderTexture.Sample(samplerState, glitchedCoord);
        
        // RGB channel separation (chromatic aberration)
        float separationAmount = 0.003; // 0.3% of screen width
        float2 redOffset = float2(-separationAmount, 0);
        float2 blueOffset = float2(separationAmount, 0);
        
        // Only apply separation during glitch events
        if (random1 > 0.8) {
            float4 redChannel = shaderTexture.Sample(samplerState, glitchedCoord + redOffset);
            float4 blueChannel = shaderTexture.Sample(samplerState, glitchedCoord + blueOffset);
            
            // Combine separated channels
            color.r = redChannel.r;
            color.g = glitchedColor.g;
            color.b = blueChannel.b;
        } else {
            color = glitchedColor;
        }
        
        // Digital noise overlay
        float noise = frac(sin(dot(tex * Resolution, float2(12.9898, 78.233)) + Time * 1000.0) * 43758.5453);
        if (random1 > 0.9 && noise > 0.95) {
            // Occasional bright white noise pixels
            color.rgb = lerp(color.rgb, float3(1.0, 1.0, 1.0), 0.8);
        } else if (random1 > 0.85 && noise > 0.9) {
            // Some black corruption pixels  
            color.rgb = lerp(color.rgb, float3(0.0, 0.0, 0.0), 0.6);
        }
        
        // Scan line interference
        float scanLine = sin(tex.y * Resolution.y * 0.5 + Time * 10.0);
        if (random1 > 0.88) {
            color.rgb *= (1.0 + scanLine * 0.1); // Subtle scan line brightening during glitches
        }
    }

    // Return the final color
    return color;
}
