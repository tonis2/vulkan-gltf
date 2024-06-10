#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_GOOGLE_include_directive : require

#include "types.glsl"

layout(location = 0) out vec2 widget_size;
layout(location = 1) out vec2 center_pos;
layout(location = 2) out vec2 texture_pos;


// Default vertices, for drawing the SDF primitives on
vec2 vertices[4] = vec2[](
    vec2(0.0, 0.0),
    vec2(-1.0, 0.0),
    vec2(0.0, -1.0),
    vec2(-1.0, -1.0)
);

// mat4 translate(vec2 data) {
//     return mat4(
//         vec4(1.0, 0.0, 0.0, 0.0),
//         vec4(0.0, 1.0, 0.0, 0.0),
//         vec4(0.0, 0.0, 1.0, 0.0),
//         vec4(data.x, data.y, 0.0, 1.0)
//     );
// }

void main() {
    vec2 vertex = vertices[gl_VertexIndex];
    CanvasBuffer canvas_item = canvas_buffer[draw_index];
    widget_size = canvas_item.size / resolution.xy / 2;

    vec4 vertex_pos = ortho * vec4(vertex * canvas_item.size - canvas_item.corner, 1.0, 1.0);
    vec4 tex_pos = ortho * vec4(vertex * canvas_item.size - canvas_item.corner, 0.0, 0.0);
    vec2 corner = ((ortho * vec4(canvas_item.corner, 0.0, 0.0)) / -2).xy;

    // Rotate
    if (canvas_item.rotation > 0) {
        vertex_pos.xy = rotate(vertex_pos.xy, canvas_item.rotation);
        tex_pos.xy = rotate(tex_pos.xy, canvas_item.rotation);
    }

    center_pos = corner;
    texture_pos = tex_pos.xy - widget_size ;
    gl_Position = vertex_pos;
}