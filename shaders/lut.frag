// Apply LUT for OBSpad, like OBS's Apply LUT filter. The LUT is a strip of
// uLutSize tiles (blue), each uLutSize² (x = red, y = green).
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uAmount;   // 0..1
uniform float uLutSize;  // e.g. 33 or 64
uniform sampler2D uTexture;
uniform sampler2D uLut;

out vec4 fragColor;

vec3 lookup(vec3 c) {
  float n = uLutSize;
  float b = c.b * (n - 1.0);
  float b0 = floor(b);
  float b1 = min(b0 + 1.0, n - 1.0);
  // Texel centres inside a tile.
  float x = (c.r * (n - 1.0) + 0.5) / (n * n);
  float y = (c.g * (n - 1.0) + 0.5) / n;
  vec3 s0 = texture(uLut, vec2(x + b0 / n, y)).rgb;
  vec3 s1 = texture(uLut, vec2(x + b1 / n, y)).rgb;
  return mix(s0, s1, b - b0);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  vec4 c = texture(uTexture, uv);
  if (c.a <= 0.0) {
    fragColor = c;
    return;
  }
  vec3 rgb = clamp(c.rgb / c.a, 0.0, 1.0);  // premultiplied -> straight
  vec3 graded = mix(rgb, lookup(rgb), uAmount);
  fragColor = vec4(graded * c.a, c.a);
}
