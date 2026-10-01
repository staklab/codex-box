# GPT-6.1 Sol、GPT-6 Sol 与 GPT-6 Luna 定价

核对日期：2026-10-01。应用中的美元费用按官方 API token 价格估算。

## API 价格

单位为美元 / 百万 tokens；下表适用于单次输入不超过 272,000 tokens 的请求。

| 模型 | 模式 | 普通输入 | 缓存读取 | 缓存写入 | 输出 |
| --- | --- | ---: | ---: | ---: | ---: |
| GPT-6.1 Sol | Standard | 2 | 0.10 | 2.50 | 10 |
| GPT-6.1 Sol | Fast | 4 | 0.20 | 5 | 20 |
| GPT-6 Sol | Standard | 2 | 0.20 | 2.50 | 10 |
| GPT-6 Sol | Fast | 4 | 0.40 | 5 | 20 |
| GPT-6 Luna | Standard | 0.10 | 0.01 | 0.125 | 0.50 |
| GPT-6 Luna | Fast | 0.20 | 0.02 | 0.25 | 1 |

Fast 为适用 Standard 费率的 2 倍；兼容日志中的 `fast` 和 `priority`。Batch / Flex 为适用 Standard 费率的 50%。

单次输入超过 272,000 tokens 时，整个请求的输入、缓存读取与缓存写入费率乘 2，输出费率乘 1.5；该规则与 Fast 倍率叠加。阈值包含缓存输入，不使用整个会话的累计用量判断。

缓存写入费率为普通输入的 1.25 倍。有缓存写入分类时，从普通输入中扣除这一部分再单独计费，避免重复收费。日志未提供分类时无法还原这项附加费。

## Codex 订阅与 credits

官方 Codex 价格页规定：Fast 对套餐内用量消耗为 Standard 的 2.5 倍，对购买的 credits 和企业按量付费为 2 倍。Codex credits 不另收缓存写入费。API token 美元估算与套餐用量分别计算，应用的费用估算不作为订阅额度扣减公式。

## 模型选项

三个模型的 API 标称上下文为 1,050,000 tokens、最大输出为 128,000 tokens。桌面有效窗口以本机模型目录及运行上报为准。

GPT-6.1 Sol 支持 low、medium、high、xhigh、max；GPT-6 Sol 和 GPT-6 Luna 还支持 none。应用保留当前实际读取到的推理强度。

## 官方来源

- [API Standard 与 Fast 价格表](https://developers.openai.com/api/docs/pricing)
- [GPT-6.1 Sol 模型与计费规则](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
- [GPT-6 Sol 模型与计费规则](https://developers.openai.com/api/docs/models/gpt-6-sol)
- [GPT-6 Luna 模型与计费规则](https://developers.openai.com/api/docs/models/gpt-6-luna)
- [Codex 套餐用量与 credits 价格](https://learn.chatgpt.com/docs/pricing)
