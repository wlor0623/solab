<div align="center">
  <img src="assets/app_icon.png" alt="SoLab Icon" width="120" />
  <h1>SoLab</h1>
  <p><em>AI 驱动的 APK 逆向工作台 · 多模型 LLM 客户端</em><br/>
  <em>AI-powered APK reverse-engineering workbench · Multi-model LLM client</em></p>

  [![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)
</div>

---

**SoLab**（包名 `zhou.solab`）是一个以 Android 为主的 LLM 聊天客户端，提供用于已获授权 APK 的分析与构建工作流。选择 APK 后，可由内置 "SoLab 助手"（对话式 AI）驱动分析、定位、修改与签名；产物在工作目录中单独生成，不覆盖源 APK。

支持接入多个兼容模型服务。服务可用性、费用、鉴权方式与数据政策以服务提供方当前规则为准；请仅使用你有权使用的账号或密钥。

**SoLab** (package name `zhou.solab`) is an Android-first LLM chat client that provides an analysis and build workflow for APKs you are authorized to handle. After selecting an APK, the built-in "SoLab Assistant" can drive analysis, locating, patching, and signing. Outputs are generated separately in the workspace and never overwrite the source APK.

It supports multiple compatible model services. Availability, pricing, authentication, and data policies are determined by each provider; use only accounts or keys you are authorized to use.

## ✨ 核心能力 / Core Capabilities

| 能力 (Capability) | 说明 (Description) |
| --- | --- |
| **APK 工作台** / APK Workbench | 解包 / 分析 / 修改 / 重签名，dryRun 预览、显式确认与产物分离；Unpack / analyze / patch / re-sign, with dryRun preview, explicit confirmation, and separate outputs |
| **进程内 MCP 服务器** / In-process MCP server | 局域网 HTTP 直连（默认端口 8800），电脑端 AI 客户端直连手机工具链，无桥接架构；LAN HTTP direct link (port `8800`), no bridging |
| **DEX 分析引擎** / DEX engine | methods/fields 定位、smali 读写、交叉引用、混淆类反查；method/field locate, smali read/write, cross-reference, obfuscation look-up |
| **SO 分析引擎** / SO engine | ELF 解析、函数 / 控制流 / 加密识别、反汇编、模拟执行；ELF parse, control-flow / encryption detection, disassembly, emulation |
| **Blutter 集成** / Blutter integration | 基于 MIT 许可 Blutter 组件的本地 Flutter AOT 分析；local Flutter AOT analysis using MIT-licensed Blutter components |
| **特征规则库** / Signature rules | 广告 SDK 特征、厂商快速开关、订阅同步；ad SDK signatures, vendor quick toggles, subscription sync |
| **分析报告体系** / Report system | 源包一致性（reportSourceApk / boundApk）与新鲜度校验（reportFreshness）；source-consistency & freshness integrity checks |
| **AI 基础设施** / AI infra | 世界书、助手记忆、指令注入、内置 SoLab 助手；world book, assistant memory, instruction injection, built-in assistant |

## 📦 从源码构建 / Build from source

```bash
flutter pub get
powershell -ExecutionPolicy Bypass -File tools/build_android_arm64.ps1
```

- 需要 JDK 21（Gradle 8.14 与更高 JDK 不兼容）。
- 产物：`dist/SoLab-<版本>-arm64-v8a.apk`；交付后自动清理可重建缓存。
- 支持平台：Android 为主（本仓库仅面向 Android 维护与构建）。

Requirements:

- JDK 21 is required (`Gradle 8.14` is not compatible with newer JDKs).
- Output: `dist/SoLab-<version>-arm64-v8a.apk`; rebuildable caches are cleaned after delivery.
- Platforms: Android is the primary, actively-maintained target.

### 🤖 GitHub Actions 云端构建 / Build via GitHub Actions

仓库自带工作流 `.github/workflows/build-apk.yml`（Flutter 3.44.1 + JDK 21），两种触发方式：

- **手动**：GitHub 仓库 → Actions → Build APK → Run workflow，完成后在该次运行的 Artifacts 下载 APK。
- **自动**：推送 `v*` 标签（如 `v2.3.1`）自动构建并创建 Release 附带 APK。

云端构建默认产出**未签名** APK（无法直接安装）。如需签名包，在仓库 Settings → Secrets and variables → Actions 配置 `KEYSTORE_BASE64`（keystore 的 base64）、`KEYSTORE_PASSWORD`、`KEY_ALIAS`、`KEY_PASSWORD` 四个 secrets，工作流会自动生成 `key.properties` 完成签名。

The repo includes `.github/workflows/build-apk.yml` (Flutter 3.44.1 + JDK 21). Trigger manually from the Actions tab, or push a `v*` tag to build and publish a Release. Builds are unsigned unless the `KEYSTORE_BASE64` / `KEYSTORE_PASSWORD` / `KEY_ALIAS` / `KEY_PASSWORD` secrets are configured.

## 🔄 同步上游 / Upstream sync

Kelivo 固定使用 `upstream` 远端,SoLab 发布仓库使用 `origin`。提交或暂存本地改动后,执行 `powershell -ExecutionPolicy Bypass -File tools/sync_upstream.ps1`;脚本会拉取并合并上游、检查 SoLab 名称没有被覆盖,再运行关键验证。

Kelivo is tracked through the `upstream` remote, while `origin` is reserved for the SoLab repository. After committing or stashing local changes, run `powershell -ExecutionPolicy Bypass -File tools/sync_upstream.ps1` to merge upstream updates and verify the SoLab identity and key tests.

## ⚖️ 开源声明 / Open-source statement

本项目基于 [Kelivo](https://github.com/Chevey339/kelivo) 二次开发，SoLab 代码遵循 **AGPL-3.0** 协议发布。第三方组件仍分别适用其原有许可证，详见应用内「设置 → 关于 → 开源协议与来源」。

This project is derived from [Kelivo](https://github.com/Chevey339/kelivo). SoLab code is released under the **AGPL-3.0** license. Third-party components remain subject to their original licenses; see the in-app "Settings → About → Licenses & Sources" page.

### 参考与使用的开源项目 / Third-party components

| 组件 (Component) | 用途 (Purpose) | 许可证 (License) | 声明 (Notice) |
| --- | --- | --- | --- |
| **Blutter** | Flutter AOT 本地分析组件；Flutter AOT local analysis component | MIT | [源码与许可证](https://github.com/worawit/blutter) |
| **PPTool** | Dart 对象池引用定位参考；Dart pool-pointer reference lookup | Apache-2.0 | [源码](https://github.com/Kirlif/PPTool) |
| **SOMCP** | MCP 网关与逆向工具聚合参考；MCP gateway and tooling reference | AGPL-3.0 | [源码与许可证](https://github.com/bilieebiliee1-design/SOMCP) |
| **ApkDataMultiplexing** | APK 数据复用与 V2/V3 签名组件；APK data multiplexing and signing | 未声明 | [来源](https://github.com/L-JINBIN/ApkDataMultiplexing) |
| **ApkSignatureKillerEx** | 原包签名校验处理参考；signature-check handling reference | 未声明 | [来源](https://github.com/L-JINBIN/ApkSignatureKillerEx) |
| **DPatch 载荷** | DPatch 模式使用的独立 DEX / 原生载荷；independent DEX / native payload for DPatch mode | 许可证未确认 | 网络来源，未提供可复现原始链接；不得据此推定可再分发授权 |
| **小奶瓶项目** | SoLab APK 工具能力的历史来源；historical source | 未声明 | [MT 论坛项目帖](https://bbs.binmt.cc/thread-171312-1-1.html) |

完整许可证与来源见 [LICENSE](LICENSE)、应用内「设置 → 关于 → 开源协议与来源」以及 `assets/licenses/`。未声明许可证的材料只列来源，不视为已获再分发授权。 Full license and source records are available in [LICENSE](LICENSE), in-app under "Settings → About → Licenses & Sources", and in `assets/licenses/`.

`android/app/libs/apk-data-multiplexing.jar` 的上游项目未声明再分发许可证。发布前请取得作者书面许可，或替换为有明确许可证的实现。

DPatch 模式所含的 `pandora_loader.dex` 与 `libpandora.so` 为网络来源材料，当前没有可复现的原始链接或许可证记录。它们仅按原样保留用于审计与兼容；公开发布前应取得再分发许可，或替换为具备明确许可证的自研实现。

## 使用边界 / Responsible use

仅分析、修改或分发你拥有或已获得明确授权的 APK。第三方模型服务、规则订阅和局域网 MCP 服务均由使用者自行启用并承担相应的账号、网络与数据风险。

## 📄 许可证 / License

[AGPL-3.0](LICENSE)

<br/>
<div align="center"><sub>Made with 💗 · 用代码改代码，用 AI 反折 AI</sub></div>
