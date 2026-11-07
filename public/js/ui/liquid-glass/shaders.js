// Liquid Glass shaders, vendored from liquid-glass-studio (MIT, (c) 2024
// Charles Yin — https://github.com/iyinchao/liquid-glass-studio). The glass
// lighting (refraction, chromatic dispersion, Fresnel, glare, LCH tinting) is
// the project's `fragment-main.glsl` STEP 9; the SDF of the shape is
// re-expressed as the union of N rounded rectangles taken from live DOM rects
// (one per floating control) instead of the demo's single mouse-driven shape,
// its viewport-relative units are taken against a reference viewport height
// (u_viewH) because our canvas only covers a bar of buttons, and everything
// outside the glass is output transparent so the canvas overlays the app.
// `#include`s are inlined (no build step). Also uses Inigo Quilez's
// rounded-box SDF and the GLSL LCH helpers credited in the original.

export const MAX_SHAPES = 16

// --- shared GLSL fragments -------------------------------------------------

// The shape field: signed distance (in normalised-y units, px / u_resolution.y)
// to the union of the rounded rects in u_shapeBox. gl_FragCoord is physical px,
// y-up; shape centres/sizes are supplied in the same space.
const SDF_LIB = `
uniform int u_shapeCount;
uniform vec4 u_shapeBox[${MAX_SHAPES}]; // xy = centre (phys px), zw = half size (phys px)
uniform float u_shapeR[${MAX_SHAPES}];  // corner radius (phys px)
// The project's canvas is the whole viewport and its units are fractions of
// that height; ours is only as big as a bar of buttons, so the same units are
// taken against a reference viewport height (phys px) instead of the canvas's.
uniform float u_viewH;

float lgRoundRect(vec2 p, vec2 c, vec2 halfSize, float r) {
  vec2 q = abs(p - c) - halfSize + vec2(r);
  return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}
float mainSDF(vec2 fragPx) {
  float d = 1e9;
  for (int i = 0; i < ${MAX_SHAPES}; i++) {
    if (i >= u_shapeCount) break;
    vec4 b = u_shapeBox[i];
    d = min(d, lgRoundRect(fragPx, b.xy, b.zw, u_shapeR[i]));
  }
  return d / u_viewH;
}`

const MATH_LIB = `
float safeAsin(float x) { return asin(clamp(x, -1.0, 1.0)); }`

// Gradient of the field → surface normal (original getNormal, now parameterless).
const NORMAL_LIB = `
vec2 getNormal(vec2 p) {
  vec2 h = vec2(max(abs(dFdx(p.x)), 0.0001), max(abs(dFdy(p.y)), 0.0001));
  vec2 grad = vec2(
    mainSDF(p + vec2(h.x, 0.0)) - mainSDF(p - vec2(h.x, 0.0)),
    mainSDF(p + vec2(0.0, h.y)) - mainSDF(p - vec2(0.0, h.y))
  ) / (2.0 * h);
  return grad * 1.414213562 * 1000.0;
}`

// LCH color helpers (from the project's lib/color.glsl).
const COLOR_LIB = `
const vec3 D65_WHITE = vec3(0.95045592705, 1.0, 1.08905775076);
vec3 WHITE = D65_WHITE;
const mat3 RGB_TO_XYZ_M = mat3(0.4124,0.3576,0.1805, 0.2126,0.7152,0.0722, 0.0193,0.1192,0.9505);
const mat3 XYZ_TO_RGB_M = mat3(3.2406255,-1.537208,-0.4986286, -0.9689307,1.8757561,0.0415175, 0.0557101,-0.2040211,1.0569959);
float UNCOMPAND_SRGB(float a){ return a > 0.04045 ? pow((a+0.055)/1.055, 2.4) : a/12.92; }
float COMPAND_RGB(float a){ return a <= 0.0031308 ? 12.92*a : 1.055*pow(a, 0.41666666666)-0.055; }
vec3 RGB_TO_XYZ(vec3 rgb){ return rgb * RGB_TO_XYZ_M; }
vec3 SRGB_TO_RGB(vec3 s){ return vec3(UNCOMPAND_SRGB(s.x),UNCOMPAND_SRGB(s.y),UNCOMPAND_SRGB(s.z)); }
vec3 RGB_TO_SRGB(vec3 rgb){ return vec3(COMPAND_RGB(rgb.x),COMPAND_RGB(rgb.y),COMPAND_RGB(rgb.z)); }
vec3 SRGB_TO_XYZ(vec3 s){ return RGB_TO_XYZ(SRGB_TO_RGB(s)); }
float XYZ_TO_LAB_F(float x){ return x > 0.00885645167 ? pow(x, 0.333333333) : 7.78703703704*x + 0.13793103448; }
vec3 XYZ_TO_LAB(vec3 xyz){ vec3 s = xyz / WHITE; s = vec3(XYZ_TO_LAB_F(s.x),XYZ_TO_LAB_F(s.y),XYZ_TO_LAB_F(s.z)); return vec3(116.0*s.y-16.0, 500.0*(s.x-s.y), 200.0*(s.y-s.z)); }
vec3 SRGB_TO_LAB(vec3 s){ return XYZ_TO_LAB(SRGB_TO_XYZ(s)); }
vec3 LAB_TO_LCH(vec3 Lab){ return vec3(Lab.x, sqrt(dot(Lab.yz,Lab.yz)), atan(Lab.z,Lab.y)*57.2957795131); }
vec3 SRGB_TO_LCH(vec3 s){ return LAB_TO_LCH(SRGB_TO_LAB(s)); }
vec3 XYZ_TO_RGB(vec3 xyz){ return xyz * XYZ_TO_RGB_M; }
vec3 XYZ_TO_SRGB(vec3 xyz){ return RGB_TO_SRGB(XYZ_TO_RGB(xyz)); }
float LAB_TO_XYZ_F(float x){ return x > 0.206897 ? x*x*x : 0.12841854934*(x-0.137931034); }
vec3 LAB_TO_XYZ(vec3 Lab){ float w=(Lab.x+16.0)/116.0; return WHITE*vec3(LAB_TO_XYZ_F(w+Lab.y/500.0),LAB_TO_XYZ_F(w),LAB_TO_XYZ_F(w-Lab.z/200.0)); }
vec3 LAB_TO_SRGB(vec3 lab){ return XYZ_TO_SRGB(LAB_TO_XYZ(lab)); }
vec3 LCH_TO_LAB(vec3 LCh){ return vec3(LCh.x, LCh.y*cos(LCh.z*0.01745329251), LCh.y*sin(LCh.z*0.01745329251)); }
vec3 LCH_TO_SRGB(vec3 lch){ return LAB_TO_SRGB(LCH_TO_LAB(lch)); }
float vec2ToAngle(vec2 v){ float a = atan(v.y, v.x); if (a < 0.0) a += 2.0*PI; return a; }
vec4 getTextureDispersion(sampler2D tex1, sampler2D tex2, float mixRate, vec2 offset, float factor){
  vec4 pixel = vec4(1.0);
  float bgR = texture(tex1, g_uv + offset*(1.0-(N_R-1.0)*factor)).r;
  float bgG = texture(tex1, g_uv + offset*(1.0-(N_G-1.0)*factor)).g;
  float bgB = texture(tex1, g_uv + offset*(1.0-(N_B-1.0)*factor)).b;
  float blurR = texture(tex2, g_uv + offset*(1.0-(N_R-1.0)*factor)).r;
  float blurG = texture(tex2, g_uv + offset*(1.0-(N_G-1.0)*factor)).g;
  float blurB = texture(tex2, g_uv + offset*(1.0-(N_B-1.0)*factor)).b;
  pixel.r = mix(bgR, blurR, mixRate);
  pixel.g = mix(bgG, blurG, mixRate);
  pixel.b = mix(bgB, blurB, mixRate);
  return pixel;
}`

// --- passes ----------------------------------------------------------------

export const VERTEX = `#version 300 es
in vec4 a_position;
out vec2 v_uv;
void main(){ v_uv = (a_position.xy + 1.0) * 0.5; gl_Position = a_position; }`

// Main pass: the glass. SDF → refraction with dispersion, Fresnel and glare,
// LCH-tinted — the project's STEP 9, with the outside made transparent.
export const MAIN = `#version 300 es
precision highp float;
#define PI (3.14159265359)
const float N_R = 1.0 - 0.02;
const float N_G = 1.0;
const float N_B = 1.0 + 0.02;
in vec2 v_uv;
uniform sampler2D u_blurredBg;
uniform sampler2D u_bg;
uniform vec2 u_resolution; // the backdrop texture, phys px
uniform vec2 u_texPad;     // how far it reaches past the output on each side, phys px
uniform float u_shadowExpand; // the project's soft shadow (fragment-bg.glsl): its reach, css px
uniform float u_shadowFactor;
uniform vec2 u_shadowOffset;  // phys px, y up
// outside the glass, the shadow only reaches as far as there is room (what
// clips the button): its own reach, strength and drop there
uniform float u_shadowOutExpand;
uniform float u_shadowOutFactor;
uniform vec2 u_shadowOutOffset;
vec2 g_uv;                 // this fragment's place in the backdrop texture
uniform float u_dpr;
uniform vec4 u_tint;
uniform float u_refThickness;
uniform float u_refDistance;
uniform float u_refFactor;
uniform float u_refDispersion;
uniform float u_refFresnelRange;
uniform float u_refFresnelFactor;
uniform float u_refFresnelHardness;
uniform float u_glareRange;
uniform float u_glareConvergence;
uniform float u_glareOppositeFactor;
uniform float u_glareFactor;
uniform float u_glareHardness;
uniform float u_glareChroma; // how much colour the rim light adds (the demo's 30; 0: white light)
uniform float u_glareAngle;
uniform int u_blurEdge;
out vec4 fragColor;
${SDF_LIB}
${MATH_LIB}
${NORMAL_LIB}
${COLOR_LIB}
void main(){
  g_uv = (gl_FragCoord.xy + u_texPad) / u_resolution;
  float h1x = u_viewH / u_dpr; // the reference viewport height, css px
  float merged = mainSDF(gl_FragCoord.xy);
  // The shadow the project bakes into its background, under and around the
  // shape: the glass refracts it (a darker rim inside the lens), and around
  // the glass it lifts it off the page.
  float shadow = exp(-1.0 / u_shadowExpand * abs(mainSDF(gl_FragCoord.xy + u_shadowOffset)) * h1x) * 0.6 * u_shadowFactor;
  float shadowOut = exp(-1.0 / u_shadowOutExpand * abs(mainSDF(gl_FragCoord.xy + u_shadowOutOffset)) * h1x) * 0.6 * u_shadowOutFactor;
  vec4 outColor = vec4(0.0);
  if (merged < 0.005) {
    float nmerged = -1.0 * (merged * h1x);
    float x_R_ratio = 1.0 - nmerged / u_refThickness;
    float thetaI = safeAsin(pow(x_R_ratio, 2.0));
    float thetaT = safeAsin(1.0 / u_refFactor * sin(thetaI));
    float edgeFactor = -1.0 * tan(thetaT - thetaI);
    if (nmerged >= u_refThickness) { edgeFactor = 0.0; }
    if (edgeFactor <= 0.0) {
      outColor = texture(u_blurredBg, g_uv);
      outColor.rgb -= vec3(shadow);
      outColor = mix(outColor, vec4(u_tint.r, u_tint.g, u_tint.b, 1.0), u_tint.a * 0.8);
    } else {
      float edgeH = nmerged / u_refThickness;
      vec2 normal = getNormal(gl_FragCoord.xy);
      vec4 blurredPixel = getTextureDispersion(
        u_bg, u_blurredBg,
        u_blurEdge > 0 ? 1.0 : edgeH,
        // the project's offset is this many viewport-heights; in our canvas's uv
        -normal * edgeFactor * u_refDistance * u_dpr * u_viewH / u_resolution,
        u_refDispersion
      );
      blurredPixel.rgb -= vec3(shadow);
      outColor = mix(blurredPixel, vec4(u_tint.r, u_tint.g, u_tint.b, 1.0), u_tint.a * 0.8);
      float fresnelFactor = clamp(pow(1.0 + merged * h1x / 1500.0 * pow(500.0 / u_refFresnelRange, 2.0) + u_refFresnelHardness, 5.0), 0.0, 1.0);
      vec3 fresnelTintLCH = SRGB_TO_LCH(mix(vec3(1.0), vec3(u_tint.r, u_tint.g, u_tint.b), u_tint.a * 0.5));
      fresnelTintLCH.x += 20.0 * fresnelFactor * u_refFresnelFactor;
      fresnelTintLCH.x = clamp(fresnelTintLCH.x, 0.0, 100.0);
      outColor = mix(outColor, vec4(LCH_TO_SRGB(fresnelTintLCH), 1.0), fresnelFactor * u_refFresnelFactor * 0.7 * length(normal));
      float glareGeoFactor = clamp(pow(1.0 + merged * h1x / 1500.0 * pow(500.0 / u_glareRange, 2.0) + u_glareHardness, 5.0), 0.0, 1.0);
      float glareAngle = (vec2ToAngle(normalize(normal)) - PI / 4.0 + u_glareAngle) * 2.0;
      int glareFarside = 0;
      if (glareAngle > PI * (2.0 - 0.5) && glareAngle < PI * (4.0 - 0.5) || glareAngle < PI * (0.0 - 0.5)) { glareFarside = 1; }
      float glareAngleFactor = (0.5 + sin(glareAngle) * 0.5) * (glareFarside == 1 ? 1.2 * u_glareOppositeFactor : 1.2) * u_glareFactor;
      glareAngleFactor = clamp(pow(glareAngleFactor, 0.1 + u_glareConvergence * 2.0), 0.0, 1.0);
      vec3 glareTintLCH = SRGB_TO_LCH(mix(blurredPixel.rgb, vec3(u_tint.r, u_tint.g, u_tint.b), u_tint.a * 0.5));
      glareTintLCH.x += 150.0 * glareAngleFactor * glareGeoFactor;
      glareTintLCH.y += u_glareChroma * glareAngleFactor * glareGeoFactor;
      glareTintLCH.x = clamp(glareTintLCH.x, 0.0, 120.0);
      outColor = mix(outColor, vec4(LCH_TO_SRGB(glareTintLCH), 1.0), glareAngleFactor * glareGeoFactor * length(normal));
    }
  }
  // Fade to transparent across the edge so the canvas overlays the app cleanly.
  float alpha = outColor.a * (1.0 - smoothstep(-0.0015, 0.0015, merged));
  // the glass over its shadow, premultiplied
  fragColor = vec4(outColor.rgb * alpha, alpha) + vec4(0.0, 0.0, 0.0, shadowOut) * (1.0 - alpha);
}`
