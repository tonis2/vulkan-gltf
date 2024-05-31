#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require

layout (buffer_reference, std140) readonly buffer CanvasBuffer {
    uint type;
    uint radius;
    vec2 size;
    vec2 corner;
    vec3 color;
};

layout( push_constant ) uniform constants
{
    uint draw_index;
    CanvasBuffer canvas_buffer;
};

// vec2 v_new_size = vec2(vertex.pos.x * canvas_item.width, vertex.pos.y * canvas_item.width);
// vec2 v_new_pos = vec2(v_new_size.x - canvas_item.corner.x, v_new_size.y - canvas_item.corner.y);

