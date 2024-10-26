// Shader written in Slang https://github.com/shader-slang/slang
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
    float4 emissiveFactor;
    float4 baseColorFactor;
    Texture normalTexture;
    Texture occlusionTexture;
    Texture emissiveTexture;
    Texture baseColorTexture;
    Texture metallicRoughnessTexture;
    
    float4 getBaseColor(float2 tex_pos) {
        if (baseColorTexture.source >= 0) {
            return materialSamplers[baseColorTexture.source].Sample(tex_pos) * baseColorFactor;
        }

        return baseColorFactor;
    }
};

struct PushData {
    float4x4 model_matrix;
    int material_index;
    bool has_skin;
    float4x4* joints;
    Material* materials;
};

[vk_push_constant]
const PushData push_constant;

[vk_binding(0)]
cbuffer Uniforms
{
    float4x4 projection;
    float4x4 view;
}

[vk_binding(1)]
uniform Sampler2D materialSamplers[];


struct VertexInput
{
    float3	position;
    float2	tex_cord;
    float4	skin_pos;
    float4	skin_weight;
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
VertexOutPut vertexMain(VertexInput input)
{
    float4x4 skin_matrix = float4x4(1);

    if (push_constant.has_skin) {
        skin_matrix =
             input.skin_weight[0] * push_constant.joints[uint(input.skin_pos[0])] +
             input.skin_weight[1] * push_constant.joints[uint(input.skin_pos[1])] +
             input.skin_weight[2] * push_constant.joints[uint(input.skin_pos[2])] +
             input.skin_weight[3] * push_constant.joints[uint(input.skin_pos[3])];
        
    }

    VertexOutPut output = {
        {
            input.tex_cord,
            push_constant.material_index,
        },
        mul(mul(mul(projection, view), push_constant.model_matrix), float4(input.position, 1.0))
    };

    return output;
}

// Fragment Shader
[shader("fragment")]
float4 fragmentMain(FragmentData input) : SV_Target
{
    Material material;
    float4 color = float4(0.5, 0.5, 0.5, 1.0);

    if (input.material_index >= 0) {
        material = push_constant.materials[input.material_index];
        return material.getBaseColor(input.tex_cord);
    }

    return color;
}