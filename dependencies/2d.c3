module vge;

import std::io;
import std::math;
import std::math::vector;
import std::collections::list;
import std::sort;
// Code taken from https://github.com/audulus/vger-rs/

const MAGENTA = Color {
    1.0,
    0.0,
    1.0,
    1.0,
};

const CYAN = Color {
    0.0,
    1.0,
    1.0,
    1.0,
};

const WHITE = Color {
    1.0,
    1.0,
    1.0,
    1.0,
};

struct Color {
   float r;
   float g;
   float b;
   float a;
}

enum PrimType: uint {
    CIRCLE,
    ARC,
    RECT,
    RECT_STROKE,
    BEZIER,
    SEGMENT,
    CURVE,
    WIRE,
    TEXT,
    PATH_FILL,
    BLURRED_RECT,
}


struct Line {
    uint type;
    Vec2f position;
    Vec2f dir;
    Color color;
    float thickness;
}

fn Line createLine(PrimType type, Vec2f from, Vec2f to, Color color = CYAN) {
    Vec2f dir = to - from;
    return Line {
        .type = (uint)type,
        .position = (from + to) / 2,
        .thickness = 1.0,
        .dir = dir,
        .color = color 
    };
}