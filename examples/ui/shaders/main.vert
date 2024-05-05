#version 450
#extension GL_EXT_buffer_reference2 : require

layout (binding = 0) uniform uniform_matrix
{
  mat4 projection;
  mat4 view;
};

layout (buffer_reference, std140) readonly buffer VertexBuffer {
    vec2 pos;
    // vec2 dir;
    // uint type;
    // float thickness;
    // vec4 color;
};

layout( push_constant ) uniform constants
{
    VertexBuffer vertex_buffer;
};

void main() {
    VertexBuffer vertex = vertex_buffer[gl_VertexIndex];  

    // vec2 n = vec2(-vertex.dir.y, vertex.dir.x) / length(dir);
    // vec2 apos = vertex.pos.y * vertex.dir + vertex.pos.x * n * vertex.thickness;
    // vec4 new_pos = vec4(apos + inst_pos, 0.0, 1.0);


    gl_Position = projection * view * vec4(vertex.pos, 1.0, 1.0);
}