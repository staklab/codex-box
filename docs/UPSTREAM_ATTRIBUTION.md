# 上游署名与贡献者操作指南

## 当前许可结论

- `lizhelang/codexbar` 使用 MIT License，允许二次开发和重新发布。发布时必须保留
  原版权声明与 MIT 许可文本。
- `CodexPlusPlus` 主仓库使用 AGPL-3.0。`codex-box` 只参考产品方向并独立实现，
  不复制或改编其源码与素材；若未来需要纳入其代码，应先取得单独授权，或在法律审查后
  按 AGPL-3.0 处理整个衍生作品。
- `CodexPlusPlus-Themes` 的仓库工具和清单结构使用 MIT，但每套主题及素材以主题目录
  内的 `LICENSE.md` 为准。
- `Codex-Dream-Skin` 使用 MIT，可在保留许可与版权声明的前提下参考或改编。

## 是否把上游作者添加为 GitHub Contributor

不需要，也不应为了致谢伪造提交作者或 `Co-authored-by` trailer。

GitHub 的 Contributors 页面根据真实提交历史自动生成：

- 当前项目独立发布，上游作者通过 `README.md`、`LICENSE` 和
  `THIRD_PARTY_NOTICES.md` 获得明确署名。
- 未来若直接 cherry-pick 上游提交，应保留原 commit author；推荐使用
  `git cherry-pick -x <commit>`，便于追溯来源。
- 只有某人实际共同创作了该提交且同意署名时，才使用
  `Co-authored-by: Name <email>`。
- 从上游复制或改编文件时，应在文件头或第三方声明中保留该文件适用的版权与许可，
  不能只依赖 Contributors 页面。

## 引入新上游内容的检查清单

1. 在复制代码或素材前读取目标文件和仓库的许可证。
2. 区分“功能想法 / 数据格式兼容”与“复制 / 改编受版权保护的实现”。
3. 记录仓库 URL、具体文件、基准 commit、许可证和版权人。
4. 将所需版权及许可文本加入 `THIRD_PARTY_NOTICES.md`。
5. 图片、字体和人物/IP素材单独核验权利，开源代码许可证不自动覆盖这些资产。
6. 提交前确认没有 token、账号数据、私有配置、构建产物或本地主题进入 Git。

## 当前公开仓库的署名位置

- `LICENSE`：保留直接上游版权，并追加本项目版权。
- `README.md` / `README.en.md`：说明衍生关系和主要参考项目。
- `THIRD_PARTY_NOTICES.md`：记录完整许可边界与链接。
- `FORK_RATIONALE.md`：说明技术取向和独立实现边界。
