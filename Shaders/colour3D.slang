// 3D vertex-color shader for Vulkan (Slang/HLSL style).

struct VSInput {
    [[vk::location(0)]] float3 position;
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

[[vk::binding(1, 0)]]
cbuffer Model : register(b1) {
    float4x4 uModel;
};

[[vk::binding(2, 0)]]
cbuffer View : register(b2) {
    float4x4 uView;
};

[shader("vertex")]
VSOutput mainVS(VSInput input) {
    float4 worldPos = mul(uModel, float4(input.position, 1.0));
    float4 viewPos = mul(uView, worldPos);
    float4 clipPos = mul(uTransform, viewPos);
    VSOutput output;
    output.position = clipPos;
    output.color = input.color;
    return output;
}

[shader("fragment")]
float4 mainPS(VSOutput input) : SV_Target0 {
    return input.color;
}
