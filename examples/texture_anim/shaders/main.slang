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
        if (baseColorTexture.sampler >= 0)
        {
            return image_samplers[baseColorTexture.sampler].Sample(tex_pos) * baseColorFactor;
        }

        return baseColorFactor;
    }

    float3 getNormal(float2 tex_pos, float3x3 tbn)
    {
        float4 normal_texture = image_samplers[normalTexture.sampler].Sample(tex_pos);
        return mul(tbn, normalize(normal_texture.xyz * 2.0 - 1.0));
    }
};

struct PushData
{
    float4x4 model_matrix;
    float4x4 model_inverse;
    int material_index;
    bool has_skin;
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
    Vertex *vertices;
    Light *lights;
    Uniform *uniform;
    Material *materials;
    float4x4 *joints;
    uint light_count;
}

[vk_binding(1)]
uniform Sampler2D image_samplers[];

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

    float4 frag_pos = mul(mul(push_constant.model_matrix, skin_matrix), float4(vertex.position.xyz, 1.0));
    float4 vertex_pos = mul(mul(uniform.projection, uniform.view), frag_pos);

    float4 normal = normalize(mul(push_constant.model_inverse, vertex.normal));
    float4 tangent = normalize(mul(push_constant.model_inverse, vertex.tangent));
    float4 bitangent = normalize(mul(push_constant.model_inverse, float4(cross(normal.xyz, tangent.xyz) * tangent.w, 0.0)));
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
    Material material;
    float4 diffuse_color = float4(0.4, 0.3, 0.3, 1.0);
    float4 specular_color = float4(0.0, 0.0, 0.0, 0.0);

    if (input.material_index >= 0)
    {
        material = materials[input.material_index];
        diffuse_color = material.getBaseColor(input.tex_cord);
    }

    if (diffuse_color.a == 0.0)
        discard;

    // Calculate lights
    for (int i = 0; i < light_count; i++)
    {
        Light light = lights[i];
        float3 lightDirection = light.position.xyz - input.frag_pos.xyz * light.position.w;
        float3 lightDirectionNormal = normalize(lightDirection);
        float3 normal = material.normalTexture.sampler >= 0 ? material.getNormal(input.tex_cord, input.tbn) : input.normal;
        float lambert = max(0.0, dot(normal, lightDirectionNormal));
    
        float lightDistance = length(lightDirection);
        float3 eyeDirection = normalize(-input.sv_position.xyz);
        float4 diffuseTemp = float4(clamp(diffuse_color.rgb * light.color.rgb * lambert, 0, 1), diffuse_color.a);

        float3 reflectedDirection = normalize(-reflect(lightDirectionNormal, normal));
        float specularIntensity = max(dot(reflectedDirection, eyeDirection), 0);
        float4 specularTemp = clamp(diffuse_color * float4(light.color.rgb, 1.0) * pow(specularIntensity, material.emissiveStrength), 0, 1);

        float constantAttenuation = 1;
        float linearAttenuation = 0;
        float quadraticAttenuation = 0;
        float attenuation =
            1 / (constantAttenuation + linearAttenuation * lightDistance + quadraticAttenuation * (lightDistance * lightDistance));

        diffuseTemp.rgb *= attenuation;
        specularTemp.rgb *= attenuation;

        diffuse_color += diffuseTemp;

        specular_color += specularTemp;
    }

    return diffuse_color + specular_color * material.emissiveFactor;
}
