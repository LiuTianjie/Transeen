<p align="center"><img src="docs/assets/app-icon.png" alt="Transeen" width="96" /></p>
<h1 align="center">Transeen</h1>
<p align="center"><strong>让译文留在原处。</strong><br />框选屏幕，在原处读懂。原生 Mac 截图、标注与翻译工具。</p>
<p align="center">
  <a href="project.yml"><img src="https://img.shields.io/badge/macOS-26%2B-343b48?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="macOS 26+" /></a>
  <a href="https://github.com/LiuTianjie/Transeen/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/LiuTianjie/Transeen/ci.yml?style=flat-square&amp;label=build" alt="Build" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-64748b?style=flat-square" alt="MIT license" /></a>
</p>
<p align="center">
  <a href="https://github.com/LiuTianjie/Transeen/releases/latest">下载</a> ·
  <a href="https://transeen.itool.tech/zh/">官网</a> ·
  <a href="CHANGELOG.md">更新记录</a> ·
  <a href="README.md">English</a>
</p>
<p align="center"><img src="docs/assets/preview.webp" alt="Transeen 原位翻译真实渲染与原生工具栏" width="820" /></p>
<p align="center"><sub>使用演示内容与固定译文，展示真实渲染和原生工具栏。</sub></p>

Transeen 是一款 macOS 菜单栏应用。框选屏幕区域或打开图片，在原处查看译文、对照原文，再标注、复制、保存或钉住结果。

**官方应用需要 Transeen 专用 TR- 激活码。** 无需登录即可激活本机，也可以选择绑定 iTool 账号。源代码采用 MIT 许可证，允许商业使用。 [Licensing](LICENSING.md).

## 主要功能

- **原位翻译。** 本机 Vision OCR，结合像素样式排版，随时对照原文；长译文可以在完整文字视图中阅读。
- **独立标注。** 箭头、形状、画笔与编号保留在独立图层，支持撤销与重做。
- **自选翻译服务。** Apple 本机翻译，或兼容 OpenAI 的本地 / 远端模型。模型模式只发送识别文字，不发送截图。
- **轻巧的原生工具。** 菜单栏入口、自定义快捷键、钉图、PNG 导出与复制。不保存截图历史，不持续捕获屏幕。
- **检查更新。** 从菜单栏或启动面板选择“检查更新…”，查看最新 GitHub 版本与下载入口。

## 开始使用

1. 从 GitHub Releases 下载 Mac 通用版本，移入“应用程序”后打开。需要 macOS 26 或更高版本。
2. 打开“激活与账号…”，输入 TR- 激活码。SM- 和 IT- 是其他产品的激活码，不能通用。
3. 按指引开启屏幕录制权限，选择翻译语言。Apple 首次使用可能需要下载语言包。
4. 按 Control–Option–2 框选翻译，Control–Option–3 截图标注，Tab 对照原文与译文。

| 操作 | 默认快捷键 |
| --- | --- |
| 按默认模式框选 | `⌃⌥2` |
| 截图标注 | `⌃⌥3` |
| 对照原文与译文 | `Tab` / `⌃⌥Space` |
| 复制 / 保存 PNG | `⌘C` / `⌘S` |
| 撤销 / 重做 | `⌘Z` / `⌘⇧Z` |

当前应用界面为简体中文。可翻译语言以应用内列表为准。

## 从源码构建

需要 Xcode 26.4 或更高版本、Swift 6 与 XcodeGen。

```sh
brew install xcodegen
./scripts/build.sh
```

应用生成于 `dist/Transeen.app`。没有 Developer ID 身份时使用临时签名；签名构建可设置 `TRANSEEN_SIGNING_IDENTITY`。托管激活服务与 MIT 源码许可分开；独立分发应配置自己的授权后端。

```sh
./scripts/test.sh
./scripts/test-license.sh
./scripts/test-lifecycle.sh
```

测试覆盖图像排版、翻译协议、授权状态、版本比较和截图生命周期。安装语言包后，可用 `TRANSEEN_TEST_APPLE=1 ./scripts/test-lifecycle.sh` 单独验证真实 Apple 翻译。

## 隐私与边界

截图与 OCR 在本机处理。外部模型模式会将识别文字发送至你选择的接口。授权使用随机安装 ID 与钥匙串回执，不读取硬件序列号。检查更新会访问 GitHub。

密集排版、专业术语和公式仍可能需要修正。翻译质量取决于所选服务，重要内容请对照原文核实。

## License

[MIT](LICENSE) © 2026 LiuTianjie.
