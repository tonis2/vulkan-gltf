module pipelines;

import std::io;
import std::collections;
import vk;
import std::encoding::json;

def TextureList = List(<DescriptorImageInfo>);

struct DescriptorInfo {
    uint binding;
    DescriptorType type;
    ShaderStageFlagBits stage;
    TextureList textures;
    MemoryBlock buffer;
}

// struct PipelineData {
//     List(<WriteDescriptorSet>) descriptor_data;
//     DescriptorSetLayout descriptor_layout;
//     PipelineLayout pipeline_layout;
//     Shader shader;
// }

struct RenderState {
    Shader shader;

    List(<WriteDescriptorSet>) descriptor_data;
    List(<DescriptorSetLayoutBinding>) descriptor_layout_bindings;

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
    DescriptorInfo[] descriptors;
}

fn void RenderState.free(self, Device device) {
    self.shader.free(device);
    self.descriptor_layout.free(device);
    self.pipeline_layout.free(device);
    self.pipeline.free(device);
    self.descriptor_layout_bindings.free();
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
    .setDepthCompareOp(vk::COMPARE_OP_LESS)
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

