import AudioToolbox
import CoreAudioKit

// MARK: - IMPSYAudioUnit View Controller Provision

extension IMPSYAudioUnit {

    public override func requestViewController(completionHandler: @escaping (AUViewControllerBase?) -> Void) {
        DispatchQueue.main.async {
            let vc = IMPSYViewController()
            vc.audioUnit = self
            completionHandler(vc)
        }
    }
}
