# 贡献指南 / Contributing

欢迎向 SoLab 提交代码、报告问题或改进文档。请先阅读 [README.md](README.md) 与 [AGENTS.md](AGENTS.md)。

欢迎任何形式的贡献：Bug 报告、功能建议、文档改进、代码提交。参与即表示你同意你的贡献在 **AGPL-3.0** 协议下发布。

## 开发环境 / Environment

- Flutter ≥ 3.44（`environment.sdk: ^3.12.1`）
- Android 构建需要 **JDK 21**（Gradle 8.14 与 JDK 25+ 不兼容）；通过环境变量 `JAVA_HOME` 指定，不要写死在仓库的 `android/gradle.properties` 中。
- 平台：Android 为主（本仓库仅面向 Android 维护与构建）。

```bash
flutter pub get
flutter analyze
powershell -ExecutionPolicy Bypass -File tools/run_targeted_tests.ps1 <与改动相关的测试文件>
powershell -ExecutionPolicy Bypass -File tools/build_android_arm64.ps1
```

## 测试策略 / Testing

与 [AGENTS.md](AGENTS.md) 保持一致：

- **只运行与本次改动相关的测试文件**，不要默认跑全量 `flutter test`（2000+ 用例）。
- 验证顺序：`flutter analyze`（改动文件）→ 相关测试文件 → 构建（如需）。
- flutter 命令不能并发执行（native assets 锁冲突会互相踩坏 build 目录）。

## 提交流程 / Submitting changes

1. 从 `master` 切出功能分支：`git checkout -b feat/your-change`。
2. 提交信息遵循 Conventional Commits，类型前缀 `feat:` / `fix:` / `chore:` / `docs:` / `refactor:`，并附简要中文说明（示例见仓库历史）。
3. 改动必须通过 `flutter analyze` 与相关测试。
4. 提交时不要包含：机器专属绝对路径、本地工具输出/产物、密钥或私人信息。
5. 发起 Pull Request，描述改动目的与验证结果。

## 需要注意的约定 / Conventions

- 工具链有硬性回归基线（R1-R9，见 [AGENTS.md](AGENTS.md)），涉及引擎/规则能力变更必须同步 bump `analysisVersion`，不得绕过。
- `assets/licenses/` 收录了已整理的第三方许可证文本；新增第三方代码、资源或预编译二进制时，必须在 `NOTICE` 补充可复现的来源、版本与许可证。
- 包名/应用标识：应用包名 `zhou.solab`；Dart 包名为 `solab`（imports 使用 `package:solab/...`）。
