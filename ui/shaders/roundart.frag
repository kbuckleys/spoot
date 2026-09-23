#version 440
// A COVER WITH ITS CORNERS TURNED, in one pass and no offscreen layer. The
// image is sampled straight from its own texture -- an Image is a texture
// provider -- and the corner is a distance test, antialiased over one pixel.
//
// `crop` squares a cover that is not square, the way PreserveAspectCrop did:
// the texture is the whole loaded image, and this picks its centre.
//
// The .qsb beside this file is what Qt loads, and it is checked in so spoot needs
// no shader compiler to run. After editing, rebuild it:
//   /usr/lib/qt6/bin/qsb --qt6 -o roundart.frag.qsb roundart.frag
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;
    vec2 crop;
    float radius;
};
layout(binding = 1) uniform sampler2D source;

void main() {
    vec2 uv = vec2(0.5) + (qt_TexCoord0 - vec2(0.5)) * crop;
    vec2 p = qt_TexCoord0 * size;
    vec2 q = abs(p - size * 0.5) - (size * 0.5 - vec2(radius));
    float d = length(max(q, 0.0)) - radius;
    float a = clamp(0.5 - d, 0.0, 1.0);
    fragColor = texture(source, uv) * (a * qt_Opacity);
}
