import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    override func sceneDidBecomeActive(_ scene: UIScene) {
        super.sceneDidBecomeActive(scene)
        print("#### SceneDelegate:: sceneDidBecomeActive")
    }

    override func sceneWillEnterForeground(_ scene: UIScene) {
        super.sceneWillEnterForeground(scene)
        print("#### SceneDelegate:: sceneWillEnterForeground")
    }

    override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        super.scene(scene, openURLContexts: URLContexts)
        let urls = URLContexts.map(\.url.absoluteString)
        print("#### SceneDelegate:: openURLContexts = \(urls)")
    }
}
