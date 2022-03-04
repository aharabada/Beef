Texture2D tex2D;
SamplerState linearSampler
{
    Filter = MIN_MAG_MIP_LINEAR;
    AddressU = Clamp;
    AddressV = Clamp;
};

float4 WindowSize;
float4 BackgroundColor = float4(1, 0, 0, 1);

struct PS_INPUT
{
	float4 Pos : SV_POSITION;    
    float2 Tex : TEXCOORD;
	float4 Color : COLOR0;
};

struct VS_INPUT
{
	float4 Pos : POSITION;    
    float2 Tex : TEXCOORD;
	float4 Color : COLOR;
};

PS_INPUT VS(VS_INPUT input)
{
	PS_INPUT output;
	
	output.Pos = float4(input.Pos.x / WindowSize.x * 2 - 1, 1 - input.Pos.y / WindowSize.y * 2, 0, 1);
	
	output.Color = input.Color;
	output.Tex = input.Tex;
	
	output.Color = float4(input.Color.b * input.Color.a, input.Color.g * input.Color.a, input.Color.r * input.Color.a, input.Color.a);

    return output;  
}

float4 PS(PS_INPUT input) : SV_Target
{
	float4 aTex = tex2D.Sample(linearSampler, input.Tex);
	float aGrey = input.Color.r * 0.299 + input.Color.g * 0.587 + input.Color.b * 0.114;
		float a = lerp(aTex.a, 0, aGrey);

	// blend
	float r = aTex.r * input.Color.r + (1.0 - aTex.r) * BackgroundColor.r;// * v_background_colour_linear.r
	float g = aTex.g * input.Color.g + (1.0 - aTex.g) * BackgroundColor.g;// * v_background_colour_linear.g
	float b = aTex.b * input.Color.b + (1.0 - aTex.b) * BackgroundColor.b;// * v_background_colour_linear.b

    return float4(r, g, b, aTex.a); // * input.Color;
}
