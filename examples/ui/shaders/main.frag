#version 450
#extension GL_ARB_separate_shader_objects : enable
#extension GL_GOOGLE_include_directive : require

#include "types.glsl"

// layout(location = 0) in vec4 fragColor;
layout(location = 0) out vec4 outColor;

float sdBox( in vec2 p, in vec2 b )
{
    vec2 d = abs(p)-b;
    return length(max(d,0.0)) + min(max(d.x,d.y),0.0);
}

void main() {
    outColor = vec4(0.5, 0.5, 0.5, 1.0);
}