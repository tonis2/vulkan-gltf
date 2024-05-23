#version 450
#extension GL_ARB_separate_shader_objects : enable
#extension GL_GOOGLE_include_directive : require
#extension GL_EXT_buffer_reference2 : require

#include "types.glsl"

// layout(location = 0) in vec4 fragColor;
layout(location = 0) out vec4 outColor;

float roundRectSDF(vec2 p, vec2 size, float radius) {
  vec2 d = abs(p) - size;
  return min(max(d.x, d.y), 0.0) + length(max(d,0.0))- radius;
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

    vec2 resolution = vec2(800, 600);
    float aspect = resolution.x / resolution.y;

    vec2 item_corner = canvas_item.corner / resolution.x;
    vec2 widget_size = vec2(canvas_item.width, canvas_item.width) / resolution.x;

    vec2 point = gl_FragCoord.xy / resolution.x;

    vec2 pos = (point - item_corner - widget_size / 2) - vec2(aspect / 100);
    
    float will_paint = 0;

    switch (canvas_item.type) {
        case 0: {
            float radius = canvas_item.radius / 100;
            will_paint = roundRectSDF(pos, widget_size / 2 - vec2(radius), radius);
            break;
        }
        case 1: {
            will_paint = circleSDF(pos, (widget_size.x / 2));
          
            break;
        }
    }

    will_paint = smoothedge(will_paint, widget_size);
	// coloring
    vec4 col = (will_paint > 0) ? vec4(0.5, 0.0, 0.5, 0.0) : vec4(canvas_item.color, 1.0);
    outColor = col;
}