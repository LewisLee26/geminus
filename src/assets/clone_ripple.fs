#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec4 sprite_rect;
uniform float time;
uniform float tint_alpha;
uniform vec4 mask_rect;   // dissolve mask cell in atlas UVs
uniform float use_mask;   // 1 = apply dissolve mask (spawn/vanish), 0 = none
out vec4 finalColor;
void main() {
    vec2 local = (fragTexCoord - sprite_rect.xy) / sprite_rect.zw;
    // Diagonal coordinate sweeping across the sprite over time. Lower
    // frequency = wider bands.
    float band = local.x + local.y;
    float wave = sin(band * 3.1415927 - time * 3.0);
    // Slight horizontal ripple of the sample position (in atlas UV space).
    vec2 uv = fragTexCoord;
    uv.x += wave * 0.004 * sprite_rect.z;
    vec4 tex = texture(texture0, uv) * colDiffuse * fragColor;
    // Shine: a soft, wide bright band (broad smoothstep), kept subtle.
    float shine = smoothstep(0.2, 1.0, wave);
    vec3 rgb = tex.rgb + vec3(shine) * 0.1;
    // Transparent overall; the shine band is a touch more opaque so it pops.
    float a = tex.a * (tint_alpha + shine * 0.12);
    // Dissolve: during spawn/vanish, multiply alpha by the mask luminance at
    // this fragment's local position (white keeps, black hides) so the clone
    // materializes/dematerializes while still rippling and transparent.
    if (use_mask > 0.5) {
        vec2 maskUV = mask_rect.xy + local * mask_rect.zw;
        vec4 m = texture(texture0, maskUV);
        a *= (m.r + m.g + m.b) / 3.0;
    }
    finalColor = vec4(rgb, clamp(a, 0.0, 1.0));
}
