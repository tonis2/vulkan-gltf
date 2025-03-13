module ecs;

import std::math;
import std::io;
import std::collections::list;
import std::collections::map;
import std::encoding::json;

def ComponentMap = HashMap(<String, Component>);

bitstruct Entity : ulong {
    uint index : 0..31;
    uint entries : 32..63;
}

struct BufferView {
    uint offset;
    uint size;
    uint stride;
    any value;
}

struct Component {
    DynamicBuffer data;
    uint index;
}

fn Component create_component(uint index, uint size = 256) {
    return Component {
        .index = index,
        .data = DynamicBuffer {
            .size = size,
            .used_size = 0,
            .data = mem::new_array(char, size)
        }
    };
}

// fn void Component.free(&self) {
//     self.data.free();
// }

struct EntityManager {
    ComponentMap keys;
    // List(<EntityMap>) entities;
    // List(<BufferView>) views;
}

fn void EntityManager.free(&self) {
    @pool() {
        foreach (key : self.keys.tcopy_keys()) self.keys[key]!!.data.free();
    };
    self.keys.free();
}

macro bool Entity.@has(self, $type, EntityManager manager) {
    uint! key = manager.keys[$typeof($type).nameof].index;

    if (try key) {
        uint mask = 1 << key;
        return self.entries & mask == mask;
    }

    return false;
}

macro void EntityManager.@query(self, ...) {
    $for (var $i = 0; $i < $vacount; $i++);
	$endfor

    return self.entities;
}

macro Entity EntityManager.@create_entity(&self, ...) {
    uint! key;
    String type_name;
    Entity entity;

    // Create type index or add type index to entity bitmask
    $for (var $i = 0; $i < $vacount; $i++);
        type_name = $typeof($vaarg[$i]).nameof;
        key = self.keys[type_name].index;
        if (try key) {
            entity.entries |= 1 << key;
        }
        else {
            uint key_index = (uint)self.keys.len() + 1;
            self.keys[type_name] = create_component(key_index);
            self.keys[type_name]!!.data.push(&&$vaarg[$i], $typeof($vaarg[$i]).sizeof);
            entity.entries |= 1 << key_index;
        }
	$endfor
    
    return entity;
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
        Position{},
        Velocity{},
        Render{}
    );

    Entity player2 = manager.@create_entity(
        Position{},
    );

    io::printfn("%s", player.@has(Position{}, manager));
    io::printfn("%s", player2.@has(Render{}, manager));


    // foreach (entity: manager.@query(Position{}, Velocity{}, Render{})) {

    // }

}



