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

struct Vertex {
    Vec3f pos;
    Vec2f tex_cord;
    Vec4f skin_pos;
    Vec4f skin_weight;
}

struct PushConstantData {
    Matrix4f matrix;
    int material_index;
    bool has_skin;
    vk::DeviceAddress skins;
    vk::DeviceAddress materials;
}

MemoryBlock index_buffer;
MemoryBlock vertex_buffer;
MemoryBlock material_buffer;
MemoryBlock uniform_buffer;
MemoryBlock joint_buffer;

Gltf gltf;
List(<Vertex>) vertices;
List(<ushort>) indices;
List(<Matrix4f>) joints;
Animations animations;

DescriptorImages descriptor_images;

Vec2f window_size = {800, 600};

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
    );
    defer win.free();

    // Vulkan context
    DeviceContext context = helpers::createContext(win, debug: true)!!;
    defer context.free();

    // Create camera
    camera::Camera camera = camera::new(eye: {0.0, 5.0, 10}, aspect: window_size.x/window_size.y, min_zoom: 0.01, max_zoom: 1000);

    gltf = gltf::loadFile("assets/scene_test.glb")!;
    defer gltf.free();

    // Preload vertex data from GLTF
    foreach (mesh: gltf.meshes) {
        foreach (prim_index, &primitive: mesh.primitives) {
            Accessor pos_accessor = gltf.accessors[primitive.attributes["POSITION"]!!];
            Accessor index_accessor = gltf.accessors[primitive.attributes["indices"]!!];
            primitive.attributes["first_index"] = indices.len();
            primitive.attributes["first_vertex"] = vertices.len();

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

                Vec4f skin_pos = {|
                    usz! attribute = primitive.attributes["JOINTS_0"];
                    if (catch err = attribute) return Vec4f {0,0,0,0};
                    Accessor accessor = gltf.accessors[attribute];

                    if (accessor.data_type == DataType.USHORT) {
                        short[4] array = gltf.@castBuffer(accessor, i, short[4]);
                        return Vec4f{array[0], array[1], array[2], array[3]};
                    };

                    if (accessor.data_type == DataType.CHAR) {
                        char[4] array = gltf.@castBuffer(accessor, i, char[4]);
                        return Vec4f{array[0], array[1], array[2], array[3]};
                    };

                    return Vec4f {0,0,0,0};
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
                    .tex_cord = tex_cord,
                    .skin_pos = skin_pos,
                    .skin_weight = skin_weight
                });
            }
        }
    }

    defer {
        vertices.free();
        indices.free();
        joints.free();
    }

    foreach (animation: gltf.animations) animations.push(gltf.loadAnimation(animation));
    foreach (&skin: gltf.skins) {
        Accessor skin_accessor = gltf.accessors[skin.inverseBindAccessor];
        for (uint i; i < skin_accessor.count; i++) {
            Matrix4f matrix = gltf.@castBuffer(skin_accessor, i, Matrix4f).transpose();
            skin.inverseBindMatrices.push(matrix);
            joints.push(matrix);
        }
    }

    // Create allocator of 50MB - DEVICE_ONLY memory
    vk::Allocation device_allocation = vk::Allocation {
        .device = context.device,
        .pdevice = context.pdevice,
        .properties = vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .size = 50_000_000
    }.build()!;

    // Allocation where data can be changed from CPU, used when you need to update the data
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

   // Creating buffers
    vertex_buffer = vk::bufferCreateInfo()
               .setUsage(vk::BUFFER_USAGE_VERTEX_BUFFER_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT)
               .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
               .setSize(vertices.byte_size())
               .bind(&device_allocation)!;

    index_buffer = vk::bufferCreateInfo()
                .setUsage(vk::BUFFER_USAGE_INDEX_BUFFER_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT)
                .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
                .setSize(indices.byte_size())
                .bind(&device_allocation)!;

    material_buffer = vk::bufferCreateInfo()
                .setUsage(vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT)
                .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
                .setSize(gltf.materials.byte_size())
                .bind(&local_allocation)!;

    uniform_buffer = vk::bufferCreateInfo()
                .setUsage(vk::BUFFER_USAGE_UNIFORM_BUFFER_BIT)
                .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
                .setSize(UniformData.sizeof)
                .bind(&local_allocation)!;

    joint_buffer = vk::bufferCreateInfo()
                .setUsage(vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT)
                .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
                .setSize(joints.byte_size())
                .bind(&local_allocation)!;

    // Upload data to buffer
    uniform_buffer.upload(&&camera.matrix(), uniform_buffer.size);

    // Create stage buffers and then copy the data to GPU only buffers
    MemoryBlock vertex_stage_buffer = context.device.staging_buffer(size: vertices.byte_size(), data: vertices.entries, pdevice: context.pdevice)!;
    MemoryBlock index_stage_buffer = context.device.staging_buffer(size: indices.byte_size(), data: indices.entries, pdevice: context.pdevice)!;
    MemoryBlock material_stage_buffer = context.device.staging_buffer(size: gltf.materials.byte_size(), data: gltf.materials.entries, pdevice: context.pdevice)!;

    context.device.@single_time_command(queue: context.queue_family.graphics_handle, queue_index: context.queue_family.graphics; CommandBuffer command_buffer) {
         vk::cmdCopyBuffer(command_buffer, index_stage_buffer.buffer, index_buffer.buffer, 1, &&BufferCopy {
             .srcOffset = 0,
             .dstOffset = 0,
             .size = indices.byte_size()
         });

         vk::cmdCopyBuffer(command_buffer, vertex_stage_buffer.buffer, vertex_buffer.buffer, 1, &&BufferCopy {
            .srcOffset = 0,
            .dstOffset = 0,
            .size = vertices.byte_size()
         });

        vk::cmdCopyBuffer(command_buffer, material_stage_buffer.buffer, material_buffer.buffer, 1, &&BufferCopy {
            .srcOffset = 0,
            .dstOffset = 0,
            .size = gltf.materials.byte_size()
         });
    }!;

    index_stage_buffer.free(context.device);
    vertex_stage_buffer.free(context.device);
    material_stage_buffer.free(context.device);

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
            case EXTERNAL_BIN: io::printfn("Load image data here");
        }

        // Create vulkan texture image
        descriptor_images.createImage(image_data, &device_allocation, context.queue_family)!;
        image_data.free();
    }

    // Create depth texture
    descriptor_images.createDepthTexture(&device_allocation, context.queue_family, window_size, context.depth_format)!;

    defer {
        foreach (texture: descriptor_images) texture.free(context.device);
        descriptor_images.free();
    }

    // Pipeline stuff
    DescriptorSetLayout descriptor_set_layout = vk::descriptorSetLayoutCreateInfo()
    .setFlags(vk::DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR)
    .setBindings({
        {
            .binding = 0,
            .descriptorType = vk::DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk::SHADER_STAGE_VERTEX_BIT
        },
        {
            .binding = 1,
            .descriptorType = vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = (uint)descriptor_images.len(),
            .stageFlags = vk::SHADER_STAGE_FRAGMENT_BIT
        },
    }).build(context.device)!;

    // Descriptor sets for push descriptors
    WriteDescriptorSet[] descriptorSets = {
        vk::writeDescriptorSet()
        .setDescriptorType(vk::DESCRIPTOR_TYPE_UNIFORM_BUFFER)
        .setDstBinding(0)
        .setBufferInfo({
            {
                .buffer = uniform_buffer.buffer,
                .offset = 0,
                .range = UniformData.sizeof,
            },
        }),
        vk::writeDescriptorSet()
        .setDstBinding(1)
        .setDescriptorType(vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
        .setImageInfo(descriptor_images.array_view())
    };

    PipelineLayout pipeline_layout = vk::pipelineLayoutCreateInfo()
    .setPushConstantRanges({
        {
            .offset = 0,
            .size = PushConstantData.sizeof,
            .stageFlags = vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT,
        },
    })
    .setSetLayouts({ descriptor_set_layout }).build(context.device)!;


    char[*] shader = $embed("./shaders/shader.spv");

    ShaderModule shader_module = vk::shaderModuleCreateInfo()
    .setCodeSize(shader.len)
    .setCode((uint*)&shader[0])
    .build(context.device)!;

    defer shader_module.free(context.device);

    Pipeline pipeline = vk::graphicsPipelineCreateInfo()
    .setStages({
        vk::pipelineShaderStageCreateInfo()
        .setStage(vk::SHADER_STAGE_VERTEX_BIT)
        .setMod(shader_module)
        .setName("main"),
        vk::pipelineShaderStageCreateInfo()
        .setStage(vk::SHADER_STAGE_FRAGMENT_BIT)
        .setMod(shader_module)
        .setName("main")
    })
     .setLayout(pipeline_layout)
     .setVertexInputState(&&vk::pipelineVertexInputStateCreateInfo()
        .setVertexBindingDescriptions(
        {
            {
             .binding = 0,
             .stride = Vertex.sizeof,
             .inputRate = vk::VERTEX_INPUT_RATE_VERTEX,
            }
        })
        .setVertexAttributeDescriptions({
            {
               .binding = 0,
               .location = 0,
               .format = vk::FORMAT_R32G32B32_SFLOAT,
               .offset = Vertex.pos.offsetof
            },
            {
               .binding = 0,
               .location = 1,
               .format = vk::FORMAT_R32G32_SFLOAT,
               .offset = Vertex.tex_cord.offsetof
            },
            {
               .binding = 0,
               .location = 2,
               .format = vk::FORMAT_R32G32B32A32_SFLOAT,
               .offset = Vertex.skin_pos.offsetof
            },
            {
               .binding = 0,
               .location = 3,
               .format = vk::FORMAT_R32G32B32A32_SFLOAT,
               .offset = Vertex.skin_weight.offsetof
            }
        })
    )
    .setDynamicState(
       &&vk::pipelineDynamicStateCreateInfo()
        .setDynamicStates(
        {
            vk::DYNAMIC_STATE_VIEWPORT,
            vk::DYNAMIC_STATE_LINE_WIDTH,
            vk::DYNAMIC_STATE_SCISSOR
        })
    )
    .setRasterizationState(
        &&vk::pipelineRasterizationStateCreateInfo()
        .setDepthClampEnable(vk::FALSE)
        .setRasterizerDiscardEnable(vk::FALSE)
        .setPolygonMode(vk::POLYGON_MODE_FILL)
        .setLineWidth(1.0)
        .setCullMode(vk::CULL_MODE_NONE)
        .setFrontFace(vk::FRONT_FACE_COUNTER_CLOCKWISE)
        .setDepthBiasEnable(vk::FALSE)
    )
    .setInputAssemblyState(&&vk::pipelineInputAssemblyStateCreateInfo().setTopology(vk::PRIMITIVE_TOPOLOGY_TRIANGLE_LIST))
    .setMultisampleState(&&vk::pipelineMultisampleStateCreateInfo()
                      .setSampleShadingEnable(vk::FALSE)
                      .setRasterizationSamples(vk::SAMPLE_COUNT_1_BIT)
                      .setMinSampleShading(1.0)
                      .setAlphaToCoverageEnable(vk::FALSE)
                      .setAlphaToOneEnable(vk::FALSE))
    .setDepthStencilState(&&vk::pipelineDepthStencilStateCreateInfo()
        .setDepthTestEnable(vk::TRUE)
        .setDepthWriteEnable(vk::TRUE)
        .setDepthCompareOp(vk::COMPARE_OP_LESS)
        .setBack({.compareOp = vk::COMPARE_OP_ALWAYS}))
    .setColorBlendState(&&vk::pipelineColorBlendStateCreateInfo()
                    .setBlendConstants({ 0.0, 0.0, 0.0, 0.0 })
                    .setLogicOp(vk::LOGIC_OP_COPY)
                    .setAttachments({
                       {
                           .colorWriteMask =
                               vk::COLOR_COMPONENT_R_BIT |
                               vk::COLOR_COMPONENT_G_BIT |
                               vk::COLOR_COMPONENT_B_BIT |
                               vk::COLOR_COMPONENT_A_BIT,
                           .blendEnable = vk::TRUE,
                           .srcColorBlendFactor = vk::BLEND_FACTOR_SRC_ALPHA,
                           .dstColorBlendFactor = vk::BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                           .colorBlendOp = vk::BLEND_OP_ADD,
                           .srcAlphaBlendFactor = vk::BLEND_FACTOR_ONE,
                           .dstAlphaBlendFactor = vk::BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                           .alphaBlendOp = vk::BLEND_OP_ADD,
                       }}))
    .setViewportState(&&vk::pipelineViewportStateCreateInfo()
            .setViewports({{}})
            .setScissors({{}}))
    .setNext(&&vk::pipelineRenderingCreateInfo()
                .setColorAttachmentFormats({ context.surface_format.format })
                .setDepthAttachmentFormat(context.depth_format)
            )
    .build(context.device)!;

    defer {
        descriptor_set_layout.free(context.device);
        pipeline_layout.free(context.device);
        pipeline.free(context.device);
    }


    SemaphoreList wait_semaphores;
    SemaphoreList signal_semaphores;
    FenceList frame_fences;

    for (uint i = 0; i < MAX_FRAMES_IN_FLIGHT; ++i) {
        wait_semaphores.push(vk::semaphoreCreateInfo().build(context.device))!;
        signal_semaphores.push(vk::semaphoreCreateInfo().build(context.device))!;
        frame_fences.push(vk::fenceCreateInfo().setFlags(vk::FENCE_CREATE_SIGNALED_BIT).build(context.device))!;
    }

    Scene scene = gltf.scenes[0];
    Clock time = clock::now();

    bool running = true;
    uint frame = 0;
    MouseParams last_params;

    while (running) {
        c3w::Event event = win.getEvent();

        if (animations.len() > 0) gltf.animate(animation: &animations[0], time: time.mark());

        if (event.mouse_click == LEFT_MOUSE) {
           MouseParams params = c3w::getMousePos(win);
           camera.rotate((float)params.x - last_params.x, -((float)params.y - last_params.y));
           uniform_buffer.upload(&&camera.matrix(), UniformData.sizeof);
           last_params = params;
        }

        switch (event.type) {
            case c3w::MOUSE_PRESSED: {
                if ((MouseButton)event.value == MOUSE_SCROLL_UP) {
                    camera.zoom(5);
                    uniform_buffer.upload(&&camera.matrix(), UniformData.sizeof);
                }
                if ((MouseButton)event.value == MOUSE_SCROLL_DOWN) {
                    camera.zoom(-5);
                    uniform_buffer.upload(&&camera.matrix(), UniformData.sizeof);
                }
            }
            case c3w::MOUSE_RELEASED: {}
            case c3w::KEY_PRESSED: {
                if (event.value == c3w::ESCAPE) running = false;
            }
        }

        Fence frame_fence = frame_fences[frame];
        Semaphore wait_semaphore = wait_semaphores[frame];
        Semaphore signal_semaphore = signal_semaphores[frame];

        frame_fence.wait(context.device)!;
        frame_fence.reset(context.device)!;

        uint next_image = context.swapchain.getNextImage(context.device, wait_semaphore);

        // Start dynamic rendering
        RenderingInfo rendering_info = vk::renderingInfo()
        .setLayerCount(1)
        .setRenderArea({
            .offset = Offset2D{ .x = 0, .y = 0 },
            .extent = context.extent,
        })
        .setColorAttachments({
            vk::renderingAttachmentInfo()
            .setImageView(context.swapchain_views[next_image])
            .setImageLayout(vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
            .setStoreOp(vk::ATTACHMENT_STORE_OP_STORE)
            .setLoadOp(vk::ATTACHMENT_LOAD_OP_CLEAR)
            .setClearValue({
                .color = { .float32 = { 0.0, 0.0, 0.0, 1.0 }}
            })
        })
        .setDepthAttachment(&&vk::renderingAttachmentInfo()
            .setImageView(descriptor_images[descriptor_images.len() - 1].imageView)
            .setImageLayout(vk::IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
            .setStoreOp(vk::ATTACHMENT_STORE_OP_STORE)
            .setLoadOp(vk::ATTACHMENT_LOAD_OP_CLEAR)
            .setClearValue({ .depthStencil = { 1.0f, 0 } })
        );

        CommandBuffer command_buffer = context.command_buffers[next_image];
        vk::resetCommandBuffer(command_buffer, 0)!;
        vk::beginCommandBuffer(command_buffer, &&vk::commandBufferBeginInfo())!;

        ImageMemoryBarrier image_memory_start = vk::imageMemoryBarrier()
        .setDstAccessMask(vk::ACCESS_COLOR_ATTACHMENT_WRITE_BIT)
        .setOldLayout(vk::IMAGE_LAYOUT_UNDEFINED)
        .setNewLayout(vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        .setImage(context.swapchain_images[next_image])
        .setSubresourceRange({
            .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        });

        vk::cmdPipelineBarrier(
            command_buffer,
            vk::PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk::PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &image_memory_start
        );

        vk::cmdBeginRendering(command_buffer, &rendering_info);

        vk::cmdSetViewport(command_buffer, 0, 1, &&vk::Viewport{.width = window_size.x, .height = -window_size.y, .minDepth = 0.0, .maxDepth = 1.0, .y = window_size.y });
        vk::cmdSetScissor(command_buffer, 0, 1, &&vk::Rect2D {.extent = context.extent, .offset = { .x = 0, .y = 0 }});

        vk::cmdBindPipeline(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        vk::cmdPushDescriptorSetKHR(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline_layout, 0, descriptorSets.len, descriptorSets.ptr);

        vk::cmdBindVertexBuffers(command_buffer, 0, 1, &&vk::Buffer[1]{vertex_buffer.buffer}, &&vk::DeviceSize[1]{0});
        vk::cmdBindIndexBuffer(command_buffer, index_buffer.buffer, 0, vk::INDEX_TYPE_UINT16);

        foreach (node: scene.nodes) drawNode(gltf.nodes[node], command_buffer, pipeline_layout);

        vk::cmdEndRendering(command_buffer);

        ImageMemoryBarrier image_memory_end = vk::imageMemoryBarrier()
        .setSrcAccessMask(vk::ACCESS_COLOR_ATTACHMENT_WRITE_BIT)
        .setOldLayout(vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        .setNewLayout(vk::IMAGE_LAYOUT_PRESENT_SRC_KHR)
        .setImage(context.swapchain_images[next_image])
        .setSubresourceRange({
            .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        });

        vk::cmdPipelineBarrier(
            command_buffer,
            vk::PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            vk::PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &image_memory_end
        );

        SubmitInfo submit_info = vk::submitInfo()
        .setWaitSemaphores({ wait_semaphore })
        .setCommandBuffers({ command_buffer })
        .setSignalSemaphores({ signal_semaphore })
        .setWaitDstStageMask({vk::PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT});

        vk::endCommandBuffer(command_buffer)!;
        vk::queueSubmit(context.queue_family.graphics_handle, 1, &submit_info, frame_fence)!;

        PresentInfoKHR present_info = vk::presentInfo()
        .setWaitSemaphores({ signal_semaphore })
        .setSwapchains({ context.swapchain })
        .setImageIndices({ next_image });

        vk::queuePresentKHR(context.queue_family.graphics_handle, &present_info)!;
        frame = (frame + 1) % 2;
    }

    context.device.waitIdle();
    wait_semaphores.release(context.device);
    signal_semaphores.release(context.device);
    frame_fences.release(context.device);
}

fn void drawNode(Node node, CommandBuffer buffer, PipelineLayout pipeline_layout) {

    if (node.hasSkin()) {
        Skin skin = gltf.skins[node.skin];
        foreach (joint_index, joint: skin.joints) {
           Node joint_node = gltf.nodes[joint];
           joints[joint_index] = joint_node.globalMatrix().mul(skin.inverseBindMatrices[joint_index]).transpose();
        }
        joint_buffer.upload(joints.entries, joints.byte_size());
    }

    if (node.hasMesh()) {
        gltf::Mesh mesh = gltf.meshes[node.mesh];
        foreach (index, primitive: mesh.primitives) {
            Accessor index_accessor = gltf.accessors[primitive.attributes["indices"]!!];
            gltf::BufferView index_view = gltf.bufferViews[index_accessor.view];

            PushConstantData constant_data = {
                .matrix = node.globalMatrix().transpose(),
                .material_index = (int)primitive.attributes["material"] ?? -1,
                .has_skin = node.hasSkin(),
                .skins = joint_buffer.address,
                .materials = material_buffer.address
            };

            vk::cmdPushConstants(buffer, pipeline_layout, vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT, 0, PushConstantData.sizeof, &constant_data);
            vk::cmdDrawIndexed(buffer, index_accessor.count, 1, (uint)primitive.attributes["first_index"] ?? 0, (uint)primitive.attributes["first_vertex"] ?? 0, 0);
        }
    }

    // Draw child nodes
    foreach (child_index: node.children) drawNode(gltf.nodes[child_index], buffer, pipeline_layout);
}