// Shader written in Slang https://github.com/shader-slang/slang

static float PI = 3.14159265358979323846;

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

    float4 illuminate(Material material, FragmentData input)
    {
        float3 eye = uniform.eye.xyz;
        float3 normal = material.getNormal(input.tex_cord, input.tbn);
        float4 emissive = material.getEmissive(input.tex_cord);
        float4 metallic_r = material.getMetallicRoughness(input.tex_cord);
        float4 diffuse = material.getBaseColor(input.tex_cord);
        float4 ambient_occlusion = material.getOcclusion(input.tex_cord);
  
        float roughness = metallic_r.g;
        float metallic = metallic_r.b;
        
        float3 F0 = 0.04 * (1.0 - metallic) + diffuse.rgb * metallic;
        float3 V = normalize(eye - input.sv_position.xyz);

        switch (type)
        {
            // Directional
            case 0:
            case 1:
            {
                float3 L = normalize(position.xyz - input.sv_position.xyz);
                float3 H = normalize(V + L);

                float distance    = length(position - input.sv_position);
                float attenuation = 1.0 / (distance * distance);
                float3 radiance     = color.rgb;

                float NDF = DistributionGGX(normal, H, roughness);        
                float G   = GeometrySmith(normal, V, L, roughness);      
                float3 F  = fresnelSchlick(max(dot(H, V), 0.0), F0);
               
                float3 kS = F;
                float3 kD = float3(1.0) - kS;
                kD *= 1.0 - metallic;
                       
                float3 numerator    = NDF * G * F;
                float denominator = 4.0 * max(dot(normal, V), 0.0) * max(dot(normal, L), 0.0) + 0.0001;
                float3 specular     = numerator / denominator; 
                float NdotL = max(dot(normal, L), 0.0);      
                return diffuse;
            }
            case 2:
            {
                return color;
            }
        }
        return color;
    }
};

float3 fresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
} 

float DistributionGGX(float3 N, float3 H, float roughness)
{
    float a      = roughness*roughness;
    float a2     = a*a;
    float NdotH  = max(dot(N, H), 0.0);
    float NdotH2 = NdotH*NdotH;
	
    float num   = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
	
    return num / denom;
}

float GeometrySchlickGGX(float NdotV, float roughness)
{
    float r = (roughness + 1.0);
    float k = (r*r) / 8.0;

    float num   = NdotV;
    float denom = NdotV * (1.0 - k) + k;
	
    return num / denom;
}
float GeometrySmith(float3 N, float3 V, float3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2  = GeometrySchlickGGX(NdotV, roughness);
    float ggx1  = GeometrySchlickGGX(NdotL, roughness);
	
    return ggx1 * ggx2;
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

        return float4(1.0);
    }

    float4 getMetallicRoughness(float2 tex_pos)
    {
        if (metallicRoughnessTexture.can_sample())
        {
            return image_samplers[metallicRoughnessTexture.sampler].Sample(tex_pos) * roughnessFactor;
        }

        return float4(1.0);
    }

    float4 getEmissive(float2 tex_pos)
    {
        if (emissiveTexture.can_sample())
        {
            return image_samplers[emissiveTexture.sampler].Sample(tex_pos) * emissiveFactor;
        }

        return float4(1.0);
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
    float4x4 inverse_node_matrix;
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

    float4 color = float4(0.0, 0.0, 0.0, 0.0);
    // Calculate lights
    for (int i = 0; i < light_count; i++)
    {
        Light light = lights[i];

        float4 light_color;
        if (input.material_index >= 0)
        {
            Material material = materials[input.material_index];
            float4 diffuse_texture = material.getBaseColor(input.tex_cord);
            // float3 normal = material.getNormal(input.tex_cord, input.tbn);    

            if (diffuse_texture.a == 0.0)
                discard;

            // Diffuse light
            light_color = light.illuminate(material, input);     
        } else {
            light_color = float4(0.2, 0.2, 0.2, 1.0);
        }

        // Calculate shadow
        float4x4 light_view = light_matrices[i];
        float4 shadow_pos = mul(light_view, input.world_pos);
        shadow_pos = shadow_pos / shadow_pos.w;
        float3 shadow_cords = float3(shadow_pos.xy * float2(0.5, -0.5) + 0.5, shadow_pos.z);
        float4 occluderDepth = shadow_samplers[i].Sample(shadow_cords.xy);
        // Fix artifacts
        const bool outOfView = (shadow_cords.x < 0.001f || shadow_cords.x > 0.999f || shadow_cords.y < 0.001f || shadow_cords.y > 0.999f);
        float shadowFactor = shadow_cords.z < occluderDepth.x + 0.0005 || outOfView ? 1.0 : 0.3;

        color += light_color * shadowFactor;
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


