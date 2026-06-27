#version 330
#ifdef GL_ES
precision mediump float;
#endif

// Vertex shader for the CRT effect.
// Raylib expects location 0 for position and location 1 for texcoord.
layout(location = 0) in vec3 vertex;
layout(location = 1) in vec2 texcoord;

uniform mat4 mvp;
out vec2 fragTexCoord;

void main() {
    fragTexCoord = texcoord;
    gl_Position = mvp * vec4(vertex, 1.0);
}
