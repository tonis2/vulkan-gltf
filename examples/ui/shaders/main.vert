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

// Default vertices, for drawing the SDF primitives on
vec2 vertices[4] = vec2[](
    vec2(0.0, 0.0),
    vec2(-1.0, 0.0),
    vec2(0.0, -1.0),
    vec2(-1.0, -1.0)
);

void main() {
    vec2 vertex = vertices[gl_VertexIndex];
    CanvasBuffer canvas_item = canvas_buffer[draw_index];

    vec4 pos = ortho * vec4(vertex * canvas_item.size - canvas_item.corner, 1.0, 1.0);

    gl_Position = pos;
    
    frag_pos = pos.xy;

    switch (canvas_item.type) {
        case 0: {
            vec4 corner = (ortho * vec4(canvas_item.corner, 0.0, 0.0)) / -2;
            corner_pos = corner.xy;
            widget_size = canvas_item.size / resolution.xy / 2;
            break;
        }
        case 1: {
            vec4 corner = (ortho * vec4(canvas_item.corner, 0.0, 0.0)) / vec4(-2, -(2 * resolution.x / resolution.y), 1, 1);
            corner_pos = corner.xy;
            widget_size = canvas_item.size / resolution.x / 2;
            break;
        }
    }

    out_resolution = resolution;
}