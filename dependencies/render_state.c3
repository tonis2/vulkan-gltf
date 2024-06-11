module pipelines;
import std::math;
import std::io;
import std::collections;
import vk;
import std::encoding::json;
import stb;

def DescriptorImages = List(<DescriptorImageInfo>);

fault TextureError
{
    FILE_NOT_FOUND,
}

fn void! DescriptorImages.loadPath(&self, String path, vk::Allocation* allocator, QueueFamily queue) {
    vk::Device device = allocator.device;
    vk::PhysicalDevice pdevice = allocator.pdevice; 

    Format image_format = vk::FORMAT_R8G8B8A8_UNORM;
    DescriptorImageInfo texture = { .imageLayout = vk::IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };

    stb::Image! image_data = stb::loadImage(path, stb::Channel.STBI_RGB_ALPHA);

    defer image_data.free()!!;

    if (catch err = image_data) {
        io::printfn("Failed loading image");
        return TextureError.FILE_NOT_FOUND?;
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
        texture_image.bind(allocator)!;

    MemoryBlock stage_image = device.staging_buffer(.size = (usz)image_data.width * image_data.height * 4, .data = image_data.pixels, .pdevice = pdevice)!;
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

    device.@single_time_command(.queue = queue.graphics_handle, .queue_index = queue.graphics; CommandBuffer command_buffer) {
        
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
                        .setMagFilter(vk::FILTER_NEAREST)
                        .setMinFilter(vk::FILTER_NEAREST)
                        .setAddressModeU(vk::SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
                        .setAddressModeV(vk::SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
                        .setAddressModeW(vk::SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
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

    self.push(texture);
}

struct RenderState {
    Shader shader;

    DescriptorSetLayout descriptor_layout;
    PipelineLayout pipeline_layout;
    Pipeline pipeline;

    PrimitiveTopology topology;
    PolygonMode polygon_mode;
    CullModeFlagBits cull_mode;
    FrontFace front_face;

    bool enable_depth;

    vk::Format[] color_attachments;
    vk::Format depth_format;
    vk::PipelineColorBlendAttachmentState[] blend_attachments;
    vk::DynamicState[] dynamic_states;
    PushConstantRange[] push_constants;
}

fn void RenderState.free(self, Device device) {
    self.shader.free(device);
    self.descriptor_layout.free(device);
    self.pipeline_layout.free(device);
    self.pipeline.free(device);
}

fn RenderState! RenderState.build(&self, Device device) {

    PipelineVertexInputStateCreateInfo vertex_info = vk::pipelineVertexInputStateCreateInfoBuilder().setVertexBindingDescriptionCount(0);

    PipelineInputAssemblyStateCreateInfo assembly_state = vk::pipelineInputAssemblyStateCreateInfoBuilder()
    .setTopology(self.topology);

    PipelineRasterizationStateCreateInfo rasterization_state = vk::pipelineRasterizationStateCreateInfoBuilder()
    .setDepthClampEnable(vk::FALSE)
    .setRasterizerDiscardEnable(vk::FALSE)
    .setDepthBiasEnable(vk::FALSE)
    .setPolygonMode(self.polygon_mode)
    .setLineWidth(1.0)
    .setCullMode(self.cull_mode)
    .setFrontFace(self.front_face);

    PipelineViewportStateCreateInfo view_port_state = {
        .sType = vk::STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };

    PipelineMultisampleStateCreateInfo multi_sample_state = vk::pipelineMultisampleStateCreateInfoBuilder()
    .setSampleShadingEnable(vk::FALSE)
    .setRasterizationSamples(vk::SAMPLE_COUNT_1_BIT)
    .setMinSampleShading(1.0)
    .setAlphaToCoverageEnable(vk::FALSE)
    .setAlphaToOneEnable(vk::FALSE);

    PipelineColorBlendStateCreateInfo color_blend_state = vk::pipelineColorBlendStateCreateInfoBuilder()
    .setBlendConstants({ 0.0, 0.0, 0.0, 0.0 })
    .setLogicOp(vk::LOGIC_OP_COPY)
    .setAttachments(self.blend_attachments);

    PipelineDynamicStateCreateInfo dynamic_states = vk::pipelineDynamicStateCreateInfoBuilder()
    .setDynamicStates(self.dynamic_states);

    PipelineRenderingCreateInfo rendering_info = vk::pipelineRenderingCreateInfoBuilder()
    .setColorAttachmentFormats(self.color_attachments)
    .setDepthAttachmentFormat(self.depth_format);

    PipelineDepthStencilStateCreateInfo depth_state = vk::pipelineDepthStencilStateCreateInfoBuilder()
    .setDepthTestEnable((uint)self.enable_depth)
    .setDepthWriteEnable((uint)self.enable_depth)
    .setDepthCompareOp(vk::COMPARE_OP_LESS_OR_EQUAL)
    .setBack({.compareOp = vk::COMPARE_OP_ALWAYS});
    // DescriptorSetLayoutCreateInfo descriptorLayoutInfo = vk::descriptorSetLayoutCreateInfoBuilder()
    //                         .setFlags(vk::DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR);

    // foreach (descriptor: self.descriptors) {
    //     WriteDescriptorSet data = vk::writeDescriptorSetBuilder()
    //         .setDstBinding(descriptor.binding)
    //         .setDescriptorType(descriptor.type);

    //     DescriptorSetLayoutBinding binding = {
    //         .binding = descriptor.binding,
    //         .descriptorType = descriptor.type,
    //         .stageFlags = descriptor.stage
    //     };

    //     if (descriptor.type == vk::DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
    //         data.setBufferInfo({
    //             {
    //                 .buffer = descriptor.buffer.buffer,
    //                 .offset = 0,
    //                 .range = descriptor.buffer.size,
    //             },
    //         });
    //         binding.descriptorCount = 1;
    //     }

    //     if (descriptor.type == vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) {
    //         data.setImageInfo(descriptor.textures.array_view());
    //         binding.descriptorCount = (uint)descriptor.textures.len();
    //     }

    //     self.descriptor_layout_bindings.push(binding);
    //     self.descriptor_data.push(data);
    // }

    // self.descriptor_layout = descriptorLayoutInfo
    // .setBindings(self.descriptor_layout_bindings.array_view())
    // .build(device)!;

    self.pipeline_layout = vk::pipelineLayoutCreateInfoBuilder()
    .setPushConstantRanges(self.push_constants)
    .setSetLayouts({ self.descriptor_layout }).build(device)!;

    GraphicsPipelineCreateInfo pipeline_info = vk::graphicsPipelineCreateInfoBuilder()
    .setStages(&self.shader.stages)
    .setLayout(self.pipeline_layout)
    .setVertexInputState(&vertex_info)
    .setDynamicState(&dynamic_states)
    .setRasterizationState(&rasterization_state)
    .setInputAssemblyState(&assembly_state)
    .setMultisampleState(&multi_sample_state)
    .setColorBlendState(&color_blend_state)
    .setViewportState(&view_port_state)
    .setDepthStencilState(&depth_state)
    .setNext(&rendering_info);

    self.pipeline = pipeline_info.build(device)!;

    return *self;
}

