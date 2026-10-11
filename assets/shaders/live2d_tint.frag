#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 textureSize;
uniform vec3 multiplyColor;
uniform vec3 screenColor;
uniform sampler2D atlas;
out vec4 fragColor;

void main() {
  vec4 pixel = texture(atlas, FlutterFragCoord().xy / textureSize);
  vec3 rgb = pixel.rgb * multiplyColor * (vec3(1.0) - screenColor)
    + screenColor * pixel.a;
  fragColor = vec4(clamp(rgb, vec3(0.0), vec3(pixel.a)), pixel.a);
}
