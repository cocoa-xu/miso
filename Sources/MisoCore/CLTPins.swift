import Foundation

enum CLTPins {
  struct Package: Sendable {
    let filename: String
    let sha256: String
    let identifier: String
    let version: String
  }
  struct SizeControl: Sendable {
    let bomBytes: UInt64
    let payloadBytes: UInt64
    let sha256: String
  }
  static let packages: [String: [Package]] = [
    "082-41241": [
      .init(
        filename: "CLTools_Executables.pkg",
        sha256: "43c15c1f952c7a4c1a8f67c6b46350b83e217c610d7d3c14aa09e88bb251a4b6",
        identifier: "com.apple.pkg.CLTools_Executables", version: "16.4.0.0.1.1747106510"),
      .init(
        filename: "CLTools_macOSNMOS_SDK.pkg",
        sha256: "ba3453d62b3d2babf67f3a4a44e8073d6555c85f114856f4390a1f53bd76e24a",
        identifier: "com.apple.pkg.CLTools_SDK_macOS_NMOS", version: "16.4.0.0.1.1747106510"),
      .init(
        filename: "CLTools_macOSLMOS_SDK.pkg",
        sha256: "ee10f491e7c5518bb7346527c242ec34b2d431bb787a2ee00247553e9806ea45",
        identifier: "com.apple.pkg.CLTools_SDK_macOS_LMOS", version: "16.4.0.0.1.1747106510"),
      .init(
        filename: "CLTools_macOS_SDK.pkg",
        sha256: "a4621c6d19332f76c7c5208c386ef8cef89846bccbb204e02856ba23d646cfcf",
        identifier: "com.apple.pkg.CLTools_macOS_SDK", version: "16.4.0.0.1.1747106510"),
      .init(
        filename: "CLTools_SwiftBackDeploy.pkg",
        sha256: "e0fc4381f493af8f917f088b8a69bc836d9a6e9638f921e80756a8c47a4f187d",
        identifier: "com.apple.pkg.CLTools_SwiftBackDeploy", version: "16.4.0.0.1.1747106510"),
      .init(
        filename: "CLTools_macOS_DevSDK_Remove_macOS14.pkg",
        sha256: "13104801ff0ab16637c024d521e3ef97a4c71a127731f03d22c13158bfe19497",
        identifier: "com.apple.pkg.CLTools_SDK_macOS14", version: "16.4.0.0.1.1747106510"),
      .init(
        filename: "CLTools_macOS_DevSDK_Remove_macOS13.pkg",
        sha256: "269b51299c7e34d02985f33c3c72a6e53dc83117110b0d1a2e962b5f124fbed2",
        identifier: "com.apple.pkg.CLTools_SDK_macOS13", version: "16.4.0.0.1.1747106510"),
      .init(
        filename: "CLTools_macOS_DevSDK_Remove_macOS12.pkg",
        sha256: "61bb1112c295245195d53a5b77e83466924759576822c1e502216c1ed1d26111",
        identifier: "com.apple.pkg.CLTools_SDK_macOS12", version: "16.4.0.0.1.1747106510"),
      .init(
        filename: "CLTools_macOS_DevSDK_Remove_macOS110.pkg",
        sha256: "e5149ab585e81d2595352c11422f5592b8ca60bc4ffcb0996b68385244e45f01",
        identifier: "com.apple.pkg.CLTools_SDK_macOS110", version: "16.4.0.0.1.1747106510"),
    ],
    "082-83364": [
      .init(
        filename: "CLTools_Executables.pkg",
        sha256: "d1a517e663d7ba169296683255bcf5b498802b843603cee40ec4b6fb7c991bea",
        identifier: "com.apple.pkg.CLTools_Executables", version: "27.0.0.0.1788430756"),
      .init(
        filename: "CLTools_macOS_DevSDK_Remove_macOS13.pkg",
        sha256: "36bf6d0cc05b23cf055a111c5aac56ffc17ae9b589ab5e89bcce798dae1ebc85",
        identifier: "com.apple.pkg.CLTools_SDK_macOS13", version: "27.0.0.0.1788430630"),
      .init(
        filename: "CLTools_macOS_SDK.pkg",
        sha256: "10342d8fdf7e0878e01bf8adce6db5be7f10cec87a40eee8c0d3ca9f22107fd0",
        identifier: "com.apple.pkg.CLTools_macOS_SDK", version: "27.0.0.0.1788430631"),
      .init(
        filename: "CLTools_macOS_DevSDK_Remove_macOS12.pkg",
        sha256: "dc66174bd01a50ea9399978aaf307d5b55c2386f98b165964c9804055c3494b3",
        identifier: "com.apple.pkg.CLTools_SDK_macOS12", version: "27.0.0.0.1788430631"),
      .init(
        filename: "CLTools_macOSLMOS_SDK.pkg",
        sha256: "e4e017a68641660767f2512185a027fab7dfcce2387cbbfcdffdd4558da3d576",
        identifier: "com.apple.pkg.CLTools_SDK_macOS_LMOS", version: "27.0.0.0.1788430673"),
      .init(
        filename: "CLTools_SwiftBackDeploy.pkg",
        sha256: "1576af8ef207eac1e3736a884e3b48a198210ef580fe8a264c31b35b930ebeff",
        identifier: "com.apple.pkg.CLTools_SwiftBackDeploy", version: "27.0.0.0.1788430643"),
      .init(
        filename: "CLTools_macOSNMOS_SDK.pkg",
        sha256: "d55351824fd17742fd6e1e7a252fa1028698f32147ee48be9a6b75442bf30575",
        identifier: "com.apple.pkg.CLTools_SDK_macOS_NMOS", version: "27.0.0.0.1788430688"),
      .init(
        filename: "CLTools_macOS_DevSDK_Remove_macOS14.pkg",
        sha256: "94f7042d226b31478e5f7305fdb66c0ca4b7234447d0b9feb82b59d02b087e6b",
        identifier: "com.apple.pkg.CLTools_SDK_macOS14", version: "27.0.0.0.1788430630"),
      .init(
        filename: "CLTools_macOS_DevSDK_Remove_macOS110.pkg",
        sha256: "42a7b3b4d866763cc67f89e26ca071078aa4e0bc6424a5714d29551632ecef21",
        identifier: "com.apple.pkg.CLTools_SDK_macOS110", version: "27.0.0.0.1788430630"),
    ],
    "140-17812": [
      .init(
        filename: "CLTools_macOS_DevSDK_Remove_macOS14.pkg",
        sha256: "c19a61d24b5f5230a7cea1583320cb41ff8c8a34eb1c4b10ba40acb06a4f0c77",
        identifier: "com.apple.pkg.CLTools_SDK_macOS14", version: "26.6.0.0.1781586377"),
      .init(
        filename: "CLTools_macOS_DevSDK_Remove_macOS13.pkg",
        sha256: "ddcd3b8c3d1e8cc7349000d14dde58a4cb3df64c682c6a0ab4101b6bffd126b0",
        identifier: "com.apple.pkg.CLTools_SDK_macOS13", version: "26.6.0.0.1781586384"),
      .init(
        filename: "CLTools_macOS_DevSDK_Remove_macOS12.pkg",
        sha256: "81a078c579598b7b04eb9ff1774825630058f44ba1ff4cf30ba9bac042956170",
        identifier: "com.apple.pkg.CLTools_SDK_macOS12", version: "26.6.0.0.1781586378"),
      .init(
        filename: "CLTools_SwiftBackDeploy.pkg",
        sha256: "1c3242d9ffb9cbde2853d2362913e7c367269b1ab9766d2e22b89fdd61377fcf",
        identifier: "com.apple.pkg.CLTools_SwiftBackDeploy", version: "26.6.0.0.1781586382"),
      .init(
        filename: "CLTools_macOS_SDK.pkg",
        sha256: "5832a2626db5b0ae8dcae14caaaa0020f9e328a1babb7e58113cb4c1ff9ab18e",
        identifier: "com.apple.pkg.CLTools_macOS_SDK", version: "26.6.0.0.1781586369"),
      .init(
        filename: "CLTools_macOS_DevSDK_Remove_macOS110.pkg",
        sha256: "186b59700b2fc5e00843b1cd19af9cbf24a46cc44e9b67e14456f92351eea4ae",
        identifier: "com.apple.pkg.CLTools_SDK_macOS110", version: "26.6.0.0.1781586368"),
      .init(
        filename: "CLTools_macOSLMOS_SDK.pkg",
        sha256: "07835d08fcdc4a57b930c9a7f5c91df18666d4fa246ae994c8850cfe5aab9753",
        identifier: "com.apple.pkg.CLTools_SDK_macOS_LMOS", version: "26.6.0.0.1781586411"),
      .init(
        filename: "CLTools_macOSNMOS_SDK.pkg",
        sha256: "debe353b27a13cd678b26ab216a040acf07b62c0639d8ac522df4ca07d121eb2",
        identifier: "com.apple.pkg.CLTools_SDK_macOS_NMOS", version: "26.6.0.0.1781586415"),
      .init(
        filename: "CLTools_Executables_Universal.pkg",
        sha256: "a1486ac20337956d9553de7c4cc6bf58fe7bd1ad7c1d76dec68901c96fb4572e",
        identifier: "com.apple.pkg.CLTools_Executables", version: "26.6.0.0.1781586589"),
    ],
  ]
  static let sizes: [String: [String: SizeControl]] = [
    "082-83364/CLTools_Executables.pkg": [
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.asan_abi_iossim.a":
        .init(
          bomBytes: 131136, payloadBytes: 117384,
          sha256: "8fdadb365c3ad5481c48f37f8380a80384ac66a804038217028d4dc913533f95"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.asan_abi_tvossim.a":
        .init(
          bomBytes: 131136, payloadBytes: 117400,
          sha256: "0abfdf86251adfa8c992ceca298d3a1fbbafbc6d9e08da2a4302fdc275cabf75"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.asan_abi_watchossim.a":
        .init(
          bomBytes: 131136, payloadBytes: 117400,
          sha256: "ea0f778c068bd7e94e9547fc125cccc0a40294e3ca32daac97b3166a95eea5f3"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.asan_abi_xrossim.a":
        .init(
          bomBytes: 131136, payloadBytes: 117496,
          sha256: "84eb3bc171954445077c2e8dce103def8e55c14a781ac8a5eb4a5b0a0370c9f3"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.asan_iossim_dynamic.dylib":
        .init(
          bomBytes: 2_113_600, payloadBytes: 2_118_064,
          sha256: "46963ebf598a6234a7168646617f3e1802ce1ae7e3580b40d53937856b140084"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.asan_tvossim_dynamic.dylib":
        .init(
          bomBytes: 2_113_600, payloadBytes: 2_118_064,
          sha256: "54ce187df861ec067c01403d45d0056a055b0dba7c79646edee9d99f95cd02fb"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.asan_watchossim_dynamic.dylib":
        .init(
          bomBytes: 2_113_600, payloadBytes: 2_118_080,
          sha256: "bced024f46d0495b00cf37caff4cacaf4bbb8a779628cd0cfac4489b892fa149"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.asan_xrossim_dynamic.dylib":
        .init(
          bomBytes: 2_113_600, payloadBytes: 2_118_064,
          sha256: "1fc4c818675feb70a65a867638e6c9dc9cb858b11b234e33f749f4d3c2fa8e9b"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.cc_kext_sepos.a":
        .init(
          bomBytes: 753756, payloadBytes: 725912,
          sha256: "8f2c793873345b6c6d95f678a1e94a424682e044247216ab4f09ac8e0fc1899f"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.iossim.a": .init(
        bomBytes: 344156, payloadBytes: 311792,
        sha256: "023462d05f147d97071cd592ddc406000df2838a6bf88c7332c9a130dc1542dc"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.profile_iossim.a":
        .init(
          bomBytes: 507968, payloadBytes: 489792,
          sha256: "757f77646c8d66f37943e3e492059326ccc3ee0a82bf1da17a8401a75e570cfa"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.profile_tvossim.a":
        .init(
          bomBytes: 507968, payloadBytes: 490120,
          sha256: "1a526f60d97e0f0367b6f28a0744b6e5b1e30aa4ded231bcf1aed83ba8daf6de"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.profile_watchossim.a":
        .init(
          bomBytes: 507968, payloadBytes: 489904,
          sha256: "57f190c8ef3f32bd29b09187600da7b72c91b39196f72513e1e3fe56705f7615"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.profile_xrossim.a":
        .init(
          bomBytes: 507968, payloadBytes: 492040,
          sha256: "07c7aa486fdf47764b5c7ef06114ebbc5f099c39587e36c16fd413c56b296fe6"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.sepos.a": .init(
        bomBytes: 786524, payloadBytes: 769320,
        sha256: "4578cdc2c354d691a07afc4e9a989f98ea4ecb336d4692d02c58559e45b87a45"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.tsan_iossim_dynamic.dylib":
        .init(
          bomBytes: 2_113_600, payloadBytes: 2_126_064,
          sha256: "94a4c38ced553f440a8cce7188464ec3075634ece68bc47ac42876d3bdcf1e12"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.tsan_tvossim_dynamic.dylib":
        .init(
          bomBytes: 2_113_600, payloadBytes: 2_126_064,
          sha256: "3781af263bb6ae6958d89969d039ee0dd80132925b7580782730aa08937c2fd0"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.tsan_watchossim_dynamic.dylib":
        .init(
          bomBytes: 2_113_600, payloadBytes: 2_126_080,
          sha256: "44303d19351c55b6137a5ce06451f353bf83c13bb274aa6c0a6d2e1d1860af5d"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.tsan_xrossim_dynamic.dylib":
        .init(
          bomBytes: 2_113_600, payloadBytes: 2_126_064,
          sha256: "644a079df75ac213fd026db3889b01df4614ffe70844c279c0056eac209bb4ae"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.tvossim.a": .init(
        bomBytes: 344156, payloadBytes: 311792,
        sha256: "7e4e656ab4924f8d56e7beb25113ffee39b7b74e7deaef621b323f06e51dbd1a"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.ubsan_iossim_dynamic.dylib":
        .init(
          bomBytes: 884800, payloadBytes: 888368,
          sha256: "9abf1e1e7d49ec3d4bc5e81c86c512dcede3ba240750e2e8dd855ac2d2cbaee0"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.ubsan_tvossim_dynamic.dylib":
        .init(
          bomBytes: 884800, payloadBytes: 888384,
          sha256: "298c5f0f660a53b633b5cace4d533bed293a9798b82b964f3d115811d6c80a62"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.ubsan_watchossim_dynamic.dylib":
        .init(
          bomBytes: 884800, payloadBytes: 888384,
          sha256: "422096f34fb7d69fec7c4001bf5385d3e2de6409329ab901713081c8d196d9ea"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.ubsan_xrossim_dynamic.dylib":
        .init(
          bomBytes: 884800, payloadBytes: 888384,
          sha256: "6daac2f6ea48a287166b9dece374d3614fd3a389a905b805d27474c1574eeb53"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.watchossim.a":
        .init(
          bomBytes: 344156, payloadBytes: 311992,
          sha256: "6aafe8f841615bcae7ba36789188b77315767067956d7984544beead86922ae9"),
      "Library/Developer/CommandLineTools/usr/lib/clang/21/lib/darwin/libclang_rt.xrossim.a": .init(
        bomBytes: 393280, payloadBytes: 377592,
        sha256: "e43ee7b7e4124b9ba34d03768682fd0cef58c2fcaf667e740400cbfaaa9f8522"),
      "Library/Developer/CommandLineTools/usr/lib/swift-6.2/xros/libswiftCompatibilitySpan.dylib":
        .init(
          bomBytes: 163904, payloadBytes: 172096,
          sha256: "2995ba74cbf2eb7ffed50d8f292ef8dbbe21d4cee301c551412809f935f6b63a"),
      "Library/Developer/CommandLineTools/usr/lib/swift/xros/libswiftCompatibility50.a": .init(
        bomBytes: 32832, payloadBytes: 13128,
        sha256: "b68d7ab57fa2971b83a212c1c28479ee38a2ac0db49d825249586ffb4ac54fd4"),
      "Library/Developer/CommandLineTools/usr/lib/swift/xros/libswiftCompatibility51.a": .init(
        bomBytes: 49216, payloadBytes: 32048,
        sha256: "fc7bbd44476359e12684096390962d349e034d80b1786c99728d0edd2bdf26dc"),
      "Library/Developer/CommandLineTools/usr/lib/swift/xros/libswiftCompatibility56.a": .init(
        bomBytes: 98368, payloadBytes: 87680,
        sha256: "19eb7ae2adaf58049b09a39aa2a91ce2877b7cbbc3c8942a6ea9ee468c761474"),
      "Library/Developer/CommandLineTools/usr/lib/swift/xros/libswiftCompatibilityConcurrency.a":
        .init(
          bomBytes: 32832, payloadBytes: 8160,
          sha256: "9bbf6b53abcbf2880fe3af1e63370d4364a02ad0a62dc3d506f1747d531e0953"),
      "Library/Developer/CommandLineTools/usr/lib/swift/xros/libswiftCompatibilityDynamicReplacements.a":
        .init(
          bomBytes: 32832, payloadBytes: 6176,
          sha256: "7e6cd8c266ee580305750ae6a3bae5a2893ef2dc04847919b30c8e7e7b92b3f9"),
      "Library/Developer/CommandLineTools/usr/lib/swift/xros/libswiftCompatibilityPacks.a": .init(
        bomBytes: 32832, payloadBytes: 16872,
        sha256: "4650ebd3689eaa5fb159c66cb78f19f87c42cb2986a7c3b7ae7cf8ac4e17a3ae"),
      "Library/Developer/CommandLineTools/usr/lib/swift/xros/libswiftCxx.a": .init(
        bomBytes: 409664, payloadBytes: 392272,
        sha256: "7a9bfd4f3dcaf9b7a52e0c8aebd908b3d6b38862d7db6160f55982c0f4afbbb5"),
      "Library/Developer/CommandLineTools/usr/lib/swift/xros/libswiftCxxStdlib.a": .init(
        bomBytes: 524352, payloadBytes: 498264,
        sha256: "db9c74ae68b127364fd311306ec6ef826884ca40f26b56f97ae95aa877c810e9"),
      "Library/Developer/CommandLineTools/usr/lib/swift/xros/libswiftSwiftDirectRuntime.a": .init(
        bomBytes: 32832, payloadBytes: 3616,
        sha256: "27afeb8d01aa86f95b78a2a35e707f2da0eadcf402e03fa227833e6bc1f742ba"),
    ]
  ]
}
