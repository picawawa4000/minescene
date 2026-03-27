// 3D textured block shader for Vulkan (Slang/HLSL style).

struct VSInput {
    [[vk::location(0)]] float3 position;
    [[vk::location(1)]] float4 color;
    [[vk::location(2)]] float2 textureCoordinates;
};

struct VSOutput {
    [[vk::location(0)]] float4 color;
    [[vk::location(1)]] float2 textureCoordinates;
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

[[vk::binding(3, 0)]]
Texture2D<float4> uTexture;

[[vk::binding(4, 0)]]
SamplerState uSampler;

[[vk::push_constant]]
cbuffer ModelOffsetPushConstant {
    float4 uModelOffset;
};

[shader("vertex")]
VSOutput mainVS(VSInput input) {
    float4 worldPos = float4(input.position + uModelOffset.xyz, 1.0);
    float4 viewPos = mul(uView, worldPos);
    float4 clipPos = mul(uTransform, viewPos);
    VSOutput output;
    output.position = clipPos;
    output.color = input.color;
    output.textureCoordinates = input.textureCoordinates;
    return output;
}

[shader("fragment")]
float4 mainPS(VSOutput input) : SV_Target0 {
    return uTexture.Sample(uSampler, input.textureCoordinates) * input.color;
}
