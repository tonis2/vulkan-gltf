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
def ActionMap = HashMap(<Action, void*>);

macro uint BufferID.hash(BufferID i) => builtin::@generic_hash((ulong)i);
macro uint Action.hash(Action i) => builtin::@generic_hash(i.ordinal);

struct EntityManager {
    ComponentMap keys;
    BufferMap views;
    List(<Allocator>) buffers;
    List(<Entity>) entities;
    UploadFN uploadFN;
}

fn EntityManager create_manager(UploadFN uploadFN, Allocator[] buffers) {
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
            is_valid = entity.has_name($typeof($vaarg[$i]).nameof, self);
        $endfor
        if (is_valid) @callback(entity);
    }
}

macro Component EntityManager.@create_component(&self, #data) {
    Component component;

    if (catch err = self.keys[$typeof(#data).nameof]) {
        uint buffer_index = 0;
        uint key_index = (uint)self.keys.len();

        $if $typeof(#data).has_tagof("BUFFER"):
            buffer_index = $typeof(#data).tagof("BUFFER");
        $endif

        component = {
            .id = key_index,
            .buffer = buffer_index,
            .size = $typeof(#data).sizeof,
        };

        self.keys[$typeof(#data).nameof] = component;
    } else {
        component = self.keys[$typeof(#data).nameof]!!;
    }
    
    component.offset = self.buffers[component.buffer].usedSize();
    self.buffers[component.buffer].push(&&#data, $typeof(#data).sizeof);

    return component;
}

macro Entity EntityManager.@create_entity(&self, ...) {
    Component! component;
    String type_name;
    Entity entity = {.id = (uint)self.entities.len()};

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

macro Entity.@get(self, #type, EntityManager manager) {
    Component component = manager.keys[#type.nameof]!!;
    BufferID index = {
        .component = component.id,
        .entity = self.id,
    };

    Allocator buffer = manager.buffers[component.buffer];
    uint type_offset = manager.views[index]!!.offset;

    return bitcast(*(char[#type.sizeof]*)buffer.data()[type_offset..(type_offset + #type.sizeof)], #type);
}

macro Entity.@set(self, #data, EntityManager manager, usz offset = 0) {
    Component component = manager.keys[$typeof(#data).nameof]!!;
    BufferID index = {
        .component = component.id,
        .entity = self.id,
    };

    Allocator buffer = manager.buffers[component.buffer];
    uint type_offset = manager.views[index]!!.offset;

    return buffer.upload(&&#data, $typeof(#data).sizeof, type_offset + offset);
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

fn ulong get_address(Entity entity, EntityManager manager) {
    Component* component = null;
    @pool() {
        foreach (key : manager.views.tcopy_keys()) {
            if (key.entity == entity.id) {
                manager.keys.@each_entry(; Entry(<String, Component>)* entry) {
                    if (entry.value.id == key.component) {
                         component = &entry.value;
                    }
                };
            }
        }
    };

    uint offset = manager.views[BufferID {
        .component = component.id,
        .entity = entity.id,
    }]!!.offset;

    return manager.buffers[component.buffer].getAddress() + offset;
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

fn uint get_offset(Entity entity, EntityManager manager) {
    uint offset;
    @pool() {
        foreach (key : manager.views.tcopy_keys()) {
            if (key.entity == entity.id) {
                offset = manager.views[key]!!.offset;
            }
        }
    };

    return 0;
}

macro Entity.@set_value(self, #type, #data, EntityManager manager, usz offset = 0) {
    Component component = manager.keys[#type.nameof]!!;
    BufferID index = {
        .component = component.id,
        .entity = self.id,
    };

    Allocator buffer = manager.buffers[component.buffer];
    uint type_offset = manager.views[index]!!;

    return buffer.upload(&&#data, $typeof(#data).sizeof, type_offset + offset);
}

macro Component.@set(self, #data, EntityManager manager, usz offset = 0) {
    Allocator buffer = manager.buffers[self.buffer];
    return buffer.upload(&&#data, $typeof(#data).sizeof, self.offset + offset);
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

//     velocity_comp.@set(Velocity{ 3.0, 3.0, 3.0 }, manager);

//     Entity player = manager.@create_entity(
//         Position {
//             .translation = {1.0, 1.0, 1.0},
//             .scale = {1.0, 1.0, 1.0}
//         },
//     );

//     Entity player2 = manager.@create_entity(
//         Position{},
//         velocity_comp
//     );

//     player.add(velocity_comp, manager);

//     manager.@query(Position{}, Velocity{}; Entity entity) {
//         Velocity velocity = entity.@get(Velocity, manager);
//         io::printfn("QUERY ENTRY");

//         assert(velocity.x == 3.000000);
//         assert(velocity.y == 3.000000);

//         entity.@set(Position {
//             .translation = {5.0, 5.0, 5.0},
//             .scale = {5.0, 5.0, 5.0}
//         }, manager);

//         Position position = entity.@get(Position, manager);
//         assert(position.translation.x == 5.000000);
//     };
// }



