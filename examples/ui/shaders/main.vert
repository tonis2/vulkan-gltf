#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_GOOGLE_include_directive : require

#include "types.glsl"

layout(location = 0) out vec2 widget_size;
layout(location = 1) out vec2 out_resolution;
layout(location = 2) out vec2 corner_pos;
layout(location = 3) out vec2 frag_pos;

layout (binding = 0) uniform uniform_matrix
{
  mat4 ortho;
  vec2 resolution;
};

void main() {
    VertexBuffer vertex = vertex_buffer[gl_VertexIndex];
    CanvasBuffer canvas_item = canvas_buffer[draw_index];

    vec4 pos = ortho * vec4(calculatePos(vertex, canvas_item), 1.0, 1.0);

    gl_Position = pos;
    
    frag_pos = pos.xy;
    corner_pos = canvas_item.corner / resolution.x;

    widget_size = vec2(canvas_item.width, canvas_item.width) / resolution.x / 2;
    out_resolution = resolution;
}