module vge;

import std::io;
import std::math;
import std::math::vector;
import std::collections::list;
import std::sort;
// Code taken from https://github.com/audulus/vger-rs/ 


enum PrimType {
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

struct Prim {
    float[4] quad_bounds;
    float[4] tex_bounds;
    float[6] cvs;

    float width;
    float height;
    float radius;

    // indexes
    uint xform;
    uint prim_type;
    uint start;
    uint count;
    uint paint;
    uint glyph;
    uint scissors;
}

struct Interval {
    float a;
    float b;
}

struct PathSegment {
    Vec2f[3] cvs;
    int next;
    int previous;
}

struct PathScannerNode {
    float coord;
    uint seg;
    bool end;
}

struct PathScanner {
    List(<PathSegment>) segments;
    List(<PathScannerNode>) nodes;
    uint index;
    int first;
    Interval interval;
}

fn void PathScanner.init(&self) {
    self.nodes.clear();
    self.index = 0;

    foreach (uint i, segment: self.segments) {
        Interval y_interval = self.segments[i].y_interval();
        self.nodes.push(PathScannerNode {
            .coord = y_interval.a,
            .seg = i,
            .end = false,
        });
        self.nodes.push(PathScannerNode {
            .coord = y_interval.b,
            .seg = i,
            .end = true,
        });
    }

    quicksort(self.nodes, fn int (PathScannerNode a, PathScannerNode b) => (int)(a.coord < b.coord));
}

fn void PathScanner.begin(&self, Vec2f[] cvs) {
    self.segments.clear();

    for (uint i; i < cvs.len - 2; i += 2) {
        self.segments.push({
            .cvs = { cvs[i], cvs[i + 1], cvs[i + 2] },
            .next = -1,
            .previous = -1
        });
    }

    self.init();
}

fn bool PathScanner.next(&self) {
    float y = self.nodes[self.index].coord;
    usz n = self.nodes.len();

    self.interval.a = y;

    while (self.index < n && self.nodes[self.index].coord == y) {
        PathScannerNode node = self.nodes[self.index];
        assert(node.seg < self.segments.len());

        if (node.end) {
            int prev = self.segments[node.seg].previous;
            int next = self.segments[node.seg].next;

            if (prev > 0) {
                PathSegment* segment = &self.segments[prev];
                segment.next = self.segments[node.seg].next;
            }
            if (next > 0)  {
                PathSegment* segment = &self.segments[next];
                segment.previous = self.segments[node.seg].previous;
            }
            if (self.first == node.seg) {
                self.first = self.segments[node.seg].next;
            }
            PathSegment* segment = &self.segments[node.seg];
            segment.next = -1;
            segment.previous = -1;
        } 
        else {
            PathSegment* segment = &self.segments[node.seg];
            segment.next = self.first;
            if (self.first) {
                PathSegment* segment2 = &self.segments[self.first];
                segment2.previous = node.seg;
            }
            self.first = node.seg;
        }

        self.index += 1;
    }

    if (self.index < n) {
        self.interval.b = self.nodes[self.index].coord;
    }

    return self.index < n;
}

fn void PathScanner.free(&self) {
    self.segments.free();
    self.nodes.free();
}

fn Interval PathSegment.y_interval(&self) {
    return Interval {
        .a = math::min(self.cvs[0].y, self.cvs[1].y, self.cvs[2].y) - 1.0,
        .b = math::max(self.cvs[0].y, self.cvs[1].y, self.cvs[2].y) + 1.0
    };
}


module test;

import vge;
import std::math::vector;

fn void scanning() @test {
    PathScanner scan;
    defer scan.free();

    Vec2f[] cvs = {
        {1.0, 0.0},
        {1.0, 1.0},
        {0.0, 1.0},
        {-1.0, 1.0},
        {-1.0, 0.0},
        {-1.0, -1.0},
        {0.0, -1.0},
        {1.0, -1.0},
        {1.0, 0.0},
    };

    scan.begin(cvs);

    assert(scan.segments.len() == 4);
}