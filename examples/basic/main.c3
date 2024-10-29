import std::io;
import std::math;
import std::collections::list;
import std::time;

import vk;
import stb;
import camera;
import gltf;
import c3w;

def TextureList = List(<DescriptorImageInfo>);

const WIDTH = 800;
const HEIGHT = 600;
const ENABLE_VALIDATION_LAYERS = false;
const MAX_FRAMES_IN_FLIGHT = 2;
const VK_API_VERSION_1_3 = vk::@makeApiVersion(0,1,3,0);

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

Instance instance;
DebugUtilsMessengerEXT debug_messenger;
PhysicalDevice physical_device;
QueueFamily queue_family;
Device device;
SurfaceKHR surface;

Gltf gltf;

ZStringList validations;
ZStringList extensions;
ZStringList device_extensions;
List(<Vertex>) vertices;
List(<ushort>) indices;
List(<Matrix4f>) joint_data;
Animations animations;

TextureList material_textures;

vk::Format depth_format;
DescriptorImageInfo depth_texture;
vk::Image depth_image;

MemoryBlock index_buffer;
MemoryBlock vertex_buffer;
MemoryBlock material_buffer;
MemoryBlock uniform_buffer;
MemoryBlock joint_buffer;

vk::Allocation local_allocation;
vk::Allocation device_allocation;

fn void! main()
{
    // Load gltf
    gltf = gltf::loadFile("assets/scene_test.glb")!;
    defer gltf.free();

    foreach (&buffer: gltf.buffers) {
        if (buffer.type == EXTERNAL_BIN) {
            File! data = file::open("assets/".concat((String)buffer.uri), "r");
            if (catch err = data) {
                io::printfn("asset not found");
                return;
            }
            buffer.data = buffer.from_binary(&data)!;
        }
    }

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

    foreach (animation: gltf.animations) {
        animations.push(gltf.loadAnimation(animation));
    }

    foreach (&skin: gltf.skins) {
        Accessor skin_accessor = gltf.accessors[skin.inverseBindAccessor];
        for (uint i; i < skin_accessor.count; i++) {
                Matrix4f matrix = gltf.@castBuffer(skin_accessor, i, Matrix4f).transpose();
                skin.inverseBindMatrices.push(matrix);
                joint_data.push(matrix);
        }
    }

    c3w::Window win = c3w::new(
        params: {
            .width = WIDTH,
            .height = HEIGHT,
            .x = 0,
            .y = 0
        },
        name: "GLTF animation"
    );
    defer win.free();
    
    camera::Camera camera = camera::new(eye: {0.0, 5.0, 10}, aspect: 800/600, min_zoom: 0.01, max_zoom: 1000);

    device_extensions.add_array({"VK_KHR_swapchain", "VK_KHR_push_descriptor", "VK_KHR_dynamic_rendering"});
    validations.add_array({"VK_LAYER_KHRONOS_validation"});
    extensions.add_array({"VK_KHR_surface", "VK_EXT_debug_utils"});

    if (env::OS_TYPE == MACOS) {
        extensions.add_array({"VK_MVK_macos_surface", "VK_KHR_portability_enumeration"});
        device_extensions.push("VK_KHR_portability_subset");
    }

    if (env::OS_TYPE == WIN32) {
        extensions.add_array({"VK_KHR_win32_surface"});
    }

    if (env::OS_TYPE == LINUX) {
        extensions.add_array({"VK_KHR_xlib_surface"});
    }

    vk::checkInstanceExtensionSupport(extensions)!;

    InstanceCreateInfo instanceInfo = vk::instanceCreateInfo()
    .setApplicationInfo(&&ApplicationInfo{
      .pApplicationName = "TEST",
      .pEngineName = "Super engine",
      .applicationVersion = vk::@makeApiVersion(0,1,0,0),
      .engineVersion = vk::@makeApiVersion(0,1,0,0),
      .apiVersion = vk::@makeApiVersion(0,1,3,0)
    })
    .setFlags(env::os_is_darwin() ? vk::INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0)
    .setEnabledExtensionNames(extensions.array_view());

    DebugUtilsMessengerCreateInfoEXT debug_info = DebugUtilsMessengerCreateInfoEXT {
        .sType = vk::STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = vk::DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = vk::DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = (PFN_vkDebugUtilsMessengerCallbackEXT)&vk::debugCallback
    };

    // Debug enabled
    if (ENABLE_VALIDATION_LAYERS) {
      vk::checkValidationLayersSupport(validations)!!;
      instanceInfo.enabledLayerCount = (uint)validations.len();
      instanceInfo.ppEnabledLayerNames = (char*)validations.entries;
    }

    vk::createInstance(&instanceInfo, null, &instance)!!;
    vk::loadExtensions(instance);

    if (ENABLE_VALIDATION_LAYERS) {
        debug_messenger = debug_info.build(instance)!!;
    }

    // Create surface
    $switch(env::OS_TYPE)
        $case LINUX: {
            XlibSurfaceCreateInfoKHR createInfo = {
                vk::STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR, 
                null, 
                0, 
                win.src.display, 
                win.src.window, 
            };

            vk::createXlibSurfaceKHR(instance, &createInfo, null, &surface)!!;
        }
        $case MACOS: {
            MacOSSurfaceCreateInfoMVK createInfo = { 
                vk::STRUCTURE_TYPE_MACOS_SURFACE_CREATE_INFO_MVK, 
                null, 
                0, 
                win.src.window
            };
        }
        $case WIN32: {
            Win32SurfaceCreateInfoKHR createInfo = {
                vk::STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
                null,
                0,
                win.src.window,
                &win.src.hdc
            };
        }
        $default: {}
    $endswitch

    DeviceList devices = instance.getDevices()!!;
    bool found_device = false;

    foreach (entry: devices) {
        QueueFamily queue;
        // Check for device extension support
        bool supports_extensions = entry.checkExtensionSupport(device_extensions)!!;
        QueuePropertiesList queue_properties = entry.getQueueProperties()!!;

        queue.graphics = queue_properties.find(fn (usz index, QueueFamilyProperties props) => (QueueFlagBits)props.queueFlags & vk::QUEUE_GRAPHICS_BIT != 0);

        PhysicalDeviceProperties properties;
        vk::getPhysicalDeviceProperties(entry, &properties);

        if (surface.checkSurfaceSupport(queue.graphics, entry)!!) queue.present = queue.graphics;
        if (queue.is_ready() && supports_extensions && properties.vendorID != 0) {
            io::printfn("Device selected %s", (ZString)properties.deviceName[0..]);

            physical_device = entry;
            queue_family = queue;
            found_device = true;
            break;
        }
    }

    devices.free();

    if (!found_device) {
      io::printfn("Did not found suitable device!");
      return;
    }

    // Required for using push descriptors
    PhysicalDeviceProperties2 deviceProps2 = vk::physicalDeviceProperties2()
                                                .setNext(&&vk::physicalDevicePushDescriptorProperties().setMaxPushDescriptors(1));

    vk::getPhysicalDeviceProperties2(physical_device, &deviceProps2);

    PhysicalDeviceDescriptorIndexingFeatures device_indexing_feature = {
       .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
    };

   PhysicalDeviceBufferDeviceAddressFeatures buffer_device_feature = {
       .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES,
       .pNext = &device_indexing_feature,
       .bufferDeviceAddress = vk::TRUE,
       .bufferDeviceAddressCaptureReplay = vk::TRUE
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

    DeviceQueueCreateInfo graphicsInfo = vk::deviceQueueCreateInfo()
    .setQueueFamilyIndex(queue_family.graphics)
    .setQueuePriorities({1.0});

    device = vk::deviceCreateInfo()
      .setQueueCreateInfos({ graphicsInfo })
      .setEnabledExtensionNames(device_extensions.array_view())
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
    
    depth_format = vk::findDepthFormat(features: vk::FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT, device: physical_device);

    SurfaceFormatKHR format = SurfaceFormatKHR {.format = vk::FORMAT_B8G8R8A8_UNORM, .colorSpace = vk::COLOR_SPACE_SRGB_NONLINEAR_KHR};
    Extent2D extent = capabilities.maxImageExtent;
    uint min_images = capabilities.maxImageCount != 0 ? capabilities.maxImageCount : capabilities.minImageCount + 2;

    SwapchainCreateInfoKHR swapchain_info = vk::swapchainCreateInfo()
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
      .setImageExtent(extent);

    SwapchainKHR swapchain = swapchain_info.build(device)!;
    ImageViewList swapchain_views;
    vk::ImageList swapchain_images = swapchain.getImages(device, swapchain_info.minImageCount)!;

    for (int i = 0; i < swapchain_info.minImageCount; ++i) {
        ImageView view = vk::imageViewCreateInfo()
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

    CommandPool command_pool = device.createCommandPool(queue: queue_family.graphics)!;
    CommandBufferList command_buffers = device.createCommandBuffers(command_pool, swapchain_info.minImageCount)!;

    // Create allocator of 50MB - DEVICE_ONLY memory
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
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
        .size = 20_000_000
    }.build()!;

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
                .setUsage(vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT)
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
                .setSize(joint_data.byte_size())
                .bind(&local_allocation)!;

    // Upload data to buffer
    uniform_buffer.upload(&&camera.matrix(), uniform_buffer.size, device);
    material_buffer.upload(gltf.materials.entries, gltf.materials.byte_size(), device);

    // Create stage buffers and then copy the data to GPU only buffers
    MemoryBlock vertex_stage_buffer = device.staging_buffer(size: vertices.byte_size(), data: vertices.entries, pdevice: physical_device)!;
    MemoryBlock index_stage_buffer = device.staging_buffer(size: indices.byte_size(), data: indices.entries, pdevice: physical_device)!;

    device.@single_time_command(queue: queue_family.graphics_handle, queue_index: queue_family.graphics; CommandBuffer command_buffer) {
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

    // Set-up descriptor info
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
                .descriptorCount = (uint)material_textures.len(),
                .stageFlags = vk::SHADER_STAGE_FRAGMENT_BIT
            },
        }).build(device)!;

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
        .setImageInfo(material_textures.array_view())
    };
    
    PipelineLayout pipeline_layout = vk::pipelineLayoutCreateInfo()
    .setPushConstantRanges({
        {
            .offset = 0,
            .size = PushConstantData.sizeof,
            .stageFlags = vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT,
        },
    })
    .setSetLayouts({ descriptor_set_layout }).build(device)!;

    char[*] shader = $embed("./shaders/shader.spv");

    ShaderModule shader_module = vk::shaderModuleCreateInfo()
    .setCodeSize(shader.len)
    .setCode((uint*)&shader[0])
    .build(device)!;

    defer shader_module.free(device);

    // Create Renderpipeline info
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
                .setColorAttachmentFormats({ swapchain_info.imageFormat })
                .setDepthAttachmentFormat(depth_format)
            )
    .build(device)!;

    // Create syncronisation stuff
    SemaphoreList wait_semaphores;
    SemaphoreList signal_semaphores;
    FenceList frame_fences;

    for (uint i = 0; i < MAX_FRAMES_IN_FLIGHT; ++i) {
        wait_semaphores.push(vk::semaphoreCreateInfo().build(device))!;
        signal_semaphores.push(vk::semaphoreCreateInfo().build(device))!;
        frame_fences.push(vk::fenceCreateInfo().setFlags(vk::FENCE_CREATE_SIGNALED_BIT).build(device))!;
    }

    Scene scene = gltf.scenes[0];
    Clock time = clock::now();

    // Rendering loop
    bool running = true;
    uint frame = 0;
    MouseParams last_params;

    while (running) {
        c3w::Event event = win.getEvent();

        if (animations.len() > 0) gltf.animate(animation: &animations[0], time: time.mark());

        if (event.mouse_click == LEFT_MOUSE) {
           MouseParams params = c3w::getMousePos(win);
           camera.rotate((float)params.x - last_params.x, -((float)params.y - last_params.y));
           uniform_buffer.upload(&&camera.matrix(), uniform_buffer.size, device);
           last_params = params;
        }

        switch (event.type) {
            case c3w::MOUSE_PRESSED: {
                if ((MouseButton)event.value == MOUSE_SCROLL_UP) {
                    camera.zoom(5);
                    uniform_buffer.upload(&&camera.matrix(), uniform_buffer.size, device);
                }
                if ((MouseButton)event.value == MOUSE_SCROLL_DOWN) {
                    camera.zoom(-5);
                    uniform_buffer.upload(&&camera.matrix(), uniform_buffer.size, device);
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

        frame_fence.wait(device)!;
        frame_fence.reset(device)!;

        uint next_image = swapchain.getNextImage(device, wait_semaphore);

        // Start dynamic rendering
        RenderingInfo rendering_info = vk::renderingInfo()
        .setLayerCount(1)
        .setRenderArea({
            .offset = Offset2D{ .x = 0, .y = 0 },
            .extent = swapchain_info.imageExtent,
        })
        .setColorAttachments({
            vk::renderingAttachmentInfo()
            .setImageView(swapchain_views[next_image])
            .setImageLayout(vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
            .setStoreOp(vk::ATTACHMENT_STORE_OP_STORE)
            .setLoadOp(vk::ATTACHMENT_LOAD_OP_CLEAR)
            .setClearValue({
                .color = { .float32 = { 0.0, 0.0, 0.0, 1.0 }}
            })
        })
        .setDepthAttachment(&&vk::renderingAttachmentInfo()
            .setImageView(depth_texture.imageView)
            .setImageLayout(vk::IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
            .setStoreOp(vk::ATTACHMENT_STORE_OP_STORE)
            .setLoadOp(vk::ATTACHMENT_LOAD_OP_CLEAR)
            .setClearValue({ .depthStencil = { 1.0f, 0 } })
        );

        CommandBuffer command_buffer = command_buffers[next_image];
        vk::resetCommandBuffer(command_buffer, 0)!;
        vk::beginCommandBuffer(command_buffer, &&vk::commandBufferBeginInfo())!;

        ImageMemoryBarrier image_memory_start = vk::imageMemoryBarrier()
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

        vk::cmdBeginRendering(command_buffer, &rendering_info);

        vk::cmdSetViewport(command_buffer, 0, 1, &&vk::Viewport{.width = WIDTH, .height = -HEIGHT, .minDepth = 0.0, .maxDepth = 1.0, .y = HEIGHT });
        vk::cmdSetScissor(command_buffer, 0, 1, &&vk::Rect2D {.extent = swapchain_info.imageExtent, .offset = { .x = 0, .y = 0 }});

        vk::cmdBindPipeline(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        vk::cmdPushDescriptorSetKHR(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline_layout, 0, descriptorSets.len, descriptorSets.ptr);

        vk::cmdBindVertexBuffers(command_buffer, 0, 1, &&vk::Buffer[1]{vertex_buffer.buffer}, &&vk::DeviceSize[1]{0});
        vk::cmdBindIndexBuffer(command_buffer, index_buffer.buffer, 0, vk::INDEX_TYPE_UINT16);

        foreach (node: scene.nodes) drawNode(gltf.nodes[node], command_buffer, pipeline_layout, device);

        vk::cmdEndRendering(command_buffer);

        ImageMemoryBarrier image_memory_end = vk::imageMemoryBarrier()
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

        SubmitInfo submit_info = vk::submitInfo()
        .setWaitSemaphores({ wait_semaphore })
        .setCommandBuffers({ command_buffer })
        .setSignalSemaphores({ signal_semaphore })
        .setWaitDstStageMask({vk::PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT});

        vk::endCommandBuffer(command_buffer)!;
        vk::queueSubmit(queue_family.graphics_handle, 1, &submit_info, frame_fence)!;

        PresentInfoKHR present_info = vk::presentInfo()
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
    joint_data.free();
    animations.release();
    swapchain_images.free();
    swapchain_views.free();
    vertices.free();
    indices.free();
    uniform_buffer.free(device);
    vertex_buffer.free(device);
    command_pool.free(device);

    descriptor_set_layout.free(device);
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

    if (node.hasSkin()) {
        Skin skin = gltf.skins[node.skin];
        foreach (joint_index, joint: skin.joints) {
           Node joint_node = gltf.nodes[joint];
           joint_data[joint_index] = joint_node.globalMatrix().mul(skin.inverseBindMatrices[joint_index]).transpose();
        }
        joint_buffer.upload(joint_data.entries, joint_data.byte_size(), device);
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

        vk::Image texture_image = vk::imageCreateInfo()
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

        MemoryBlock stage_image = device.staging_buffer(size: (usz)image_data.width * image_data.height * 4, data: image_data.pixels, pdevice: physical_device)!;
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

        device.@single_time_command(queue: queue_family.graphics_handle, queue_index: queue_family.graphics; CommandBuffer command_buffer) {
           
            vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo()
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

            vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo()
            .setImageMemoryBarriers({ finalize_barrier }));
        }!;

        texture.sampler = vk::samplerCreateInfo()
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

        texture.imageView = vk::imageViewCreateInfo()
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

    depth_texture.imageLayout = vk::IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;

    depth_image = vk::imageCreateInfo()
    .setImageType(vk::IMAGE_TYPE_2D)
    .setExtent({.width = WIDTH, .height = HEIGHT, .depth = 1 })
    .setMipLevels(1)
    .setArrayLayers(1)
    .setSamples(vk::SAMPLE_COUNT_1_BIT)
    .setUsage(vk::IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | vk::IMAGE_USAGE_SAMPLED_BIT)
    .setInitialLayout(vk::IMAGE_LAYOUT_UNDEFINED)
    .setTiling(vk::IMAGE_TILING_OPTIMAL)
    .setFormat(depth_format)
    .build(device)!;

    depth_image.bind(&device_allocation)!;

    depth_texture.sampler = vk::samplerCreateInfo()
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
        
    depth_texture.imageView = vk::imageViewCreateInfo()
        .setViewType(vk::IMAGE_VIEW_TYPE_2D)
        .setFormat(depth_format)
        .setSubresourceRange({
          .aspectMask = vk::IMAGE_ASPECT_DEPTH_BIT,
          .baseMipLevel = 0,
          .baseArrayLayer = 0,
          .layerCount = 1,
          .levelCount = 1,
        })
        .setImage(depth_image)
        .build(device)!;

    device.@single_time_command(queue: queue_family.graphics_handle, queue_index: queue_family.graphics; CommandBuffer command_buffer) {
       ImageMemoryBarrier imageMemoryBarrier = vk::imageMemoryBarrier()
       .setImage(depth_image)
       .setSubresourceRange({
          .aspectMask = vk::IMAGE_ASPECT_DEPTH_BIT,
          .baseMipLevel = 0,
          .baseArrayLayer = 0,
          .layerCount = 1,
          .levelCount = 1,
       })
       .setSrcAccessMask(0)
       .setDstAccessMask(vk::ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)
       .setOldLayout(vk::IMAGE_LAYOUT_UNDEFINED)
       .setNewLayout(vk::IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL);

       vk::cmdPipelineBarrier(
           command_buffer,
           vk::PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | vk::PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
           vk::PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | vk::PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
           0,
           0,
           null,
           0,
           null,
           1,
           &imageMemoryBarrier
       );
    }!;
}