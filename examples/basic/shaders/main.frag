#version 450
#extension GL_ARB_separate_shader_objects : enable
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_GOOGLE_include_directive : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_EXT_buffer_reference2 : require

#include "types.glsl"

layout(binding = 1) uniform sampler2D materialSamplers[];

layout(location = 0) in flat int material_index;
layout(location = 1) in vec2 tex_cord;
layout(location = 2) in vec3 in_position;

layout(location = 0) out vec4 outColor;

vec4 getBaseColor(Material material) {
    Texture value = material.baseColorTexture;
    if (value.source >= 0) {
        return texture(materialSamplers[value.source], tex_cord) * material.baseColorFactor;
    }

    return material.baseColorFactor;
}


void main() {
    Material material;
    outColor = vec4(0.5, 0.5, 0.5, 1.0);

    if (material_index >= 0) {
        outColor = getBaseColor(material);
    }
}