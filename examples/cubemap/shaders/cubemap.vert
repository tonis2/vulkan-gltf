#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require

layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer VertexBuffer {
  vec3 position;
};

layout(binding = 0) uniform uniform_matrix
{
  mat4 projection;
  mat4 view;
};

layout( push_constant ) uniform constants
{
	mat4 model_matrix;
	VertexBuffer vertex_buffer;
};

layout (location = 0) out vec3 outUVW;


void main() 
{
	VertexBuffer vertex = vertex_buffer[gl_VertexIndex];	
	outUVW = vertex.position;
	// outUVW.xy *= -1.0;
	
	mat4 viewMat = mat4(mat3(view));
	vec4 pos = projection * viewMat * model_matrix * vec4(vertex.position, 1.0);

	gl_Position = pos.xyww;
}