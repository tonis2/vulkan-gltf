import std::io;
import vk;
import glfw;
import stb;
import camera;
import std::math;
import std::collections::list;
import gltf;
import pipelines;
import std::time;
import vge;

fn void! main()
{
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

    while (scan.next()) {
        io::printfn("interval %d active: %d ", scan.interval.a, scan.interval.b);

        int index = scan.first;
        while (index) {
            io::printfn("index %d ", index);
            index = scan.segments[index].next;
        }
    }

}