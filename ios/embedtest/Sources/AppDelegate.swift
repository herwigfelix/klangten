import UIKit
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        let vc = UIViewController(); vc.view.backgroundColor = .black
        w.rootViewController = vc; w.makeKeyAndVisible(); self.window = w
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        let outPath = (docs as NSString).appendingPathComponent("elten_test.txt")
        setenv("ELTEN_TEST_OUT", outPath, 1)
        let rubyDir = Bundle.main.resourcePath!
        let bootFile = (rubyDir as NSString).appendingPathComponent("boot.rb")
        elten_ruby_run(rubyDir, bootFile)   // main thread
        NSLog("[Elten embed] finished; result at \(outPath)")
        return true
    }
}
