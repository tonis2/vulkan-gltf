#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_GOOGLE_include_directive : require

#include "types.glsl"

layout(location = 0) out vec2 widget_size;
layout(location = 1) out vec2 out_resolution;

layout (binding = 0) uniform uniform_matrix
{
  mat4 ortho;
  vec2 resolution;
};

void main() {
    VertexBuffer vertex = vertex_buffer[gl_VertexIndex];
    CanvasBuffer canvas_item = canvas_buffer[draw_index];

    float aspect = resolution.x / resolution.y;

    vec2 v_new_size = vec2(vertex.pos.x * canvas_item.width, vertex.pos.y * canvas_item.width);
    vec2 v_new_pos = vec2(v_new_size.x - canvas_item.corner.x, v_new_size.y - canvas_item.corner.y);

    gl_Position = ortho * vec4(v_new_pos, 1.0, 1.0);

  
    widget_size = vec2(canvas_item.width, canvas_item.width) / resolution.x / 2;

    out_resolution = resolution;
}