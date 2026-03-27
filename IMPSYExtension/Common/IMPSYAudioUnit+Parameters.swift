import AudioToolbox

// MARK: - IMPSYAudioUnit Parameter Tree

extension IMPSYAudioUnit {

    func setupParameterTree() {
        let threshold = AUParameterTree.createParameter(
            withIdentifier:  "threshold",
            name:            "Threshold",
            address:         ParameterAddress.threshold.rawValue,
            min:             ParameterRanges.thresholdMin,
            max:             ParameterRanges.thresholdMax,
            unit:            .seconds,
            unitName:        nil,
            flags:           [.flag_IsReadable, .flag_IsWritable],
            valueStrings:    nil,
            dependentParameters: nil
        )
        threshold.value = ParameterDefaults.threshold

        let sigmaTemp = AUParameterTree.createParameter(
            withIdentifier:  "sigmaTemp",
            name:            "Sigma Temp",
            address:         ParameterAddress.sigmaTemp.rawValue,
            min:             ParameterRanges.sigmaTempMin,
            max:             ParameterRanges.sigmaTempMax,
            unit:            .generic,
            unitName:        nil,
            flags:           [.flag_IsReadable, .flag_IsWritable],
            valueStrings:    nil,
            dependentParameters: nil
        )
        sigmaTemp.value = ParameterDefaults.sigmaTemp

        let piTemp = AUParameterTree.createParameter(
            withIdentifier:  "piTemp",
            name:            "Pi Temp",
            address:         ParameterAddress.piTemp.rawValue,
            min:             ParameterRanges.piTempMin,
            max:             ParameterRanges.piTempMax,
            unit:            .generic,
            unitName:        nil,
            flags:           [.flag_IsReadable, .flag_IsWritable],
            valueStrings:    nil,
            dependentParameters: nil
        )
        piTemp.value = ParameterDefaults.piTemp

        let timescale = AUParameterTree.createParameter(
            withIdentifier:  "timescale",
            name:            "Timescale",
            address:         ParameterAddress.timescale.rawValue,
            min:             ParameterRanges.timescaleMin,
            max:             ParameterRanges.timescaleMax,
            unit:            .rate,
            unitName:        nil,
            flags:           [.flag_IsReadable, .flag_IsWritable],
            valueStrings:    nil,
            dependentParameters: nil
        )
        timescale.value = ParameterDefaults.timescale

        parameterTree_ = AUParameterTree.createTree(withChildren: [
            threshold, sigmaTemp, piTemp, timescale
        ])

        // Propagate changes to the engine
        parameterTree_.implementorValueObserver = { [weak self] param, value in
            guard let self, let addr = ParameterAddress(rawValue: param.address) else { return }
            switch addr {
            case .threshold:  self.engine.threshold = Double(value)
            case .sigmaTemp:  self.engine.sigmaTemp = value
            case .piTemp:     self.engine.piTemp    = value
            case .timescale:  self.engine.timescale = value
            }
        }

        parameterTree_.implementorValueProvider = { [weak self] param in
            guard let self, let addr = ParameterAddress(rawValue: param.address) else { return 0 }
            switch addr {
            case .threshold:  return Float(self.engine.threshold)
            case .sigmaTemp:  return self.engine.sigmaTemp
            case .piTemp:     return self.engine.piTemp
            case .timescale:  return self.engine.timescale
            }
        }
    }
}
