// Shader written in Slang https://github.com/shader-slang/slang

static float PI = 3.14159265358979323846;
static float ambient_constant = 0.4;

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

    float3 illuminate(Material material, FragmentData input)
    {
        float3 eye = uniform.eye.xyz;
        Optional<float3> normal = material.getNormal(input.tex_cord, input.tbn); 
        float4 albedo = material.getBaseColor(input.tex_cord);
        
        float4 metallic_r = material.getMetallicRoughness(input.tex_cord);
        float roughness = metallic_r.g;
        float metallic = metallic_r.b;
        
        float3 F0 = lerp(float3(0.4), albedo.rgb, metallic);
        float3 V = normalize(eye - input.world_pos.xyz);
        float3 L = normalize(position.xyz - input.world_pos.xyz);
        float3 H = normalize(V + L);

        if (normal.hasValue) {
            // float3 R = reflect(-V, normal.value);
            float NdotV = max(dot(normal.value, V), 0.00001);
            float NdotL = saturate(dot(normal.value, L));
            float NdotH = saturate(dot(normal.value, H));
            float VdotH = saturate(dot(H, V));

            float3 F = freshnel(F0, NdotV, NdotH);
            float D = distributionGGX(NdotH, roughness);
            float G = geomSmith(NdotV, roughness) * geomSmith(NdotL, roughness);
            float denominator = max(4.0 * NdotL * NdotV, 0.001);

            float3 cook_torrence_specular = D * F * G / denominator;

            float3 diffuse = (1.0 - F) * (1.0 - metallic) * albedo.rgb / PI;

            float3 light_intensity = float3(0.0);
            switch (type) {
                case 0: {
                    // Point
                    light_intensity = (color.rgb + (albedo.rgb * 0.2)) * (intensity * 0.0002);
                    break;
                }
                case 1: {
                    // Directional
                    light_intensity = (color.rgb + (albedo.rgb * 0.2)) * (intensity * 0.0002);
                    break;
                }
                case 2: {

                }
            }

            // float3 specular = pow(NdotH, 25);
         
            return (diffuse + cook_torrence_specular) * light_intensity * NdotL;
        }

        return albedo.rgb;
    }
};

float geomSmith(float Ndot, float alpha) {
    float k = pow(alpha + 1.0, 2) / 8.0;
	float d = Ndot * (1-k) + k;
	return Ndot / d;
}

float distributionGGX(float NdotH, float alpha) {
	float alpha4 = pow(alpha, 4);
	float d = NdotH * NdotH * (alpha4 - 1.0) + 1.0;
	return alpha4 / (PI * d * d);
}

float3 freshnel(float3 F0, float dotV, float dotH) {
    return F0 + (1.0 - F0) * pow((1 - dotV * dotH), 5.0);
}

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


    float4 getOcclusion(float2 tex_pos)
    {
        if (occlusionTexture.can_sample())
        {
            return image_samplers[occlusionTexture.sampler].Sample(tex_pos);
        }

        return float4(0.0);
    }

    float4 getMetallicRoughness(float2 tex_pos)
    {
        if (metallicRoughnessTexture.can_sample())
        {
            return image_samplers[metallicRoughnessTexture.sampler].Sample(tex_pos) * roughnessFactor;
        }

        return float4(0.0);
    }

    float4 getEmissive(float2 tex_pos)
    {
        if (emissiveTexture.can_sample())
        {
            return image_samplers[emissiveTexture.sampler].Sample(tex_pos) * emissiveFactor * emissiveStrength;
        }

        return float4(0.0);
    }

    Optional<float3> getNormal(float2 tex_pos, float3x3 tbn)
    {
        if (normalTexture.can_sample())
        {
            float4 normal_texture = image_samplers[normalTexture.sampler].Sample(tex_pos);
            return mul(tbn, normalize(normal_texture.xyz * 2.0 - 1.0));
        }
        return none;
    }
};


struct Vertex
{
    float4 position;
    float4 normal;
    float2 tex_cord;
    float2 pad;
    float4 tangent;
    uint4 skin_pos;
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

struct DrawCommand
{
    int material_index;
    int has_skin;
    uint instance_offset;
    float4x4 node_matrix;
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
    Vertex *vertices;
    DrawCommand *draw_data;
    float4x4 *instance_data;
    Light *lights;
    Material *materials;
    float4x4 *joints;
    float4x4 *light_matrices;
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
    float4 world_pos;
    float4 sv_position : SV_Position;
};

struct VertexInput
{
    uint32_t vertID : SV_VertexID;
    uint32_t drawID : SV_DrawIndex;
    uint32_t instanceID : SV_InstanceID;
}

[shader("vertex")]
FragmentData vertexMain(VertexInput input)
{
    DrawCommand instance = draw_data[input.drawID];
    Vertex vertex = vertices[input.vertID];

    float4x4 skin_matrix = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    };

    if (instance.has_skin > 0)
    {
        skin_matrix =
            vertex.skin_weight[0] * joints[vertex.skin_pos[0]] +
            vertex.skin_weight[1] * joints[vertex.skin_pos[1]] +
            vertex.skin_weight[2] * joints[vertex.skin_pos[2]] +
            vertex.skin_weight[3] * joints[vertex.skin_pos[3]];
    }

    float4x4 node_matrix = mul(instance.node_matrix, skin_matrix);
    // float4x4 inverse_matrix = mul(instance.inverse_node_matrix, skin_matrix);

    if (input.instanceID > 0) {
        node_matrix = mul(node_matrix, instance_data[instance.instance_offset + input.instanceID]);
    }

    float4 world_pos = mul(node_matrix, float4(vertex.position.xyz, 1.0));
    float4 vertex_pos = mul(mul(uniform.perspective, uniform.view), world_pos);

    float3 normal = normalize(mul(float3x3(instance.node_matrix), vertex.normal.xyz));
    float3 tangent = normalize(mul(float3x3(instance.node_matrix), vertex.tangent.xyz));
    float3 bitangent = cross(normal, tangent) * vertex.tangent.w;
    float3x3 tbn = transpose(float3x3(tangent, bitangent, normal));

    FragmentData output = {
        vertex.tex_cord,
        instance.material_index,
        tbn,
        normal.xyz,
        world_pos,
        vertex_pos / vertex_pos.w
    };

    return output;
}

// Fragment Shader
[shader("fragment")]
float4 fragmentMain(FragmentData input)
    : SV_Target
{
    Optional<Material> material;
    float4 color = float4(0.0, 0.0, 0.0, 0.0);

    if (input.material_index >= 0) material = materials[input.material_index];

    if (material.hasValue) {
        float4 albedo = material.value.getBaseColor(input.tex_cord);
        if (albedo.a == 0.0) discard;

        float4 emissive = material.value.getEmissive(input.tex_cord);
        float4 ambient_occlusion = material.value.getOcclusion(input.tex_cord);
        float3 ambient = albedo.rgb * float3(ambient_constant);

        color += emissive + float4(ambient, 1.0);
    }

    // Calculate lights
    for (int i = 0; i < light_count; i++)
    {
        Light light = lights[i];

        if (material.hasValue) {
            light.color.rgb = light.illuminate(material.value, input);
        }
        
        // Calculate shadow
        float4x4 light_view = light_matrices[i];
        float4 shadow_pos = mul(light_view, input.world_pos);
        shadow_pos = shadow_pos / shadow_pos.w;
        float3 shadow_cords = float3(shadow_pos.xy * float2(0.5, -0.5) + 0.5, shadow_pos.z);
        float4 occluderDepth = shadow_samplers[i].Sample(shadow_cords.xy);

        // Fix artifacts
        const bool outOfView = (shadow_cords.x < 0.001f || shadow_cords.x > 0.999f || shadow_cords.y < 0.001f || shadow_cords.y > 0.999f);
        float shadowFactor = shadow_cords.z < occluderDepth.x + 0.0001 || outOfView ? 1.0 : 0.4;
        color += float4(light.color.rgb * shadowFactor, 1.0) ;
    }

    return color;
}

struct ShadowData
{
    float4 sv_position : SV_Position;
};

[shader("vertex")]
ShadowData vertexShadow(VertexInput input)
{
    DrawCommand instance = draw_data[input.drawID];
    Vertex vertex = vertices[input.vertID];

    float4x4 skin_matrix = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    };

    if (instance.has_skin > 0)
    {
        skin_matrix =
            vertex.skin_weight[0] * joints[vertex.skin_pos[0]] +
            vertex.skin_weight[1] * joints[vertex.skin_pos[1]] +
            vertex.skin_weight[2] * joints[vertex.skin_pos[2]] +
            vertex.skin_weight[3] * joints[vertex.skin_pos[3]];
    }

    float4x4 node_matrix = mul(instance.node_matrix, skin_matrix);
    float4x4 light_view = light_matrices[push_constant.light_index];

    if (input.instanceID > 0) {
        node_matrix = mul(node_matrix, instance_data[instance.instance_offset + input.instanceID]);
    }

    float4 frag_pos = mul(mul(node_matrix, skin_matrix), float4(vertex.position.xyz, 1.0));

    return {
        mul(light_view, frag_pos)
    };
}


