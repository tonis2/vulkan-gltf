module helpers::buffer(<Type>);

import std::io, std::math;
import vk;

// def ElementPredicate = fn bool(Type *type);
// def ElementTest = fn bool(Type *type, any context);
// const ELEMENT_IS_EQUATABLE = types::is_equatable_type(Type);
// const ELEMENT_IS_POINTER = Type.kindof == POINTER;

fn usz alignUp(usz value, usz factor)  => value + factor - 1 - (value + factor - 1) % factor;

struct Buffer
{
	usz size;
    usz used_size;
    usz allocator_offset;
    vk::Buffer buffer;
	vk::Allocation* allocator;
    vk::BufferUsageFlagBits usage;
    DeviceAddress address;
}

fn Buffer Buffer.new(vk::BufferUsageFlagBits usage, vk::Allocation* allocator, Type* data, usz data_size = 0) @operator(construct)
{   
    if (data_size == 0) data_size = Type.sizeof;

    vk::Device device = allocator.device;
    vk::PhysicalDevice pdevice = allocator.pdevice;

    vk::Buffer buffer = vk::bufferCreateInfo()
    .setUsage(usage)
    .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
    .setSize(data_size)
    .build(device)!!;

    MemoryRequirements mem_reqs = buffer.memoryRequirements(device);
    uint memory_type = allocator.pdevice.getMemoryType(allocator.properties, mem_reqs.memoryTypeBits);

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

    usz size = alignUp(mem_reqs.size, mem_reqs.alignment);

    if ((allocator.size - allocator.used_size) < size) io::printfn("Allocation has no enough free memory");
    assert((allocator.size - allocator.used_size) > size);

    usz offset = alignUp(allocator.used_size, mem_reqs.alignment);
    vk::bindBufferMemory(allocator.device, buffer, allocator.memory, offset)!!;
 
    usz allocator_offset = allocator.used_size;
    allocator.used_size += size;
    vk::DeviceAddress address;

    if ((MemoryPropertyFlagBits)usage & vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT) {
        BufferDeviceAddressInfo address_info = {
            .sType = vk::STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
            .buffer = buffer
        };
        address = vk::getBufferDeviceAddress(allocator.device, &address_info);
    }

    Buffer response = Buffer {
        .buffer = buffer,
        .size = data_size,
        .used_size = 0,
        .allocator_offset = allocator_offset,
        .allocator = allocator,
        .address = address,
    };
    
    if (data != null) {
        // Device
        if ((MemoryPropertyFlagBits)allocator.properties & vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT) {

        }

        // Local
        if ((MemoryPropertyFlagBits)allocator.properties & (vk::MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk::MEMORY_PROPERTY_HOST_CACHED_BIT)) {
            response.upload(data, data_size);
        }
    }

    return response;
}

fn void Buffer.upload(&self, void* data, ulong size, usz offset = 0)
{
    mem::copy(self.allocator.mapped + self.allocator_offset + offset, data, size);
}

fn void Buffer.push(&self, void* data, ulong size, usz offset = 0)
{
    mem::copy(self.allocator.mapped + self.allocator_offset + offset + self.used_size, data, size);
    self.used_size += size;
}

fn void Buffer.free(&self)
{
    vk::destroyBuffer(self.allocator.device, self.buffer, null);
}

// macro Buffer @from_list(#list, vk::BufferUsageFlagBits flags, vk::Allocation* allocator)
// {
//     usz list_size = #list.byte_size();

// }
