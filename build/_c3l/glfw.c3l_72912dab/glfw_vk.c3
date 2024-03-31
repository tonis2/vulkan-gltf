module glfw @if($feature(GLFW_VK));
import vk;
import std::collections::list;

const VK_ENABLED = $feature(GLFW_VK);

extern fn void* getInstanceProcAddress (vk::Instance instance, char *procname) @extern("glfwGetInstanceProcAddress") @if(VK_ENABLED);
extern fn vk::Result vKcreateWindowSurface (vk::Instance instance, GLFWwindow *window, vk::AllocationCallbacks *allocator, vk::SurfaceKHR *surface) @extern("glfwCreateWindowSurface") @if(VK_ENABLED);

fn vk::SurfaceKHR! createWindowSurface(vk::Instance instance, GLFWwindow *window, vk::AllocationCallbacks *allocator) @if(VK_ENABLED) {
    vk::SurfaceKHR surface;
    if (vKcreateWindowSurface(instance, window, allocator, &surface) != 0)
    {
        return GlfwErrors.FAILED_CREATING_SURFACE?;
    }

    return surface;
}

fn ZStringList getRequiredExtensions() @if(VK_ENABLED) {
    ZStringList extensions;
    uint glfwExtensions_count = 0;
    ZString* glfwExtensions = (ZString*)glfw::getRequiredInstanceExtensions(&glfwExtensions_count);
    for (int i = 0; i < glfwExtensions_count; ++i) extensions.push(glfwExtensions[i]);

    return extensions;
}
