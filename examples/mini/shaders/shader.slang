// Shader written in Slang https://github.com/shader-slang/slang

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

struct PushData
{
    float4x4 model_matrix;
    int material_index;
    bool has_skin;
    uint pos_offset;
    uint normal_offset;
    uint tex_offset;
};


struct Uniform
{
    float4x4 projection;
    float4x4 view;
    float3 eye;
}

[vk_push_constant]
const PushData push_constant;


[vk_binding(0)]
cbuffer Buffers
{
    float4x4 *joints;
    Uniform *uniform;
    Material *materials;
    uint64_t *gltf_data;
}

[vk_binding(1)]
uniform Sampler2D image_samplers[];

struct Vertices
{
    float3[2399] position;
    float3[2399] normal;
    float2[2399] tex_cord;
};

// Output of the fragment shader
struct FragmentData
{
    float2 tex_cord;
    int material_index;
};

struct VertexOutPut
{
    FragmentData vertex_output;
    float4 sv_position : SV_Position;
};

[shader("vertex")]
VertexOutPut vertexMain(uint32_t vertID: SV_VertexID, uint32_t drawId: SV_DrawIndex)
{

    float4x4 skin_matrix = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    };

    Vertices* vertices = (Vertices*)gltf_data;
    float3* pos = (float3*)gltf_data;
    // float3* normals = (float3*)gltf_data + 4347 * sizeof(float3);
    float2* tex_cords = (float2*)gltf_data + (4347 * sizeof(float3));
    // if (push_constant.has_skin)
    // {
    //     skin_matrix =
    //         vertex.skin_weight[0] * joints[uint(vertex.skin_pos[0])] +
    //         vertex.skin_weight[1] * joints[uint(vertex.skin_pos[1])] +
    //         vertex.skin_weight[2] * joints[uint(vertex.skin_pos[2])] +
    //         vertex.skin_weight[3] * joints[uint(vertex.skin_pos[3])];
    // }

    VertexOutPut output = {
        {
            tex_cords[vertID],
            push_constant.material_index,
        },
        mul(mul(mul(mul(uniform.projection, uniform.view), push_constant.model_matrix), skin_matrix), float4(pos[vertID], 1.0))
    };

    return output;
}

// Fragment Shader
[shader("fragment")]
float4 fragmentMain(FragmentData input)
    : SV_Target
{
    Material material;
    float4 color = float4(0.5, 0.5, 0.5, 1.0);

    if (input.material_index >= 0)
    {
        material = materials[input.material_index];
        return material.getBaseColor(input.tex_cord);
    }

    return color;
}
