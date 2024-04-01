#version 450
#extension GL_ARB_separate_shader_objects : enable
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_nonuniform_qualifier : require

struct Texture {
    int samp;
    int source;
};

struct Material
{
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

layout (binding = 1, std430) buffer MaterialBuffer {
    Material materials[4];
};

layout(binding = 2) uniform sampler2D materialSamplers[];

layout(location = 0) in vec2 tex_cord;
layout(location = 1) in flat int m_index;
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

    if  (m_index >= 0) {
        material = materials[m_index];
        outColor = getBaseColor(material);
    }
}