# KnowLake

KnowLake 是 macOS 资料库。可以导入本地 Markdown 或微信公众号文章，用 Codex 生成笔记和看板，在应用内阅读并导出。

## 开发

需要 macOS 14+、Xcode 16+ 或同等 Swift 6 工具链、uv、Node.js 20+ 和 npm。

```sh
bash scripts/setup.sh
swift run KnowLake
```

采集和阅读可以独立使用。生成内容需要支持 App Server 的 Codex CLI 和有效登录，已验证技能注册协议的 CLI 版本为 0.166.0。Codex 路径留空时，应用从 PATH、`~/.local/bin` 和常见 Homebrew 目录查找。也可在设置中指定可执行文件。写作校对技能随 App 提供。

## 使用

- 按 `⌘N` 添加内容。可以批量粘贴微信公众号链接，或者选择本地 Markdown 模式，粘贴文字或选择 UTF-8 文件。
- 可在资料归档后生成 Markdown 笔记和 HTML 看板。Codex 图像和联合生成依赖所用账号与 CLI 提供的能力。
- 微信默认通过 HTTP 读取可访问页面。需要用浏览器渲染时，设置 `KNOWLAKE_WECHAT_BROWSER=1` 后重新运行 setup，按引擎说明准备可选浏览器。 [引擎说明](engine/README.md)

首次打开在 `~/.KnowLake` 建立资料库和模板 `config.json`。凭据和应用设置留在这个配置文件。启用生成时，所选内容由用户自己的 Codex 会话处理。库备份包含资料和任务记录，应用配置由用户单独管理。

## 打包

```sh
bash scripts/package.sh
```

本地构建生成 `.dist/KnowLake.app`，并准备对应的外部 Python Runtime。默认临时签名，适合在构建机器上验证。从其他机器安装时需一并准备匹配的运行环境。打包只使用程序资源，配置模板在运行时生成。要随本地构建准备可选微信浏览器依赖，执行 `KNOWLAKE_WECHAT_BROWSER=1 bash scripts/package.sh`。

## 验证

```sh
swift test --filter 'ModuleIsolationTests|EngineRuntimeTests|ReaderCitationTests|GenerationCheckpointsTests|CodexRuntimeTests'
uv run --directory engine --no-sync pytest -q
npm --prefix web run check
```

## 许可证

KnowLake 自有代码采用 Apache License 2.0。阅读器依赖、微信解析器和随包技能保留各自的许可证。 [Apache-2.0](LICENSE) · [第三方声明](engine/THIRD_PARTY.md)
