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

BufferMap buffer_map;

Gltf gltf;
List(<Vertex>) vertices;
List(<ushort>) indices;
List(<Matrix4f>) joints;
Animations animations;

fn void! main()
{
    c3w::Window win = c3w::new(
        params: {
            .width = 800,
            .height = 600,
            .x = 0,
            .y = 0
        },
        name: "GLTF animation"
    );
    defer win.free();

    // Vulkan context
    DeviceContext context = helpers::createContext(win, debug: false)!!;
    defer context.free();

    // Create camera
    camera::Camera camera = camera::new(eye: {0.0, 5.0, 10}, aspect: 800/600, min_zoom: 0.01, max_zoom: 1000);

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

    buffer_map = *BufferMap{}.new_init_with_key_values(
        "vertex", vk::bufferCreateInfo()
            .setUsage(vk::BUFFER_USAGE_VERTEX_BUFFER_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT)
            .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
            .setSize(vertices.byte_size())
            .bind(&device_allocation)!,
        "index", vk::bufferCreateInfo()
            .setUsage(vk::BUFFER_USAGE_INDEX_BUFFER_BIT | vk::BUFFER_USAGE_TRANSFER_DST_BIT)
            .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
            .setSize(indices.byte_size())
            .bind(&device_allocation)!,
        "material", vk::bufferCreateInfo()
            .setUsage(vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT)
            .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
            .setSize(gltf.materials.byte_size())
            .bind(&local_allocation)!,
        "uniform", vk::bufferCreateInfo()
            .setUsage(vk::BUFFER_USAGE_UNIFORM_BUFFER_BIT)
            .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
            .setSize(UniformData.sizeof)
            .bind(&local_allocation)!,
        "joints", vk::bufferCreateInfo()
            .setUsage(vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT)
            .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
            .setSize(joints.byte_size())
            .bind(&local_allocation)!,
    );

    defer buffer_map.delete();

    // Upload data to buffer
    buffer_map.upload(
        name: "uniform",
        data: &&camera.matrix(), 
        size: UniformData.sizeof,
    )!;

    buffer_map.upload(
        name: "joints",
        data: joints.entries, 
        size: joints.byte_size(),
    )!;

    buffer_map.upload_device(
        name: "vertex",
        data: vertices.entries, 
        size: vertices.byte_size(),
        queue: context.queue_family
    )!;

    buffer_map.upload_device(
        name: "index",
        data: indices.entries, 
        size: indices.byte_size(),
        queue: context.queue_family
    )!;
    
}