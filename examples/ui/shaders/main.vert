#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_GOOGLE_include_directive : require
#extension GL_EXT_nonuniform_qualifier : require

#include "types.glsl"

layout(location = 0) out vec2 widget_size;
layout(location = 1) out vec4 center_pos;
layout(location = 2) out vec2 texture_pos;
// layout(location = 3) out vec4 corner2;
// layout(location = 4) out vec2 center;

layout(binding = 1) uniform sampler2D materialSamplers[];


// Default vertices, for drawing the SDF primitives on
vec2 vertices[6] = vec2[](
    vec2(0.0, 0.0),
    vec2(1.0, 0.0),
    vec2(1.0, 1.0),
    vec2(1.0, 1.0),
    vec2(0.0, 1.0),
    vec2(0.0, 0.0)
);

void main() {
    CanvasBuffer canvas_item = canvas_buffer[draw_index];
    vec2 vertex = vertices[gl_VertexIndex];

    mat4 transform = projection * view * canvas_item.transform;

    float scale = projection[0][0] - 2.0;

    vec2 corner = canvas_item.corner / resolution;
    vec2 size = canvas_item.size / resolution;
    vec2 vertex_pos = (vertex * size + corner);

    // center = corner - size / 2;
    // inverse(projection) * view * canvas_item.transform * vec4(size + corner + vec2(scale), 0.0, 0.0)
    center_pos = vec4(0.9, 0.5, 0.0, 0.0);
    
    widget_size = size;
    texture_pos = vertex;

    gl_Position = transform * vec4(vertex_pos - scale, 0.0, 1.0);
    // corner2 = projection * view * canvas_item.transform * vec4(corner, 0.0, 1.0) / 2  + vec4(widget_size, 0.0, 0.0);
   // center_pos = projection * view * canvas_item.transform * vec4(corner, 0.0, 1.0) / 2  + vec4(widget_size, 0.0, 0.0);
}