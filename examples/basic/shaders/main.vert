#version 450

layout(location = 0) in vec3 vp;
layout(location = 1) in vec2 v_texcord;

layout(location = 0) out vec2 o_texcord;
layout(location = 1) out flat int o_m_index;

layout(binding = 0) uniform uniform_matrix
{
  mat4 projection;
  mat4 view;
};

layout( push_constant ) uniform constants
{
    mat4 model_matrix;
    int material_index;
};

void main() {
    o_m_index = material_index;
    o_texcord = v_texcord;
    gl_Position = projection * view * model_matrix * vec4(vp, 1.0);
}