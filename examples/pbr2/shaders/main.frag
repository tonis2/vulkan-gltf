#version 450
#extension GL_ARB_separate_shader_objects : enable
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_buffer_reference2 : require

struct Texture {
    int samp;
    int source;
};

layout (buffer_reference, std430, buffer_reference_align = 16) readonly buffer MaterialBuffer {
    bool doubleSided;
    float emissiveStrength;
    float metallicFactor;
    float roughnessFactor;
    vec4 emissiveFactor;
    vec4 baseColorFactor;
    Texture normalTexture;
    Texture occlusionTexture;
    Texture emissiveTexture;
    Texture baseColorTexture;
    Texture metallicRoughnessTexture;
};

layout(binding = 1) uniform sampler2D materialSamplers[];
layout(binding = 2) uniform samplerCube cubeMap;

layout(location = 0) in vec2 tex_cord;
layout(location = 1) in flat int m_index;
layout(location = 2) in MaterialBuffer materials;

layout(location = 0) out vec4 outColor;

vec4 getBaseColor(MaterialBuffer material) {
    Texture value = material.baseColorTexture;
    if (value.source >= 0) {
        return texture(materialSamplers[value.source], tex_cord) * material.baseColorFactor;
    }

    return material.baseColorFactor;
}

void main() {
    MaterialBuffer material;
    outColor = vec4(0.5, 0.5, 0.5, 1.0);

    if  (m_index >= 0) {
        material = materials[m_index];
        outColor = getBaseColor(material);
    }
}