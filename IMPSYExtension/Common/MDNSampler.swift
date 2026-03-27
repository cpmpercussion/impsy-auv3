import Foundation
import Accelerate

// MARK: - MDNSampler
//
// Pure-Swift port of the Mixture Density Network sampling from IMPSY (mdrnn.py).
// The TFLite model outputs MDN parameters in this layout:
//
//   [ mus: M×D | sigmas: M×D | piLogits: M ]
//
// where M = numMixtures, D = dimension (including time delta at index 0).
//
// All model values are scaled by SCALE_FACTOR = 10; we divide by 10 on output.

enum MDNSampler {

    // MARK: - Main sampling entry point

    /// Sample a prediction vector from MDN output parameters.
    ///
    /// - Parameters:
    ///   - params: Flat array of MDN parameters, length = M*(2D+1)
    ///   - dimension: Full model dimension (including time delta)
    ///   - numMixtures: Number of Gaussian mixture components
    ///   - piTemp: Temperature for mixture selection (higher = more diverse)
    ///   - sigmaTemp: Temperature for Gaussian sampling (higher = more random)
    /// - Returns: Sampled vector of length `dimension`; index 0 is time delta.
    static func sample(
        params: [Float],
        dimension: Int,
        numMixtures: Int,
        piTemp: Float,
        sigmaTemp: Float
    ) -> [Float] {
        let muCount = numMixtures * dimension

        guard params.count >= muCount * 2 + numMixtures else {
            return [Float](repeating: 0, count: dimension)
        }

        let mus      = Array(params[0..<muCount])
        let sigmas   = Array(params[muCount..<muCount * 2])
        let piLogits = Array(params[muCount * 2..<muCount * 2 + numMixtures])

        // 1. Select mixture component using softmax with temperature
        let pis = softmaxWithTemperature(piLogits, temperature: piTemp)
        let m   = sampleCategorical(pis)

        // 2. Extract mu and sigma for the chosen component
        let muVec    = Array(mus[m * dimension ..< (m + 1) * dimension])
        let sigmaVec = Array(sigmas[m * dimension ..< (m + 1) * dimension])

        // 3. Sample from diagonal Gaussian: x_i = mu_i + sigma_i * sqrt(sigmaTemp) * N(0,1)
        let sqrtSigmaTemp = sqrtf(sigmaTemp)
        var output = [Float](repeating: 0, count: dimension)
        for i in 0..<dimension {
            output[i] = muVec[i] + sigmaVec[i] * sqrtSigmaTemp * standardNormal()
        }

        return postProcess(output)
    }

    // MARK: - Post-processing

    /// Undo SCALE_FACTOR=10, enforce minimum dt, clamp values to [0,1].
    static func postProcess(_ raw: [Float]) -> [Float] {
        var out = raw.map { $0 / IMPSYConstants.scaleFactor }
        // Dimension 0: time delta — must be positive
        out[0] = max(out[0], Float(IMPSYConstants.minimumDeltaTime))
        // Dimensions 1…N: normalised values — clamp to [0,1]
        for i in 1..<out.count {
            out[i] = min(max(out[i], 0.0), 1.0)
        }
        return out
    }

    // MARK: - Softmax with temperature

    static func softmaxWithTemperature(_ logits: [Float], temperature: Float) -> [Float] {
        let safeTemp = max(temperature, 1e-6)
        var scaled = logits.map { $0 / safeTemp }

        // Subtract max for numerical stability
        let maxVal = scaled.max() ?? 0
        scaled = scaled.map { $0 - maxVal }

        var exps = scaled.map { expf($0) }
        let sum  = exps.reduce(0, +)
        guard sum > 0 else {
            // Uniform fallback
            let n = Float(logits.count)
            return logits.map { _ in 1.0 / n }
        }
        return exps.map { $0 / sum }
    }

    // MARK: - Categorical sampling

    static func sampleCategorical(_ probs: [Float]) -> Int {
        var r = Float.random(in: 0..<1)
        for (i, p) in probs.enumerated() {
            r -= p
            if r <= 0 { return i }
        }
        return probs.count - 1
    }

    // MARK: - Standard normal via Box-Muller

    static func standardNormal() -> Float {
        // Box-Muller transform: generates N(0,1) from two uniform samples
        let u1 = Float.random(in: Float.ulpOfOne..<1.0)   // avoid log(0)
        let u2 = Float.random(in: 0.0..<1.0)
        return sqrtf(-2.0 * logf(u1)) * cosf(2.0 * .pi * u2)
    }
}
