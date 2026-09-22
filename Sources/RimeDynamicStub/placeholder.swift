// 空占位翻译单元 Swift 化:SwiftPM 的 C target 需至少一个源文件产生对象文件,
// 但 Xcode 对宿主/测试共享产品生成的动态产品变体,链接时不携带覆盖插桩运行时
// (-fprofile-instr-generate 编译进 C TU 的 ___llvm_profile_runtime 引用无处解析)。
// Swift target 的产品变体链接自带该通道,且对象文件照常供给静态归档,故占位
// 改为 Swift 空 TU。tbd 框架的发现机制与语言无关。
