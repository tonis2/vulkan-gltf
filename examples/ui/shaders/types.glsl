#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require

layout (buffer_reference, scalar, buffer_reference_align = 4) readonly buffer VertexBuffer {
    vec2 pos;
};

layout (buffer_reference, std430, buffer_reference_align = 4) readonly buffer CanvasBuffer {
    float width;
    vec2 center;
    vec3 color;
};

layout( push_constant ) uniform constants
{
    mat4 model_matrix;
    uint draw_index;
    VertexBuffer vertex_buffer;
    CanvasBuffer canvas_buffer;
};