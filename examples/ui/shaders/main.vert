#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_GOOGLE_include_directive : require

#include "types.glsl"

layout (binding = 0) uniform uniform_matrix
{
  mat4 ortho;
};

void main() {
    VertexBuffer vertex = vertex_buffer[gl_VertexIndex];
    CanvasBuffer canvas_item = canvas_buffer[draw_index];

    vec2 new_size = vec2(vertex.pos.x * canvas_item.width, vertex.pos.y * canvas_item.width) + vec2(-10, -10);
    vec2 new_pos = vec2(new_size.x - canvas_item.corner.x, new_size.y - canvas_item.corner.y);

    gl_Position = ortho * vec4(new_pos, 1.0, 1.0);
}