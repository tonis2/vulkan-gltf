// Shader written in Slang https://github.com/shader-slang/slang

struct TextureInfo
{
    int source;
    int sampler;
    float rotation;
    float pad;
    float2 offset;
    float2 scale;

    bool can_sample()
    {
        return sampler >= 0;
    }
};

struct Material
{
    bool doubleSided;
    uint alphaMode;
    float cutOff;
    float emissiveStrength;
    float metallicFactor;
    float roughnessFactor;
    float2 pad;
    float4 emissiveFactor;
    float4 baseColorFactor;
    TextureInfo normalTexture;
    TextureInfo occlusionTexture;
    TextureInfo emissiveTexture;
    TextureInfo baseColorTexture;
    TextureInfo metallicRoughnessTexture;

    float4 getBaseColor(float2 tex_pos)
    {
        if (baseColorTexture.can_sample())
        {
            return image_samplers[baseColorTexture.sampler].Sample(tex_pos) * baseColorFactor;
        }

        return baseColorFactor;
    }
};


struct Vertex
{
    float3 position;
    float3 normal;
    float2 tex_cord;
    float4 skin_pos;
    float4 skin_weight;
};

struct Light
{
    float4 position;
    float4 color;
    uint type;
    float intensity;
    float range;
    float inner_angle;
    float outer_angle;
    float3 pad;
}

struct DrawCommand
{   
    uint indexCount;
    uint firstInstance;
    uint instanceCount;
    uint firstIndex;
    uint vertexOffset;

    int material_index;
    int has_skin;
    uint instance_offset;
    float4x4 node_matrix;
}


[vk_binding(0)]
cbuffer Scene
{
    float4x4 perspective;
    float4x4 view;
    float4 eye;
    Light light;
    Vertex* vertices;
    DrawCommand* commmands;
    Material* materials;
}

[vk_binding(1)]
uniform Sampler2D image_samplers[];

[vk_binding(2)]
uniform Sampler2D shadow_samplers[];

// Output of the fragment shader
struct FragmentData
{
    float2 tex_cord;
    int material_index;
    float4 sv_position : SV_Position;
};

struct VertexInput {
    uint32_t vertID : SV_VertexID;
    uint32_t drawID : SV_DrawIndex;
    uint32_t instanceID : SV_InstanceID;
}

[shader("vertex")]
FragmentData vertexMain(VertexInput input)
{
    DrawCommand instance = commmands[input.drawID];
    Vertex vertex = vertices[input.vertID];

    float4 frag_pos = mul(instance.node_matrix, float4(vertex.position.xyz, 1.0));
    float4 vertex_pos = mul(mul(perspective, view), frag_pos);

    FragmentData output = {
        vertex.tex_cord,
        instance.material_index,
        vertex_pos
    };

    return output;
}

// Fragment Shader
[shader("fragment")]
float4 fragmentMain(FragmentData input)
    : SV_Target
{
    Material material = materials[input.material_index];
    if (input.material_index >= 0)
    {
        Material material = materials[input.material_index];
        float4 diffuse_texture = material.getBaseColor(input.tex_cord);
        return diffuse_texture;
    }

    return float4(0.5, 0.5, 0.5, 1.0);
}