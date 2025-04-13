module ecs;

import std::math;
import std::io;
import std::collections::list;
import std::collections::map;
import std::encoding::json;
import std::core::builtin;

enum GpuType : uint
{
    HOST_VISIBLE,
    DEVICE_ONLY,
    CPU_ONLY
}

enum Action : uint
{
    STAGE_TO_GPU,
}

interface Allocator
{
    fn void push(void* data, usz size);
    fn void setUsedSize(usz size);
    fn char* data();
    fn void upload(void* data, usz size, usz offset);
    fn ulong getAddress();
    fn usz usedSize();
    fn uint getType();
    fn void* getBuffer();
    fn void free();
}

fault Error
{
   NO_KEY_FOUND,
   COMPONENT_BUFFER_OVERFLOW,
}

struct Component {
    uint id;
    uint size;
    uint buffer;
    usz used_size;
    usz offset;
}

bitstruct Entity : ulong {
    uint id : 0..31;
    uint bitmask : 32..63;
}

bitstruct BufferID : ulong {
    uint component : 0..31;
    uint entity : 32..63;
}

def ComponentMap = HashMap(<String, Component>);
def ViewMap = HashMap(<BufferID, uint>);

macro uint BufferID.hash(BufferID i) => builtin::@generic_hash((ulong)i);

struct EntityManager {
    ComponentMap keys;
    ViewMap views;
    List(<Component>) components;
    List(<Allocator>) buffers;
    List(<Entity>) entities;
    UploadFN uploadFN;
}

fn EntityManager create_manager(Allocator[] buffers, UploadFN uploadFN = null) {
    EntityManager manager = {
        .uploadFN = uploadFN,
    };
    foreach (buffer: buffers) manager.buffers.push(buffer);
    return manager;
}

def UploadFN = fn void (Allocator buffer, void* data, usz data_size, usz offset);


fn void EntityManager.free(&self) {
    // foreach (buffer: self.buffers) {
    //     buffer.free();
    // };
    self.buffers.free();
    self.keys.free();
    self.views.free();
    self.entities.free();
}

macro void EntityManager.@query(self, ...; @callback(Entity entity)) {
    foreach (entity: self.entities) {
        bool is_valid = true;
        $for (var $i = 0; $i < $vacount; $i++);
            is_valid = entity.has_name($vaarg[$i], self);
        $endfor
        if (is_valid) @callback(entity);
    }
}

fn bool Entity.has_name(self, String name, EntityManager manager) {
    Component! key = manager.keys[name];

    if (try key) {
        uint mask = 1 << key.id;
        return self.bitmask & mask == mask;
    }

    return false;
}

fn Component EntityManager.new_component(&self, void* data = null, uint size = 0, uint buffer_index) {
    Allocator buffer = self.buffers[buffer_index];
    Component component = {
        .id = (uint)self.components.len(),
        .size = size,
        .buffer = buffer_index,
        .offset = buffer.usedSize()
    };

    self.components.push(component);
 
    if (data != null) {
        if (buffer.getType() == GpuType.DEVICE_ONLY.ordinal) {
            self.uploadFN(buffer, data, size, component.offset);
            buffer.setUsedSize(buffer.usedSize() + size);
        } else {
            buffer.push(data, size);
        }
    } else {
        buffer.setUsedSize(buffer.usedSize() + size);
    }

    return component;
}

macro Component EntityManager.@create_component(&self, #type = null, uint size = 0, void* data = null, int buffer_index = -1) {
    uint default_buffer = buffer_index >= 0 ? buffer_index : 0;

    if (size == 0 && data == null) {
        $if $typeof(#type).has_tagof("BUFFER"):
            default_buffer = $typeof(#type).tagof("BUFFER");
        $endif
        return self.new_component(&&#type, $typeof(#type).sizeof, default_buffer);
    } else {
        return self.new_component(data, size, default_buffer);
    }
}

macro Entity EntityManager.@create_entity(&self, ...) {
    String type_name;
    Entity entity = {.id = (uint)self.entities.len()};

    uint size = 0;
    uint buffer_index = 0;
    uint type_id = 0;
    Component component;

    // Loop over entity data
    $for (var $i = 0; $i < $vacount; $i++);
        buffer_index = 0;
        type_name = $typeof($vaarg[$i]).nameof;
        size += $typeof($vaarg[$i]).sizeof;

        $if $typeof($vaarg[$i]).has_tagof("BUFFER"):
            buffer_index = $typeof($vaarg[$i]).tagof("BUFFER");
        $endif

        $if $typeof($vaarg[$i]).nameof == "Component":
            component = $vaarg[$i];
        $else
            component = self.@create_component($vaarg[$i], buffer_index: buffer_index);
        $endif
    
        if (!self.keys.has_key(type_name)) {
            self.keys[type_name] = {
                .id = (uint)self.keys.len(),
                .buffer = buffer_index,
            };
        }
        
        type_id = self.keys[type_name]!!.id;
        entity.bitmask |= 1 << type_id;

        self.views[BufferID {
            .component = type_id,
            .entity = entity.id,
        }] = component.id;

    $endfor

    self.entities.push(entity);
    return entity;
}

macro bool Entity.@has_type(self, #type, EntityManager manager) {
    Component! key = manager.keys[#type.nameof];

    if (try key) {
        uint mask = 1 << key.id;
        return self.bitmask & mask == mask;
    }

    return false;
}

fn void Entity.add(&self, String type_name, Component component, EntityManager manager) {
    if (!manager.keys.has_key(type_name)) {
        manager.keys[type_name] = {
            .id = (uint)manager.keys.len(),
            .buffer = component.buffer,
        };
    }
    
    self.bitmask |= 1 << manager.keys[type_name]!!.id;
    manager.entities[self.id].bitmask = self.bitmask;
    manager.views[BufferID {
        .component = manager.keys[type_name]!!.id,
        .entity = self.id,
    }] = component.id;
}

fn uint get_size(Entity entity, EntityManager manager) {
    uint size;
    @pool() {
        foreach (key : manager.views.tcopy_keys()) {
            if (key.entity == entity.id) {
                size += manager.components[manager.views[key]!!].size;
            }
        }
    };
 
    return size;
}

// macro Entity.@set_value(self, #type, #data, EntityManager manager, usz offset = 0) {
//     Component component = manager.keys[#type.nameof]!!;
//     BufferID index = {
//         .component = component.id,
//         .entity = self.id,
//     };

//     Allocator buffer = manager.buffers[component.buffer];
//     uint type_offset = manager.views[index]!!;

//     return buffer.upload(&&#data, $typeof(#data).sizeof, type_offset + offset);
// }


macro @upload(EntityManager manager, #target, #data, usz size = 0, usz offset = 0) {
    usz data_size = size > 0 ? size : $typeof(*#data).sizeof;

    $if $typeof(#target).nameof == "Component":
        Allocator buffer = manager.buffers[#target.buffer];
        usz data_offset = #target.offset + offset;
   
        // if (data_offset + data_size > #target.size) {
        //     return Error.COMPONENT_BUFFER_OVERFLOW?;
        // }

        if (buffer.getType() == GpuType.DEVICE_ONLY.ordinal) {
            manager.uploadFN(buffer, #data, data_size, data_offset);
        } else {
            buffer.upload(#data, data_size, data_offset);
        }
    $endif;

    $if $typeof(#target).nameof == "Entity":
        Component component_info = manager.keys[$typeof(*#data).nameof]!!;
        BufferID index = {
            .component = component_info.id,
            .entity = #target.id,
        };

        usz data_offset = (uint)manager.components[manager.views[index]!!].offset + offset;

        // if (data_offset + data_size > component_info.size) {
        //     return Error.COMPONENT_BUFFER_OVERFLOW?;
        // }

        Allocator buffer = manager.buffers[component_info.buffer];

        if (buffer.getType() == GpuType.DEVICE_ONLY.ordinal) {
            manager.uploadFN(buffer, #data, data_size, data_offset);
        } else {
            buffer.upload(#data, data_size, data_offset);
        }
    $endif;
}


macro @get(EntityManager manager, #target, #type, usz offset = 0) {
    $if $typeof(#target).nameof == "Component":
        Allocator buffer = manager.buffers[#target.buffer];
        uint type_offset = #target.offset;

        return bitcast(*(char[#type.sizeof]*)buffer.data()[type_offset..(type_offset + #type.sizeof)], #type);
    $endif;

    $if $typeof(#target).nameof == "Entity":
        Component component = manager.keys[#type.nameof]!!;
        BufferID index = {
            .component = component.id,
            .entity = #target.id,
        };

        Allocator buffer = manager.buffers[component.buffer];
        uint type_offset = (uint)manager.components[manager.views[index]!!].offset;
        return bitcast(*(char[#type.sizeof]*)buffer.data()[type_offset..(type_offset + #type.sizeof)], #type);
    $endif;
}

macro @get_address(EntityManager manager, #target, #type = null, usz offset = 0) {
    $if $typeof(#target).nameof == "Component":
        return manager.buffers[#target.buffer].getAddress() + #target.offset + offset;
    $endif;

    $if $typeof(#target).nameof == "Entity":
        Component component = manager.keys[#type.nameof]!!;
        BufferID index = {
            .component = component.id,
            .entity = #target.id,
        };

        Allocator buffer = manager.buffers[component.buffer];
        uint type_offset = (uint)manager.components[manager.views[index]!!].offset;
        return manager.buffers[component.buffer].getAddress() + type_offset + offset;
    $endif;
}

macro @get_offset(EntityManager manager, #target, #type = null) {
    $if $typeof(#target).nameof == "Component":
        return (uint)#target.offset;
    $endif;

    $if $typeof(#target).nameof == "Entity":
        Component component = manager.keys[#type]!;

        BufferID index = {
            .component = component.id,
            .entity = #target.id,
        };

        return (uint)manager.components[manager.views[index]!].offset;
    $endif;
}

struct Buffer (Allocator) {
    usz size;
    usz used_size;
    char* mapped;
}

fn void Buffer.push(&self, void* data, usz size) @dynamic {
    if (self.used_size + size > self.size) {
        self.ensure_size(self.used_size + size);
        mem::copy(self.mapped + self.used_size, data, size);
        self.used_size += size;
    } else {
        mem::copy(self.mapped + self.used_size, data, size);
        self.used_size += size;
    }
}

fn void Buffer.ensure_size(&self, usz new_size) @dynamic {
    if (new_size > self.size) {
        self.mapped = mem::realloc(self.mapped, new_size);
        self.size = new_size;
    }
}

fn void Buffer.upload(&self, void* data, usz size, usz offset) @dynamic {
    mem::copy(self.mapped + offset, data, size);
}

fn void Buffer.free(&self) @dynamic {
    mem::free(self.mapped);
    self.size = 0;
    self.used_size = 0;
}

fn char* Buffer.data(&self) @dynamic => self.mapped;
fn usz Buffer.usedSize(&self) @dynamic => self.used_size;
fn ulong Buffer.getAddress(&self) @dynamic => 0;
fn uint Buffer.getType(&self) @dynamic => 2;
fn void* Buffer.getBuffer(&self) @dynamic => null;
fn void Buffer.setUsedSize(&self, usz size) @dynamic {
    self.ensure_size(size);
    self.used_size = size;
}

module ecs @if($feature(ECS_EXTRA));
import gltf;
import std::math;
import std::io;
import std::collections::list;
import std::collections::map;
import std::time;

def AnimationMap = HashMap(<String, AnimationChannel>);
def AnimationChannel = List(<AnimationFrame>);
def NodeMap = HashMap(<uint, uint>);
def MeshMap = HashMap(<String, MeshData>);

struct Animations {
    AnimationSkin skin;
    AnimationMap channels;
    EntityManager manager;
    Component component;
    List(<AnimationValue>) values;
}

struct AnimationSkin {
    String name;
    List(<Node>) nodes;
    NodeMap node_map;
}

enum AnimationProperty {
    TRANSLATION,
    ROTATION,
    SCALE,
    WEIGHTS,
    POINTER
}

enum Interpolation {
    LINEAR,
    STEP,
    CUBICSPLINE,
}

struct AnimationValue {
    float time;
    Vec4f value;
}

struct AnimationFrame {
    double elapsed_time;
    double max_time;
    uint node;
    usz value_offset;
    usz value_count;
    AnimationProperty path;
    Interpolation interpolation;
}

struct Node {
    Vec3f scale;
    Vec3f translation;
    Quaternionf rotation;
    Matrix4f matrix;
    Matrix4f inverse_bind;
    int parent;
}

struct MeshData {
    uint indexCount;
    uint firstInstance;
    uint instanceCount;
    uint firstIndex;
    uint vertexOffset;
    int materialIndex;
}

struct AnimationInfo {
    gltf::Skin skin;
    uint buffer_index;
    String[] channels;
}

struct MeshInfo {
    String name;
    gltf::Mesh data;
}

struct Vertex {
    Vec3f pos;
    Vec3f normal;
    Vec2f tex_cord;
    Vec4f tangent;
    uint[4] skin_pos;
    Vec4f skin_weight;
}

fn MeshData*! MeshMap.add_mesh(&self, Gltf gltf, EntityManager manager, Component* vertices, Component* indices, MeshInfo mesh) {
    List(<Vertex>) vertex_data;
    List(<ushort>) index_data;

    MeshData data = {
        .firstIndex = (uint)indices.used_size / ushort.sizeof,
        .vertexOffset = (uint)vertices.used_size / Vertex.sizeof,
    };

    foreach (primitive: mesh.data.primitives) {
        Accessor index_accessor = gltf.accessors[primitive.attributes["indices"]!!];
        Accessor pos_accessor = gltf.accessors[primitive.attributes["POSITION"]!!];

        data.indexCount += index_accessor.count;
        data.materialIndex = (int)primitive.attributes["material"] ?? -1;

        for (usz i; i < index_accessor.count; i++) {
            index_data.push(gltf.@castBuffer(index_accessor, i, ushort));
        }

        for (usz i; i < pos_accessor.count; i++) {
            Vec2f tex_cord = {|
                usz! attribute = primitive.attributes["TEXCOORD_0"];
                if (catch err = attribute) return Vec2f {0,0};

                Accessor accessor = gltf.accessors[attribute];
                return gltf.@castBuffer(accessor, i, Vec2f);
            |};

            Vec3f normal = {|
                usz! attribute = primitive.attributes["NORMAL"];
                if (catch err = attribute) return Vec3f {0,0,0};

                Accessor accessor = gltf.accessors[attribute];
                return gltf.@castBuffer(accessor, i, Vec3f);
            |};

            Vec4f tangent = {|
                usz! attribute = primitive.attributes["TANGENT"];
                if (catch err = attribute) return Vec4f {0,0,0,0};
                Accessor accessor = gltf.accessors[attribute];
                return gltf.@castBuffer(accessor, i, Vec4f);
            |};

            uint[4] skin_pos = {|
                usz! attribute = primitive.attributes["JOINTS_0"];
                if (catch err = attribute) return uint[4] {0,0,0,0};
                Accessor accessor = gltf.accessors[attribute];

                if (accessor.data_type == DataType.USHORT) {
                    short[4] array = gltf.@castBuffer(accessor, i, short[4]);
                    return uint[4]{array[0], array[1], array[2], array[3]};
                };

                if (accessor.data_type == DataType.CHAR) {
                    char[4] array = gltf.@castBuffer(accessor, i, char[4]);
                    return uint[4]{array[0], array[1], array[2], array[3]};
                };

                return uint[4] {0,0,0,0};
            |};

            Vec4f skin_weight = {|
                usz! attribute = primitive.attributes["WEIGHTS_0"];
                if (catch err = attribute) return Vec4f {0,0,0,0};

                Accessor accessor = gltf.accessors[attribute];
                return gltf.@castBuffer(accessor, i, Vec4f);
            |};

            Vec3f position = gltf.@castBuffer(pos_accessor, i, Vec3f);

            vertex_data.push({
                .pos = position,
                .normal = normal,
                .tex_cord = tex_cord,
                .tangent = tangent,
                .skin_pos = skin_pos,
                .skin_weight = skin_weight
            });
        }
    }

    if (vertex_data.byte_size() + vertices.used_size > vertices.size || index_data.byte_size() + indices.used_size > indices.size) {
        return Error.COMPONENT_BUFFER_OVERFLOW?;
    }

    @upload(manager, *vertices, vertex_data.entries, size: vertex_data.byte_size(), offset: vertices.used_size);
    @upload(manager, *indices, index_data.entries, size: index_data.byte_size(), offset: indices.used_size);

    indices.used_size += index_data.byte_size();
    vertices.used_size += vertex_data.byte_size();

    vertex_data.free();
    index_data.free();

    self.set(mesh.name, data);

    return self.get_ref(mesh.name)!!;
}


fn Animations! create_animation(AnimationInfo info, Gltf gltf, EntityManager manager) {
    AnimationSkin skin_data = load_skin_data(info.skin, gltf);

    Animations animations =  {
        .skin = skin_data,
        .manager = manager,
        .component = manager.@create_component(size: (uint)animations.skin.nodes.len() * Matrix4f.sizeof, buffer_index: info.buffer_index),
    };

    foreach (channel_name: info.channels) {
        gltf::Animation! animation = gltf.findAnimation(channel_name);

        if (try animation) {
            animations.channels[channel_name] = load_animation_data(animation, animations.skin, gltf, &animations.values)!;
        } else {
            io::printfn("animation channel %s not found", channel_name);
        }
    }

    return animations;
}

fn Matrix4f Node.global_matrix(self, List(<Node>) nodes) {
    Matrix4f current_matrix = self.local_matrix();
    Node active_node = self;

    while (active_node.parent != -1) {
        Node parent = nodes[active_node.parent];
        current_matrix = parent.local_matrix().mul(current_matrix);
        active_node = parent;
    }

    return current_matrix;
}

fn Matrix4f Node.local_matrix(&self) => to_matrix(self.translation, self.scale, self.rotation);

fn Matrix4f to_matrix(Vec3f translation, Vec3f scale, Quaternionf rotation) {
    return Matrix4f {
        scale.x, 0, 0, translation.x,
        0, scale.y, 0, translation.y,
        0, 0, scale.z, translation.z,
        0.0, 0.0, 0.0, 1.0,
    }.mul(rotation.to_matrixf());
}

fn void Animations.free(self) {
    self.skin.free();
    self.values.free();

    @pool() {
        foreach (key : self.channels.tcopy_keys()) {
            self.channels[key]!!.free();
        }
    };

    self.channels.free();
}

<*
 @require time > 0 "Time must be bigger than 0"
*>
fn void! Animations.run_animation(&self, String name, double time) {
    AnimationChannel* channel = self.channels.get_ref(name)!;
    channel.run_animation(self.values, &self.skin, time);

    foreach (index, node: self.skin.nodes) {
        Matrix4f matrix = node.global_matrix(self.skin.nodes).mul(node.inverse_bind).transpose();
        ecs::@upload(self.manager, self.component, &matrix, size: Matrix4f.sizeof, offset: index * Matrix4f.sizeof);
    }
}

fn void AnimationSkin.free(self) {
    self.nodes.free();
    self.node_map.free();
}

fn void parse_nodes(List(<uint>)* joints, 
                    List(<uint>) src_joints, 
                    List(<Node>)* target_nodes, 
                    List(<gltf::Node>) gltf_nodes, 
                    List(<Matrix4f>) inverseBindMatrices,
                    NodeMap* node_map,
                    int parent = -1) @private
{
    foreach (joint : src_joints) {
        if (joints.contains(joint)) {
            continue;
        };
        
        gltf::Node node = gltf_nodes[joint];
        node_map.set(joint, (uint)target_nodes.len());

        Matrix4f inverse_bind = MATRIX4F_IDENTITY;

        if (target_nodes.len() < inverseBindMatrices.len()) {
            inverse_bind = inverseBindMatrices[target_nodes.len()];
        }   
       
        target_nodes.push({
            .scale = node.scale,
            .translation = node.translation,
            .rotation = node.rotation,
            .inverse_bind = inverse_bind,
            .parent = parent
        });
        
        joints.push(joint);

        parse_nodes(joints, node.children, target_nodes, gltf_nodes, inverseBindMatrices, node_map, (int)target_nodes.len() - 1);
    }
}

fn AnimationSkin load_skin_data(gltf::Skin skin, Gltf gltf) {
    List(<uint>) joints;

    AnimationSkin animation;
    Accessor skin_accessor = gltf.accessors[skin.inverseBindAccessor];
    List(<Matrix4f>) inverseBindMatrices;

    for (uint i = 0; i < skin_accessor.count; i++) {
        Matrix4f matrix = gltf.@castBuffer(skin_accessor, i, Matrix4f).transpose();
        inverseBindMatrices.push(matrix);
    }

    parse_nodes(&joints, skin.joints, &animation.nodes, gltf.nodes, inverseBindMatrices, &animation.node_map);
    joints.free();
    inverseBindMatrices.free();
    return animation;
}


fn AnimationChannel! load_animation_data(gltf::Animation animation, AnimationSkin skin, Gltf gltf, List(<AnimationValue>)* values) {
    AnimationChannel response;    
    foreach (channel : animation.channels) {
        AnimationSampler sampler = animation.samplers[channel.sampler];

        Accessor time_accessor = gltf.accessors[sampler.input];
        Accessor value_accessor = gltf.accessors[sampler.output];

        uint node_index = skin.node_map[(uint)channel.target.node]!;

        AnimationFrame frame = {
            .elapsed_time = 0,
            .path = AnimationProperty.from_ordinal(channel.target.path.ordinal),
            .node = node_index,
            .interpolation = Interpolation.from_ordinal(sampler.interpolation.ordinal),
            .value_offset = values.len(),
            .value_count = time_accessor.count
        };

        if (time_accessor.max.len() > 0) {
            frame.max_time = time_accessor.max[0];
        } else {
            frame.max_time = 1;
            io::printfn("Animation has no max time");
        }

        for (ulong i; i < time_accessor.count; i++) {
            values.push({
                .time = gltf.@castBuffer(time_accessor, i, float),
                .value = gltf.@castBuffer(value_accessor, i, Vec4f),
            });
        }
        response.push(frame);
    };

    return response;
}


fn void AnimationChannel.run_animation(&self, List(<AnimationValue>) values, AnimationSkin* skin, double current_time) {
    foreach (&channel: self) {
        channel.elapsed_time += current_time;
        if (channel.elapsed_time > channel.max_time) channel.elapsed_time = 0;

        for (uint index = 0; index < channel.value_count; index++) {
            AnimationValue current_value = values[index + channel.value_offset];

            if (channel.elapsed_time < current_value.time && index > 0) {
                Node* node = &skin.nodes[channel.node];
                if (channel.interpolation == STEP) {
                        switch (channel.path) {
                            case TRANSLATION: {
                                node.translation = current_value.value.xyz;
                            }
                            case ROTATION: {
                                node.rotation = Quaternionf{.v = current_value.value};
                            }
                            case SCALE: {
                                node.scale = current_value.value.xyz;
                            }
                            default: {}
                        }
                    }

                    if (channel.interpolation == LINEAR) {
                        AnimationValue prev_value = values[index + channel.value_offset - 1];
                        float interpolation_value = (float)(channel.elapsed_time - prev_value.time) / (float)(current_value.time - prev_value.time);
                        switch (channel.path) {
                            case TRANSLATION: {
                                node.translation = prev_value.value.xyz.lerp(current_value.value.xyz, interpolation_value);
                            }
                            case ROTATION: {
                                node.rotation = Quaternionf{.v = prev_value.value}.slerp(Quaternionf{.v = current_value.value}, interpolation_value);
                            }
                            case SCALE: {
                                node.scale = prev_value.value.xyz.lerp(current_value.value.xyz, interpolation_value);
                            }
                            default: {}
                        }
                    }
                break;
            }
        }
    }
}

// struct Position  {
//     Vec3f scale;
//     Vec3f translation;
//     Quaternionf rotation;
// }

// struct Velocity @tag("BUFFER", 0) {
//     float x;
//     float y;
//     float z;
// }

// fn void main() {
//     Buffer buffer;
//     defer buffer.free();

//     EntityManager manager = create_manager({
//         &buffer,
//     });

//     defer manager.free();

//     Component velocity_comp = manager.@create_component(Velocity{ 1.0, 2.0, 3.0 });
//     Component animation_comp = manager.@create_component(size: Position.sizeof);
    
//     ecs::@upload(manager, velocity_comp, Velocity{ 3.0, 3.0, 3.0 }, size: Velocity.sizeof);
 
//     Entity player = manager.@create_entity(
//         Position {
//             .translation = {1.0, 1.0, 1.0},
//             .scale = {1.0, 1.0, 1.0}
//         },
//     );

//     Entity player2 = manager.@create_entity(
//         Position{},
//         velocity_comp,
//         animation_comp
//     );

//     player.add("Velocity", velocity_comp, manager);
    
//     assert(@get_offset(manager, player, "Position")!! == Velocity.sizeof + Position.sizeof);
//     assert(@get_offset(manager, player2, "Position")!! == Velocity.sizeof + Position.sizeof * 2);

//     manager.@query("Position", "Velocity"; Entity entity) {
//         Velocity velocity = @get(manager, entity, Velocity);
//         io::printfn("QUERY ENTRY");

//         assert(velocity.x == 3.000000);
//         assert(velocity.y == 3.000000);

//         @upload(manager, entity, Position {
//             .translation = {5.0, 5.0, 5.0},
//             .scale = {5.0, 5.0, 5.0}
//         });

//         Position position = @get(manager, entity, Position);
//         assert(position.translation.x == 5.000000);
//     };
// }

// Todo:
// Test correct buffers on components
// Test entity offset
// Remove buffer.push()



