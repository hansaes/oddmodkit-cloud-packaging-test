# 云端示例打包测试说明

这是 Massive Miniteam 官方 RecipeSwitcher 示例的云端重新构建包，不是队友传送模组，也不是由已安装 Workshop 包复制得到。

来源：[官方 OddModKit](https://github.com/MassiveMiniteam/OddModKit)，固定修订 `b7ac82de0b64ef3eff744b7c4d6ca22c95d12757`；官方示例作者为 Massive Miniteam GmbH。SDK 使用 [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/)，本包仅用于非商业构建测试；未修改官方示例蓝图，仅重新构建容器并更新清单时间戳。

引擎：官方 UE 5.5.1，修订 `585df42eb3a391efd295abd231333df20cddbcf3`。源码、编辑器、引擎构建产物和游戏 EXE 不包含在这个模组包里。

仅证明云端编译、烹饪、打包及 pak 完整性检查完成，尚未在真实游戏内验证，不保证安装后可用或多人行为正确。

请先备份存档；不要替换已订阅的 RecipeSwitcher，也不要同时启用两份同 ID 模组。使用独立测试目录，例如把原生文件放在 `C:\OddModSmoke\RecipeSwitcher\`，游戏启动参数使用 `-ModsDir="C:\OddModSmoke" -EnableLoggingInShipping`，在主菜单的模组界面自行启用。请按原生游戏的启用流程测试，不使用外部注入器。
