#version 450
#extension GL_EXT_buffer_reference2 : require

layout(location = 0) in vec3 vp;
layout(location = 1) in vec2 v_texcord;
layout(location = 2) in vec4 skin_pos;
layout(location = 3) in vec4 skin_weight;

layout(location = 0) out vec2 o_texcord;
layout(location = 1) out flat int o_m_index;


layout(buffer_reference, std140, buffer_reference_align = 4) readonly buffer JointBuffer {
  mat4 matrix;
};

layout(binding = 0) uniform uniform_matrix
{
  mat4 projection;
  mat4 view;
};

layout( push_constant ) uniform constants
{
    mat4 model_matrix;
    int material_index;
    bool has_skin;
    JointBuffer joint_buffer;
};


void main() {

    mat4 skin_matrix = mat4(1);

    if (has_skin) {
        skin_matrix =
             skin_weight[0] * joint_buffer[uint(skin_pos[0])].matrix +
             skin_weight[1] * joint_buffer[uint(skin_pos[1])].matrix +
             skin_weight[2] * joint_buffer[uint(skin_pos[2])].matrix +
             skin_weight[3] * joint_buffer[uint(skin_pos[3])].matrix;
        
    }

    o_m_index = material_index;
    o_texcord = v_texcord;
    gl_Position = projection * view * model_matrix * skin_matrix * vec4(vp, 1.0);
}