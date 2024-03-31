#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int8 : require
#extension GL_GOOGLE_include_directive : require

#include "types.glsl"

layout( push_constant ) uniform constants
{
    mat4 model_matrix;
    JointBuffer joint_buffer;
    int material_index;
    int8_t has_skin;
};


// Shader out values
layout(location = 0) out int m_index;
layout(location = 1) out vec2 o_tex_cord;
layout(location = 2) out vec3 o_position;


void main() {
    VertexBuffer vertex = vertex_buffer[gl_VertexIndex];

    vec3 v_position = vertex.position;
    mat4 skin_matrix = mat4(1);

    // for (uint i = 0; i < morph_count; i++) {
    //     uint offset = morph_start + (i * morph_offset) + gl_VertexIndex;
    //     v_position += vertex_buffer[offset].position * morph_weights[i];
    // }

    if (has_skin >= 0) {
        skin_matrix =
             vertex.skin_weight[0] * joint_buffer[uint(vertex.skin_pos[0])].matrix +
             vertex.skin_weight[1] * joint_buffer[uint(vertex.skin_pos[1])].matrix +
             vertex.skin_weight[2] * joint_buffer[uint(vertex.skin_pos[2])].matrix +
             vertex.skin_weight[3] * joint_buffer[uint(vertex.skin_pos[3])].matrix;
        
    }

    m_index = material_index;
    o_position = vec3(model_matrix * vec4(v_position, 1.0));
    o_tex_cord = vertex.tex_cord;
    
    gl_Position = uniform_buffer.projection * uniform_buffer.view * model_matrix * skin_matrix * vec4(v_position, 1.0);
}