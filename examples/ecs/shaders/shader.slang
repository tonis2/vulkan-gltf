// Shader written in Slang https://github.com/shader-slang/slang

struct Material
{
    float emissiveStrength;
    float metallicFactor;
    float roughnessFactor;
    float pad;
    float4 emissiveFactor;
    float4 baseColorFactor;
    int normalTexture;
    int occlusionTexture;
    int emissiveTexture;
    int baseColorTexture;
    int metallicRoughnessTexture;
};

struct Vertex
{
    float4 position;
    float4 normal;
    float4 tex_cord;
    float4 tangent;
    uint4 skin_pos;
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
    uint instanceCount;
    uint firstIndex;
    int vertexOffset;
    uint firstInstance;

    float4x4* skin_data;
    Material* material;
    float4x4* instances;
    float4x4 node_matrix;
}

struct PushData
{
    uint draw_index;
};

[vk_push_constant]
const PushData push_constant;

[vk_binding(0)]
cbuffer Scene
{
    float4x4 perspective;
    float4x4 view;
    float4 eye;
    Light light;
    Vertex* vertices;
    DrawCommand* draw_cmds;
}

[vk_binding(1)]
uniform Sampler2D image_samplers[];

[vk_binding(2)]
uniform Sampler2D shadow_samplers[];

// Output of the fragment shader
struct FragmentData
{
    float2 tex_cord;
    uint64_t material;
    float4 sv_position : SV_Position;
};

struct VertexInput {
    uint32_t vertID : SV_VertexID;
    uint32_t instanceID : SV_InstanceID;
}

[shader("vertex")]
FragmentData vertexMain(VertexInput input)
{
    DrawCommand draw = draw_cmds[push_constant.draw_index];
    Vertex vertex = vertices[input.vertID];

    float4x4 skin_matrix = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    };

    if (draw.skin_data != nullptr)
    {
        skin_matrix =
            vertex.skin_weight[0] * draw.skin_data[vertex.skin_pos[0]] +
            vertex.skin_weight[1] * draw.skin_data[vertex.skin_pos[1]] +
            vertex.skin_weight[2] * draw.skin_data[vertex.skin_pos[2]] +
            vertex.skin_weight[3] * draw.skin_data[vertex.skin_pos[3]];
    }

    float4x4 node_matrix = mul(draw.node_matrix, skin_matrix);

    if (input.instanceID > 0) {
        node_matrix = mul(node_matrix, draw.instances[input.instanceID]);
    }

    float4 frag_pos = mul(node_matrix, float4(vertex.position.xyz, 1.0));
    float4 vertex_pos = mul(mul(perspective, view), frag_pos);

    FragmentData output = {
        vertex.tex_cord.xy,
        (uint64_t)draw.material,
        vertex_pos
    };

    return output;
}

// Fragment Shader
[shader("fragment")]
float4 fragmentMain(FragmentData input)
    : SV_Target
{
    Material* material = (Material*)input.material;

    if (material != nullptr)
    {
       return image_samplers[material.baseColorTexture].Sample(input.tex_cord) * material.baseColorFactor;
    }

    return float4(0.5, 0.5, 0.5, 1.0);
}