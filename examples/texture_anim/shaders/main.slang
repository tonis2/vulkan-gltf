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

    float4 illuminate(Material material, FragmentData input, float3 eye) {
        float3 normal = material.getNormal(input.tex_cord, input.tbn);
        float3 L = position.xyz - input.frag_pos;

        switch (type) {
            //Directional
            case 0: {
                float3 lightDir = normalize(position.xyz - input.frag_pos); 
                float3 eyeDirection = normalize(eye - input.frag_pos);
                float4 scatteredLight = float4(float3(0.2), 1.0);
                float3 reflectedVector = reflect(-lightDir.xyz, normal);

                float diffuseFactor = max(dot(normal, lightDir), 0); 
                float specularFactor = pow(max(dot(reflectedVector, eyeDirection), 0.0), 0.5); 
                return (scatteredLight * color) + (diffuseFactor * color) + (specularFactor * color);
            }
            case 1: {
               let lightSqrDist = dot(L, L);
               let lightDirVS = L * rsqrt(lightSqrDist);
               float lambert = intensity * 0.002 * max(dot(lightDirVS, normal), 0.0) / lightSqrDist;
               return lambert * color;
            }   
            case 2: {
                return color;
            }
        }
        return color;
    }
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
        if (normalTexture.can_sample())
        {
            float4 normal_texture = image_samplers[normalTexture.sampler].Sample(tex_pos);
            return mul(tbn, normalize(normal_texture.xyz * 2.0 - 1.0));
        }
        return float3(1.0);
    }
};

public typealias u8vec4 = vector<uint8_t, 4>;

struct Vertex
{
    float3 position;
    float3 normal;
    float2 tex_cord;
    float4 tangent;
    float4 bitangent;
    u8vec4 skin_pos;
    float4 skin_weight;

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


struct Instance
{
    int material_index;
    int has_skin;
    float4x4 node_matrix;
    float4x4 inverse_node_matrix;

    float3* positions;
    float3* normals;
    float2* text_cords;
    float4* tangents;
    u8vec4* skin_pos;
    float4* weights;

    // Instance data
    float3* translate;
    float4* rotate;
    float3* scale;

    Vertex get_vertex(uint index) {
        float4 tangent = tangents[index];
        float3 normal = normals[index];
        return {
            positions[index],
            normal,
            text_cords[index],
            tangent,
            {mul(cross(tangent.xyz, normal), tangent.w), 1.0},
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

struct PushData
{
    uint light_index;
};

[vk_push_constant]
const PushData push_constant;

[vk_binding(0)]
cbuffer Buffers
{
    Light *lights;
    Material *materials;
    float4x4 *joints;
    float4x4 *light_matrices;
    Instance *instances;
    Uniform *uniform;
    uint light_count;
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
    float3x3 tbn;
    float3 normal;
    float3 frag_pos;
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

    if (input.instanceID > 0) {
        float3 translation = instance.translate[input.instanceID];
        float3 scale = instance.scale[input.instanceID];
        float4x4 instance_matrix = {
            1.0, 0, 0, translation.x,
            0, 1.0, 0, translation.y,
            0, 0, 1.0, translation.z,
            0, 0, 0, 1
        };
        node_matrix = mul(node_matrix, instance_matrix);
    }

    float4 frag_pos = mul(node_matrix, float4(vertex.position.xyz, 1.0));
    float4 vertex_pos = mul(mul(uniform.perspective, uniform.view), frag_pos);
    //float4x4 inverse_matrix = mul(instance.inverse_node_matrix, skin_matrix);

    float4 normal = normalize(mul(instance.inverse_node_matrix, float4(vertex.normal, 1.0)));
    float4 tangent = normalize(mul(instance.inverse_node_matrix, vertex.tangent));
    float4 bitangent = normalize(mul(instance.inverse_node_matrix, vertex.bitangent));
    float3x3 tbn = float3x3(tangent.xyz, bitangent.xyz, normal.xyz);

    FragmentData output = {
        vertex.transformed_tex_pos(materials[instance.material_index]),
        instance.material_index,
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
    Material material = materials[input.material_index];
    float4 diffuse_texture = material.getBaseColor(input.tex_cord);
    if (input.material_index >= 0)
    {
        Material material = materials[input.material_index];
        float4 diffuse_texture = material.getBaseColor(input.tex_cord);
 
        float3 light_factor = float3(0.0);

        if (diffuse_texture.a == 0.0)
            discard;

        // Calculate lights
        for (int i = 0; i < light_count; i++)
        {
            Light light = lights[i];

            // Diffuse light
            float4 color = light.illuminate(material, input, uniform.eye.xyz);

            // Calculate shadow
            float4x4 light_view = light_matrices[i];
            float4 shadow_pos = mul(light_view, float4(input.frag_pos, 1.0));
            shadow_pos = shadow_pos / shadow_pos.w;
            float3 shadow_cords = float3(
                shadow_pos.xy * float2(0.5, -0.5) + 0.5,
                shadow_pos.z);

            float4 occluderDepth = shadow_samplers[i].Sample(shadow_cords.xy);
            // Fix artifacts
            const bool outOfView = (shadow_cords.x < 0.001f || shadow_cords.x > 0.999f || shadow_cords.y < 0.001f || shadow_cords.y > 0.999f);
            float shadowFactor = shadow_cords.z < occluderDepth.x + 0.0005 || outOfView ? 1.0 : 0.3;

            light_factor += (color.rgb ) * shadowFactor;
        }

        return diffuse_texture * float4(light_factor, 1.0);
    }

    return float4(0.5, 0.5, 0.5, 1.0);
}

struct ShadowData
{
    float4 sv_position : SV_Position;
};

[shader("vertex")]
ShadowData vertexShadow(VertexInput input)
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

    float4x4 light_view = light_matrices[push_constant.light_index];
    float4 frag_pos = mul(mul(instance.node_matrix, skin_matrix), float4(vertex.position.xyz, 1.0));

    return {
        mul(light_view, frag_pos)
    };
}

// float4 qmul(float4 q1, float4 q2)
// {
//     return float4(
//         q2.xyz * q1.w + q1.xyz * q2.w + cross(q1.xyz, q2.xyz),
//         q1.w * q2.w - dot(q1.xyz, q2.xyz)
//     );
// }

// // Vector rotation with a quaternion
// // http://mathworld.wolfram.com/Quaternion.html
// float3 rotate_vector(float3 v, float4 r)
// {
//     float4 r_c = r * float4(-1, -1, -1, 1);
//     return qmul(r, qmul(float4(v, 0), r_c)).xyz;
// }