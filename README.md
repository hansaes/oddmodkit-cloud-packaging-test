# OddModKit 云端打包前置验证

目标：先判断免费的 GitHub Actions 标准 Windows 托管运行器能否提供模组打包所需的环境。模组的游戏内使用由用户自行验证。

**已添加真实源代码构建和打包的手动工作流，仍需真实云端运行验证；不是队友传送模组。尚未生成可安装包。**

第一轮已经在 GitHub Actions 实际运行：编译器、Windows SDK、官方示例和磁盘检查通过；因尚未获取 UE 5.5 Windows 工具链而中止。详见 [真实运行结果](RESULTS.md)。

## 这一轮检查什么

- 手动触发 `OddModKit cloud packaging preflight`，只使用公开仓库的标准 `windows-2022` 运行器，最长 10 分钟。
- 云端下载官方 SDK 固定修订 `b7ac82de0b64ef3eff744b7c4d6ca22c95d12757`，检查官方 RecipeSwitcher 示例资产。
- 记录实际 CPU、内存、磁盘余量、Visual Studio C++ 和 Windows SDK。
- 检查预期云端 UE 5.5 Windows 工具链；尚未配置引擎获取，因此会明确失败，而不是把诊断成功误报为打包成功。
- 保存 `preflight.json`，报告只保留一天；不上传游戏、引擎、凭据或整个工作目录。

## 继续打包前的必要条件

GitHub Actions 不会自动附带 Unreal Engine。需要先落实有权使用的 UE 5.5 Windows 构建环境，并实测下载、安装或编译是否能放进免费运行器的空间与时间限制。

当前账号已接受 EpicGames 组织邀请，官方引擎仓库与 UE 5.5.1 标签的读取权限已验证。这个授权结果不代表引擎已经构建或模组已经打包成功。

需要自行配置授权时，参考 [Epic 官方 GitHub 关联指南](https://www.unrealengine.com/ue-on-github)。不得把密码或令牌写进公开仓库、工作流输入或聊天。

后续阶段采用官方示例 RecipeSwitcher 进行 Win64 打包，沿用 chunk 12。只有实际生成非空 `.pak`、`.utoc`、`.ucas` 和 `.manifest`，并留存真实编译、烹饪和打包结果，才报告“打包成功”。

## 真实构建工作流

`OddModKit Windows package smoke test` 在标准 `windows-2022` 托管运行器内完成：固定 UE 5.5.1 源码获取、Win64 依赖同步、MSVC 14.38 选择、ShaderCompileWorker / UnrealPak / LocEditor 编译、BuildCookRun 和 chunk 12 验证。最多运行 350 分钟，不使用公开引擎缓存或付费大型运行器。

启动时运行 `scripts/Start-CloudPackageSmoke.ps1`，使用已有 GitHub CLI 登录。它只向官方 API 请求一个指定修订的五分钟临时归档地址，再以加密 Secret 交给本次工作流并立即启动；不下载引擎到本机，也不把本机登录令牌复制到云端。该 Secret 仅传给源码下载步骤；下载完成后可删除。单独点击网页 Run workflow 不会自动刷新已过期链接，必须重新取得授权地址。

构建结果报告为 `package-smoke-report`。只有烹饪、打包和检查都通过，才出现 `RecipeSwitcher-package-smoke`，原始引擎源码、编辑器、游戏 EXE 和构建日志均不在 artifact 中。构建失败不产生可安装包，报告提供失败阶段、返回值和有限的错误类别；需要分析更多错误时先增加脱敏诊断，而不是公开完整引擎日志。

## 不执行的操作

- 不安装本机 Unreal Engine，不运行本机自托管流水线。
- 不启动付费大型运行器，不建立云桌面或持久云服务。
- 不上传现有联机 DLL、游戏安装文件、存档或账号信息。
- 不自动安装或启用模组，不发布 Steam Workshop。
- 不用已安装的 Workshop 成品冒充本次新打包结果。
- 不覆盖已经订阅的同名 RecipeSwitcher 模组；后续测试须放到独立的 `-ModsDir` 中。

## 官方参考

- [ModKit Getting Started](https://github.com/MassiveMiniteam/OddModKit/wiki/1-%7C-Getting-started)
- [官方 SDK 及许可证](https://github.com/MassiveMiniteam/OddModKit)
- [GitHub 标准托管运行器](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

官方 SDK 采用 CC BY-NC 4.0，涉及示例的改作或分发须遵守其署名及非商业条件。本仓库只提供自编前置检查脚本；SDK 由工作流从官方仓库读取。
