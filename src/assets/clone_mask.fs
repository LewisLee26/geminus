#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec4 sprite_rect;
uniform vec4 mask_rect;
out vec4 finalColor;
void main() {
    vec4 tex = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
    vec2 local = (fragTexCoord - sprite_rect.xy) / sprite_rect.zw;
    vec2 maskUV = mask_rect.xy + local * mask_rect.zw;
    vec4 m = texture(texture0, maskUV);
    float lum = (m.r + m.g + m.b) / 3.0;
    finalColor = vec4(tex.rgb, tex.a * lum);
}
