#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : enable
#extension GL_EXT_scalar_block_layout : require

layout(location = 0) out vec2 o_texcord;
layout(location = 1) out flat int o_m_index;
layout(location = 2) out flat uint64_t materials;


layout(buffer_reference, std140, buffer_reference_align = 4) readonly buffer JointBuffer {
  mat4 matrix;
};

layout(binding = 0) uniform uniform_matrix
{
  mat4 projection;
  mat4 view;
};

layout(buffer_reference, std140) readonly buffer VertexBuffer {
  vec3 position;
  vec2 tex_cord;
  vec4 skin_pos;
  vec4 skin_weight;
};

layout( push_constant ) uniform constants
{
    mat4 model_matrix;
    int material_index;
    bool has_skin;
    JointBuffer joint_buffer;
    uint64_t material_buffer;
    VertexBuffer vertex_buffer;
};



void main() {
    VertexBuffer vertex = vertex_buffer[gl_VertexIndex];

    mat4 skin_matrix = mat4(1);

    if (has_skin) {
        skin_matrix =
             vertex.skin_weight[0] * joint_buffer[uint(vertex.skin_pos[0])].matrix +
             vertex.skin_weight[1] * joint_buffer[uint(vertex.skin_pos[1])].matrix +
             vertex.skin_weight[2] * joint_buffer[uint(vertex.skin_pos[2])].matrix +
             vertex.skin_weight[3] * joint_buffer[uint(vertex.skin_pos[3])].matrix;
        
    }

    o_m_index = material_index;
    o_texcord = vertex.tex_cord;
    materials = material_buffer;

    gl_Position = projection * view * model_matrix * skin_matrix * vec4(vertex.position, 1.0);
}