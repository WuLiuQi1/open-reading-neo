#include <flutter/runtime_effect.glsl>

// The engine supplies the input texture's physical dimensions and sampler.
uniform vec2 uSize;
uniform float uClearHeight;
uniform float uMaxSigma;
uniform vec2 uDirection;
uniform sampler2D uInput;
out vec4 fragColor;

vec4 sampleInput(vec2 position) {
  vec2 uv = clamp(position / uSize, 0.5 / uSize, 1.0 - 0.5 / uSize);
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uInput, uv);
}

void main() {
  vec2 position = FlutterFragCoord().xy;
  float progress = clamp(position.y / max(uClearHeight, 1.0), 0.0, 1.0);
  float sigma = uMaxSigma * (1.0 - progress);
  if (sigma < 0.1) {
    fragColor = sampleInput(position);
    return;
  }

  // Combine adjacent discrete Gaussian taps using the linear input sampler.
  // Unlike sparse quadrature, every physical source pixel contributes; pairing
  // halves texture reads without changing the Gaussian kernel or its radius.
  vec4 total = sampleInput(position);
  float weightSum = 1.0;
  float coefficient = 1.0;
  float ratio = exp(-0.5 / (sigma * sigma));
  float ratioStep = ratio * ratio;
  int radius = int(ceil(3.0 * sigma));
  for (int i = 1; i <= 384; i += 2) {
    if (i > radius) break;
    coefficient *= ratio;
    ratio *= ratioStep;
    float firstWeight = coefficient;
    coefficient *= ratio;
    ratio *= ratioStep;
    float secondWeight = i + 1 <= radius ? coefficient : 0.0;
    float pairWeight = firstWeight + secondWeight;
    // At very small sigma, the finite tail may underflow to zero.
    if (pairWeight < 0.000001) break;
    float offset = float(i) + secondWeight / pairWeight;
    vec2 delta = uDirection * offset;
    total += (sampleInput(position - delta) + sampleInput(position + delta))
        * pairWeight;
    weightSum += 2.0 * pairWeight;
  }
  fragColor = total / weightSum;
}
