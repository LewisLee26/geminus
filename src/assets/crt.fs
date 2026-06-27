#version 330

in vec2 fragTexCoord;
out vec4 fragColor;

uniform sampler2D texture0;
uniform float     _Curvature;
uniform float     _VignetteWidth;
uniform float     _VignetteFadeIntensity;
uniform vec2      resolution;
uniform float     _ChromAbAmount;
uniform float     _MaskIntensity;
uniform float     _CornerShape;
uniform float     _EdgeWidth;
uniform float     _EdgeFade;
uniform float     _GlowIntensity;
uniform float     _GlowRadius;

// Barrel distortion. distFromCenter is normalised: 0 = centre, 1 = corner.
vec2 warpCoords(vec2 uv, float curvature, out float distFromCenter) {
    uv = uv * 2.0 - 1.0;
    distFromCenter = length(uv) * 0.7071;
    uv *= (1.0 + curvature * dot(uv, uv));
    return uv * 0.5 + 0.5;
}

// 7-tap binomial tent blur along one axis. stepSize = radius / resolution.
vec3 bloomSample(sampler2D tex, vec2 uv, vec2 stepSize) {
    // 36 + 2×28 + 2×14 + 2×4 = 128
    const float w0 = 0.28125;
    const float w1 = 0.21875;
    const float w2 = 0.109375;
    const float w3 = 0.03125;

    vec3 sum = vec3(0.0);
    sum += texture(tex, clamp(uv - stepSize * 3.0, 0.0, 1.0)).rgb * w3;
    sum += texture(tex, clamp(uv - stepSize * 2.0, 0.0, 1.0)).rgb * w2;
    sum += texture(tex, clamp(uv - stepSize,        0.0, 1.0)).rgb * w1;
    sum += texture(tex, clamp(uv,                   0.0, 1.0)).rgb * w0;
    sum += texture(tex, clamp(uv + stepSize,        0.0, 1.0)).rgb * w1;
    sum += texture(tex, clamp(uv + stepSize * 2.0,  0.0, 1.0)).rgb * w2;
    sum += texture(tex, clamp(uv + stepSize * 3.0,  0.0, 1.0)).rgb * w3;
    return sum;
}

void main()
{
    float distFromCenter;
    vec2 uv        = warpCoords(fragTexCoord, _Curvature, distFromCenter);
    vec2 clampedUV = clamp(uv, 0.0, 1.0);

    // Edge mask – superellipse with safe pow() base to avoid pow(0,0) NaN.
    vec2  crtUV    = uv * 2.0 - 1.0;
    float shapeVal = pow(max(abs(crtUV.x), 1e-6), _CornerShape)
                   + pow(max(abs(crtUV.y), 1e-6), _CornerShape);
    float edgeMask = 1.0 - smoothstep(1.0, 1.0 + _EdgeWidth + _EdgeFade, shapeVal + _EdgeWidth);

    // Chromatic aberration – radial offset from warped centre, aspect-correct.
    vec2  toCenter    = uv - 0.5;
    float toCenterLen = length(toCenter);
    vec2  caDir       = (toCenterLen > 0.0001)
                        ? (toCenter / toCenterLen) * (_ChromAbAmount * distFromCenter / resolution)
                        : vec2(0.0);

    float rCol = texture(texture0, clamp(clampedUV + caDir, 0.0, 1.0)).r;
    float gCol = texture(texture0, clampedUV).g;
    float bCol = texture(texture0, clamp(clampedUV - caDir, 0.0, 1.0)).b;
    vec4  col  = vec4(rCol, gCol, bCol, 1.0);

    // Phosphor slot mask.
    const float third     = 1.0 / 3.0;
    const float twothirds = 2.0 / 3.0;
    float rowIndex    = fract(clampedUV.y * resolution.y / 3.0);
    vec3  maskPattern = vec3(0.0);
    maskPattern.r = step(twothirds, rowIndex);
    maskPattern.g = step(third, rowIndex) - step(twothirds, rowIndex);
    maskPattern.b = 1.0 - step(third, rowIndex);
    col.rgb = mix(col.rgb, col.rgb * maskPattern, _MaskIntensity);

    // Bloom – H+V axial passes plus 4 diagonal taps for a rounder kernel.
    // Diagonal contribution (4 × 0.02 = 0.08) is folded into the normaliser.
    vec2 stepH   = vec2(_GlowRadius / resolution.x, 0.0);
    vec2 stepV   = vec2(0.0, _GlowRadius / resolution.y);
    vec2 diag    = vec2(_GlowRadius / resolution.x, _GlowRadius / resolution.y);
    vec3 blurred = (bloomSample(texture0, clampedUV, stepH)
                  + bloomSample(texture0, clampedUV, stepV)) * 0.5;
    const float dw = 0.02;
    blurred += texture(texture0, clamp(clampedUV + vec2( diag.x,  diag.y), 0.0, 1.0)).rgb * dw;
    blurred += texture(texture0, clamp(clampedUV + vec2(-diag.x,  diag.y), 0.0, 1.0)).rgb * dw;
    blurred += texture(texture0, clamp(clampedUV + vec2( diag.x, -diag.y), 0.0, 1.0)).rgb * dw;
    blurred += texture(texture0, clamp(clampedUV + vec2(-diag.x, -diag.y), 0.0, 1.0)).rgb * dw;
    blurred /= 1.08;

    float glowFactor = smoothstep(0.6, 1.0, max(blurred.r, max(blurred.g, blurred.b)));
    col.rgb += blurred * (glowFactor * _GlowIntensity);

    // Vignette – distFromCenter in [0,1] so _VignetteWidth is a direct screen fraction.
    col.rgb *= 1.0 - smoothstep(_VignetteWidth, 1.0, distFromCenter) * _VignetteFadeIntensity;

    col.rgb *= edgeMask;

    fragColor = clamp(col, 0.0, 1.0);
}
