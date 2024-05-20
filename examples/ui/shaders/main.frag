#version 450
#extension GL_ARB_separate_shader_objects : enable
#extension GL_GOOGLE_include_directive : require
#extension GL_EXT_buffer_reference2 : require

#include "types.glsl"

// layout(location = 0) in vec4 fragColor;
layout(location = 0) out vec4 outColor;

float RectSDF(vec2 point, vec2 center)
{
    vec2 d = abs(point)-center;
    return length(max(d,0.0)) + min(max(d.x,d.y),0.0);
}

float CircleSDF(vec2 point, vec2 center, float radius)
{
    return length(point - center) - radius;
}

void main() {
    CanvasBuffer canvas_item = canvas_buffer[draw_index];

    vec2 frag_pos = canvas_item.corner;
    vec2 widget_size = vec2(canvas_item.width, canvas_item.width);
    vec2 point = gl_FragCoord.xy;

    float will_paint = 0;

    switch (canvas_item.type) {
        case 0: {
            will_paint = RectSDF(point, frag_pos);
        }
        case 1: {
            will_paint = CircleSDF(point, frag_pos + widget_size / 2, canvas_item.radius);
        }
    }
    
	// coloring
    vec4 col = (will_paint > 0.0) ? vec4(0, 0, 0, 0) : vec4(0.65, 0.85, 1.0, 1.0);
    outColor = col;
}