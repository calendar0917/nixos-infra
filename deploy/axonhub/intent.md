# axonhub 渠道意图

## 目标（最大化减少我的心智负担）
- 我要的是「能稳定出 deepseek 结果」且尽量便宜：两条线 `deepseek-jb`（破限）和 `deepseek-safe`（非破限），
  客户端用模型名选线。另两张旧卡 `gpt-5.6-luna` / `gpt-5.6-sol` 与 jb 保持一致，因为客户端还在用。
- 我只提供每条渠道的性质描述、url 和 key 引用名；其余（成功率、429、延迟、配额、是否 DS、是否临时）
  全部由系统自动探测推导，不要让我维护字段，也不要每次变更来问我。

## 模型分类（硬，2026-11-28 W34）
- `deepseek-jb` / `deepseek-safe` 以及旧卡 `gpt-5.6-luna` / `gpt-5.6-sol` 只允许关联
  `ds_kind=ds` 的渠道。free、非 DS、身份未公开的 stealth 模型不得挂在任意优先级，包括后备位。
- opencode 的免费模型走独立 `free-*` 卡，客户端显式选模型名；不得再把它们塞进 `deepseek-*` 兜底。
  同一 verified family 可共用一张卡；不同 family 或身份无法验证的模型分别建卡，避免冒名归类。
- `W38-FREE-COPY-TRANSITION`：`free-hy4-flash` / `free-hungerg-stealth` 已从渠道 51 复制关联；
  `deepseek-jb` / `deepseek-safe` / `gpt-5.6-luna` / `gpt-5.6-sol` 上的原 51 关联全部保留。
  当前不执行 migrate/remove；删除必须等用户显式批准。
- 破限/非破限是用途边界，不是模型家族：`deepseek-safe` 只收用户标为非破限的 DS 渠道；
  `deepseek-jb` 收破限 DS，`luna/sol` 跟随 jb。DS 家族证明不代表破限，free 也不代表破限。
- `hy4-flash-free` 的上游目录确认是腾讯 Hy4；`hungerg-free` 目录只写 stealth reasoning，
  没有 canonical_id/family，响应也只暴露 `hungerg-free` 与 HungerG 自称，不能标成 DS、GPT 或混元。

## 取舍规则（稳定 > 成本，硬顺序，不要临场发挥）
1. 先筛「能不能用」：当前探活失败、连续 5xx/504、额度窗口未到 → 不进候选最高位，哪怕它免费。
2. 再筛「合不合意图」：free/非 DS 不进 deepseek 卡任何位置，改走独立 free 卡；临时渠道不能长期占坑；破限/非破限不混。
3. 两人都通过的候选，才按成本排序：同层内优先更便宜/更稳的；便宜渠道只有在实时成功率不低于
   主力渠道 10 个百分点以内时才允许上位。
4. 冲突时的唯一答案：**宁可多花 token、多等 5 秒，也不用便宜换稳定**。
   只有「稳定性指标基本持平（24h 成功率差 ≤ 2 个百分点、429/5xx 无显著上升）」才允许按成本切换。

## 渠道性质约束（硬）
- free 渠道只能服务独立 free 卡，不能作为 deepseek 卡的首选、后备或任何优先级兜底。
  免费只表示价格，不表示模型家族；每个模型的身份必须由上游目录/响应证明，不能凭名字猜。
- 临时渠道（名字带 temp/weekend、创建时间近、或备注写了临时）不能长期占坑：
  可以让它先吃流量，但要在复评时给出「继续/退役」建议，并标注额度窗口。
- 破限线和非破限线分开：给非破限的渠道不要自动加到破限线当主力。

## 质量约束（软，按权重判断）
- 24h 成功率明显低的（例如低于 80%）降权或移到观察位；但有临时额度/周限额的要先看额度窗口。
- 429 高的降权：同一把 key 上的多个渠道要一起看，避免把共用 key 的两条同时拉高。
- 连续探活失败、上游持续 5xx/504 的渠道：保留关联但降到位、交给探活等待恢复，不要直接删除。
- 延迟只在同一优先级组内比较，不因为慢就跨优先级挪。

## 档位与人工约定
- `temp-1127` 是 deepseek-jb 的第二顺位备用主力，用户明确要等它的额度窗口过了再接回。
  不要归档、不要暂停它的探活。
- `公益-墨析` 是非破限线的主力，除非连续多轮失败，否则不要挪出首位。
- 同一条线里最多三条渠道并列最高位；同层等权轮转以避开 429。

## 变更纪律
- 每次只做少量、可解释的变更；每条建议必须写明「依据哪条意图 + 哪个画像字段」。
- 不确定就输出「不改」并说明缺什么证据，不要猜。
- 默认只报不写；`auto_apply` 由我再显式打开一次，之后每次变更不用再问我。

## 渠道输入（用户只提供性质 + url + key 引用名）
下面是当前 10 条渠道的用户输入样例（其中 1 条已禁用，仍保留配置待评估）。**这里没有渠道号、没有优先级、没有 key 明文**；`key_ref` 只是引用名。

- 公益-墨析：稳定的非破限 DS 中转，url=https://jpn.cdn.moxuna.com/v1，key_ref=AXONHUB_KEY_MOXUNA
- cmd：便宜的 DS 中转，说是有周限额，url=https://api.commandcode.ai/provider/v1，key_ref=AXONHUB_KEY_CMD
- hub-1125：备用的 DS 中转，url=https://hub.oaifree.com/v1，key_ref=AXONHUB_KEY_HUB1125
- temp-1127：临时破限 DS，五小时额度，url=https://linuxdo.si/v1，key_ref=AXONHUB_KEY_TEMP1127
- opencode：opencode 的 DS 通道，url=https://opencode.ai/zen/go，key_ref=AXONHUB_KEY_OPENCODE
- hub-1127-2：临时便宜 DS，url=https://hub.oaifree.com/v1，key_ref=AXONHUB_KEY_HUB11272
- weekend-temp：周末临时便宜 DS，url=https://codexfree.xiaotuxp.com/v1，key_ref=AXONHUB_KEY_WEEKEND
- weekend-temp-2：周末临时便宜 DS，url=https://free.hiyo.top/v1，key_ref=AXONHUB_KEY_WEEKEND
- opencode-free：opencode 免费模型通道（hy4-flash-free / hungerg-free），只服务独立 free 卡，url=https://opencode.ai/zen/go，key_ref=AXONHUB_KEY_OPENCODE_FREE
- 96110-free-ds：免费 DS（实测 deepseek-v4-1-flash-1017），**已禁用（首字延迟过高），保留配置待评估**；原为非破限 DS 主力，也可用于破限线，url=https://api.96110.li/v1，key_ref=AXONHUB_KEY_96110
- 117-9973-ds：免费 DS（目录实测 deepseek-v4.1-flash），IP+HTTP 站点；首字延迟实测 0.6s（远低于 25 的 4.36s / 46 的 5.15s，未触发 96110 那种高延迟禁用）；用户指定 jb/safe 首位 p1，url=http://117.50.34.24:9973/v1，key_ref=AXONHUB_KEY_117_9973
