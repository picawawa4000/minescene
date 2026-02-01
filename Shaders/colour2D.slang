// 2D vertex-color shader for Vulkan (Slang/HLSL style).

struct VSInput {
    [[vk::location(0)]] float2 position;
    [[vk::location(1)]] float4 color;
};

struct VSOutput {
    [[vk::location(0)]] float4 color;
    float4 position : SV_Position;
};

[[vk::binding(0, 0)]]
cbuffer Transform : register(b0) {
    float4x4 uTransform;
};

[shader("vertex")]
VSOutput mainVS(VSInput input) {
    float4 pos = mul(uTransform, float4(input.position, 0.0, 1.0));
    VSOutput output;
    output.position = pos;
    output.color = input.color;
    return output;
}

[shader("fragment")]
float4 mainPS(VSOutput input) : SV_Target0 {
    return input.color;
}
