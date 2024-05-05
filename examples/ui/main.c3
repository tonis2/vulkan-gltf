import std::io;
import vk;
import glfw;
import stb;
import camera;
import std::math;
import std::collections::list;
import pipelines;
import std::time;
import vge;

const WIDTH = 800;
const HEIGHT = 600;
const ENABLE_VALIDATION_LAYERS = false;
const MAX_FRAMES_IN_FLIGHT = 2;

Vec2f[] vertices = {
    {0., 0.}, 
    {1.1, -1.},
    {1.1, 1.},
    {-1.1, 1.},
    {-1.1, -1.},
};

ushort[] indices = {
    0, 1, 2, 
    0, 2, 3,
    0, 3, 4,
    0, 4, 1
};

// Load shaders
char[*] vertex_shader_data = $embed("./shaders/vertex.spv");
char[*] fragment_shader_data = $embed("./shaders/fragment.spv");

Instance instance;
DebugUtilsMessengerEXT debug_messenger;
PhysicalDevice physical_device;
QueueFamily queue_family;
Device device;

ZStringList validations;
ZStringList extensions;
ZStringList device_extensions;

vk::Format depth_format;
DescriptorImageInfo depth_texture;
vk::Image depth_image;

MemoryBlock index_buffer;
MemoryBlock vertex_buffer;

vk::Allocation local_allocation;
vk::Allocation device_allocation;

fn void! main()
{
    List(<Line>) lines;
    defer lines.free();

    Line line = vge::createLine(.from = {0, 0}, .to = {10.0, 10.0}, .type = PrimType.BEZIER);

    glfw::init();
    glfw::windowHint(glfw::GLFW_CLIENT_API, glfw::GLFW_NO_API);
    glfw::windowHint(glfw::GLFW_RESIZABLE, glfw::GLFW_FALSE);
    glfw::windowHint(glfw::CONTEXT_VERSION_MAJOR, 4);
    glfw::windowHint(glfw::CONTEXT_VERSION_MINOR, 1);
    GLFWwindow window = glfw::createWindow(WIDTH, HEIGHT, "GLTF basic", null, null);

    if (window == null)
    {
        io::printfn("Failed to init glfw window");
        return;
    }

    EventHandler eventHandler = { .window = window };
    eventHandler.init();
    camera::Camera camera = camera::new(.eye = {0.0, 5.0, 10}, .aspect = 800/600, .min_zoom = 0.01, .max_zoom = 1000);


    validations.add_array({"VK_LAYER_KHRONOS_validation"});
    device_extensions.add_array({"VK_KHR_swapchain", "VK_KHR_push_descriptor", "VK_KHR_dynamic_rendering"});

    // SETUP extensions
    ZStringList glfw_extensions = glfw::getRequiredExtensions();
    extensions.add_all(&glfw_extensions);
    glfw_extensions.free();

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
      .apiVersion = vk::@makeApiVersion(0,1,3,0)
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

    // Required for using push descriptors
    PhysicalDeviceProperties2 deviceProps2 = vk::physicalDeviceProperties2Builder()
                                                .setNext(&&vk::physicalDevicePushDescriptorPropertiesKHRBuilder().setMaxPushDescriptors(1));

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

    DeviceQueueCreateInfo graphicsInfo = vk::deviceQueueCreateInfoBuilder()
    .setQueueFamilyIndex(queue_family.graphics)
    .setQueuePriorities({1.0});

    device = vk::deviceCreateInfoBuilder()
      .setQueueCreateInfos({ graphicsInfo })
      .setEnabledExtensionNames(device_extensions.array_view())
      .setNext(&device_features)
      .build(physical_device)!;

       queue_family.graphics_handle = device.getQueue(queue_family.graphics);

    SurfaceFormatList surface_formats = surface.getFormats(physical_device)!;
    PresentModeList present_modes = surface.getPresentModes(physical_device)!;
    SurfaceCapabilitiesKHR capabilities = surface.deviceSurfaceCapabilities(physical_device)!;

    defer {
      surface_formats.free();
      present_modes.free();
    }
    
    depth_format = vk::findDepthFormat(.device = physical_device, .features = vk::FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT);
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


    vertex_buffer = vk::bufferCreateInfoBuilder()
          .setUsage(vk::BUFFER_USAGE_VERTEX_BUFFER_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT)
          .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
          .setSize(vertices.len * Vec2f.sizeof)
          .bind(&device_allocation)!;

    index_buffer = vk::bufferCreateInfoBuilder()
          .setUsage(vk::BUFFER_USAGE_INDEX_BUFFER_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT)
          .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
          .setSize(indices.len * ushort.sizeof)
          .bind(&device_allocation)!;

}