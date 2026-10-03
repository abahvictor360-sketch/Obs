// Sharpen (unsharp mask) for ObsPad, like OBS's Sharpen filter.
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uAmount;  // 0..1
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  vec2 t = 1.0 / uSize;
  vec4 c = texture(uTexture, uv);
  vec4 n = texture(uTexture, uv + vec2(0.0, -t.y)) + texture(uTexture, uv + vec2(0.0, t.y)) +
           texture(uTexture, uv + vec2(-t.x, 0.0)) + texture(uTexture, uv + vec2(t.x, 0.0));
  vec4 sharp = c + (c * 4.0 - n) * uAmount * 2.0;
  fragColor = vec4(clamp(sharp.rgb, vec3(0.0), vec3(c.a)), c.a);
}
