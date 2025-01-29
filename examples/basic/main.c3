import std::io;
import std::math;
import std::collections::list;
import std::time;

import vk;
import stb;
import camera;
import gltf;
import c3w;
import helpers;

const MAX_FRAMES_IN_FLIGHT = 2;

struct InstanceData {
    int material_index;
    int has_skin;
    Matrix4f node_matrix;

    vk::DeviceAddress positions;
    vk::DeviceAddress normals;
    vk::DeviceAddress tex_cords;
    vk::DeviceAddress skin_pos;
    vk::DeviceAddress weights;

    vk::DeviceAddress translate;
    vk::DeviceAddress rotate;
    vk::DeviceAddress scale;

}

struct Uniform {
    Matrix4f perspective;
    Matrix4f view;
    Vec4f eye;
}

// Used to send buffer device addresses to GPU
struct AddressBuffer {
    vk::DeviceAddress materials;
    vk::DeviceAddress joints;
    vk::DeviceAddress instance_buffer;
    vk::DeviceAddress uniform_buffer;
}

Gltf gltf;
AnimationChannels animaton_data;

DescriptorImages descriptor_images;

List(<DrawIndexedIndirectCommand>) indirect_commands;

Vec2f window_size = {800, 600};
char[*] shader = $embed("./shaders/shader.spv");

camera::Camera camera;

fn void! main()
{
    c3w::Window win = c3w::new(
        params: {
            .width = (int)window_size.x,
            .height = (int)window_size.y,
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
    camera = camera::new(eye: {0.0, 5.0, 10}, aspect: window_size.x/window_size.y, min_zoom: 0.01, max_zoom: 1000);

    gltf = gltf::loadFile("assets/scene_test.glb")!!;
    defer gltf.free();
    Scene scene = gltf.scenes[0];

    defer indirect_commands.free();

    if (!gltf.animations.is_empty()) animaton_data = gltf.load_animations({0});
    defer animaton_data.release();

    // Create allocator of 50MB - DEVICE_ONLY memory
    vk::Allocation device_allocation = vk::Allocation {
        .device = context.device,
        .pdevice = context.pdevice,
        .properties = vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
        .size = 50_000_000
    }.build()!;

    // Allocation where data can be changed from CPU
    vk::Allocation local_allocation = vk::Allocation {
        .device = context.device,
        .pdevice = context.pdevice,
        .properties = vk::MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk::MEMORY_PROPERTY_HOST_CACHED_BIT,
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
        .size = 20_000_000
    }.build()!;

    defer {
        device_allocation.free();
        local_allocation.free();
    }
  
    Memory uniform = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        &local_allocation,
        &&Uniform {
            .perspective = camera.perspective.transpose(),
            .view = camera.view.transpose(),
            .eye = Vec4f {camera.eye, 0.0 },
        },
        data_size: Uniform.sizeof
    )!!;
    
    Memory material_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        &local_allocation,
        gltf.materials.entries,
        gltf.materials.byte_size()
    )!!;

    uint joint_buffer_size = 0;
    foreach (skin_index, skin: gltf.skins) joint_buffer_size += (uint)skin.joints.len();

    Memory joint_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        &local_allocation,
        null,
        data_size: joint_buffer_size * Matrix4f.sizeof
    )!!;

    Memory instance_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        &local_allocation,
        null,
        data_size: InstanceData.sizeof * gltf.meshes.len()
    )!!;

    Memory mesh_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | vk::BUFFER_USAGE_INDEX_BUFFER_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT,
        &device_allocation,
        gltf.buffers[0].data,
        data_size: scene.buffer_info.byteLength,
        stage_allocator: &local_allocation,
        queue: &context.graphics_queue
    )!!;

    Memory indirect_commands_buffer = vk::new_buffer(
        vk::BUFFER_USAGE_INDIRECT_BUFFER_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT,
        &device_allocation,
        null,
        data_size: gltf.meshes.len() * DrawIndexedIndirectCommand.sizeof,
    )!!;

    Memory addresses = vk::new_buffer(
        vk::BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        &local_allocation,
        &&AddressBuffer {
            material_buffer.address,
            joint_buffer.address,
            instance_buffer.address,
            uniform.address
        },
        data_size: AddressBuffer.sizeof
    )!!;

    List(<uint>) scene_nodes = gltf::flatten_nodes(scene.nodes, gltf);

    foreach (node_index: scene_nodes) {
        Node node = gltf.nodes[node_index];
        bool skinned_node = node.hasSkin();

        if (node.hasMesh()) {
            Matrix4f node_matrix = node.globalMatrix().transpose();
            Mesh mesh = gltf.meshes[node.mesh];

            foreach (prim_index, primitive: mesh.primitives) {
                Accessor index_accessor = gltf.accessors[primitive.attributes["indices"]!!];
                int material_index = (int)primitive.attributes["material"] ?? -1;

                usz pos_offset = gltf.get_offset(primitive.attributes["POSITION"]!!);
                usz index_offset = gltf.get_offset(primitive.attributes["indices"]!!);
                usz normal_offset = gltf.get_offset(primitive.attributes["NORMAL"] ?? 0);
                usz tex_offset = gltf.get_offset(primitive.attributes["TEXCOORD_0"] ?? 0);
                usz skinpos_offset = gltf.get_offset(primitive.attributes["JOINTS_0"] ?? 0);
                usz weights_offset = gltf.get_offset(primitive.attributes["WEIGHTS_0"] ?? 0);

                InstanceData data = {
                    .has_skin = (int)skinned_node,
                    .material_index = material_index,
                    .node_matrix = node_matrix,

                    .positions = mesh_buffer.address + (uint)pos_offset,
                    .normals = mesh_buffer.address + (uint)normal_offset,
                    .tex_cords = mesh_buffer.address + (uint)tex_offset,
                    .skin_pos = mesh_buffer.address + (uint)skinpos_offset,
                    .weights = mesh_buffer.address + (uint)weights_offset,
                };

                DrawIndexedIndirectCommand command = DrawIndexedIndirectCommand {
                    .indexCount = index_accessor.count,
                    .firstInstance = 0,
                    .instanceCount = 1,
                    .firstIndex = (uint)index_offset / index_accessor.stride(),
                    .vertexOffset = 0,
                };

                // Instanced node
                if (node.attributes.len() > 0) {
                    // Accessor translation_accessor = gltf.accessors[node.attributes["TRANSLATION"]!!];
                    // // command.instanceCount = translation_accessor.count;
                    // usz translation_offset = gltf.get_offset(node.attributes["TRANSLATION"] ?? 0);
                    // usz rotation_offset = gltf.get_offset(node.attributes["ROTATION"] ?? 0);
                    // usz scale_offset = gltf.get_offset(node.attributes["SCALE"] ?? 0);
                }

                indirect_commands.push(command);
                instance_buffer.push(&data, size: InstanceData.sizeof);
            }
        }
    }
    
    indirect_commands_buffer.upload_from_stage(indirect_commands.entries, indirect_commands.byte_size(), &local_allocation, context.graphics_queue)!;

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
        descriptor_images.addImageTexture(image_data, &device_allocation, &local_allocation, context.graphics_queue)!;
        image_data.free();
    }

    // Create depth texture
    descriptor_images.addDepthTexture(&device_allocation, context.graphics_queue, window_size, context.depth_format)!;
    
    defer {
        foreach (texture: descriptor_images) texture.free(context.device);
        descriptor_images.free();
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
            .setImageInfo(descriptor_images.array_view())
        },
        ShaderStageFlags[]{
            vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT,
            vk::SHADER_STAGE_FRAGMENT_BIT,
        },
        PushConstantRange[] {},
        context.device
    )!;

    defer pipeline_layout.free(context.device);

    ShaderModule shader_module = vk::shaderModuleCreateInfo()
    .setCodeSize(shader.len)
    .setCode((uint*)&shader[0])
    .build(context.device)!;

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
        vk::DYNAMIC_STATE_SCISSOR
    });

    PipelineDepthStencilStateCreateInfo stencil_state = vk::pipelineDepthStencilStateCreateInfo()
    .setDepthTestEnable(vk::TRUE)
    .setDepthWriteEnable(vk::TRUE)
    .setDepthCompareOp(vk::COMPARE_OP_LESS_OR_EQUAL)
    .setBack({.compareOp = vk::COMPARE_OP_ALWAYS});

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
    .setDepthStencilState(&stencil_state)
    .setViewportState(&view_port_state)
    .setNext(&p_rendering_info)
    .build(context.device)!;

    defer pipeline.free(context.device);

    Clock time = clock::now();

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
        if (!animaton_data.is_empty()) animaton_data.run_animation(&gltf, time.mark());

        // Update joint animations buffer
        foreach (skin: gltf.skins) {
            foreach (joint_index, joint: skin.joints) {
                Node joint_node = gltf.nodes[joint];
                Matrix4f data = joint_node.globalMatrix().mul(skin.inverseBindMatrices[joint_index]).transpose();
                joint_buffer.upload(&data, size: Matrix4f.sizeof, offset: joint_index * Matrix4f.sizeof);
            }
        }

        c3w::Event event = win.getEvent();

        if (win.is_pressed(LEFT_MOUSE)) {
            Vec2f mouse_pos = win.getMousePos();
            camera.rotate(mouse_pos.x - prev_mouse.x, -(mouse_pos.y - prev_mouse.y));
            uniform.upload(&&camera.view.transpose(), size: Matrix4f.sizeof, offset: Uniform.view.offsetof);
            prev_mouse = mouse_pos;
        }

        if (win.is_pressed(MOUSE_SCROLL_UP)) {
            camera.zoom(5);
            uniform.upload(&&camera.view.transpose(), size: Matrix4f.sizeof, offset: Uniform.view.offsetof);
        }

        if (win.is_pressed(MOUSE_SCROLL_DOWN)) {
            camera.zoom(-5);
            uniform.upload(&&camera.view.transpose(), size: Matrix4f.sizeof, offset: Uniform.view.offsetof);
        }

        if (win.is_pressed(ESCAPE)) {
            running = false;
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
        vk::resetCommandBuffer(command_buffer, 0)!;
        vk::beginCommandBuffer(command_buffer, &&vk::commandBufferBeginInfo())!;
 
        vk::cmdSetLineWidth(command_buffer, 1.0);
        vk::cmdSetViewport(command_buffer, 0, 1, &&vk::Viewport{.width = window_size.x, .height = -window_size.y, .minDepth = 0.0, .maxDepth = 1.0, .y = window_size.y });
        vk::cmdSetScissor(command_buffer, 0, 1, &&vk::Rect2D {.extent = context.extent, .offset = { .x = 0, .y = 0 }});

        // Begin dynamic rendering
        vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo().setImageMemoryBarriers({ begin_barrier }));
        vk::cmdPushDescriptorSetKHR(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline_layout.layout, 0, (uint)pipeline_layout.sets.len(), pipeline_layout.sets.entries);
        vk::cmdBindIndexBuffer(command_buffer, mesh_buffer.buffer, 0, vk::INDEX_TYPE_UINT16);

        vk::cmdBindPipeline(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline);
 
        rendering_info.setColorAttachments({ main_render_target });
        rendering_info.setDepthAttachment(&main_depth_target);

        vk::cmdBeginRendering(command_buffer, &rendering_info);
        vk::cmdDrawIndexedIndirect(command_buffer, indirect_commands_buffer.buffer, 0, (uint)indirect_commands.len(), DrawIndexedIndirectCommand.sizeof);
        vk::cmdEndRendering(command_buffer);
      
        vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo().setImageMemoryBarriers({ end_barrier }));
        vk::endCommandBuffer(command_buffer)!!;
         
        context.present_image(next_image, command_buffer)!;
    }
    
    context.device.waitIdle();
}