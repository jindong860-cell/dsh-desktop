# DSH Desktop v2.3.6

Windows 桌面封装版 DeepSeek Harness。项目以 **MSIX + PowerShell 5.1 + Go Host** 实现，运行时安装在用户自行选择的目录中。

> **非官方项目**：本项目是基于 DeepSeek Harness 的第三方社区桌面封装，不是 DeepSeek 官方产品。

## 功能

- Windows 10/11 x64 MSIX 安装包
- 首次启动可选择 DSH 运行环境目录
- 自动安装便携 Node.js 24
- 安装/修复 `@deepseek-ai/dsh`
- 处理 DeepSeek Harness prerelease 的 peer dependency 闭包与版本一致性
- 中文/空格路径支持
- DSH Core 安装向导、实时 npm 日志与环境校验
- Core 更新检查、修复、启动、停止和日志入口
- API Key 由 DeepSeek Harness 自己管理，DSH Desktop 不读取或上传 API Key

## 当前稳定基线

本仓库固定在 **DSH Desktop 2.3.6**。这是当前保留的稳定桌面外壳基线；后续 WebView2 / Native v3 实验分支不属于本版本。

DeepSeek Harness 仍处于快速迭代阶段，上游 prerelease 版本可能发生依赖或配置格式变化。DSH Desktop 2.3.6 默认把 DSH Core 的兼容边界固定在已验证的 prerelease 版本，并对 `@deepseek-ai/dsh-*` peer 包进行版本收敛。

## 从源码构建测试 MSIX

### 环境

- Windows 10/11 x64
- Windows PowerShell 5.1
- Go 1.23+
- 管理员权限（仅测试证书写入 `LocalMachine\TrustedPeople` 时需要）

Visual Studio 不是必需项。构建脚本会优先使用本机 Windows SDK；如果没有，会通过 NuGet 下载 `Microsoft.Windows.SDK.BuildTools`。

### 一键构建 + 签名 + 安装

以管理员身份运行：

```bat
Build-And-Install-Test-MSIX.cmd
```

脚本会：

1. 检查源文件与工具
2. 创建本地测试签名证书
3. 从 `host/` 编译 `DSHDesktopHost.exe`
4. 生成并签名 MSIX
5. 验证签名
6. 卸载旧测试包并安装新包

测试证书只适用于开发/个人测试环境。公开分发请使用可信的代码签名证书或 Microsoft Store 签名。

## 使用

安装后从开始菜单打开 **DSH Desktop**。首次使用选择运行目录，例如：

```text
D:\DSH Desktop
```

然后按安装向导完成 Node.js 与 DSH Core 初始化。在 Harness Web UI 的 **Settings / Models** 中配置 API Key。

## 故障排查

### `cordis.patch.yml` YAML 解析失败

如果错误指向：

```text
%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml
```

可完全退出 DSH Desktop 后运行：

```text
tools\Repair-Web-Profile.cmd
```

它会先备份旧文件，再把用户 Web overlay 重置为合法的空 YAML 列表 `[]`。它不会删除 API Key、会话或模型设置。

### 日志

运行环境日志位于：

```text
<你的运行环境目录>\logs
```

## 生产签名

`.github/workflows/release-msix.yml` 支持使用仓库 Secrets 构建正式签名 MSIX：

- `MSIX_PFX_BASE64`
- `MSIX_PFX_PASSWORD`
- `MSIX_PUBLISHER`

不要把 PFX、密码或 API Key 提交到仓库。

## License

DSH Desktop 使用 [MIT License](LICENSE)。DeepSeek Harness 同样采用 MIT License；详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。