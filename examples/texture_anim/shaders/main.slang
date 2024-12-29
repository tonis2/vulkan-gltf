// Shader written in Slang https://github.com/shader-slang/slang

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
};

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

    float3 getNormal(float2 tex_pos, float3x3 tbn)
    {
        if (normalTexture.can_sample()) {
            float4 normal_texture = image_samplers[normalTexture.sampler].Sample(tex_pos);
            return mul(tbn, normalize(normal_texture.xyz * 2.0 - 1.0));
        }
        return float3(1.0);
    }
};

struct PushData
{
    int material_index;
    bool has_skin;
    uint light_index;
    Uniform *uniform;
};

struct Uniform
{
    float4x4 perspective;
    float4x4 view;
    float4 eye;
    float4x4 node_matrix;
    float4x4 node_inverse_matrix;
}

[vk_push_constant]
const PushData push_constant;

[vk_binding(0)]
cbuffer Buffers
{
    Vertex *vertices;
    Light *lights;
    Material *materials;
    float4x4 *joints;
    float4x4 *light_matrices;
    uint light_count;
}

[vk_binding(1)]
uniform Sampler2D image_samplers[];

[vk_binding(2)]
uniform Sampler2D shadow_samplers[];

struct Vertex
{
    float4 position;
    float4 normal;
    float4 tangent;
    float4 skin_pos;
    float4 skin_weight;
    float2 tex_cord;
    float2 pad;

    float2 transformed_tex_pos(Material material)
    {
        TextureInfo texture_info = material.baseColorTexture;

        float3x3 translation_matrix = {
            texture_info.scale.x,
            0,
            texture_info.offset.x,
            0,
            texture_info.scale.y,
            texture_info.offset.y,
            0,
            0,
            1,
        };

        float3x3 rotation = float3x3(
            cos(texture_info.rotation), sin(texture_info.rotation), 0,
            -sin(texture_info.rotation), cos(texture_info.rotation), 0,
            0, 0, 1);

        // translation_matrix = mul(mul(translation_matrix, rotation), scale);

        return mul(translation_matrix, float3(tex_cord, 1.0)).xy;
    }
};

// Output of the fragment shader
struct FragmentData
{
    float2 tex_cord;
    int material_index;
    float3x3 tbn;
    float3 normal;
    float3 frag_pos;
    float4 sv_position : SV_Position;
};

[shader("vertex")]
FragmentData vertexMain(uint32_t vertID: SV_VertexID)
{
    Vertex vertex = vertices[vertID];
    float4x4 skin_matrix = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    };

    if (push_constant.has_skin)
    {
        skin_matrix =
            vertex.skin_weight[0] * joints[uint(vertex.skin_pos[0])] +
            vertex.skin_weight[1] * joints[uint(vertex.skin_pos[1])] +
            vertex.skin_weight[2] * joints[uint(vertex.skin_pos[2])] +
            vertex.skin_weight[3] * joints[uint(vertex.skin_pos[3])];
    }

    Uniform* uniform = push_constant.uniform;
    float4 frag_pos = mul(mul(uniform.node_matrix, skin_matrix), float4(vertex.position.xyz, 1.0));
    float4 vertex_pos = mul(mul(uniform.perspective, uniform.view), frag_pos);

    float4 normal = normalize(mul(uniform.node_inverse_matrix, vertex.normal));
    float4 tangent = normalize(mul(uniform.node_inverse_matrix, vertex.tangent));
    float4 bitangent = normalize(mul(uniform.node_inverse_matrix, float4(cross(normal.xyz, tangent.xyz) * tangent.w, 0.0)));
    float3x3 tbn = float3x3(tangent.xyz, bitangent.xyz, normal.xyz);

    FragmentData output = {
        vertex.transformed_tex_pos(materials[push_constant.material_index]),
        push_constant.material_index,
        tbn,
        normal.xyz,
        frag_pos.xyz,
        vertex_pos
    };

    return output;
}

// Fragment Shader
[shader("fragment")]
float4 fragmentMain(FragmentData input)
    : SV_Target
{

    Uniform *uniform = push_constant.uniform;

    if (input.material_index >= 0)
    {
        Material material = materials[input.material_index];
        float4 diffuse_texture = material.getBaseColor(input.tex_cord);
        float3 normal_texture = material.getNormal(input.tex_cord, input.tbn);

        if (diffuse_texture.a == 0.0)
            discard;

        // Calculate lights
        for (int i = 0; i < light_count; i++)
        {
            Light light = lights[i];
            float3 light_dir = normalize(light.position.xyz - input.frag_pos.xyz);
            float3 eye = normalize(-input.frag_pos.xyz);

            float3 halfway = normalize(light_dir + eye);
            float specularIntensity = max(0.0, dot(normal_texture, halfway));

            float4 diffuseTemp = float4(clamp(diffuse_texture.rgb * light.color.rgb * specularIntensity, 0, 1), diffuse_texture.a);
            float4 specularTemp = clamp(diffuse_texture * float4(light.color.rgb, 1.0) * pow(specularIntensity, material.emissiveStrength), 0, 1);

            // Shadow color
            float4x4 light_view = light_matrices[i];
            float4 shadow_pos = mul(light_view, float4(input.frag_pos, 1.0));

            float3 posLightSpace = shadow_pos.xyz / shadow_pos.w;
            float2 shadowCords = posLightSpace.xy * 0.5 + 0.5;

            float4 occluderDepth = shadow_samplers[i].Sample(shadowCords.xy);
            float shadowFactor = occluderDepth.x + 0.001 > posLightSpace.z ? 1.0 : 0.0;

            // ambient += ambient_light;
            diffuse_texture += diffuseTemp * shadowFactor;
            // light_color *= shadowFactor;
        }

        return diffuse_texture;
    }

    return float4(1.0);
}

struct ShadowData
{
    float4 sv_position : SV_Position;
};

[shader("vertex")]
ShadowData vertexShadow(uint32_t vertID: SV_VertexID)
{
    Vertex vertex = vertices[vertID];
    float4x4 skin_matrix = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    };

    Uniform* uniform = push_constant.uniform;

    if (push_constant.has_skin)
    {
        skin_matrix =
            vertex.skin_weight[0] * joints[uint(vertex.skin_pos[0])] +
            vertex.skin_weight[1] * joints[uint(vertex.skin_pos[1])] +
            vertex.skin_weight[2] * joints[uint(vertex.skin_pos[2])] +
            vertex.skin_weight[3] * joints[uint(vertex.skin_pos[3])];
    }

    float4x4 light_view = light_matrices[push_constant.light_index];

    float4 frag_pos = mul(mul(uniform.node_matrix, skin_matrix), float4(vertex.position.xyz, 1.0));

    return {
        mul(light_view, frag_pos)
    };
}
