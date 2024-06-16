#version 450
#extension GL_ARB_separate_shader_objects : enable
#extension GL_GOOGLE_include_directive : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_nonuniform_qualifier : require

// Code made thanks to great examples from
// https://thebookofshaders.com/edit.php?log=160414041142
// https://www.shadertoy.com/view/tltXDl

#include "types.glsl"

layout(binding = 1) uniform sampler2D materialSamplers[];

layout(location = 0) in vec2 widget_size;
layout(location = 1) in vec2 center_pos;
layout(location = 2) in vec2 tex_pos;

layout(location = 0) out vec4 outColor;


float roundedBoxSDF(vec2 center, vec2 size, vec4 radius) {
    radius.xy = (center.x > 0.0) ? radius.xy : radius.zw;
    radius.x  = (center.y > 0.0) ? radius.x  : radius.y;
    
    vec2 q = abs(center) - size + radius.x;
    return min(max(q.x,q.y),0.0) + length(max(q,0.0)) - radius.x;
}


float sdRoundBox( vec3 p, vec3 b, float r )
{
  vec3 q = abs(p) - b + r;
  return length(max(q,0.0)) + min(max(q.x,max(q.y,q.z)),0.0) - r;
}

// float ring(vec2 p, float radius, float width) {
//   return abs(length(p) - radius * 0.5) - width;
// }

// float circleSDF(vec2 center, float radius)
// {
//     return length(center) - radius;
// }

void main() {
    CanvasBuffer canvas_item = canvas_buffer[draw_index];
    vec2 point = gl_FragCoord.xy / resolution.xy - center_pos;

    float distance = 0;

    // switch (canvas_item.type) {
    //     case 0: {
           
    //         break;
    //     }
    //     case 1: {
    //         // Circle
    //         distance = circleSDF(point * vec2(aspect, 1.0), widget_size.x * aspect);
    //         break;
    //     }
    // }

    distance = roundedBoxSDF(point, widget_size, canvas_item.border_radius / 10.0);

    vec4 fillColor = vec4(0.5, 0.5, 0.5, 0.0);
    vec4 canvasColor = canvas_item.texture_id > -1 ? texture(materialSamplers[canvas_item.texture_id], tex_pos) : distance > 0 ? fillColor : canvas_item.color;

    float border_size = canvas_item.border_width / 100.0;
    float borderAlpha = smoothstep(border_size - 0.002, border_size, abs(distance));
    float smoothedAlpha =  smoothstep(0.0, 1.0 / resolution.x, distance);

    vec4 widgerColor = mix(canvas_item.border_color, canvasColor, borderAlpha);

    outColor = mix(widgerColor, fillColor, smoothedAlpha);
}