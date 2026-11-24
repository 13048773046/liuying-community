import Darwin
import Flutter
import UIKit

// Swift 不总是把 ptrace 的 C 变体导入到作用域；用显式符号声明保证 Release 构建可编译。
@_silgen_name("ptrace")
private func liuying_ptrace(
  _ request: Int32,
  _ pid: Int32,
  _ addr: UnsafeMutableRawPointer?,
  _ data: Int32
) -> Int32

private let liuying_pt_deny_attach: Int32 = 31

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var privacyCover: UIView?

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    guard let window = self.window, privacyCover == nil else { return }
    let cover = UIView(frame: window.bounds)
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    cover.backgroundColor = UIColor(red: 0.055, green: 0.075, blue: 0.085, alpha: 1)
    let title = UILabel()
    title.text = "流萤社区"
    title.textColor = UIColor(white: 0.92, alpha: 1)
    title.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
    title.textAlignment = .center
    title.frame = cover.bounds
    title.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    cover.addSubview(title)
    window.addSubview(cover)
    privacyCover = cover
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    privacyCover?.removeFromSuperview()
    privacyCover = nil
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    #if !DEBUG
    // 关闭 debugserver 附加；越狱设备上的动态调试/注入会先被这里挡住。
    _ = liuying_ptrace(liuying_pt_deny_attach, 0, nil, 0)
    if getenv("DYLD_INSERT_LIBRARIES") != nil {
      exit(0)
    }
    if isJailbroken() {
      showIntegrityAlert()
    }
    #endif
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  #if !DEBUG
  private func isJailbroken() -> Bool {
    let paths = [
      "/Applications/Cydia.app",
      "/Library/MobileSubstrate/MobileSubstrate.dylib",
      "/bin/bash",
      "/usr/sbin/sshd",
      "/etc/apt",
      "/private/var/lib/apt/",
      "/var/jb/",
    ]
    for path in paths where FileManager.default.fileExists(atPath: path) {
      return true
    }
    if let url = URL(string: "cydia://package/com.example.package"),
       UIApplication.shared.canOpenURL(url) {
      return true
    }
    let probe = "/private/liuying_jailbreak_probe.txt"
    do {
      try "probe".write(toFile: probe, atomically: true, encoding: .utf8)
      try FileManager.default.removeItem(atPath: probe)
      return true
    } catch {
      return false
    }
  }

  private func showIntegrityAlert() {
    DispatchQueue.main.async {
      let alert = UIAlertController(
        title: "设备环境异常",
        message: "检测到越狱或注入环境，账号凭证可能被读取。为保护账号安全，建议在官方系统环境使用。",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "退出", style: .destructive) { _ in exit(0) })
      alert.addAction(UIAlertAction(title: "继续", style: .cancel))
      self.window?.rootViewController?.present(alert, animated: true)
    }
  }
  #endif
}
