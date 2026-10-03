// Chroma / Color / Luma Key for OBSpad (ImageFilter.shader, Impeller).
// Modeled on OBS's chroma_key_filter / color_key_filter / luma_key_filter.
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;          // set by the engine: size of the input texture
uniform float uMode;         // 0 chroma, 1 color, 2 luma
uniform vec3 uKey;           // key color, 0..1
uniform float uSimilarity;   // 0..1
uniform float uSmoothness;   // 0..1
uniform float uSpill;        // 0..1 (chroma only)
uniform float uOpacity;      // 0..1
uniform vec4 uLuma;          // min, minSmooth, max, maxSmooth
uniform sampler2D uTexture;  // set by the engine: the filtered content

out vec4 fragColor;

vec2 cbcr(vec3 rgb) {
  return vec2(
    dot(rgb, vec3(-0.100644, -0.338572, 0.439216)) + 0.501961,
    dot(rgb, vec3(0.439216, -0.398942, -0.040274)) + 0.501961);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  vec4 px = texture(uTexture, uv);
  if (px.a <= 0.0) {
    fragColor = vec4(0.0);
    return;
  }
  vec3 rgb = px.rgb / px.a;  // un-premultiply
  float a = px.a;

  if (uMode < 0.5) {
    float base = distance(cbcr(rgb), cbcr(uKey)) - uSimilarity;
    float mask = pow(clamp(base / max(uSmoothness, 0.0001), 0.0, 1.0), 1.5);
    float spill = pow(clamp(base / max(uSpill, 0.0001), 0.0, 1.0), 1.5);
    float gray = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    rgb = mix(vec3(gray), rgb, spill);
    a *= mask;
  } else if (uMode < 1.5) {
    float base = distance(rgb, uKey) - uSimilarity;
    a *= clamp(base / max(uSmoothness, 0.0001), 0.0, 1.0);
  } else {
    float l = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    float lo = smoothstep(uLuma.x - uLuma.y, uLuma.x + 0.0001, l);
    float hi = 1.0 - smoothstep(uLuma.z - 0.0001, uLuma.z + uLuma.w, l);
    a *= lo * hi;
  }
  a *= uOpacity;
  fragColor = vec4(rgb * a, a);  // premultiplied
}
