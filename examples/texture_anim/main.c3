import std::io;
import std::math;
import std::collections::list;
import std::time;
import std::thread;

import vk;
import stb;
import camera;
import gltf;
import c3w;
import helpers;

const MAX_FRAMES_IN_FLIGHT = 2;
const MAX_FPS = 90;
NanoDuration min_frame_time = 100_000_00_00 / MAX_FPS;

struct Vertex {
    Vec3f pos;
    Vec3f normal;
    Vec2f tex_cord;
    Vec4f tangent;
    uint[4] skin_pos;
    Vec4f skin_weight;
}

struct DrawData {
    int material_index;
    int has_skin;
    uint instance_offset;
    Matrix4f node_matrix;
    Matrix4f inverse_node_matrix;
}

struct PushConstantData {
    uint light_index;
}


// Used to send buffer device addresses to GPU
struct AddressBuffer {
    vk::DeviceAddress mesh_buffer;
    vk::DeviceAddress draw_buffer;
    vk::DeviceAddress instance_buffer;
    vk::DeviceAddress lights;
    vk::DeviceAddress materials;
    vk::DeviceAddress joints;
    vk::DeviceAddress light_matrixes;
    vk::DeviceAddress uniform_buffer;
    uint light_count;
}

Gltf gltf;
AnimationChannels animaton_data;

DescriptorImages descriptor_images;
DescriptorImages shadow_maps;


char[*] shader = $embed("./shaders/main.spv");

camera::Camera camera;

fn void main()
{
    c3w::Window win = c3w::new(
        params: {
            .width = 1200,
            .height = 900,
            .x = 0,
            .y = 0
        },
        name: "GLTF animation"
    )!!;
    defer win.free();

    // Vulkan context
    DeviceContext context = helpers::createContext(win, debug: false)!!;
    defer context.free();

    // Create camera
    camera = camera::new(eye: {0.0, 2.0, 10}, aspect: Vec2f{win.width, win.height}.x / win.height, min_zoom: 0.01, max_zoom: 1000);

    gltf = gltf::loadFile("assets/scene_test.glb")!!;
    defer gltf.free();

    if (gltf.lights.is_empty()) {
        gltf.lights.push(Light {
            .position = {2, 12.0, 5},
            .color = {1, 1, 1},
            .intensity = 54351,
            .type = DIRECTIONAL
        });
    }

    Scene scene = gltf.scenes[0];

    if (!gltf.animations.is_empty()) animaton_data = gltf.load_animations({0});
    defer animaton_data.release();

    // Create allocator of 50MB - DEVICE_ONLY memory
    vk::Allocation device_allocation = vk::Allocation {
        .device = context.device,
        .pdevice = context.pdevice,
        .properties = vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
        .size = 100_000_000
    }.build()!!;

    // Allocation where data can be changed from CPU
    vk::Allocation local_allocation = vk::Allocation {
        .device = context.device,
        .pdevice = context.pdevice,
        .properties = vk::MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk::MEMORY_PROPERTY_HOST_CACHED_BIT,
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
        .size = 50_000_000
    }.build()!!;

    defer {
        device_allocation.free();
        local_allocation.free();
    }

    List(<uint>) scene_nodes = gltf::flatten_nodes(scene.nodes, gltf);
    defer scene_nodes.free();

    List(<Vertex>) vertices;
    List(<ushort>) indices;

    List(<Matrix4f>) instance_matrices;
    defer instance_matrices.free();

    Memory indirect_commands_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_INDIRECT_BUFFER_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT,
        &local_allocation,
        null,
        data_size: gltf.meshes.len() * DrawIndexedIndirectCommand.sizeof,
    )!!;

    Memory draw_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        &local_allocation,
        null,
        data_size: DrawData.sizeof * gltf.meshes.len()
    )!!;

    foreach (&mesh: gltf.meshes) {
        foreach (prim_index, &primitive: mesh.primitives) {
                Accessor index_accessor = gltf.accessors[primitive.attributes["indices"]!!];
                Accessor pos_accessor = gltf.accessors[primitive.attributes["POSITION"]!!];
                primitive.attributes["vertex_offset"] = (uint)vertices.len();
                primitive.attributes["index_offset"] = (uint)indices.len(); 
            
                for (usz i; i < index_accessor.count; i++) {
                    indices.push(gltf.@castBuffer(index_accessor, i, ushort));
                }

                for (usz i; i < pos_accessor.count; i++) {
                    Vec2f tex_cord = {|
                        usz! attribute = primitive.attributes["TEXCOORD_0"];
                        if (catch err = attribute) return Vec2f {0,0};

                        Accessor accessor = gltf.accessors[attribute];
                        return gltf.@castBuffer(accessor, i, Vec2f);
                    |};

                    Vec3f normal = {|
                        usz! attribute = primitive.attributes["NORMAL"];
                        if (catch err = attribute) return Vec3f {0,0,0};

                        Accessor accessor = gltf.accessors[attribute];
                        return gltf.@castBuffer(accessor, i, Vec3f);
                    |};

                    Vec4f tangent = {|
                        usz! attribute = primitive.attributes["TANGENT"];
                        if (catch err = attribute) return Vec4f {0,0,0,0};
                        Accessor accessor = gltf.accessors[attribute];
                        return gltf.@castBuffer(accessor, i, Vec4f);
                    |};

                    uint[4] skin_pos = {|
                        usz! attribute = primitive.attributes["JOINTS_0"];
                        if (catch err = attribute) return uint[4] {0,0,0,0};
                        Accessor accessor = gltf.accessors[attribute];

                        if (accessor.data_type == DataType.USHORT) {
                            short[4] array = gltf.@castBuffer(accessor, i, short[4]);
                            return uint[4]{array[0], array[1], array[2], array[3]};
                        };

                        if (accessor.data_type == DataType.CHAR) {
                            char[4] array = gltf.@castBuffer(accessor, i, char[4]);
                            return uint[4]{array[0], array[1], array[2], array[3]};
                        };

                        return uint[4] {0,0,0,0};
                    |};

                    Vec4f skin_weight = {|
                        usz! attribute = primitive.attributes["WEIGHTS_0"];
                        if (catch err = attribute) return Vec4f {0,0,0,0};

                        Accessor accessor = gltf.accessors[attribute];
                        return gltf.@castBuffer(accessor, i, Vec4f);
                    |};

                    Vec3f position = gltf.@castBuffer(pos_accessor, i, Vec3f);

                    vertices.push({
                            .pos = position,
                            .normal = normal,
                            .tex_cord = tex_cord,
                            .tangent = tangent,
                            .skin_pos = skin_pos,
                            .skin_weight = skin_weight
                        }
                    );
                }
            }
    }

    foreach (node_index: scene_nodes) {
        Node node = gltf.nodes[node_index];
        bool skinned_node = node.hasSkin();

        if (node.hasMesh()) {
            Matrix4f node_matrix = node.globalMatrix().transpose();
            Matrix4f inverse_node_matrix = node_matrix.inverse()!!;
            Mesh mesh = gltf.meshes[node.mesh];

            foreach (prim_index, primitive: mesh.primitives) {
                Accessor index_accessor = gltf.accessors[primitive.attributes["indices"]!!];
                int material_index = (int)primitive.attributes["material"] ?? -1;

                DrawIndexedIndirectCommand command = DrawIndexedIndirectCommand {
                    .indexCount = index_accessor.count,
                    .firstInstance = 0,
                    .instanceCount = 1,
                    .firstIndex = (uint)primitive.attributes["index_offset"] ?? 0,
                    .vertexOffset = (uint)primitive.attributes["vertex_offset"] ?? 0,
                };
                
                DrawData data = {
                    .has_skin = (int)skinned_node,
                    .material_index = material_index,
                    .node_matrix = node_matrix,
                    .inverse_node_matrix = inverse_node_matrix,
                    .instance_offset = (uint)instance_matrices.len()
                };

                draw_buffer.push(&data, size: DrawData.sizeof);

                // Instanced node
                if (node.attributes.len() > 0) {
                    // io::printfn("has instancing");
                    Accessor translation_accessor = gltf.accessors[node.attributes["TRANSLATION"]!!];
                    Accessor rotation_accessor = gltf.accessors[node.attributes["ROTATION"]!!];
                    Accessor scale_accessor = gltf.accessors[node.attributes["SCALE"]!!];
                    command.instanceCount = translation_accessor.count;
                    command.firstInstance = 2;

                    for (uint i = 0; i < translation_accessor.count; i++) {
                      Vec3f translation = gltf.@castBuffer(translation_accessor, i, Vec3f);
                      Quaternionf rotation = gltf.@castBuffer(rotation_accessor, i, Quaternionf);
                      Vec3f scale = gltf.@castBuffer(scale_accessor, i, Vec3f);
                      instance_matrices.push(gltf::to_matrix(translation, scale, rotation).transpose());
                    }
                }

                indirect_commands_buffer.push(&command, size: DrawIndexedIndirectCommand.sizeof);
            }
        }
    }

    Memory uniform = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        &local_allocation,
        &&camera.data(),
        data_size: CameraData.sizeof
    )!!;
    
    Memory material_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT,
        &device_allocation,
        gltf.materials.entries,
        gltf.materials.byte_size(),
        stage_allocator: &local_allocation,
        queue: &context.graphics_queue
    )!!;

    Memory light_matrix_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        &local_allocation,
        null,
        data_size: gltf.lights.len() * Matrix4f.sizeof
    )!!;

    uint joint_buffer_size = 0;
    foreach (skin_index, skin: gltf.skins) joint_buffer_size += (uint)skin.joints.len();

    Memory joint_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        &local_allocation,
        null,
        data_size: joint_buffer_size * Matrix4f.sizeof
    )!!;

    Memory light_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT,
        &device_allocation,
        gltf.lights.entries,
        data_size: gltf.lights.byte_size(),
        stage_allocator: &local_allocation,
        queue: &context.graphics_queue
    )!!;

    Memory vertex_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT,
        &device_allocation,
        vertices.entries,
        data_size: vertices.byte_size(),
        stage_allocator: &local_allocation,
        queue: &context.graphics_queue
    )!!;

    Memory index_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_INDEX_BUFFER_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT,
        &device_allocation,
        indices.entries,
        data_size: indices.byte_size(),
        stage_allocator: &local_allocation,
        queue: &context.graphics_queue
    )!!;

    vertices.free();
    indices.free();

    Memory instance_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT,
        &device_allocation,
        instance_matrices.entries,
        data_size: instance_matrices.len() * Matrix4f.sizeof,
        stage_allocator: &local_allocation,
        queue: &context.graphics_queue
    )!!;

    Memory addresses = vk::new_buffer(
        vk::BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        &local_allocation,
        &&AddressBuffer {
            vertex_buffer.address,
            draw_buffer.address,
            instance_buffer.address,
            light_buffer.address,
            material_buffer.address,
            joint_buffer.address,
            light_matrix_buffer.address,
            uniform.address,
            (uint)gltf.lights.len()
        },
        data_size: AddressBuffer.sizeof
    )!!;

    // Create GLTF texture images
    foreach (image : gltf.images) {
        stb::Image image_data;
        switch (image.type) {
            case ENCODED_BASE64: {
                image_data = stb::loadFromBuffer(image.data, image.data.len, stb::Channel.STBI_RGB_ALPHA)!!;
            };
            case ENCODED_BIN: {
                gltf::BufferView buffer_view = gltf.bufferViews[image.view];
                image_data = stb::loadFromBuffer(gltf.buffers[buffer_view.buffer].data[buffer_view.offset..], (uint)buffer_view.byteLength, stb::Channel.STBI_RGB_ALPHA)!!;
            };
            case EXTERNAL_BIN: image_data = stb::loadImage(image.uri, stb::Channel.STBI_RGB_ALPHA)!!;
            default: {}
        }

        // Create vulkan texture image
        if (catch err = descriptor_images.addImageTexture(image_data, &device_allocation, &local_allocation, context.graphics_queue)) {
            io::printfn("GPU allocator is too small for textures");
            return;
        };

        image_data.free();
    }

    // Create depth texture
    descriptor_images.addDepthTexture(&device_allocation, context.graphics_queue, Vec2f{win.width, win.height}, context.depth_format)!!;

    // Shadowmap depth
    foreach (i, light: gltf.lights) {
        shadow_maps.addDepthTexture(&device_allocation, context.graphics_queue, Vec2f{win.width, win.height}, context.depth_format)!!;

        // Upload light view matrixes
        Matrix4f light_view = camera.perspective.mul(matrix::look_at(<float>)(light.position, camera.target, {0.0, 1.0, 0.0})).transpose();
        light_matrix_buffer.upload(&light_view, size: Matrix4f.sizeof, offset: Matrix4f.sizeof * i);
    }
    
    defer {
        foreach (texture: descriptor_images) texture.free(context.device);
        descriptor_images.free();
        foreach (texture: shadow_maps) texture.free(context.device);
        shadow_maps.free();
    }

    PipelineLayer pipeline_layout = helpers::createPipelineLayout(
        {
            vk::writeDescriptorSet()
            .setDescriptorType(vk::DESCRIPTOR_TYPE_UNIFORM_BUFFER)
            .setDstBinding(0)
            .setBufferInfo({
                {
                    .buffer = addresses.buffer,
                    .offset = 0,
                    .range = AddressBuffer.sizeof,
                },
            }),
            vk::writeDescriptorSet()
            .setDstBinding(1)
            .setDescriptorType(vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
            .setImageInfo(descriptor_images.array_view()),
            vk::writeDescriptorSet()
            .setDstBinding(2)
            .setDescriptorType(vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
            .setImageInfo(shadow_maps.array_view())
        },
        ShaderStageFlags[]{
            vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT,
            vk::SHADER_STAGE_FRAGMENT_BIT,
            vk::SHADER_STAGE_FRAGMENT_BIT
        },
        PushConstantRange[]{
            {
                .offset = 0,
                .size = PushConstantData.sizeof,
                .stageFlags = vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT,
            },
        },
        context.device
    )!!;

    defer pipeline_layout.free(context.device);

    ShaderModule shader_module = vk::shaderModuleCreateInfo()
    .setCodeSize(shader.len)
    .setCode((uint*)&shader[0])
    .build(context.device)!!;

    defer shader_module.free(context.device);

    PipelineRenderingCreateInfo p_rendering_info = vk::pipelineRenderingCreateInfo()
    .setColorAttachmentFormats({context.surface_format.format})
    .setDepthAttachmentFormat(context.depth_format);

    PipelineMultisampleStateCreateInfo multi_sample_state = vk::pipelineMultisampleStateCreateInfo()
    .setSampleShadingEnable(vk::FALSE)
    .setRasterizationSamples(vk::SAMPLE_COUNT_1_BIT)
    .setMinSampleShading(1.0)
    .setAlphaToCoverageEnable(vk::FALSE)
    .setAlphaToOneEnable(vk::FALSE);

    PipelineColorBlendStateCreateInfo color_blend_state = vk::pipelineColorBlendStateCreateInfo()
    .setBlendConstants({ 1.0, 1.0, 1.0, 1.0 })
    .setLogicOp(vk::LOGIC_OP_COPY)
    .setLogicOpEnable(vk::FALSE)
    .setAttachments({
    {
        .colorWriteMask =
            vk::COLOR_COMPONENT_R_BIT |
            vk::COLOR_COMPONENT_G_BIT |
            vk::COLOR_COMPONENT_B_BIT |
            vk::COLOR_COMPONENT_A_BIT,  
        .blendEnable = vk::TRUE,
        .srcAlphaBlendFactor = vk::BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk::BLEND_FACTOR_ZERO,
        .srcColorBlendFactor = vk::BLEND_FACTOR_SRC_ALPHA,
        .dstColorBlendFactor = vk::BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = vk::BLEND_OP_ADD,
        .alphaBlendOp = vk::BLEND_OP_ADD,
    }});

    PipelineRasterizationStateCreateInfo rasterisation_state = vk::pipelineRasterizationStateCreateInfo()
    .setDepthClampEnable(vk::FALSE)
    .setRasterizerDiscardEnable(vk::FALSE)
    .setPolygonMode(vk::POLYGON_MODE_FILL)
    .setLineWidth(1.0)
    .setCullMode(vk::CULL_MODE_NONE)
    .setFrontFace(vk::FRONT_FACE_COUNTER_CLOCKWISE)
    .setDepthBiasEnable(vk::FALSE);

    PipelineViewportStateCreateInfo view_port_state = vk::pipelineViewportStateCreateInfo()
            .setViewports({{}})
            .setScissors({{}});

   PipelineDynamicStateCreateInfo dynamic_state = vk::pipelineDynamicStateCreateInfo()
    .setDynamicStates(
    {
        vk::DYNAMIC_STATE_VIEWPORT,
        vk::DYNAMIC_STATE_LINE_WIDTH,
        vk::DYNAMIC_STATE_SCISSOR,
        vk::DYNAMIC_STATE_PRIMITIVE_TOPOLOGY_EXT,
        vk::DYNAMIC_STATE_POLYGON_MODE_EXT,
        vk::DYNAMIC_STATE_CULL_MODE,
        vk::DYNAMIC_STATE_DEPTH_COMPARE_OP,
        vk::DYNAMIC_STATE_DEPTH_TEST_ENABLE,
        vk::DYNAMIC_STATE_DEPTH_WRITE_ENABLE,
        vk::DYNAMIC_STATE_RASTERIZER_DISCARD_ENABLE
    });

    Pipeline pipeline = vk::graphicsPipelineCreateInfo()
    .setStages({
        vk::pipelineShaderStageCreateInfo()
        .setStage(vk::SHADER_STAGE_VERTEX_BIT)
        .setMod(shader_module)
        .setName("vertexMain"),
        vk::pipelineShaderStageCreateInfo()
        .setStage(vk::SHADER_STAGE_FRAGMENT_BIT)
        .setMod(shader_module)
        .setName("fragmentMain")
    })
    .setLayout(pipeline_layout.layout)
    .setInputAssemblyState(&&vk::pipelineInputAssemblyStateCreateInfo().setTopology(vk::PRIMITIVE_TOPOLOGY_TRIANGLE_LIST))
    .setVertexInputState(&&vk::pipelineVertexInputStateCreateInfo().setVertexAttributeDescriptionCount(0))
    .setDynamicState(&dynamic_state)
    .setRasterizationState(&rasterisation_state)
    .setMultisampleState(&multi_sample_state)
    .setColorBlendState(&color_blend_state)
    .setViewportState(&view_port_state)
    .setNext(&p_rendering_info)
    .build(context.device)!!;

    Pipeline shadow_pipeline = vk::graphicsPipelineCreateInfo()
    .setStages({
        vk::pipelineShaderStageCreateInfo()
        .setStage(vk::SHADER_STAGE_VERTEX_BIT)
        .setMod(shader_module)
        .setName("vertexShadow"),
    })
    .setLayout(pipeline_layout.layout)
    .setInputAssemblyState(&&vk::pipelineInputAssemblyStateCreateInfo().setTopology(vk::PRIMITIVE_TOPOLOGY_TRIANGLE_LIST))
    .setVertexInputState(&&vk::pipelineVertexInputStateCreateInfo().setVertexAttributeDescriptionCount(0))
    .setDynamicState(&dynamic_state)
    .setRasterizationState(&rasterisation_state)
    .setMultisampleState(&multi_sample_state)
    .setColorBlendState(&color_blend_state)
    .setViewportState(&view_port_state)
    .setNext(&p_rendering_info)
    .build(context.device)!!;

    defer {
        pipeline.free(context.device);
        shadow_pipeline.free(context.device);
    }

    Clock time = clock::now();
    Clock animation_time = clock::now();

    bool running = true;
    MouseParams last_params;

    RenderingInfo rendering_info = vk::renderingInfo()
    .setLayerCount(1)
    .setRenderArea({
        .offset = Offset2D{ .x = 0, .y = 0 },
        .extent = context.extent,
    });

    Vec2f prev_mouse;


    while (running) {
        NanoDuration start_time = time.mark();
        if (!animaton_data.is_empty()) animaton_data.run_animation(&gltf, animation_time.mark());
        //material_buffer.upload(gltf.materials.entries, gltf.materials.byte_size());

        //Update joint animations buffer
        foreach (skin: gltf.skins) {
            foreach (joint_index, joint: skin.joints) {
                Node joint_node = gltf.nodes[joint];
                Matrix4f data = joint_node.globalMatrix().mul(skin.inverseBindMatrices[joint_index]).transpose();
                joint_buffer.upload(&data, size: Matrix4f.sizeof, offset: joint_index * Matrix4f.sizeof);
            }
        }    

        EventMap[] event_map = win.getEvent();

        foreach (event: event_map) {
            switch {
                case event.is_pressed(LEFT_MOUSE): {
                    Vec2f mouse_pos = win.getMousePos();
                    camera.rotate(mouse_pos.x - prev_mouse.x, (mouse_pos.y - prev_mouse.y));
                    uniform.upload(&&camera.data(), size: CameraData.sizeof);
                    prev_mouse = mouse_pos;
                }
                case event.is_pressed(MOUSE_SCROLL_DOWN): {
                    camera.zoom(2);
                    uniform.upload(&&camera.data(), size: CameraData.sizeof);
                }
                case event.is_pressed(MOUSE_SCROLL_UP): {
                    camera.zoom(-2);
                    uniform.upload(&&camera.data(), size: CameraData.sizeof);
                }
                case event.is_pressed(ESCAPE): {
                    running = false;
                }
            }
        }

        uint next_image = context.next_image()!!;
    
        ImageMemoryBarrier2 begin_barrier = {
            .sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .image = context.swapchain_images[next_image],
            .srcStageMask = vk::PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = vk::PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = vk::ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = vk::IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .subresourceRange = {
                .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            }
        };

        ImageMemoryBarrier2 end_barrier = {
            .sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .image = context.swapchain_images[next_image],
            .srcStageMask = vk::PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = vk::PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
            .srcAccessMask = vk::ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = 0,
            .oldLayout = vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .newLayout = vk::IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .subresourceRange = {
                .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            }
        };

       RenderingAttachmentInfo main_render_target = vk::renderingAttachmentInfo()
        .setImageView(context.swapchain_views[next_image])
        .setImageLayout(vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        .setStoreOp(vk::ATTACHMENT_STORE_OP_STORE)
        .setLoadOp(vk::ATTACHMENT_LOAD_OP_CLEAR)
        .setClearValue({
            .color = { .float32 = { 0.0, 0.0, 0.0, 1.0 }}
        });

        RenderingAttachmentInfo main_depth_target = vk::renderingAttachmentInfo()
        .setImageView(descriptor_images.last()!!.imageView)
        .setImageLayout(vk::IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
        .setStoreOp(vk::ATTACHMENT_STORE_OP_STORE)
        .setLoadOp(vk::ATTACHMENT_LOAD_OP_CLEAR)
        .setClearValue({ .depthStencil = { 1.0, 0 } });

        CommandBuffer command_buffer = context.command_buffers[next_image];
        vk::resetCommandBuffer(command_buffer, 0)!!;
        vk::beginCommandBuffer(command_buffer, &&vk::commandBufferBeginInfo())!!;

        // Dynamic state
        vk::cmdSetDepthTestEnable(command_buffer, vk::TRUE);
        vk::cmdSetDepthWriteEnable(command_buffer, vk::TRUE);
        vk::cmdSetRasterizerDiscardEnable(command_buffer, vk::FALSE);
        vk::cmdSetCullMode(command_buffer, vk::CULL_MODE_NONE);
        vk::cmdSetPolygonModeEXT(command_buffer, vk::POLYGON_MODE_FILL);
        vk::cmdSetPrimitiveTopology(command_buffer, vk::PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
        vk::cmdSetDepthCompareOp(command_buffer, vk::COMPARE_OP_LESS_OR_EQUAL);
 
        vk::cmdSetLineWidth(command_buffer, 1.0);
        vk::cmdSetViewport(command_buffer, 0, 1, &&vk::Viewport{.width = win.width, .height = -win.height, .minDepth = 0.0, .maxDepth = 1.0, .y = win.height });
        vk::cmdSetScissor(command_buffer, 0, 1, &&vk::Rect2D {.extent = context.extent, .offset = { .x = 0, .y = 0 }});

        // Begin dynamic rendering
        vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo().setImageMemoryBarriers({ begin_barrier }));
        vk::cmdPushDescriptorSetKHR(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline_layout.layout, 0, (uint)pipeline_layout.sets.len(), pipeline_layout.sets.entries);
        vk::cmdBindIndexBuffer(command_buffer, index_buffer.buffer, 0, vk::INDEX_TYPE_UINT16);

        // Draw shadowmap
        vk::cmdBindPipeline(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, shadow_pipeline);

        foreach (uint light_index, light: gltf.lights) {
            RenderingAttachmentInfo shadow_depth_target = vk::renderingAttachmentInfo()
            .setImageView(shadow_maps[light_index].imageView)
            .setImageLayout(vk::IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
            .setStoreOp(vk::ATTACHMENT_STORE_OP_STORE)
            .setLoadOp(vk::ATTACHMENT_LOAD_OP_CLEAR)
            .setClearValue({ .depthStencil = { 1.0, 0 } });
            
            rendering_info.colorAttachmentCount = 0;
            rendering_info.pColorAttachments = null;
            rendering_info.setDepthAttachment(&shadow_depth_target);

            PushConstantData constant_data = {
                .light_index = light_index,
            };

            vk::cmdPushConstants(command_buffer, pipeline_layout.layout, vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT, 0, PushConstantData.sizeof, &constant_data);
            vk::cmdBeginRendering(command_buffer, &rendering_info);
            vk::cmdDrawIndexedIndirect(command_buffer, indirect_commands_buffer.buffer, 0, (uint)gltf.meshes.len(), DrawIndexedIndirectCommand.sizeof);
            vk::cmdEndRendering(command_buffer);
        }

        vk::cmdBindPipeline(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        // Draw color view
        rendering_info.setColorAttachments({ main_render_target });
        rendering_info.setDepthAttachment(&main_depth_target);

        vk::cmdBeginRendering(command_buffer, &rendering_info);
        vk::cmdDrawIndexedIndirect(command_buffer, indirect_commands_buffer.buffer, 0, (uint)gltf.meshes.len(), DrawIndexedIndirectCommand.sizeof);
        vk::cmdEndRendering(command_buffer);
      
        vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo().setImageMemoryBarriers({ end_barrier }));
        vk::endCommandBuffer(command_buffer)!!;

        NanoDuration time_delta = (start_time - time.mark());

        if (time_delta < min_frame_time) {
            std::thread::sleep_ns(min_frame_time - time_delta)!!;
            time_delta = (start_time - time.mark());
        }

        // io::printfn("%s", time_delta);

        context.present_image(next_image, command_buffer)!!;
    }   
    
    context.device.waitIdle();
}