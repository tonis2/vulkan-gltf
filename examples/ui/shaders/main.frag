#version 450
#extension GL_ARB_separate_shader_objects : enable
#extension GL_GOOGLE_include_directive : require
#extension GL_EXT_buffer_reference2 : require

// Created thanks to https://thebookofshaders.com/edit.php?log=160414041142

#include "types.glsl"

layout(location = 0) in vec2 widget_size;
layout(location = 1) in vec2 resolution;
layout(location = 2) in vec2 corner_pos;
layout(location = 3) in vec2 frag_pos;

// layout(location = 0) in vec4 fragColor;
layout(location = 0) out vec4 outColor;

float roundRectSDF(vec2 p, vec2 size, float radius) {
  vec2 d = abs(p) - size;
  return min(max(d.x, d.y), 0.0) + length(max(d,0.0))- radius;
}

float ring(vec2 p, float radius, float width) {
  return abs(length(p) - radius * 0.5) - width;
}

float circleSDF(vec2 center, float radius)
{ 
    return length(center) - radius;
}

float smoothedge(float v, vec2 resolution) {
    return smoothstep(0.0, 1.0 / resolution.x, v);
}

void main() {
    CanvasBuffer canvas_item = canvas_buffer[draw_index];

    float will_paint = 0;

    switch (canvas_item.type) {
        case 0: {
            vec2 point = gl_FragCoord.xy / resolution;
            vec2 pos = (point - corner_pos - widget_size);
            // Rect
            float radius = canvas_item.radius / 1000.0;
            will_paint = roundRectSDF(pos, widget_size - vec2(radius), radius);
            break;
        }
        case 1: {
            vec2 point = gl_FragCoord.xy / resolution;
            vec2 pos = (point - corner_pos - widget_size);
            // Circle
            will_paint = circleSDF(pos, widget_size.y);
            break;
        }
    }

    will_paint = smoothedge(will_paint, widget_size);
	// coloring
    vec4 col = (will_paint > 0) ? vec4(0.5, 0.0, 0.5, 0.0) : vec4(canvas_item.color, 1.0);
    outColor = col;
}