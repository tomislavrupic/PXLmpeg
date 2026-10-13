#include <metal_stdlib>
using namespace metal;
kernel void copy_bytes(device const uchar *input [[buffer(0)]], device uchar *output [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    output[i] = input[i];
}

struct ScaleAxis { uint axis; float offset; uint quantize10; uint padding; };
kernel void scale_plane(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant ScaleAxis &p [[buffer(0)]], uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= dst.get_width() || xy.y >= dst.get_height()) return;
    uint sourceSize = p.axis == 0 ? src.get_width() : src.get_height();
    uint outputSize = p.axis == 0 ? dst.get_width() : dst.get_height();
    uint position = p.axis == 0 ? xy.x : xy.y;
    float ratio = float(sourceSize) / float(outputSize);
    float center = (float(position) + p.offset) * ratio - p.offset;
    float4 value = 0;
    if (ratio <= 1.0f) {
        int lo = int(floor(center)); float fraction = center - float(lo);
        uint a = uint(clamp(lo, 0, int(sourceSize)-1));
        uint b = uint(clamp(lo+1, 0, int(sourceSize)-1));
        uint2 ac = p.axis == 0 ? uint2(a,xy.y) : uint2(xy.x,a);
        uint2 bc = p.axis == 0 ? uint2(b,xy.y) : uint2(xy.x,b);
        value = mix(src.read(ac), src.read(bc), fraction);
    } else {
        float left = center - ratio * 0.5f, right = center + ratio * 0.5f;
        int begin = int(floor(left+0.5f)), end = int(ceil(right+0.5f));
        for (int i = begin; i < end; ++i) {
            float weight = max(0.0f, min(right,float(i)+0.5f)-max(left,float(i)-0.5f)) / ratio;
            uint at = uint(clamp(i,0,int(sourceSize)-1));
            value += src.read(p.axis == 0 ? uint2(at,xy.y) : uint2(xy.x,at)) * weight;
        }
    }
    if (p.quantize10) value = round(clamp(value * (65535.0f/64.0f),0.0f,1023.0f)) * (64.0f/65535.0f);
    dst.write(value, xy);
}

struct OrientationParameters { uint quarterTurns; uint plane; uint width; uint height; uint quantize10; };
kernel void orient_plane(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant OrientationParameters &p [[buffer(0)]], uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= dst.get_width() || xy.y >= dst.get_height()) return;
    // Work in luma sample-centre index coordinates. Left 4:2:0 chroma centres
    // lie at (2*x, 2*y+0.5), both before and after orientation.
    float2 out = float2(xy);
    if (p.plane == 1) out = 2.0f * out + float2(0.0f,0.5f);
    float2 at;
    switch (p.quarterTurns) {
        case 1: at = float2(out.y, float(p.height-1)-out.x); break;
        case 2: at = float2(float(p.width-1)-out.x, float(p.height-1)-out.y); break;
        case 3: at = float2(float(p.width-1)-out.y, out.x); break;
        default: at = out; break;
    }
    if (p.plane == 1) at = (at-float2(0.0f,0.5f))*0.5f;
    int2 lo = int2(floor(at)); float2 fraction = at-float2(lo);
    int2 maximum = int2(src.get_width()-1,src.get_height()-1);
    float4 a = src.read(uint2(clamp(lo,int2(0),maximum)));
    float4 b = src.read(uint2(clamp(lo+int2(1,0),int2(0),maximum)));
    float4 c = src.read(uint2(clamp(lo+int2(0,1),int2(0),maximum)));
    float4 d = src.read(uint2(clamp(lo+int2(1,1),int2(0),maximum)));
    float4 value = mix(mix(a,b,fraction.x),mix(c,d,fraction.x),fraction.y);
    if (p.quantize10) value = round(clamp(value * (65535.0f/64.0f),0.0f,1023.0f)) * (64.0f/65535.0f);
    dst.write(value,xy);
}
