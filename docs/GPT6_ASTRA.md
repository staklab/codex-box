# GPT-6 Astra：能力与计费

核对日期：2026-09-08。模型 ID 为 `gpt-6-astra`；API 标称上下文 1,050,000 tokens、最大输出 128,000 tokens。官方公开思考强度为 low、medium、high、xhigh、max。桌面实际可用窗口仍以本机模型目录限制及运行上报为准，不能用 API 标称容量覆盖较低的桌面限制。

## API 价格

单位为美元 / 百万 tokens。

| 模式 | 普通输入 | 缓存读取 | 缓存写入 | 输出（包含计费推理 tokens） |
| --- | ---: | ---: | ---: | ---: |
| 标准，输入不超过 272k | 10 | 1 | 12.5 | 50 |
| 标准，输入超过 272k | 20 | 2 | 25 | 75 |
| Fast，输入不超过 272k | 20 | 2 | 25 | 100 |
| Fast，输入超过 272k | 40 | 4 | 50 | 150 |

超过 272k 的判断针对单次请求输入，包含缓存输入；适用加价覆盖完整请求。不是选择大窗口就加价，也不能拿整个会话累计 tokens 判断。

缓存写入费率是普通输入的 1.25 倍。Batch / Flex 是适用标准费率的 50%；Fast 是适用费率的 2 倍，不能同时把互斥的速度档位相乘。Fast API 接受 `service_tier: "fast"` 或 `"priority"`。

当输入总量 I 包含缓存读取 C 与缓存写入 W 时，费用为：

`((I - C - W) × 输入单价 + C × 缓存读单价 + W × 缓存写单价 + O × 输出单价) / 1,000,000`

各分类先校验非负及不超过总输入。日志未提供缓存写入分类时，软件无法分离其附加费用；界面金额仍是本地日志估算，不是官方账单。工具调用费、区域处理附加费及合同专属折扣也不能从普通 token 日志完整恢复。官方 API 价格页还规定符合条件的区域处理有 10% 附加费。

## ChatGPT 登录下的 Codex 额度

Astra 支持标准与 Fast，Fast 在可用时消耗标准模式 **2.5 倍 credits**。这不是 API 的 2 倍倍率，不能用于美元 API 估算。具体额度还受任务上下文、推理、工具、缓存与套餐/合同影响，不能换算成每条消息固定费用。

官方列出的五小时本地消息估算：Plus / Standard Business 5–45；Pro 5x 25–225；Pro 20x 100–900。这是使用量估计，不是保证条数。未将其作为余额扣减公式。

## 官方来源

- [模型、上下文、推理强度与详细费率](https://developers.openai.com/api/docs/models/gpt-6-astra)
- [API 价格表](https://developers.openai.com/api/docs/pricing)
- [Codex Fast 模式与额度倍率](https://learn.chatgpt.com/docs/agent-configuration/speed)
- [Codex 套餐与使用量估算](https://learn.chatgpt.com/docs/pricing)
- [企业 credits 与 USD 计费的区别](https://learn.chatgpt.com/docs/enterprise/chatgpt-work-usage-and-cost)
