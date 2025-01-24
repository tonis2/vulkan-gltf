module helpers;

import std::io, std::math;
import vk;

fn usz alignUp(usz value, usz factor)  => value + factor - 1 - (value + factor - 1) % factor;

struct Memory
{
	usz size;
    usz used_size;
    usz allocator_offset;
    vk::Buffer buffer;
    vk::Image image;
	vk::Allocation* allocator;
    vk::BufferUsageFlagBits usage;
    DeviceAddress address;
}

fn Memory! new_buffer(vk::BufferUsageFlagBits usage, vk::Allocation* allocator, void* data = null, usz data_size, vk::Allocation* stage_allocator = null, DeviceQueue* queue = null)
{
    vk::Device device = allocator.device;
    vk::PhysicalDevice pdevice = allocator.pdevice;

    vk::Buffer buffer = vk::bufferCreateInfo()
    .setUsage(usage)
    .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
    .setSize(data_size)
    .build(device)!!;

    MemoryRequirements mem_reqs = buffer.memoryRequirements(device);
    uint memory_type = allocator.pdevice.getMemoryType(allocator.properties, mem_reqs.memoryTypeBits);
    
    usz size = alignUp(mem_reqs.size, mem_reqs.alignment);
    usz offset = alignUp(allocator.used_size, mem_reqs.alignment);

    if ((MemoryPropertyFlagBits)usage & vk::BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT) {
        MemoryRequirements desc_mem_reqs = {|
            PhysicalDeviceDescriptorBufferPropertiesEXT descriptorProperties = {
                .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT,
            };

            PhysicalDeviceProperties2 device_properties = vk::physicalDeviceProperties2()
            .setNext(&descriptorProperties)
            .build(pdevice);

            return MemoryRequirements {
                .size = alignUp(data_size, descriptorProperties.descriptorBufferOffsetAlignment),
                .alignment = descriptorProperties.descriptorBufferOffsetAlignment
            };
        |};
        mem_reqs.size = desc_mem_reqs.size;
        mem_reqs.alignment = desc_mem_reqs.alignment;
    }

    if (memory_type != allocator.memory_type) {
        io::printfn("Allocation memory type is %d, but buffer requires %d", allocator.memory_type, memory_type);
    }

    if ((allocator.size - allocator.used_size) < size) {
        io::printfn("Allocation has no enough free memory");
        return BufferError.ALLOCATION_HAS_NO_ROOM?;
    };

    vk::bindBufferMemory(allocator.device, buffer, allocator.memory, offset)!!;
    allocator.used_size += size;

    vk::DeviceAddress address;

    if ((MemoryPropertyFlagBits)usage & vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT) {
        BufferDeviceAddressInfo address_info = {
            .sType = vk::STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
            .buffer = buffer
        };
        address = vk::getBufferDeviceAddress(allocator.device, &address_info);
    }

    Memory response = {
        .buffer = buffer,
        .size = size,
        .used_size = 0,
        .allocator_offset = offset,
        .allocator = allocator,
        .address = address,
    };
    
    // CPU & GPU
    if ((MemoryPropertyFlagBits)allocator.properties & (vk::MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk::MEMORY_PROPERTY_HOST_CACHED_BIT) && data != null) {
        response.upload(data, data_size); 
    }
    // GPU only
    if ((MemoryPropertyFlagBits)allocator.properties & vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT && data != null) {
        if (stage_allocator == null) {
            io::printfn("Add stage allocator for uploading to GPU");
            return BufferError.ALLOCATION_HAS_NO_ROOM?;
        }

        Memory stage_buffer = new_buffer(
            vk::BUFFER_USAGE_TRANSFER_SRC_BIT,
            stage_allocator,
            data,
            data_size: data_size
        )!;

        device.@single_time_command(queue: *queue; CommandBuffer command_buffer) {
            vk::cmdCopyBuffer(command_buffer, stage_buffer.buffer, response.buffer, 1, &&BufferCopy {
                .srcOffset = 0,
                .dstOffset = 0,
                .size = data_size
            });
        }!;

        stage_buffer.free();
    }

    return response;
}

fn Memory! create_image_buffer(
    vk::Image image, 
    vk::Allocation* allocator
)
{
    vk::Device device = allocator.device;
    vk::PhysicalDevice pdevice = allocator.pdevice;

    MemoryRequirements mem_reqs = image.getMemoryRequirements(device);
    uint memory_type = allocator.pdevice.getMemoryType(allocator.properties, mem_reqs.memoryTypeBits);

    usz size = alignUp(mem_reqs.size, mem_reqs.alignment);
    usz offset = alignUp(allocator.used_size, mem_reqs.alignment);

    if (allocator.size - allocator.used_size < size) {
       io::printfn("Allocation has no enough free memory");
       return BufferError.ALLOCATION_HAS_NO_ROOM?;
    }

    vk::bindImageMemory(device, image, allocator.memory, offset)!;
    allocator.used_size += size;

    Memory response = {
        .image = image,
        .size = size,
        .used_size = 0,
        .allocator_offset = offset,
        .allocator = allocator
    };

    return response;
}


fn void Memory.upload(&self, void* data, ulong size, usz offset = 0)
{
    mem::copy(self.allocator.mapped + self.allocator_offset + offset, data, size);
}

fn void! Memory.upload_from_stage(&self, void* data, usz data_size, vk::Allocation* stage_allocator, DeviceQueue queue)
{
    vk::Device device = self.allocator.device;
    vk::PhysicalDevice pdevice = self.allocator.pdevice;

    Memory stage_buffer = new_buffer(
        vk::BUFFER_USAGE_TRANSFER_SRC_BIT,
        stage_allocator,
        data,
        data_size: data_size
    )!;

    device.@single_time_command(queue: queue; CommandBuffer command_buffer) {
        vk::cmdCopyBuffer(command_buffer, stage_buffer.buffer, self.buffer, 1, &&BufferCopy {
            .srcOffset = 0,
            .dstOffset = 0,
            .size = data_size
        });
    }!;

    stage_buffer.free();
}

fn void Memory.push(&self, void* data, ulong size, usz offset = 0)
{
    mem::copy(self.allocator.mapped + self.allocator_offset + offset + self.used_size, data, size);
    self.used_size += size;
}

fn void Memory.free(&self)
{
    self.allocator.used_size -= self.size;
    if (self.buffer != null) {
        vk::destroyBuffer(self.allocator.device, self.buffer, null);
    }

    if (self.image != null) {
        vk::destroyImage(self.allocator.device, self.image, null);
    }
}