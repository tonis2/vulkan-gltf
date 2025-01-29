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

public typealias u8vec4 = vector<uint8_t, 4>;

struct Vertex
{
    float3 position;
    float3 normal;
    float2 tex_cord;
    u8vec4 skin_pos;
    float4 skin_weight;
};

struct Instance
{
    int material_index;
    int has_skin;
    float4x4 node_matrix;
    float3* positions;
    float3* normals;
    float2* text_cords;
    u8vec4* skin_pos;
    float4* weights;

    // Instance data
    float3* translate;
    float4* rotate;
    float3* scale;

    Vertex get_vertex(uint index) {
        float3 normal = normals[index];
        return {
            positions[index],
            normal,
            text_cords[index],
            skin_pos[index],
            weights[index]
        };
    }
}

struct Uniform
{
    float4x4 perspective;
    float4x4 view;
    float4 eye;
}

// struct PushData
// {
//     uint light_index;
// };

// [vk_push_constant]
// const PushData push_constant;

[vk_binding(0)]
cbuffer Buffers
{
    Material *materials;
    float4x4 *joints;
    Instance *instances;
    Uniform *uniform;
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
    Instance instance = instances[input.drawID];
    Vertex vertex = instance.get_vertex(input.vertID);
    float4x4 skin_matrix = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    };

    if (instance.has_skin > 0)
    {
        uint4 skin_pos = asuint(vertex.skin_pos[0]);
        skin_matrix =
            vertex.skin_weight[0] * joints[skin_pos[0]] +
            vertex.skin_weight[1] * joints[skin_pos[1]] +
            vertex.skin_weight[2] * joints[skin_pos[2]] +
            vertex.skin_weight[3] * joints[skin_pos[3]];
    }

    float4x4 node_matrix = mul(instance.node_matrix, skin_matrix);
    float4 frag_pos = mul(node_matrix, float4(vertex.position.xyz, 1.0));
    float4 vertex_pos = mul(mul(uniform.perspective, uniform.view), frag_pos);

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
    float4 diffuse_texture = material.getBaseColor(input.tex_cord);
    if (input.material_index >= 0)
    {
        Material material = materials[input.material_index];
        float4 diffuse_texture = material.getBaseColor(input.tex_cord);
        return diffuse_texture;
    }

    return float4(0.5, 0.5, 0.5, 1.0);
}