import std::io;
import vk;
import glfw;
import stb;
import camera;
import std::math;
import std::collections::list;
import gltf;

def TextureList = List(<DescriptorImageInfo>);

const WIDTH = 800;
const HEIGHT = 600;
const VK_API_VERSION_1_3 = vk::@makeApiVersion(0,1,3,0);
const ENABLE_VALIDATION_LAYERS = true;
const MAX_FRAMES_IN_FLIGHT = 2;

struct Vertex {
    Vec3f pos;
    Vec2f tex_cord;
}

struct PushConstantData {
    Matrix4f matrix;
    int material_index;
}

// Load shaders
char[*] vertex_shader_data = $embed("./shaders/vertex.spv");
char[*] fragment_shader_data = $embed("./shaders/fragment.spv");

vk::Format depth_format = vk::FORMAT_D32_SFLOAT_S8_UINT;


Instance instance;
DebugUtilsMessengerEXT debug_messenger;
PhysicalDevice physical_device;
QueueFamily queue_family;
Device device;

Gltf gltf;

ZStringList validations;
ZStringList extensions;
ZStringList device_extensions;
List(<Vertex>) vertices;
List(<ushort>) indices;

TextureList material_textures;
DescriptorImageInfo depth_texture;

MemoryBlock index_buffer;
MemoryBlock vertex_buffer;
MemoryBlock material_buffer;
MemoryBlock uniform_buffer;

vk::Allocation local_allocation;
vk::Allocation device_allocation;

fn void! main()
{
    glfw::init();
    glfw::windowHint(glfw::GLFW_CLIENT_API, glfw::GLFW_NO_API);
    glfw::windowHint(glfw::GLFW_RESIZABLE, glfw::GLFW_FALSE);
    glfw::windowHint(glfw::CONTEXT_VERSION_MAJOR, 4);
    glfw::windowHint(glfw::CONTEXT_VERSION_MINOR, 1);
    GLFWwindow window = glfw::createWindow(WIDTH, HEIGHT, "GLTF basic", null, null);

   defer {
        glfw::destroyWindow(window);
        glfw::terminate();
        validations.free();
        extensions.free();
        device_extensions.free();
    }

    if (window == null)
    {
        io::printfn("Failed to init glfw window");
        return;
    }

    // Load gltf
    gltf = gltf::loadFile("assets/truck.glb")!;
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

                Vec3f position = gltf.@castBuffer(pos_accessor, i, Vec3f);

                vertices.push({
                    .pos = position,
                    .tex_cord = tex_cord,
                });
            }
        }
    }

    EventHandler eventHandler = { .window = window };
    eventHandler.init();
    camera::Camera camera = camera::new(.eye = {0.0, 5.0, 10}, .aspect = 800/600, .min_zoom = 0.01, .max_zoom = 1000);

    //"VK_LAYER_LUNARG_api_dump"
    validations.add_array({"VK_LAYER_KHRONOS_validation"});
    device_extensions.add_array({"VK_KHR_swapchain", "VK_KHR_push_descriptor", "VK_KHR_dynamic_rendering"});

    // SETUP extensions
    uint glfwExtensions_count = 0;
    ZString* glfwExtensions = (ZString*)glfw::getRequiredInstanceExtensions(&glfwExtensions_count);
    for (int i = 0; i < glfwExtensions_count; ++i) extensions.push(glfwExtensions[i]);

    if (ENABLE_VALIDATION_LAYERS) {
     extensions.add_array({"VK_EXT_debug_utils"});
    }

    if (env::os_is_darwin()) {
      extensions.push("VK_KHR_portability_enumeration");
      device_extensions.push("VK_KHR_portability_subset");
    }

    vk::checkExtensionSupport(extensions)!;

    InstanceCreateInfo instanceInfo = vk::instanceCreateInfoBuilder()
    .setApplicationInfo(&&ApplicationInfo{
      .pApplicationName = "Hello GLTF",
      .pEngineName = "Super engine",
      .applicationVersion = vk::@makeApiVersion(0,1,0,0),
      .engineVersion = vk::@makeApiVersion(0,1,0,0),
      .apiVersion = VK_API_VERSION_1_3
    })
    .setFlags(env::os_is_darwin() ? vk::INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0)
    .setEnabledExtensionNames(extensions.array_view());

    DebugUtilsMessengerCreateInfoEXT debug_info = vk::debugUtilsMessengerCreateInfoEXTBuilder()
             .setMessageSeverity(vk::DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)
             .setMessageType(vk::DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT)
             .setPfnUserCallback((PFN_vkDebugUtilsMessengerCallbackEXT)&vk::debugCallback);

    // Debug enabled
    if (ENABLE_VALIDATION_LAYERS) {
      vk::checkValidationLayersSupport(validations)!;
      instanceInfo.enabledLayerCount = (uint)validations.len();
      instanceInfo.ppEnabledLayerNames = (char*)validations.entries;
    }

    vk::createInstance(&instanceInfo, null, &instance)!;
    vk::loadExtensions(instance);

    if (ENABLE_VALIDATION_LAYERS) {
     debug_messenger = debug_info.build(instance)!;
    }

    SurfaceKHR surface = glfw::createWindowSurface(instance, window, null)!;

    bool found_device = false;
    // Macro to find a valid device
    instance.@requestDevice(;PhysicalDevice pdevice) {
      QueueFamily queue;
      // Check for device extension support
      bool supports_extensions = pdevice.checkExtensionSupport(device_extensions)!;
      QueuePropertiesList queue_properties = pdevice.getQueueProperties()!;

      queue.graphics = queue_properties.find(fn (usz index, QueueFamilyProperties props) => (usz)props.queueFlags & vk::QUEUE_GRAPHICS_BIT != 0);
      if (surface.checkSurfaceSupport(queue.graphics, pdevice)!) queue.present = queue.graphics;

      if (queue.is_ready() && supports_extensions) {
         physical_device = pdevice;
         queue_family = queue;
         found_device = true;
      }
    }!;

    if (!found_device) {
      io::printfn("Did not found suitable device!");
      return;
    }

    PhysicalDeviceDescriptorIndexingFeatures device_indexing_feature = {
       .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
    };

   PhysicalDeviceBufferDeviceAddressFeatures buffer_device_feature = {
       .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES,
       .pNext = &device_indexing_feature,
       .bufferDeviceAddress = vk::TRUE,
    };

    PhysicalDeviceDynamicRenderingFeatures dynamic_rendering_feature = {
       .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
       .pNext = &buffer_device_feature
    };

    PhysicalDeviceSynchronization2Features syncronisation2_feature = {
       .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES,
       .pNext = &dynamic_rendering_feature,
       .synchronization2 = vk::TRUE
    };

    PhysicalDeviceFeatures2 device_features = {
        .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &syncronisation2_feature,
    };

    vk::getPhysicalDeviceFeatures2(physical_device, &device_features);

    DeviceQueueCreateInfo graphicsInfo = vk::deviceQueueCreateInfoBuilder()
    .setQueueFamilyIndex(queue_family.graphics)
    .setQueuePriorities({1.0});

    device = vk::deviceCreateInfoBuilder()
      .setQueueCreateInfos({ graphicsInfo })
      .setEnabledExtensionNames(device_extensions.array_view())
      .setEnabledLayerCount(0)
      .setNext(&device_features)
      .build(physical_device)!;

    // Add actual queue handles to queue family, easier to keep them is one place
    queue_family.graphics_handle = device.getQueue(queue_family.graphics);

    SurfaceFormatList surface_formats = surface.getFormats(physical_device)!;
    PresentModeList present_modes = surface.getPresentModes(physical_device)!;
    SurfaceCapabilitiesKHR capabilities = surface.deviceSurfaceCapabilities(physical_device)!;

    defer {
      surface_formats.free();
      present_modes.free();
    }

    SurfaceFormatKHR format = SurfaceFormatKHR {.format = vk::FORMAT_B8G8R8A8_UNORM, .colorSpace = vk::COLOR_SPACE_SRGB_NONLINEAR_KHR};

    uint min_images = capabilities.maxImageCount != 0 ? capabilities.maxImageCount : capabilities.minImageCount + 2;
    SwapchainCreateInfoKHR swapchain_info = vk::swapchainCreateInfoKHRBuilder()
      .setMinImageCount(min_images)
      .setImageUsage(vk::IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
      .setImageSharingMode(vk::SHARING_MODE_EXCLUSIVE)
      .setCompositeAlpha(vk::COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
      .setPresentMode(vk::PRESENT_MODE_MAILBOX_KHR)
      .setPreTransform(capabilities.currentTransform)
      .setImageColorSpace(format.colorSpace)
      .setImageFormat(format.format)
      .setSurface(surface)
      .setImageArrayLayers(1)
      .setImageExtent({ .width = WIDTH, .height = HEIGHT });

    SwapchainKHR swapchain = swapchain_info.buildKHR(device)!;
    ImageViewList swapchain_views;
    vk::ImageList swapchain_images = swapchain.getImages(device, swapchain_info.minImageCount)!;

    for (int i = 0; i < swapchain_info.minImageCount; ++i) {
    ImageView view = vk::imageViewCreateInfoBuilder()
      .setViewType(vk::IMAGE_VIEW_TYPE_2D)
      .setFormat(format.format)
      .setComponents({
         .r = vk::COMPONENT_SWIZZLE_IDENTITY,
         .g = vk::COMPONENT_SWIZZLE_IDENTITY,
         .b = vk::COMPONENT_SWIZZLE_IDENTITY,
         .a = vk::COMPONENT_SWIZZLE_IDENTITY,
      })
      .setSubresourceRange({
         .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
         .baseMipLevel = 0,
         .baseArrayLayer = 0,
         .layerCount = 1,
         .levelCount = 1,
      })
      .setImage(swapchain_images[i])
      .build(device)!;
      swapchain_views.push(view);
    }

    CommandPool command_pool = device.createCommandPool(.queue = queue_family.graphics)!;
    CommandBufferList command_buffers = device.createCommandBuffers(command_pool, swapchain_info.minImageCount)!;

    // Create allocator of 10MB - DEVICE_ONLY memory
    device_allocation = vk::Allocation {
        .device = device,
        .pdevice = physical_device,
        .properties = vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .size = 50_000_000
    }.build()!;

    // Allocation where data can be changed from CPU
    local_allocation = vk::Allocation {
        .device = device,
        .pdevice = physical_device,
        .properties = vk::MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk::MEMORY_PROPERTY_HOST_CACHED_BIT,
        .size = 20_000_000
    }.build()!;

    // Create buffers, using only memory of the allocator
    vertex_buffer = vk::bufferCreateInfoBuilder()
               .setUsage(vk::BUFFER_USAGE_VERTEX_BUFFER_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT)
               .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
               .setSize(vertices.byte_size())
               .bind(&device_allocation)!;

    index_buffer = vk::bufferCreateInfoBuilder()
                .setUsage(vk::BUFFER_USAGE_INDEX_BUFFER_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT)
                .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
                .setSize(indices.byte_size())
                .bind(&device_allocation)!;

    material_buffer = vk::bufferCreateInfoBuilder()
                .setUsage(vk::BUFFER_USAGE_STORAGE_BUFFER_BIT)
                .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
                .setSize(gltf.materials.byte_size())
                .bind(&local_allocation)!;

    uniform_buffer = vk::bufferCreateInfoBuilder()
            .setUsage(vk::BUFFER_USAGE_UNIFORM_BUFFER_BIT)
            .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
            .setSize(UniformData.sizeof)
            .bind(&local_allocation)!;

    // Add data for uniform buffer
    uniform_buffer.upload(&&camera.matrix(), uniform_buffer.size, device);
    material_buffer.upload(gltf.materials.entries, gltf.materials.byte_size(), device);

    // Create stage buffers and then copy the data to GPU only buffers
    MemoryBlock vertex_stage_buffer = device.staging_buffer(.size = vertices.byte_size(), .data = vertices.entries, .pdevice = physical_device)!;
    MemoryBlock index_stage_buffer = device.staging_buffer(.size = indices.byte_size(), .data = indices.entries, .pdevice = physical_device)!;

    device.@single_time_command(.queue = queue_family.graphics_handle, .queue_index = queue_family.graphics; CommandBuffer command_buffer) {
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
    }!;

    index_stage_buffer.free(device);
    vertex_stage_buffer.free(device);

    loadTextures()!;

    // Set-up descriptor info for uniform buffer usage
    DescriptorSetLayout descriptor_set_layout = vk::descriptorSetLayoutCreateInfoBuilder()
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
                .descriptorType = vk::DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = (uint)gltf.materials.len(),
                .stageFlags = vk::SHADER_STAGE_FRAGMENT_BIT
            },
            {
                .binding = 2,
                .descriptorType = vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = (uint)material_textures.len(),
                .stageFlags = vk::SHADER_STAGE_FRAGMENT_BIT
            },
        }).build(device)!;

    WriteDescriptorSet[] descriptorSets = {
            vk::writeDescriptorSetBuilder()
            .setDescriptorType(vk::DESCRIPTOR_TYPE_UNIFORM_BUFFER)
            .setDstBinding(0)
            .setBufferInfo({
              {
                   .buffer = uniform_buffer.buffer,
                   .offset = 0,
                   .range = UniformData.sizeof,
               },
           }),
           vk::writeDescriptorSetBuilder()
            .setDescriptorType(vk::DESCRIPTOR_TYPE_STORAGE_BUFFER)
            .setDstBinding(1)
            .setBufferInfo({
              {
                   .buffer = material_buffer.buffer,
                   .offset = 0,
                   .range = gltf.materials.byte_size(),
               },
           }),
            vk::writeDescriptorSetBuilder()
            .setDstBinding(2)
            .setDescriptorType(vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
            .setImageInfo(material_textures.array_view())
    };

    // Required for using push descriptors
    PhysicalDeviceProperties2 deviceProps2 = vk::physicalDeviceProperties2Builder()
                                                .setNext(&&vk::physicalDevicePushDescriptorPropertiesKHRBuilder().setMaxPushDescriptors(1));

    vk::getPhysicalDeviceProperties2(physical_device, &deviceProps2);


    ShaderModule vertex_module = device.createShaderModule(&vertex_shader_data)!;
    ShaderModule frag_module = device.createShaderModule(&fragment_shader_data)!;
    PipelineLayout pipeline_layout = vk::pipelineLayoutCreateInfoBuilder()
    .setPushConstantRanges({
        {
            .offset = 0,
            .size = PushConstantData.sizeof,
            .stageFlags = vk::SHADER_STAGE_VERTEX_BIT,
        },
    })
    .setSetLayouts({ descriptor_set_layout }).build(device)!;

    // Create Renderpipeline info
    GraphicsPipelineCreateInfo pipeline_info = vk::graphicsPipelineCreateInfoBuilder()
    .setStages({
        vertex_module.info(vk::SHADER_STAGE_VERTEX_BIT),
        frag_module.info(vk::SHADER_STAGE_FRAGMENT_BIT)
    })
     .setLayout(pipeline_layout)
     .setVertexInputState(&&vk::pipelineVertexInputStateCreateInfoBuilder()
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
            }
        })
    )
    .setDynamicState(
       &&vk::pipelineDynamicStateCreateInfoBuilder()
        .setDynamicStates(
        {
            vk::DYNAMIC_STATE_VIEWPORT,
            vk::DYNAMIC_STATE_LINE_WIDTH,
        })
    )
    .setRasterizationState(
        &&vk::pipelineRasterizationStateCreateInfoBuilder()
        .setDepthClampEnable(vk::FALSE)
        .setRasterizerDiscardEnable(vk::FALSE)
        .setPolygonMode(vk::POLYGON_MODE_FILL)
        .setLineWidth(1.0)
        .setCullMode(vk::CULL_MODE_FRONT_BIT)
        .setFrontFace(vk::FRONT_FACE_COUNTER_CLOCKWISE)
        .setDepthBiasEnable(vk::FALSE)
    )
    .setInputAssemblyState(&&vk::pipelineInputAssemblyStateCreateInfoBuilder().setTopology(vk::PRIMITIVE_TOPOLOGY_TRIANGLE_LIST))
    .setMultisampleState(&&vk::pipelineMultisampleStateCreateInfoBuilder()
                      .setSampleShadingEnable(vk::FALSE)
                      .setRasterizationSamples(vk::SAMPLE_COUNT_1_BIT)
                      .setMinSampleShading(1.0)
                      .setAlphaToCoverageEnable(vk::FALSE)
                      .setAlphaToOneEnable(vk::FALSE))
    .setDepthStencilState(&&vk::pipelineDepthStencilStateCreateInfoBuilder()
                        .setDepthTestEnable(vk::FALSE)
                        .setDepthWriteEnable(vk::FALSE)
                        .setDepthCompareOp(vk::COMPARE_OP_LESS_OR_EQUAL)
                        .setBack({.compareOp = vk::COMPARE_OP_ALWAYS}))
    .setColorBlendState(&&vk::pipelineColorBlendStateCreateInfoBuilder()
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
    .setViewportState(&&vk::pipelineViewportStateCreateInfoBuilder()
                   .setViewports({{ .x = 0.0, .y = 0.0, .width = swapchain_info.imageExtent.width, .height = swapchain_info.imageExtent.height, .minDepth = 0.0, .maxDepth = 1.0 }})
                   .setScissors({{ .offset = { .x = 0, .y = 0 }, .extent = swapchain_info.imageExtent }}))
    .setNext(&&vk::pipelineRenderingCreateInfoBuilder().setColorAttachmentFormats({swapchain_info.imageFormat}));

    Pipeline pipeline;
    vk::createGraphicsPipelines(device, null, 1, &pipeline_info, null, &pipeline)!;

    // Create syncronisation stuff
    SemaphoreList wait_semaphores;
    SemaphoreList signal_semaphores;
    FenceList frame_fences;

    for (uint i = 0; i < MAX_FRAMES_IN_FLIGHT; ++i) {
        wait_semaphores.push(vk::semaphoreCreateInfoBuilder().build(device))!;
        signal_semaphores.push(vk::semaphoreCreateInfoBuilder().build(device))!;
        frame_fences.push(vk::fenceCreateInfoBuilder().setFlags(vk::FENCE_CREATE_SIGNALED_BIT).build(device))!;
    }

    Scene scene = gltf.scenes[0];

    // Rendering loop
    uint frame = 0;
    while(!glfw::windowShouldClose(window)) {
        eventHandler.update();

        if (eventHandler.scrolling) {
            camera.zoom((float)eventHandler.scrollY * 5);
            uniform_buffer.upload(&&camera.matrix(), uniform_buffer.size, device);
        }

        // Update camera  rotation on left-mouse click
        if (eventHandler.left_mouse_click) {
            camera.rotate((float)eventHandler.mouse_x_delta, (float)eventHandler.mouse_y_delta);
            uniform_buffer.upload(&&camera.matrix(), uniform_buffer.size, device);
        }

        Fence frame_fence = frame_fences[frame];
        Semaphore wait_semaphore = wait_semaphores[frame];
        Semaphore signal_semaphore = signal_semaphores[frame];

        frame_fence.wait(device)!;
        frame_fence.reset(device)!;

        uint next_image = swapchain.getNextImage(device, wait_semaphore);

        // Start dynamic rendering
        RenderingInfo rendering_info = vk::renderingInfoBuilder()
        .setLayerCount(1)
        .setRenderArea({
            .offset = Offset2D{ .x = 0, .y = 0 },
            .extent = swapchain_info.imageExtent,
        })
        .setColorAttachments({
            vk::renderingAttachmentInfoBuilder()
            .setImageView(swapchain_views[next_image])
            .setImageLayout(vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
            .setStoreOp(vk::ATTACHMENT_STORE_OP_STORE)
            .setLoadOp(vk::ATTACHMENT_LOAD_OP_CLEAR)
            .setClearValue({
                .color = { .float32 = { 0.0, 0.0, 0.0, 1.0 }}
            })
        });

        CommandBuffer command_buffer = command_buffers[next_image];
        vk::resetCommandBuffer(command_buffer, 0)!;
        vk::beginCommandBuffer(command_buffer, &&vk::commandBufferBeginInfoBuilder())!;

        ImageMemoryBarrier image_memory_start = vk::imageMemoryBarrierBuilder()
        .setDstAccessMask(vk::ACCESS_COLOR_ATTACHMENT_WRITE_BIT)
        .setOldLayout(vk::IMAGE_LAYOUT_UNDEFINED)
        .setNewLayout(vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        .setImage(swapchain_images[next_image])
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

        vk::cmdBeginRenderingKHR(command_buffer, &rendering_info);

        vk::cmdSetViewport(command_buffer, 0, 1, &&vk::Viewport{.width = WIDTH, .height = -HEIGHT, .minDepth = 0.0, .maxDepth = 1.0, .y = HEIGHT });
        vk::cmdSetScissor(command_buffer, 0, 1, &&vk::Rect2D {.extent = swapchain_info.imageExtent, .offset = Offset2D{ .x = 0, .y = 0 }});

        vk::cmdBindPipeline(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        vk::cmdPushDescriptorSetKHR(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline_layout, 0, descriptorSets.len, descriptorSets.ptr);

        vk::cmdBindVertexBuffers(command_buffer, 0, 1, &&vk::Buffer[1]{vertex_buffer.buffer}, &&vk::DeviceSize[1]{0});
        vk::cmdBindIndexBuffer(command_buffer, index_buffer.buffer, 0, vk::INDEX_TYPE_UINT16);

        foreach (node: scene.nodes) drawNode(gltf.nodes[node], command_buffer, pipeline_layout, device);

        vk::cmdEndRenderingKHR(command_buffer);

        ImageMemoryBarrier image_memory_end = vk::imageMemoryBarrierBuilder()
        .setSrcAccessMask(vk::ACCESS_COLOR_ATTACHMENT_WRITE_BIT)
        .setOldLayout(vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        .setNewLayout(vk::IMAGE_LAYOUT_PRESENT_SRC_KHR)
        .setImage(swapchain_images[next_image])
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

        SubmitInfo submit_info = vk::submitInfoBuilder()
        .setWaitSemaphores({ wait_semaphore })
        .setCommandBuffers({ command_buffer })
        .setSignalSemaphores({ signal_semaphore })
        .setWaitDstStageMask({vk::PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT});

        vk::endCommandBuffer(command_buffer)!;
        vk::queueSubmit(queue_family.graphics_handle, 1, &submit_info, frame_fence)!;

        PresentInfoKHR present_info = vk::presentInfoKHRBuilder()
        .setWaitSemaphores({ signal_semaphore })
        .setSwapchains({ swapchain })
        .setImageIndices({ next_image });

        vk::queuePresentKHR(queue_family.graphics_handle, &present_info)!;
        frame = (frame + 1) % 2;
    }


    device.waitIdle();
    if (ENABLE_VALIDATION_LAYERS) debug_messenger.free(instance);

    swapchain.free(device);
    foreach (view : swapchain_views) view.free(device);

    foreach (texture: material_textures) texture.free(device);
    material_textures.free();

    swapchain_images.free();
    swapchain_views.free();
    vertices.free();
    indices.free();
    uniform_buffer.free(device);
    vertex_buffer.free(device);
    command_pool.free(device);

    descriptor_set_layout.free(device);
    vertex_module.free(device);
    frag_module.free(device);
    pipeline.free(device);
    pipeline_layout.free(device);

    wait_semaphores.release(device);
    signal_semaphores.release(device);
    frame_fences.release(device);
    surface.free(instance);

    device.free();
    instance.free();
}


fn void drawNode(Node node, CommandBuffer buffer, PipelineLayout pipeline_layout, Device device) {

    if (node.hasMesh()) {
        gltf::Mesh mesh = gltf.meshes[node.mesh];
        foreach (index, primitive: mesh.primitives) {
            Accessor index_accessor = gltf.accessors[primitive.attributes["indices"]!!];
            gltf::BufferView index_view = gltf.bufferViews[index_accessor.view];

            PushConstantData constant_data = {
                .matrix = node.globalMatrix().transpose(),
                .material_index = (int)primitive.attributes["material"] ?? -1,
            };

            vk::cmdPushConstants(buffer, pipeline_layout, vk::SHADER_STAGE_VERTEX_BIT, 0, PushConstantData.sizeof, &constant_data);
            vk::cmdBindIndexBuffer(buffer, index_buffer.buffer, 0, vk::INDEX_TYPE_UINT16);
            vk::cmdDrawIndexed(buffer, index_accessor.count, 1, (uint)primitive.attributes["first_index"] ?? 0, (uint)primitive.attributes["first_vertex"] ?? 0, 0);
        }
    }

    // Draw child nodes
    foreach (child_index: node.children) drawNode(gltf.nodes[child_index], buffer, pipeline_layout, device);
}



fn void! loadTextures() {
    // Create texture-images from gltf buffer
    foreach (image : gltf.images) {
        Format image_format = vk::FORMAT_R8G8B8A8_UNORM;
        DescriptorImageInfo texture = { .imageLayout = vk::IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };

        stb::Image! image_data;

        switch (image.type) {
            case ENCODED_BASE64: {
                image_data = stb::loadFromBuffer(image.data, image.data.len, stb::Channel.STBI_RGB_ALPHA);
            };
            case ENCODED_BIN: {
                gltf::BufferView buffer_view = gltf.bufferViews[image.view];
                image_data = stb::loadFromBuffer(gltf.buffers[buffer_view.buffer].data[buffer_view.offset..], (uint)buffer_view.byteLength, stb::Channel.STBI_RGB_ALPHA);
            };
            case EXTERNAL_BIN: io::printfn("Load image data here");
        }

        defer image_data.free()!!;

        if (catch err = image_data) {
            io::printfn("Failed loading image from buffer");
            return;
        }

        vk::Image texture_image = vk::imageCreateInfoBuilder()
            .setImageType(vk::IMAGE_TYPE_2D)
            .setExtent({.width = image_data.width, .height = image_data.height, .depth = 1 })
            .setMipLevels(1)
            .setArrayLayers(1)
            .setSamples(vk::SAMPLE_COUNT_1_BIT)
            .setUsage(vk::IMAGE_USAGE_TRANSFER_DST_BIT | vk::IMAGE_USAGE_SAMPLED_BIT)
            .setInitialLayout(vk::IMAGE_LAYOUT_UNDEFINED)
            .setTiling(vk::IMAGE_TILING_OPTIMAL)
            .setFormat(image_format)
            .build(device)!;
            texture_image.bind(&device_allocation)!;

        MemoryBlock stage_image = device.staging_buffer(.size = (usz)image_data.width * image_data.height * 4, .data = image_data.pixels, .pdevice = physical_device)!;
        defer stage_image.free(device);

        vk::ImageMemoryBarrier2 transfer_barrier = {
            .sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .srcStageMask = vk::PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            .dstStageMask = vk::PIPELINE_STAGE_TRANSFER_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = vk::ACCESS_2_TRANSFER_WRITE_BIT,
            .image = texture_image,
            .oldLayout = vk::IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk::IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .subresourceRange = {
                .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
        }};

        vk::ImageMemoryBarrier2 finalize_barrier = {
            .sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .srcStageMask = vk::PIPELINE_STAGE_TRANSFER_BIT,
            .dstStageMask = vk::PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            .srcAccessMask = vk::ACCESS_2_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk::ACCESS_2_SHADER_READ_BIT,
            .image = texture_image,
            .oldLayout = vk::IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = vk::IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .subresourceRange = {
                .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            }
        };

        device.@single_time_command(.queue = queue_family.graphics_handle, .queue_index = queue_family.graphics; CommandBuffer command_buffer) {
           
            vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfoBuilder()
            .setImageMemoryBarriers({ transfer_barrier }));

            BufferImageCopy bufferCopyRegion = {
                .bufferOffset = 0,
                .bufferRowLength = 0,
                .bufferImageHeight = 0,
                .imageSubresource = {
                    .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel = 0,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
                .imageOffset = {0, 0, 0},
                .imageExtent = {.width = image_data.width, .height = image_data.height, .depth = 1 }
            };

            vk::cmdCopyBufferToImage(
                command_buffer,
                stage_image.buffer,
                texture_image,
                vk::IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                1,
                &bufferCopyRegion
            );

            vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfoBuilder()
            .setImageMemoryBarriers({ finalize_barrier }));
        }!;

        texture.sampler = vk::samplerCreateInfoBuilder()
                            .setMagFilter(vk::FILTER_LINEAR)
                            .setMinFilter(vk::FILTER_LINEAR)
                            .setAddressModeU(vk::SAMPLER_ADDRESS_MODE_REPEAT)
                            .setAddressModeV(vk::SAMPLER_ADDRESS_MODE_REPEAT)
                            .setAddressModeW(vk::SAMPLER_ADDRESS_MODE_REPEAT)
                            .setMipLodBias(0.0)
                            .setMinLod(0.0)
                            .setMaxLod(1.0)
                            .setMaxAnisotropy(1.0)
                            .setAnisotropyEnable(vk::FALSE)
                            .setBorderColor(vk::BORDER_COLOR_FLOAT_OPAQUE_WHITE)
                            .build(device)!;

        texture.imageView = vk::imageViewCreateInfoBuilder()
                        .setViewType(vk::IMAGE_VIEW_TYPE_2D)
                        .setFormat(image_format)
                        .setSubresourceRange({
                            .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                            .baseMipLevel = 0,
                            .baseArrayLayer = 0,
                            .layerCount = 1,
                            .levelCount = 1,
                        })
                        .setImage(texture_image)
                        .build(device)!;


        material_textures.push(texture);
    }

    // depth_texture.imageLayout = vk::IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;

    // vk::Image depth_image = vk::imageCreateInfoBuilder()
    // .setImageType(vk::IMAGE_TYPE_2D)
    // .setExtent({.width = WIDTH, .height = HEIGHT, .depth = 1 })
    // .setMipLevels(1)
    // .setArrayLayers(1)
    // .setSamples(vk::SAMPLE_COUNT_1_BIT)
    // .setUsage(vk::IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | vk::IMAGE_USAGE_SAMPLED_BIT)
    // .setInitialLayout(vk::IMAGE_LAYOUT_UNDEFINED)
    // .setTiling(vk::IMAGE_TILING_OPTIMAL)
    // .setFormat(depth_)
    // .build(device)!;

    // depth_image.bind(&device_allocation)!;
    // depth_texture.sampler = vk::samplerCreateInfoBuilder()
    //     .setMagFilter(vk::FILTER_LINEAR)
    //     .setMinFilter(vk::FILTER_LINEAR)
    //     .setAddressModeU(vk::SAMPLER_ADDRESS_MODE_REPEAT)
    //     .setAddressModeV(vk::SAMPLER_ADDRESS_MODE_REPEAT)
    //     .setAddressModeW(vk::SAMPLER_ADDRESS_MODE_REPEAT)
    //     .setMipLodBias(0.0)
    //     .setMinLod(0.0)
    //     .setMaxLod(1.0)
    //     .setMaxAnisotropy(1.0)
    //     .setAnisotropyEnable(vk::FALSE)
    //     .setBorderColor(vk::BORDER_COLOR_FLOAT_OPAQUE_WHITE)
    //     .build(device)!;
        
    // depth_texture.imageView = vk::imageViewCreateInfoBuilder()
    //     .setViewType(vk::IMAGE_VIEW_TYPE_2D)
    //     .setFormat(depth_)
    //     .setSubresourceRange({
    //       .aspectMask = vk::IMAGE_ASPECT_DEPTH_BIT,
    //       .baseMipLevel = 0,
    //       .baseArrayLayer = 0,
    //       .layerCount = 1,
    //       .levelCount = 1,
    //     })
    //     .setImage(depth_image)
    //     .build(device)!;

    // device.@single_time_command(.queue = queue_family.graphics_handle, .queue_index = queue_family.graphics; CommandBuffer command_buffer) {
    //    ImageMemoryBarrier imageMemoryBarrier = vk::imageMemoryBarrierBuilder()
    //    .setImage(depth_image)
    //    .setSubresourceRange({
    //       .aspectMask = vk::IMAGE_ASPECT_DEPTH_BIT | vk::IMAGE_ASPECT_STENCIL_BIT,
    //       .baseMipLevel = 0,
    //       .baseArrayLayer = 0,
    //       .layerCount = 1,
    //       .levelCount = 1,
    //    })
    //    .setSrcAccessMask(0)
    //    .setDstAccessMask(vk::ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)
    //    .setOldLayout(vk::IMAGE_LAYOUT_UNDEFINED)
    //    .setNewLayout(vk::IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL);

    //    vk::cmdPipelineBarrier(
    //        command_buffer,
    //        vk::PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | vk::PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
    //        vk::PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | vk::PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
    //        0,
    //        0,
    //        null,
    //        0,
    //        null,
    //        1,
    //        &imageMemoryBarrier
    //    );
    // }!;
}