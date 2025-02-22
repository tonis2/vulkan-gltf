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

        switch (type)
        {
            // Directional
            case 0:
            case 1:
            {
                float3 v = normalize(eye - input.sv_position.xyz);
                float3 l = normalize(position.xyz - input.sv_position.xyz);
                float3 h = normalize(v + l);
                float3 r = normalize(reflect(eye - input.sv_position.xyz, normal));

                float NoV = abs(dot(normal, l));
                float NoL = saturate(dot(normal, l));
                float NoH = saturate(dot(normal, h));
                float LoH = saturate(dot(l, h));

                float3 specularColor = lerp(float3(0.4), diffuse.rgb, 0.0);

                float3 ambient = 0.01 * color.rgb;
                
                float3 f0 = 0.04 * (1.0 - metallic) + diffuse.rgb * metallic;   
                float D = D_GGX(roughness, NoH, h);

                float V = V_SmithGGXCorrelated(roughness, NoV, NoL);
                float3  F = F_Schlick(f0, LoH);
                float3 Fr = (D * V) * F;
                float3 Fd = diffuse.rgb * Fd_Burley(roughness, NoV, NoL, LoH);

                return float4(ambient_occlusion.r * (ambient + emissive.rgb + F), diffuse.a);
            }
            case 2:
            {
                return color;
            }
        }
        return color;
    }
};

float D_GGX(float linearRoughness, float NoH, float3 h) {
    // Walter et al. 2007, "Microfacet Models for Refraction through Rough Surfaces"
    float oneMinusNoHSquared = 1.0 - NoH * NoH;
    float a = NoH * linearRoughness;
    float k = linearRoughness / (oneMinusNoHSquared + a * a);
    float d = k * k * (1.0 / PI);
    return d;
}

float V_SmithGGXCorrelated(float linearRoughness, float NoV, float NoL) {
    // Heitz 2014, "Understanding the Masking-Shadowing Function in Microfacet-Based BRDFs"
    float a2 = linearRoughness * linearRoughness;
    float GGXV = NoL * sqrt((NoV - a2 * NoV) * NoV + a2);
    float GGXL = NoV * sqrt((NoL - a2 * NoL) * NoL + a2);
    return 0.5 / (GGXV + GGXL);
}

float3 F_Schlick(const float3 f0, float VoH) {
    // Schlick 1994, "An Inexpensive BRDF Model for Physically-Based Rendering"
    return f0 + (float3(1.0) - f0) * pow(1.0 - VoH, 5);
}

float F_Schlick(float f0, float f90, float VoH) {
    return f0 + (f90 - f0) * pow(1.0 - VoH, 5);
}

float Fd_Burley(float linearRoughness, float NoV, float NoL, float LoH) {
    // Burley 2012, "Physically-Based Shading at Disney"
    float f90 = 0.5 + 2.0 * linearRoughness * LoH * LoH;
    float lightScatter = F_Schlick(1.0, f90, NoL);
    float viewScatter  = F_Schlick(1.0, f90, NoV);
    return lightScatter * viewScatter * (1.0 / PI);
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


