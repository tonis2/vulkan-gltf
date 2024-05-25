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