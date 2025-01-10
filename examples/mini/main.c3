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

struct PushConstantData {
    Matrix4f matrix;
    int material_index;
    bool has_skin;
    uint pos_offset;
    uint normal_offset;
    uint tex_offset;
}

struct Uniform {
    Matrix4f perspective;
    Matrix4f view;
    Vec4f eye;
}

// Used to send buffer device addresses to GPU
struct AddressBuffer {
    vk::DeviceAddress joints;
    vk::DeviceAddress uniform;
    vk::DeviceAddress materials;
    vk::DeviceAddress gltf;
}

MemoryBlock gltf_buffer;
MemoryBlock material_buffer;
MemoryBlock uniform_buffer;
MemoryBlock joint_buffer;
MemoryBlock address_buffer;

Gltf gltf;
List(<Matrix4f>) joints;
AnimationChannels animaton_data;

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
    )!!;
    defer win.free();

    // Vulkan context
    DeviceContext context = helpers::createContext(win, debug: false)!!;
    defer context.free();

    // Create camera
    camera::Camera camera = camera::new(eye: {0.0, 5.0, 10}, aspect: window_size.x/window_size.y, min_zoom: 0.01, max_zoom: 1000);

    gltf = gltf::loadFile("assets/duck.gltf")!!;

    defer {
        joints.free();
        gltf.free();
    }

    // animaton_data = gltf.load_animations({0});
    // defer animaton_data.release();
    
    foreach (skin: gltf.skins) {
        foreach (matrix: skin.inverseBindMatrices) joints.push(matrix);
    }

    // Create allocator of 50MB - DEVICE_ONLY memory
    vk::Allocation device_allocation = vk::Allocation {
        .device = context.device,
        .pdevice = context.pdevice,
        .properties = vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
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
    gltf_buffer = vk::bufferCreateInfo()
                .setUsage(vk::BUFFER_USAGE_INDEX_BUFFER_BIT | vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT)
                .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
                .setSize(gltf.buffers[0].size)
                .bind(&device_allocation)!;

    material_buffer = vk::bufferCreateInfo()
                .setUsage(vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT)
                .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
                .setSize(gltf.materials.byte_size())
                .bind(&device_allocation)!;

    uniform_buffer = vk::bufferCreateInfo()
                .setUsage(vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT)
                .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
                .setSize(Uniform.sizeof)
                .bind(&local_allocation)!;

    joint_buffer = vk::bufferCreateInfo()
                .setUsage(vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT)
                .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
                .setSize(joints.byte_size())
                .bind(&local_allocation)!;

    address_buffer = vk::bufferCreateInfo()
                .setUsage(vk::BUFFER_USAGE_UNIFORM_BUFFER_BIT)
                .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
                .setSize(AddressBuffer.sizeof)
                .bind(&local_allocation)!;

    AddressBuffer addresses = AddressBuffer {
        joint_buffer.address,
        uniform_buffer.address,
        material_buffer.address,
        gltf_buffer.address
    };

    Uniform uniform_data = Uniform {
        .perspective = camera.perspective.transpose(),
        .view = camera.view.transpose(),
        .eye = Vec4f {camera.eye, 0.0 },
    };

    address_buffer.upload(&addresses, AddressBuffer.sizeof);
    uniform_buffer.upload(&uniform_data, Uniform.sizeof);

    usz device_buffer_size = gltf.buffers[0].size + gltf.materials.byte_size();

    vk::@upload_from_stage(size: device_buffer_size, queue: context.graphics_queue, allocator: local_allocation; MemoryBlock stage_buffer, CommandBuffer command_buffer) {
        stage_buffer.push(gltf.buffers[0].data, gltf.buffers[0].size);
        stage_buffer.push(gltf.materials.entries, gltf.materials.byte_size());

        vk::cmdCopyBuffer(command_buffer, stage_buffer.buffer, gltf_buffer.buffer, 1, &&BufferCopy {
             .srcOffset = 0,
             .dstOffset = 0,
             .size = gltf.buffers[0].size
        });

        vk::cmdCopyBuffer(command_buffer, stage_buffer.buffer, material_buffer.buffer, 1, &&BufferCopy {
            .srcOffset = gltf.buffers[0].size,
            .dstOffset = 0,
            .size = gltf.materials.byte_size()
        });
    }!;
    
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
        descriptor_images.addImageTexture(image_data, &device_allocation, context.graphics_queue)!;
        image_data.free();
    }

    // Create depth texture
    descriptor_images.addDepthTexture(&device_allocation, context.graphics_queue, window_size, context.depth_format)!;

    defer {
        foreach (texture: descriptor_images) texture.free(context.device);
        descriptor_images.free();
    }

    // Descriptor sets for push descriptors
    WriteDescriptorSet[] descriptorSets = {
        vk::writeDescriptorSet()
        .setDescriptorType(vk::DESCRIPTOR_TYPE_UNIFORM_BUFFER)
        .setDstBinding(0)
        .setBufferInfo({
            {
                .buffer = address_buffer.buffer,
                .offset = 0,
                .range = AddressBuffer.sizeof,
            },
        }),
        vk::writeDescriptorSet()
        .setDstBinding(1)
        .setDescriptorType(vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
        .setImageInfo(descriptor_images.array_view())
    };

    DescriptorSetLayout descriptor_set_layout = helpers::createDescriptorLayout(
        descriptorSets,
        {
            vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT,
            vk::SHADER_STAGE_FRAGMENT_BIT
        }, context.device)!;

    defer descriptor_set_layout.free(context.device);


    // Pipeline stuff
    PipelineLayout pipeline_layout = vk::pipelineLayoutCreateInfo()
    .setPushConstantRanges({
        {
            .offset = 0,
            .size = PushConstantData.sizeof,
            .stageFlags = vk::SHADER_STAGE_VERTEX_BIT,
        },
    })
    .setSetLayouts({ descriptor_set_layout }).build(context.device)!;

    char[*] shader = $embed("./shaders/shader.spv");

    ShaderModule shader_module = vk::shaderModuleCreateInfo()
    .setCodeSize(shader.len)
    .setCode((uint*)&shader[0])
    .build(context.device)!;

    defer shader_module.free(context.device);

    SubpassDescription subpass = {
        .pipelineBindPoint = vk::PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &&AttachmentReference{
            .attachment = 0,
            .layout = vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        },
        .pDepthStencilAttachment = &&AttachmentReference {
            .attachment = 1,
            .layout = vk::IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        }
    };

    SubpassDependency depth_dependency = {
        .srcSubpass = vk::SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk::PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | vk::PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .srcAccessMask = 0,
        .dstStageMask = vk::PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | vk::PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .dstAccessMask = vk::ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT
    };

    SubpassDependency dependency = {
        .srcSubpass = vk::SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk::PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstStageMask = vk::PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = vk::ACCESS_COLOR_ATTACHMENT_WRITE_BIT
    };

    RenderPass render_pass = vk::renderPassCreateInfo()
    .setAttachments({
        AttachmentDescription {
            .format = context.surface_format.format,
            .samples = vk::SAMPLE_COUNT_1_BIT,
            .initialLayout = vk::IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk::IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .loadOp = vk::ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk::ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = vk::ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk::ATTACHMENT_STORE_OP_DONT_CARE
        },
        AttachmentDescription {
            .format = context.depth_format,
            .samples = vk::SAMPLE_COUNT_1_BIT,
            .loadOp = vk::ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk::ATTACHMENT_STORE_OP_DONT_CARE,
            .stencilLoadOp = vk::ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk::ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk::IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk::IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        }
    })
    .setDependencies({dependency, depth_dependency})
    .setSubpasses({subpass})
    .build(context.device)!;

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
    .setLayout(pipeline_layout)
    .setVertexInputState(&&vk::pipelineVertexInputStateCreateInfo().setVertexAttributeDescriptionCount(0))
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
    .setRenderPass(render_pass)
    .build(context.device)!;

    FrameBufferList frame_buffers;
    
    foreach (i, swapchain: context.swapchain_views) {
       FramebufferCreateInfo frame_buffer_info = vk::framebufferCreateInfo()
        .setRenderPass(render_pass)
        .setWidth((uint)window_size.x)
        .setHeight((uint)window_size.y)
        .setLayers(1)
        .setAttachments({
            context.swapchain_views[i],
            descriptor_images.last().imageView
        })!;

        frame_buffers.push(frame_buffer_info.build(context.device)!);
    }

    defer {
        render_pass.free(context.device);
        pipeline_layout.free(context.device);
        pipeline.free(context.device);
        foreach (buffer : frame_buffers) buffer.free(context.device);
    }

    Scene scene = gltf.scenes[0];
    Clock time = clock::now();

    bool running = true;
    MouseParams last_params;

   Vec2f prev_mouse;
    while (running) {
        if (!animaton_data.is_empty()) animaton_data.run_animation(&gltf, time.mark());
        c3w::Event event = win.getEvent();

        if (win.is_pressed(LEFT_MOUSE)) {
            Vec2f mouse_pos = win.getMousePos();
            camera.rotate(mouse_pos.x - prev_mouse.x, -(mouse_pos.y - prev_mouse.y));
            uniform_buffer.upload(&&camera.view.transpose(), size: Matrix4f.sizeof, offset: Uniform.view.offsetof);
            prev_mouse = mouse_pos;
        }

        if (win.is_pressed(MOUSE_SCROLL_UP)) {
            camera.zoom(5);
            uniform_buffer.upload(&&camera.view.transpose(), size: Matrix4f.sizeof, offset: Uniform.view.offsetof);
        }

        if (win.is_pressed(MOUSE_SCROLL_DOWN)) {
            camera.zoom(-5);
            uniform_buffer.upload(&&camera.view.transpose(), size: Matrix4f.sizeof, offset: Uniform.view.offsetof);
        }

        switch (event.type) {
            case KEY_PRESSED: {
                if (event.value == ESCAPE) running = false;
            }
            default: {}
        }

        uint next_image = context.next_image()!!;

        RenderPassBeginInfo render_pass_info = vk::renderPassBeginInfo()
        .setFramebuffer(frame_buffers[next_image])
        .setRenderPass(render_pass)
        .setRenderArea({
            .offset = {0, 0},
            .extent = context.extent
        })
        .setClearValues({
            ClearValue {
                .color = { .float32 = { 0.0, 0.0, 0.0, 1.0 }},
            },
            ClearValue {
                .depthStencil = { 1.0, 0},
            }
        });

        CommandBuffer command_buffer = context.command_buffers[next_image];
        vk::resetCommandBuffer(command_buffer, 0)!;
        vk::beginCommandBuffer(command_buffer, &&vk::commandBufferBeginInfo())!;

        vk::cmdBeginRenderPass(command_buffer, &render_pass_info, vk::SUBPASS_CONTENTS_INLINE);
        vk::cmdSetViewport(command_buffer, 0, 1, &&vk::Viewport{.width = window_size.x, .height = -window_size.y, .minDepth = 0.0, .maxDepth = 1.0, .y = window_size.y });
        vk::cmdSetScissor(command_buffer, 0, 1, &&vk::Rect2D {.extent = context.extent, .offset = { .x = 0, .y = 0 }});

        vk::cmdBindPipeline(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        vk::cmdPushDescriptorSetKHR(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline_layout, 0, descriptorSets.len, descriptorSets.ptr);

        foreach (node: scene.nodes) drawNode(gltf.nodes[node], command_buffer, pipeline_layout);

        vk::cmdEndRenderPass(command_buffer);
        vk::endCommandBuffer(command_buffer)!!;

        context.present_image(next_image, command_buffer)!;
    }
    
    context.device.waitIdle();
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
            
            usz pos_offset = gltf.get_offset(gltf.accessors[primitive.attributes["POSITION"]!!]);
            usz normal_offset = gltf.get_offset(gltf.accessors[primitive.attributes["NORMAL"]!!]);
            usz tex_offset = gltf.get_offset(gltf.accessors[primitive.attributes["TEXCOORD_0"]!!]);

            PushConstantData constant_data = {
                .matrix = node.globalMatrix().transpose(),
                .material_index = (int)primitive.attributes["material"] ?? -1,
                .has_skin = node.hasSkin(),
                .pos_offset = (uint)pos_offset,
                .normal_offset = (uint)normal_offset,
                .tex_offset = (uint)tex_offset
            };

            vk::cmdBindIndexBuffer(buffer, gltf_buffer.buffer, index_view.offset, vk::INDEX_TYPE_UINT16);
            vk::cmdPushConstants(buffer, pipeline_layout, vk::SHADER_STAGE_VERTEX_BIT, 0, PushConstantData.sizeof, &constant_data);
            vk::cmdDrawIndexed(buffer, index_accessor.count, 1, 0, 0, 0);
        }
    }

    // Draw child nodes
    foreach (child_index: node.children) drawNode(gltf.nodes[child_index], buffer, pipeline_layout);
}