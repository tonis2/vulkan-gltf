glslangValidator -V ./main.vert -o ./vertex.spv
glslangValidator -V ./main.frag -o ./fragment.spv

glslangValidator -V ./cubemap.vert -o ./cubemap_v.spv
glslangValidator -V ./cubemap.frag -o ./cubemap_f.spv