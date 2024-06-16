#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require

layout (buffer_reference, std430) readonly buffer CanvasBuffer {
    uint type;

    int texture_id;
    float border_width;

    vec2 size;
    vec2 corner;

    vec4 border_radius;
    vec4 color;
    vec4 border_color;
    mat4 transform;
};

layout (buffer_reference, std430) readonly buffer TextureInfo {
   vec2 size;
};

layout( push_constant ) uniform constants
{
    uint draw_index;
    CanvasBuffer canvas_buffer;
};

layout (binding = 0,  std140) uniform uniform_matrix
{
  mat4 projection;
  mat4 view;
  vec2 resolution;
};

vec2 rotate(vec2 pos, float th) {
  return mat2(cos(th), sin(th), -sin(th), cos(th)) * pos;
}

// vec2 v_new_size = vec2(vertex.pos.x * canvas_item.width, vertex.pos.y * canvas_item.width);
// vec2 v_new_pos = vec2(v_new_size.x - canvas_item.corner.x, v_new_size.y - canvas_item.corner.y);

