module ecs;

import std::math;
import std::io;
import std::collections::list;
import std::collections::map;
import std::encoding::json;

def ComponentMap = HashMap(<String, uint>);

bitstruct Entity : ulong {
    uint id : 0..31;
    uint bitmask : 32..63;
}

struct BufferView {
    usz offset;
    uint size;
    uint stride;
}

struct EntityManager {
    ComponentMap keys;
    DynamicBuffer buffer;
    List(<BufferView>) views;
    List(<Entity>) entities;
}

fn void EntityManager.free(&self) {
    self.buffer.free();
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

macro Entity EntityManager.@create_entity(&self, ...) {
    uint! key;
    String type_name;
    Entity entity = {
        .id = (uint)self.views.len()
    };

    uint size = 0;
    uint offset = (uint)self.buffer.used_size;

    // Loop over entity data
    $for (var $i = 0; $i < $vacount; $i++);
        type_name = $typeof($vaarg[$i]).nameof;
        key = self.keys[type_name];
        size += $typeof($vaarg[$i]).sizeof;

        // Push data of the entity to buffer
        self.buffer.push(&&$vaarg[$i], $typeof($vaarg[$i]).sizeof);

        if (try key) {
            // If data in data-map, only add type to entity bitmask
            entity.bitmask |= 1 << key;
        }
        else {
            // If data not in data-map, create new entry and add type to entity bitmask
            uint key_index = (uint)self.keys.len() + 1;
            self.keys[type_name] = key_index;
            entity.bitmask |= 1 << key_index;
        }
	$endfor

    self.views.push(BufferView {
        .offset = offset,
        .size = size,
    });

    self.entities.push(entity);
    
    return entity;
}

macro bool Entity.@has_type(self, $type, EntityManager manager) {
    uint! key = manager.keys[$typeof($type).nameof];

    if (try key) {
        uint mask = 1 << key;
        return self.bitmask & mask == mask;
    }

    return false;
}

fn bool Entity.has_name(self, String name, EntityManager manager) {
    uint! key = manager.keys[name];

    if (try key) {
        uint mask = 1 << key;
        return self.bitmask & mask == mask;
    }

    return false;
}

macro Entity.@get_data(self, #type, EntityManager manager, uint offset = 0) {
    BufferView view = manager.views[self.id];
    uint buffer_offset = (uint)view.offset + offset;
    return bitcast(*(char[#type.sizeof]*)manager.buffer.data[buffer_offset..(buffer_offset + #type.sizeof)], #type);
}

struct DynamicBuffer {
    usz size;
    usz used_size;
    usz page_size;
    char* data;
}

fn usz DynamicBuffer.push(&self, void* data, usz size) {
    if (self.used_size + size > self.size) {
        // need to increase mem size
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

fn void DynamicBuffer.free(&self) {
    mem::free(self.data);
    self.size = 0;
    self.used_size = 0;
}

struct Position {
    Vec3f scale;
    Vec3f translation;
    Quaternionf rotation;
}

struct Render {
    uint draw_id;
}

struct Velocity {
    float x;
    float y;
    float z;
}

fn void main() {
    EntityManager manager = {};
    defer manager.free();

    Entity player = manager.@create_entity(
        Position {
            .translation = {1.0, 1.0, 1.0},
            .scale = {1.0, 1.0, 1.0}
        },
        Velocity{},
        Render{}
    );

    Entity player2 = manager.@create_entity(
        Position{},
    );

    io::printfn("%s", player.@has_type(Position{}, manager));
    io::printfn("%s", player2.@has_type(Render{}, manager));

    manager.@query(Position{}, Velocity{}, Render{}; Entity entity) {
        Position position = entity.@get_data(Position, manager);
        io::printfn("%s", position.translation);
    };

    // foreach (entity: manager.@query(Position{}, Velocity{}, Render{})) {

    // }

}



