#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require

layout (buffer_reference, scalar, buffer_reference_align = 4) readonly buffer VertexBuffer {
    vec2 pos;
};


layout (buffer_reference, std140) readonly buffer CanvasBuffer {
    float width;
    uint type;
    uint radius;
    vec2 corner;
    vec3 color;
};


layout( push_constant ) uniform constants
{
    uint draw_index;
    VertexBuffer vertex_buffer;
    CanvasBuffer canvas_buffer;
};


// vec2 v_new_size = vec2(vertex.pos.x * canvas_item.width, vertex.pos.y * canvas_item.width);
// vec2 v_new_pos = vec2(v_new_size.x - canvas_item.corner.x, v_new_size.y - canvas_item.corner.y);

vec2 calculatePos(VertexBuffer vertex, CanvasBuffer item) {
    vec2 size = vec2(vertex.pos.x * item.width, vertex.pos.y * item.width);
    vec2 pos = vec2(size.x - item.corner.x, size.y - item.corner.y);

    return pos;
}