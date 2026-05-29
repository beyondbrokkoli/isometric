#version 460
#extension GL_GOOGLE_include_directive : require
#include "shared.glsl"

layout(location = 0) in vec3 fragColor;
layout(location = 1) in vec3 v_worldPos;
layout(location = 2) flat in uint v_shapeID;
layout(location = 3) flat in float v_colorIdx;

layout(location = 0) out vec4 outColor;

void main() {
    if (v_shapeID == MODE_POINT_CLOUD_PASS) {
        vec2 ptc = gl_PointCoord - vec2(0.5);
        float distSq = dot(ptc, ptc);
        float circle_mask = 1.0 - smoothstep(0.15, 0.25, distSq);
        float glow = pow(max(0.0, 1.0 - (sqrt(distSq) * 2.0)), 1.2);

        outColor = vec4(fragColor * 2.8, circle_mask * glow);
    }
    else {
        vec3 dpdx = dFdx(v_worldPos);
        vec3 dpdy = dFdy(v_worldPos);
        vec3 normal = normalize(cross(dpdx, dpdy));

        vec3 lightDir = normalize(vec3(0.5, 1.0, 0.8));
        vec3 viewDir = vec3(0.0, 0.0, 1.0);
        vec3 halfDir = normalize(lightDir + viewDir);

        float diffuse = max(dot(normal, lightDir), 0.25);
        float spec_intensity = mix(1.8, 0.3, v_colorIdx);
        float specular = pow(max(dot(normal, halfDir), 0.0), pc.highlight_power) * spec_intensity;

        outColor = vec4((fragColor * diffuse) + vec3(specular), 1.0);
    }
}
