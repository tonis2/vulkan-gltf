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
    DEVICE_ONLY
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

struct Component {
    uint id;
    uint size;
    uint buffer;
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

struct BufferView {
    uint offset;
    uint size;
}

def ComponentMap = HashMap(<String, Component>);
def BufferMap = HashMap(<BufferID, BufferView>);

macro uint BufferID.hash(BufferID i) => builtin::@generic_hash((ulong)i);
macro uint Action.hash(Action i) => builtin::@generic_hash(i.ordinal);

struct EntityManager {
    ComponentMap keys;
    BufferMap views;
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

macro Component EntityManager.@create_component(&self, #data, void* data = null, uint size = 0, uint buffer_index = 0) {
    Component component;

    $if $typeof(#data).nameof == "String":
        if (self.keys.has_key(#data)) {
            io::printfn("Component key already taken");
            return component;
        } else {
            uint index = buffer_index;
            uint key_index = (uint)self.keys.len();

            $if $typeof(#data).has_tagof("BUFFER"):
                index = $typeof(#data).tagof("BUFFER");
            $endif

            component = {
                .id = key_index,
                .buffer = index,
                .size = size,
            };

            self.keys[#data] = component;
        }

        Allocator buffer = self.buffers[component.buffer];
        component.offset = buffer.usedSize();
        
        if (data != null) {
            buffer.push(data, size);
        } else {
            buffer.setUsedSize(component.offset + size);
        }

        self.views[BufferID {
            .component = component.id,
            .entity = 0,
        }] = BufferView {
            .offset = (uint)component.offset,
            .size = component.size
        };
    $endif;

    $if $typeof(#data).nameof != "String":
        if (!self.keys.has_key($typeof(#data).nameof)) {
            uint index = buffer_index;
            uint key_index = (uint)self.keys.len();

            $if $typeof(#data).has_tagof("BUFFER"):
                index = $typeof(#data).tagof("BUFFER");
            $endif

            component = {
                .id = key_index,
                .buffer = index,
                .size = $typeof(#data).sizeof,
            };

            self.keys[$typeof(#data).nameof] = component;
        } else {
            component = self.keys[$typeof(#data).nameof]!!;
        }

        Allocator buffer = self.buffers[component.buffer];
        
        component.offset = buffer.usedSize();
        buffer.push(&&#data, $typeof(#data).sizeof);

        self.views[BufferID {
            .component = component.id,
            .entity = 0,
        }] = BufferView {
            .offset = (uint)component.offset,
            .size = component.size
        };
     $endif;

    return component;   
}

macro Entity EntityManager.@create_entity(&self, ...) {
    Component! component;
    String type_name;
    Entity entity = {.id = math::max((uint)1, (uint)self.entities.len())};

    uint size = 0;
    uint buffer_index = 0;

    // Loop over entity data
    $for (var $i = 0; $i < $vacount; $i++);
        type_name = $typeof($vaarg[$i]).nameof;
        size += $typeof($vaarg[$i]).sizeof;

        $if $typeof($vaarg[$i]).nameof == "Component":
            // Reuse already saved data
            entity.bitmask |= 1 << $vaarg[$i].id;
            self.views[BufferID {
                .component = $vaarg[$i].id,
                .entity = entity.id,
            }] = BufferView {
                .offset = (uint)$vaarg[$i].offset,
                .size = $typeof($vaarg[$i]).sizeof
            };
        $else
            component = self.keys[type_name];
            if (try component) {
                // If component already exists, add mark component in entitys bitmask
                entity.bitmask |= 1 << component.id;
                buffer_index = component.buffer;
            } else {
                // If component not created before, add it to component map and then to entiy's bitmask
                uint key_index = (uint)self.keys.len();
                entity.bitmask |= 1 << key_index;

                $if $typeof($vaarg[$i]).has_tagof("BUFFER"):
                    buffer_index = $typeof($vaarg[$i]).tagof("BUFFER");
                $endif

                component = {
                    .id = key_index,
                    .buffer = buffer_index,
                    .size = $typeof($vaarg[$i]).sizeof
                };

                self.keys[type_name] = component!!;
            }
            // Create a buffer view mapping and push data to buffer
            self.views[BufferID {
                .component = component!!.id,
                .entity = entity.id,
            }] = BufferView {
                .offset = (uint)self.buffers[buffer_index].usedSize(),
                .size = component!!.size
            };
            // io::printfn("%d %s", self.buffers[buffer_index].usedSize(), type_name);
            if (self.buffers[buffer_index].getType() == GpuType.DEVICE_ONLY.ordinal) {
                self.uploadFN(self.buffers[buffer_index], &&$vaarg[$i], $typeof($vaarg[$i]).sizeof, self.buffers[buffer_index].usedSize());
            } else {
                self.buffers[buffer_index].push(&&$vaarg[$i], $typeof($vaarg[$i]).sizeof);
            }
        $endif   
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

fn bool Entity.has_name(self, String name, EntityManager manager) {
    Component! key = manager.keys[name];

    if (try key) {
        uint mask = 1 << key.id;
        return self.bitmask & mask == mask;
    }

    return false;
}

fn void Entity.add(&self, Component component, EntityManager manager) {
    self.bitmask |= 1 << component.id;

    manager.entities[self.id].bitmask = self.bitmask;
    manager.views[BufferID {
        .component = component.id,
        .entity = self.id,
    }] = {
        .offset = (uint)component.offset,
        .size = component.size,
    };
}

fn uint get_size(Entity entity, EntityManager manager) {
    uint size;
    @pool() {
        foreach (key : manager.views.tcopy_keys()) {
            if (key.entity == entity.id) {
                size += manager.views[key]!!.size;
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
    $if $typeof(#target).nameof == "Component":
        Allocator buffer = manager.buffers[#target.buffer];
        buffer.upload(#data, size, #target.offset + offset);
    $endif;

    $if $typeof(#target).nameof == "Entity":
        Component component = manager.keys[$typeof(#data).nameof]!!;
        BufferID index = {
            .component = component.id,
            .entity = #target.id,
        };

        Allocator buffer = manager.buffers[component.buffer];
        uint type_offset = manager.views[index]!!.offset;

        if (buffer.getType() == GpuType.DEVICE_ONLY.ordinal) {
            manager.uploadFN(buffer, &&#data, $typeof(#data).sizeof, type_offset + offset);
        } else {
            buffer.upload(&&#data, $typeof(#data).sizeof, type_offset + offset);
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
        uint type_offset = manager.views[index]!!.offset;
        return bitcast(*(char[#type.sizeof]*)buffer.data()[type_offset..(type_offset + #type.sizeof)], #type);
    $endif;
}

macro @get_address(EntityManager manager, #target, #type = null, usz offset = 0) {
    $if $typeof(#target).nameof == "Component":
        Allocator buffer = manager.buffers[#target.buffer];

        return manager.buffers[#target.buffer].getAddress() + #target.offset + offset;
    $endif;

    $if $typeof(#target).nameof == "Entity":
        Component component = manager.keys[#type.nameof]!!;
        BufferID index = {
            .component = component.id,
            .entity = #target.id,
        };

        Allocator buffer = manager.buffers[component.buffer];
        uint type_offset = manager.views[index]!!.offset;
        return manager.buffers[component.buffer].getAddress() + type_offset + offset;
    $endif;
}

macro @get_offset(EntityManager manager, #target, #type) {
    // $if $typeof(#target).nameof == "Component":
    //     Allocator buffer = manager.buffers[#target.buffer];
    //     return;
    // $endif;

    $if $typeof(#target).nameof == "Entity":
        Component component = manager.keys[#type.nameof]!!;
        BufferID index = {
            .component = component.id,
            .entity = #target.id,
        };

        Allocator buffer = manager.buffers[component.buffer];
        uint type_offset = manager.views[index]!!.offset;
        return type_offset;
    $endif;
}

struct Buffer (Allocator) {
    usz size;
    usz used_size;
    char* mapped;
}

fn void Buffer.push(&self, void* data, usz size) @dynamic {
    if (self.used_size + size > self.size) {
        usz new_size = self.size + size;
        self.mapped = mem::realloc(self.mapped, new_size);
        self.size = new_size;
        mem::copy(self.mapped + self.used_size, data, size);
        self.used_size += size;
    } else {
        mem::copy(self.mapped + self.used_size, data, size);
        self.used_size += size;
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
fn uint Buffer.getType(&self) @dynamic => 0;
fn void* Buffer.getBuffer(&self) @dynamic => null;
fn void Buffer.setUsedSize(&self, usz size) @dynamic  {
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
    double time;
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

struct Animations {
    AnimationSkin skin;
    AnimationMap channels;
    List(<AnimationValue>) values;
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


fn Animations create_animations_manager(gltf::Skin skin, Gltf gltf) {
    return Animations {
        .skin = load_skin_data(skin, gltf),
    };
}

fn void! Animations.add_from_gltf(&self, gltf::Animation animation, Gltf gltf, String name) {
    self.channels[name] = load_animation_data(animation, self.skin, gltf, &self.values)!;
}


<*
 @require time > 0 "Time must be bigger than 0"
*>
fn void! Animations.run_animation(&self, String name, double time) {
    AnimationChannel* channel = self.channels.get_ref(name)!;
    channel.run_animation(self.values, &self.skin, time);
}

struct AnimationSkin {
    String name;
    List(<Node>) nodes;
    NodeMap node_map;
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
        if (joints.contains(joint)) continue;

        gltf::Node node = gltf_nodes[joint];
        node_map.set(joint, (uint)target_nodes.len());

        target_nodes.push({
            .scale = node.scale,
            .translation = node.translation,
            .rotation = node.rotation,
            .inverse_bind = inverseBindMatrices[target_nodes.len()],
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

    for (uint i; i < skin_accessor.count; i++) {
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
                .time = gltf.@castBuffer(time_accessor, i, double),
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

        for (uint index; index < channel.value_count; index++) {
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
                        double interpolation_value = (channel.elapsed_time - prev_value.time) / (current_value.time - prev_value.time);
                  
                        switch (channel.path) {
                            case TRANSLATION: {
                                node.translation = prev_value.value.xyz.lerp(current_value.value.xyz, (float)interpolation_value);
                            }
                            case ROTATION: {
                                node.rotation = Quaternionf{.v = prev_value.value}.slerp(Quaternionf{.v = current_value.value}, (float)interpolation_value);
                            }
                            case SCALE: {
                                node.scale = prev_value.value.xyz.lerp(current_value.value.xyz, (float)interpolation_value);
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

// struct Render {
//     uint draw_id;
// }

// struct Velocity @tag("BUFFER", 0) {
//     float x;
//     float y;
//     float z;
// }

// fn void main() {
    
//     EntityManager manager = create_manager({
//         &&Buffer{},
//         &&Buffer{}
//     });

//     defer manager.free();

//     Component velocity_comp = manager.@create_component(Velocity{ 1.0, 2.0, 3.0 });
//     Component animation_comp = manager.@create_component("Fly_animation", size: Position.sizeof);

//     ecs::@upload(manager, velocity_comp, &&Velocity{ 3.0, 3.0, 3.0 }, size: Velocity.sizeof);

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

//     player.add(velocity_comp, manager);

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



