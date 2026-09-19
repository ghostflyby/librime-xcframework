// 纯头 target 的占位翻译单元。
//
// SwiftPM 归档静态库 product 时,会把传递依赖 Clang target 的对象一并归档进 .a;
// 纯头 target 无源文件即无对象文件,libtool 文件列表会引用不存在的 RimeHeaders.o,
// 导致任何以静态库形态消费 Rime product 的包构建失败
// ("Build input file cannot be found: .../RimeHeaders.o")。
// 本文件保证 target 恒有一个对象产物,不参与头与模块内容。
const char *const RimeHeadersPlaceholder = "RimeHeaders";
