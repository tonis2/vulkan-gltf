#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require

layout (binding = 0) uniform uniform_matrix
{
  mat4 ortho;
};

layout (buffer_reference, scalar, buffer_reference_align = 4) readonly buffer VertexBuffer {
    vec2 pos;
    // vec2 dir;
    // uint type;
    // float thickness;
    // vec4 color;
};

layout( push_constant ) uniform constants
{
    mat4 model_matrix;
    VertexBuffer vertex_buffer;
};

void main() {
    VertexBuffer vertex = vertex_buffer[gl_VertexIndex];  

    // vec2 n = vec2(-vertex.dir.y, vertex.dir.x) / length(dir);
    // vec2 apos = vertex.pos.y * vertex.dir + vertex.pos.x * n * vertex.thickness;
    // vec4 new_pos = vec4(apos + inst_pos, 0.0, 1.0);


    gl_Position = ortho * vec4(vertex.pos, 1.0, 1.0);
}