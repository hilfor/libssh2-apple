import Foundation
import FMake

OutputLevel.default = .error

enum Config {
  static let libssh2Origin = "https://github.com/libssh2/libssh2.git"
  static let libssh2Tag = "libssh2-1.11.0"
  static let libssh2Version = "1.11.0"

  // What that tag pointed at when this was recorded, asserted after the clone.
  // A tag is a movable reference on a repository nobody here controls, and this
  // is the source that becomes the shipped binary.
  static let libssh2Commit = "1c3f1b7da588f2652260285529ec3c1f1125eb4e"

  // Our own OpenSSL 3.5 build. The libcrypto this framework links is chosen by
  // these two URLs and by nothing else -- there is no build flag for it -- so
  // pointing them back at a 1.1.1w release would still produce a working build,
  // and only `otool -L` on the result would say which one it got.
  //
  // The .frameworks.zip supplies the openssl.framework the dylib links against;
  // the libs.zip supplies the headers and static libs CMake configures with.
  // Both come from the same release, and must: a header set from one OpenSSL
  // and a binary from another links cleanly and then misbehaves at runtime.
  static let opensslLibsURL       = "https://github.com/hilfor/openssl-apple/releases/download/v3.5.7/openssl-libs.zip"
  static let opensslFrameworksURL = "https://github.com/hilfor/openssl-apple/releases/download/v3.5.7/openssl-dynamic.frameworks.zip"

  // Copied from that release's own release.md. A GitHub release asset can be
  // deleted and re-uploaded under the same tag, and FMake's download() is a
  // bare `curl -O -L` -- no --fail, so a 404 lands as an HTML body in a file
  // named .zip. Both cases fail here instead of at `unzip`.
  static let opensslLibsSHA256       = "7391f428fe4fb856f748d28f26b45d6afb0b0bb4124c35012a17d33f883e5d25"
  static let opensslFrameworksSHA256 = "6fa63ad184f4f4276415f12a5a0e4e48e50bc636f5bc87f855152f6672ce5110"

  static let frameworkName = "libssh2"

  // iOS device and simulator only. Platform.allCases also built watchOS, tvOS,
  // macOS, Catalyst and visionOS. The consuming app loads none of them, and
  // hilfor/openssl-apple publishes libcrypto for iOS, macOS and Catalyst only --
  // so the watchOS, tvOS and visionOS slices had nothing of ours to link
  // against in the first place.
  static let platforms: [Platform] = [.iPhoneOS, .iPhoneSimulator]
}

extension Platform {
  /// Minimum OS each slice declares, and the value CMake compiles against.
  ///
  /// iOS sits at 26.0 because that is both the consuming app's
  /// IPHONEOS_DEPLOYMENT_TARGET and the IOS_MIN_SDK_VERSION
  /// hilfor/openssl-apple builds its libcrypto with. A lower floor here would
  /// be a promise the framework cannot keep: it loads openssl.framework, which
  /// refuses to load below 26.0.
  var deploymentTarget: String {
    switch self {
    case .AppleTVOS, .AppleTVSimulator: return "14.0"
    case .iPhoneOS, .iPhoneSimulator:   return "26.0"
    case .MacOSX, .Catalyst:            return "11.0"
    case .WatchOS, .WatchSimulator:     return "7.0"
    case .XROS, .XRSimulator:           return Platform.defaultVisionOSVersion
    }
  }

  /// The architectures actually built, as opposed to every one the SDK offers.
  ///
  /// arm64e is dropped. App Store Connect rejects a third-party binary carrying
  /// that slice, and hilfor/openssl-apple builds no arm64e libcrypto for it to
  /// link against. Excluding it here means the defect is never produced --
  /// until now the consuming repo stripped it back out of the shipped artifact
  /// afterwards.
  var buildArchs: [Arch] {
    archs.filter { $0 != .arm64e }
  }

  /// Platform name for `ld -platform_version <platform> <min> <sdk>`.
  ///
  /// The three `-*_simulator_version_min` flags were removed from the linker
  /// outright ("ld: unknown options: -ios_simulator_version_min"), and the
  /// device flags that survive carry no SDK version. One grammar for every
  /// slice avoids both, and avoids the name/value mix that got
  /// `Platform.plistMinSDKVersionName` deprecated.
  var ldPlatformName: String {
    switch self {
    case .AppleTVOS:        return "tvos"
    case .AppleTVSimulator: return "tvos-simulator"
    case .MacOSX:           return "macos"
    case .Catalyst:         return "mac-catalyst"
    case .iPhoneOS:         return "ios"
    case .iPhoneSimulator:  return "ios-simulator"
    case .WatchOS:          return "watchos"
    case .WatchSimulator:   return "watchos-simulator"
    case .XROS:             return "xros"
    case .XRSimulator:      return "xros-simulator"
    }
  }
}


/// Five attempts with a widening pause between them.
///
/// Unauthenticated github.com transfers fail intermittently from this project's
/// build hosts -- one died with `curl: (35) Recv failure` on a URL that had
/// worked minutes earlier, which is why the consuming repo's fetch scripts
/// retry. Everything below pulls from github.com, and a drop on any of it
/// restarts a ten-minute cross-compile from nothing.
func retrying(_ what: String, _ body: () throws -> Void) throws {
  var attempt = 1
  while true {
    do {
      return try body()
    } catch {
      guard attempt < 5 else { throw error }
      print("  \(what) attempt \(attempt) failed, retrying")
      Thread.sleep(forTimeInterval: Double(attempt) * 2)
      attempt += 1
    }
  }
}

struct ChecksumMismatch: Error, CustomStringConvertible {
  let file: String
  let expected: String
  let actual: String

  var description: String {
    "\(file): SHA-256 \(actual), expected \(expected)"
  }
}

/// Downloads `url` and refuses to go on unless the bytes are the ones recorded
/// in Config. The retry wraps the checksum too: a truncated transfer is a
/// mismatch, and re-fetching is the right answer to it.
func downloadVerified(url: String, sha256 expected: String) throws {
  let file = (url as NSString).lastPathComponent
  try retrying(file) {
    try download(url: url)
    let actual = try sha(path: file)
    guard actual == expected else {
      throw ChecksumMismatch(file: file, expected: expected, actual: actual)
    }
  }
  print("✓ \(file) matches its recorded SHA-256")
}

try retrying("libssh2 clone") {
  try? sh("rm -rf libssh2")
  try sh("git clone --depth 1 \(Config.libssh2Origin) --branch \(Config.libssh2Tag)")
}

// `--branch <tag>` resolves through a reference on a repository nobody here
// controls. Assert what it landed on, so a moved tag fails the build rather
// than silently changing what ships.
let libssh2Head = try readLine(cmd: "git -C libssh2 rev-parse HEAD")
guard libssh2Head == Config.libssh2Commit else {
  throw ChecksumMismatch(
    file: "\(Config.libssh2Tag) (libssh2 source)",
    expected: Config.libssh2Commit,
    actual: libssh2Head
  )
}
print("✓ libssh2 at \(libssh2Head)")

try downloadVerified(url: Config.opensslLibsURL, sha256: Config.opensslLibsSHA256)
try? sh("rm -rf openssl")
try? sh("mkdir -p openssl")
try sh("unzip openssl-libs.zip -d openssl")

try downloadVerified(url: Config.opensslFrameworksURL, sha256: Config.opensslFrameworksSHA256)
try? sh("rm -rf openssl-frameworks")
try? sh("mkdir -p openssl-frameworks")
try sh("unzip openssl-dynamic.frameworks.zip -d openssl-frameworks")

let fm = FileManager.default
let cwd = fm.currentDirectoryPath
let opensslLibsRoot = "\(cwd)/openssl/libs/"
let toolchain = "\(cwd)/apple.cmake"

try write(content: appleCMake(), atPath: toolchain)

var dynamicFrameworkPaths: [String] = []
var staticFrameworkPaths: [String] = []

for p in Config.platforms {
  // Read once per platform rather than once per arch: each call shells out to
  // xcrun, and the answer cannot differ between architectures of one SDK.
  let sdkVersion = try p.sdkVersion()

  // The bitcode flags this used to carry (-fembed-bitcode on all three, plus
  // -bitcode_bundle at the link step) are gone: bitcode was removed from the
  // toolchain in Xcode 16 and the linker now answers `-bitcode_bundle is no
  // longer supported and will be ignored`.
  var env = try [
    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
    "APPLE_PLATFORM": p.sdk,
    "ZLIB_ROOT": "\(p.sdkPath())/usr",
    "APPLE_SDK_PATH": p.sdkPath(),
    "SECOND_FIND_ROOT_PATH": "\(opensslLibsRoot + p.name)/openssl"
  ]

  let frameworkDynamicPath = "frameworks/dynamic/\(p.name)/\(Config.frameworkName).framework"
  let frameworkStaticPath = "frameworks/static/\(p.name)/\(Config.frameworkName).framework"
  dynamicFrameworkPaths.append(frameworkDynamicPath)
  staticFrameworkPaths.append(frameworkStaticPath)

  for arch in p.buildArchs {

    print(env)
    print(arch)

    // Catalyst and visionOS carry their deployment target in the target triple
    // instead of a flag; ccTarget returns "" for every other platform, where
    // -DCMAKE_OSX_DEPLOYMENT_TARGET below is what sets it. This replaces a
    // Catalyst branch that hardcoded 14.0 next to a deploymentTarget of 11.0.
    let ccTarget = p.ccTarget(arch: arch, minVersion: p.deploymentTarget)
    if ccTarget.isEmpty {
      env["LDFLAGS"] = nil
      env["CFLAGS"] = nil
    } else {
      env["LDFLAGS"] = ccTarget
      env["CFLAGS"] = ccTarget
    }

    let libPath = "lib/\(p.name)-\(arch).sdk"
    let binPath = "bin/\(p.name)-\(arch).sdk"
    
    try? sh("rm -rf \(binPath)")
    
    try? sh("rm -rf \(libPath)")
    try? mkdir(libPath)

    try sh(
      "cmake",
      "-Hlibssh2 -B\(binPath)",
      "-GXcode",
      "-DCMAKE_TOOLCHAIN_FILE=\(toolchain)",
      "-DCMAKE_C_COMPILER=\(p.ccPath())",
      "-DCMAKE_OSX_ARCHITECTURES=\(arch)",
      "-DCMAKE_OSX_DEPLOYMENT_TARGET=\(p.deploymentTarget)",
      "-DBUILD_SHARED_LIBS=OFF",
      "-DWITH_EXAMPLES=OFF",
      "-DCMAKE_BUILD_TYPE=Release",
      "-DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO",
      "-DCMAKE_SYSTEM_NAME=Darwin", 
      "-DCMAKE_SYSTEM_PROCESSOR=\(arch)",
      "-DCMAKE_POLICY_DEFAULT_CMP0074=NEW",
      // libssh2 1.11.0 declares `cmake_minimum_required(VERSION 3.1)`, and
      // CMake 4 removed compatibility with anything below 3.5 -- it refuses to
      // configure at all. This is the escape hatch CMake 4 documents for
      // exactly that case; the alternative is patching upstream's CMakeLists.
      "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
//      "-DCMAKE_C_FLAGS=\"-target x86_64-apple-ios13.0-macabi -mios-version-min=13.0 -isystem \(try p.sdkPath())/System/iOSSupport/usr/include -iframework /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX11.1.sdk/System/iOSSupport/System/Library/Frameworks\"",
//      "-DCMAKE_CXX_FLAGS=\"-target x86_64-apple-ios13.0-macabi -mios-version-min=13.0\"",
//      "-DCMAKE_LDFLAGS=\"-target x86_64-apple-ios13.0-macabi  -L/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/maccatalyst  -L/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX11.1.sdk/System/iOSSupport/usr/lib -iframework /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX11.1.sdk/System/iOSSupport/System/Library/Frameworks \"",
      "-DCMAKE_INSTALL_PREFIX=\(libPath)",
      "-DBUILD_EXAMPLES=NO",
      "-DBUILD_TESTING=NO",
      // Dropped alongside these: -DWITH_EXAMPLES, -DENABLE_CRYPT_NONE and
      // -DENABLE_MAC_NONE. libssh2 1.11.0 defines none of the three, so CMake
      // filed them under "Manually-specified variables were not used by the
      // project" -- a line OutputLevel.error discards. They read as deliberate
      // choices to compile in the `none` cipher and `none` MAC, and did
      // nothing; the options that exist are BUILD_EXAMPLES and
      // ENABLE_ZLIB_COMPRESSION, both still passed.
      "-DENABLE_ZLIB_COMPRESSION=YES"
      , env: env)
    
    try sh(
      "cmake",
      "--build \(binPath)",
      "--config Release",
      "--target install"
    )
    
    try? mkdir("\(binPath)/tmp")
    
    // 1. makeing dylib
    
    try? mkdir("\(binPath)/obj")
    try cd("\(binPath)/obj") {
      try sh("ar -x \(cwd)/\(libPath)/lib/libssh2.a")
    }
    
    // dynamic framework
    try sh(
      "ld",
      "\(binPath)/obj/*.o",
      "-dylib",
      "-lSystem",
      "-lz",
      "-Fopenssl-frameworks/\(p.name)",
      "-framework Foundation",
      "-framework openssl",
      "-arch \(arch)",
      "-platform_version \(p.ldPlatformName) \(p.deploymentTarget) \(sdkVersion)",
      "-syslibroot \(p.sdkPath())",
      "-compatibility_version 1.0.0",
      "-current_version 1.0.0",
      "-application_extension",
      "-o \(binPath)/\(Config.frameworkName)"
    )
    
    try sh(
      "install_name_tool",
      "-id",
      "@rpath/\(Config.frameworkName).framework/\(Config.frameworkName)",
      "\(binPath)/\(Config.frameworkName)"
    )
    
    try sh("rm -rf \(binPath)/obj")
    
    
    // 2. creating static lib
    try mkdir("\(binPath)/lib")
    try sh(
      "lipo -create \(libPath)/lib/libssh2.a -output \(binPath)/tmp/libssh2.a"
    )
  }
  
  guard
    let arch = p.buildArchs.first
  else {
    continue
  }
  
  let libPath = "lib/\(p.name)-\(arch).sdk"
  
  let plist = try p.plist(
    name: Config.frameworkName,
    version: Config.libssh2Version,
    id: "org.libssh2",
    minSdkVersion: p.deploymentTarget
  )
  
  let moduleMap = p.module(name: Config.frameworkName, headers: .umbrellaDir("."))
  
  for path in [frameworkStaticPath, frameworkDynamicPath] {
    try? sh("rm -rf", path)
    try mkdir("\(path)/Headers")
    try sh("cp \(libPath)/include/*.h \(path)/Headers/")
    try write(content: plist, atPath: "\(path)/Info.plist")
    try mkdir("\(path)/Modules")
    try write(content: moduleMap, atPath: "\(path)/Modules/module.modulemap")
  }
  
  let aFiles = p.buildArchs.map { arch -> String in
    "bin/\(p.name)-\(arch).sdk/tmp/*.a"
  }
  
  try sh("libtool -static -o \(frameworkStaticPath)/\(Config.frameworkName) \(aFiles.joined(separator: " "))")
  
  let dylibFiles = p.buildArchs.map { arch -> String in
    "bin/\(p.name)-\(arch).sdk/\(Config.frameworkName)"
  }
  
  try sh("lipo -create \(dylibFiles.joined(separator: " ")) -output \(frameworkDynamicPath)/\(Config.frameworkName)")
  
  if p == .MacOSX || p == .Catalyst {
    for path in [frameworkStaticPath, frameworkDynamicPath] {
      try repackFrameworkToMacOS(at: path, name: Config.frameworkName)
    }
  }
}


try? sh("rm -rf xcframeworks")
try mkdir("xcframeworks/dynamic")
try mkdir("xcframeworks/static")

let xcframeworkName = "\(Config.frameworkName).xcframework"
let xcframeworkdDynamicZipName = "\(Config.frameworkName)-dynamic.xcframework.zip"
let xcframeworkdStaticZipName = "\(Config.frameworkName)-static.xcframework.zip"
try? sh("rm \(xcframeworkdDynamicZipName)")
try? sh("rm \(xcframeworkdStaticZipName)")

try sh(
  "xcodebuild -create-xcframework \(dynamicFrameworkPaths.map {"-framework \($0)"}.joined(separator: " ")) -output xcframeworks/dynamic/\(xcframeworkName)"
)

try cd("xcframeworks/dynamic/") {
  try sh("zip --symlinks -r ../../\(xcframeworkdDynamicZipName) \(xcframeworkName)")
}

try sh(
  "xcodebuild -create-xcframework \(staticFrameworkPaths.map {"-framework \($0)"}.joined(separator: " ")) -output xcframeworks/static/\(xcframeworkName)"
)


try cd("xcframeworks/static/") {
  try sh("zip --symlinks -r ../../\(xcframeworkdStaticZipName) \(xcframeworkName)")
}


// Build provenance. The tag says which commit of this fork published a release,
// but not which libssh2 it built, which OpenSSL it linked, or which toolchain
// built it -- and those do differ: a local build on an Xcode beta and a CI build
// bake different SDK versions into LC_BUILD_VERSION. Recording them here makes
// an artifact answerable for itself rather than only through its tag.
func capture(_ command: String) -> String {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/sh")
  p.arguments = ["-c", command]
  let pipe = Pipe()
  p.standardOutput = pipe
  do { try p.run() } catch { return "unknown" }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  let out = String(decoding: data, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return out.isEmpty ? "unknown" : out
}

let forkCommit = capture("git rev-parse HEAD")
let xcodeVersion = capture("xcodebuild -version | tr '\\n' ' '")
let iosSDK = capture("xcrun --sdk iphoneos --show-sdk-version")
// CMake compiles libssh2 here, and which major ran is not cosmetic:
// -DCMAKE_POLICY_VERSION_MINIMUM=3.5 is what lets CMake 4 configure libssh2's
// `cmake_minimum_required(VERSION 3.1)` at all, and is inert on 3.x -- so the
// same pinned commit configures under different policy semantics depending on
// the host. Neither Xcode nor the SDK version records that.
let cmakeVersion = capture("cmake --version | head -1")

let releaseMD =
  """

    libssh2 \(Config.libssh2Version), built from libssh2-apple \(forkCommit).

    | Build input | Value |
    | ----------- | ----- |
    | libssh2     | \(Config.libssh2Tag) (\(Config.libssh2Commit)) |
    | OpenSSL     | \(Config.opensslFrameworksURL) |
    | Fork commit | \(forkCommit) |
    | Toolchain   | \(xcodeVersion) |
    | iOS SDK     | \(iosSDK) |
    | CMake       | \(cmakeVersion) |

    | File                          | SHA256                                       |
    | ----------------------------- |:--------------------------------------------:|
    | \(xcframeworkdDynamicZipName) | \(try sha(path: xcframeworkdDynamicZipName)) |
    | \(xcframeworkdStaticZipName)  | \(try sha(path: xcframeworkdStaticZipName))  |

  """

try write(content: releaseMD, atPath: "release.md")
