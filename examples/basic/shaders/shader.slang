// Shader written in Slang https://github.com/shader-slang/slang

struct JointBuffer {
  float4x4 matrix;
};

struct PushData {
    float4x4 model_matrix;
    int material_index;
    bool has_skin;
    uniform StructuredBuffer<JointBuffer> joint_buffer;
};

[[vk::push_constant]]
ConstantBuffer<PushData> push_constant;

// Uniform data to be passed from application -> shader.

[[vk::binding(0, 0)]] 
cbuffer Uniforms
{
    float4x4 projection;
    float4x4 view;
}


// Per-vertex attributes to be assembled from bound vertex buffers.
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

// Vertex Shader
struct VertexOutPut
{
    FragmentData vertex_input;
    float4 sv_position : SV_Position;
};

// Frag shader
struct Texture {
    int samp;
    int source;
};

[[vk::binding(1, 0)]] 
cbuffer MaterialBuffer
{
   Material materials[4];
}

[[vk::binding(2, 0)]] 
uniform Sampler2D materialSamplers[];

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


[shader("vertex")]
VertexOutPut vertexMain(VertexInput input)
{
    float4x4 skin_matrix = float4x4(1);

    if (push_constant.has_skin) {
        skin_matrix =
             input.skin_weight[0] * push_constant.joint_buffer[uint(input.skin_pos[0])].matrix +
             input.skin_weight[1] * push_constant.joint_buffer[uint(input.skin_pos[1])].matrix +
             input.skin_weight[2] * push_constant.joint_buffer[uint(input.skin_pos[2])].matrix +
             input.skin_weight[3] * push_constant.joint_buffer[uint(input.skin_pos[3])].matrix;
        
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
        material = materials[input.material_index];
        return material.getBaseColor(input.tex_cord);
    }

    return color;
}