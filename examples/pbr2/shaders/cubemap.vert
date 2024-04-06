#version 450
#extension GL_EXT_buffer_reference2 : require

layout(buffer_reference, std140) readonly buffer VertexBuffer {
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
	// outUVW = inPos;
	// outUVW.xy *= -1.0;

	mat4 viewMat = mat4(mat3(model_matrix));
	gl_Position = projection * viewMat * vec4(vertex.position.xyz, 1.0);
}