// Shader written in Slang https://github.com/shader-slang/slang

struct Uniform
{
    float4x4 projection;
    float4x4 view;
    float3 eye;
}

struct Vertex
{
    float3 position;
};

struct PushData {
    float4x4 model_matrix;
    Vertex* vertices;
    Uniform* uniform;
};

[vk_push_constant]
const PushData push_constant;

[vk_binding(0)]
uniform SamplerCube cube_texture;

struct VertexOutPut
{
    float3 outUVW;
    float4 sv_position : SV_Position;
};

[shader("vertex")]
VertexOutPut vertexMain(uint32_t vertID: SV_VertexID)
{
    Vertex vertex = push_constant.vertices[vertID];

    float4x4 view = float4x4(
        push_constant.uniform.view._m00, push_constant.uniform.view._m01, push_constant.uniform.view._m02, 0,
        push_constant.uniform.view._m10, push_constant.uniform.view._m11, push_constant.uniform.view._m12, 0,
        push_constant.uniform.view._m20, push_constant.uniform.view._m21, push_constant.uniform.view._m22, 0,
        0, 0, 0, 1,
    );

    // vertex.position.xy *= -1.0;
    vertex.position.x = -vertex.position.x;
    float4 pos = mul(mul(mul(push_constant.uniform.projection, view), push_constant.model_matrix), float4(vertex.position, 1.0));    
    VertexOutPut output = {
        vertex.position,
        pos.xyww,
    };
    return output;
}

// Fragment Shader
[shader("fragment")]
float4 fragmentMain(float3 uvw) : SV_Target
{
    return cube_texture.Sample(uvw);
}