module ecs;

import std::math;
import std::io;
import std::collections::list;
import std::collections::map;
import std::encoding::json;
import std::core::builtin;

// interface Allocator
// {
//     fn usz push(void* data, usz size);
//     fn void update(void* data, usz size, usz offset);
//     fn void free();
// }

struct Component {
    uint id;
    uint buffer;
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
def BufferMap = HashMap(<BufferID, uint>);

macro uint BufferID.hash(BufferID i) => builtin::@generic_hash((ulong)i);

struct EntityManager {
    ComponentMap keys;
    BufferMap views;
    List(<Buffer>) buffers;
    List(<Entity>) entities;
}

fn EntityManager create_manager(Buffer[] buffers) {
    EntityManager manager;
    foreach (buffer: buffers) manager.buffers.push(buffer);
    return manager;
}

fn void EntityManager.free(&self) {
    self.keys.free();
    self.views.free();
    self.entities.free();
    foreach (buffer: self.buffers) buffer.free();
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

macro Entity EntityManager.@create_entity(&self, ...) {
    Component! component;
    String type_name;
    Entity entity = {
        .id = (uint)self.views.len()
    };

    uint size = 0;
    uint buffer_index = 0;

    // Loop over entity data
    $for (var $i = 0; $i < $vacount; $i++);
        type_name = $typeof($vaarg[$i]).nameof;
        component = self.keys[type_name];

        size += $typeof($vaarg[$i]).sizeof;
       
        // Push data of the entity to buffer
        if (try component) {
            // If data in data-map, only add type to entity bitmask
            entity.bitmask |= 1 << component.id;
            buffer_index = component.buffer;
        }
        else {
            // If data not in data-map, create new entry and add type to entity bitmask
            uint key_index = (uint)self.keys.len();
            entity.bitmask |= 1 << key_index;

            $if $typeof($vaarg[$i]).has_tagof("BUFFER"):
                buffer_index = $typeof($vaarg[$i]).tagof("BUFFER");
            $endif

            component = {
                .id = key_index,
                .buffer = buffer_index
            };

            self.keys[type_name] = component!!;
        }

        self.views[BufferID {
            .component = component!!.id,
            .entity = entity.id,
        }] = (uint)self.buffers[buffer_index].used_size;
        
        self.buffers[buffer_index].push(&&$vaarg[$i], $typeof($vaarg[$i]).sizeof);
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

    Buffer buffer = manager.buffers[component.buffer];
    uint type_offset = manager.views[index]!!;

    return bitcast(*(char[#type.sizeof]*)buffer.data[type_offset..(type_offset + #type.sizeof)], #type);
}

macro Entity.@set(self, #data, EntityManager manager) {
    Component component = manager.keys[$typeof(#data).nameof]!!;
    BufferID index = {
        .component = component.id,
        .entity = self.id,
    };

    Buffer buffer = manager.buffers[component.buffer];
    uint type_offset = manager.views[index]!!;


    return buffer.update(&&#data, $typeof(#data).sizeof, type_offset);
}

struct Buffer {
    usz size;
    usz used_size;
    usz page_size;
    char* data;
}

fn usz Buffer.push(&self, void* data, usz size) {
    if (self.used_size + size > self.size) {
        usz new_size = self.size + size;
        self.data = mem::realloc(self.data, new_size);
        self.size = new_size;
        mem::copy(self.data + self.used_size, data, size);
        self.used_size += size;
    } else {
        mem::copy(self.data + self.used_size, data, size);
        self.used_size += size;
    }
    return self.used_size - size;
}

fn void Buffer.update(&self, void* data, usz size, usz offset) {
    mem::copy(self.data + offset, data, size);
}

fn void Buffer.free(&self) {
    mem::free(self.data);
    self.size = 0;
    self.used_size = 0;
}

struct Position  {
    Vec3f scale;
    Vec3f translation;
    Quaternionf rotation;
}

struct Render {
    uint draw_id;
}

struct Velocity @tag("BUFFER", 0) {
    float x;
    float y;
    float z;
}

fn void main() {
    EntityManager manager = create_manager({
        Buffer{},
        Buffer{}
    });

    defer manager.free();

    Entity player = manager.@create_entity(
        Position {
            .translation = {1.0, 1.0, 1.0},
            .scale = {1.0, 1.0, 1.0}
        },
        Velocity{ 1.0, 2.0, 3.0 },
        Render{}
    );

    Entity player2 = manager.@create_entity(
        Position{},
    );

    manager.@query(Position{}, Velocity{}, Render{}; Entity entity) {
    
        Velocity velocity = entity.@get(Velocity, manager);

        io::printfn("velocity %s %s", velocity.x, velocity.y);

        entity.@set(Position {
            .translation = {5.0, 5.0, 5.0},
            .scale = {5.0, 5.0, 5.0}
        }, manager);

        Position position = entity.@get(Position, manager);

        io::printfn("pos %s", position.translation);
    };
}



