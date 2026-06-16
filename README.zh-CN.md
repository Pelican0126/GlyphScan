# GlyphScan

[English](README.md) | **中文**

**端侧、OCR 感知的模糊匹配——在一帧充满噪声的 OCR 文本里，找出相机正对着的那一条记录。**

纯 Swift、零运行时依赖。GlyphScan 理解*中文 OCR 到底怎么错的*——因为它真的盯着字形看过。

> **状态：早期实现。** `GlyphScanCore`——召回锚定的两阶段匹配器，配可插拔打分器与候选源——已实现并通过测试（`swift test`，15 个通过）。字形混淆模型与学习型打分器（[DESIGN.zh-CN.md](docs/DESIGN.zh-CN.md) §8–9）是下一步。

---

## 问题

把手机相机对准印刷页跑 OCR，吐回来的是几百个字的一团——页眉、页脚、好几条记录混在一起、平均每十个字错一个。现在要在你本地的语料里，实时、端侧地找出用户究竟对着*哪一条*，并告诉他*该信几分*。

标准模糊匹配（Jaccard、编辑距离）在这个场景直接崩：噪声撑爆集合并集，逐字命中的记录照样得分很低；一个认错的 CJK 字把最长连续匹配拦腰砍断。GlyphScan 就是为这个场景而生。

## 有趣在哪

- **召回锚定相似度** —— 分数锚定在*候选*上，而非输入。一条逐字出现在满页噪声里的记录得分 ~1.0，而不是被周围噪声稀释到接近 0。
- **字形导出的混淆——一张表，三处用。** GlyphScan 把每个字渲染成位图、比形状，*自动*导出一张形近字表。同一张表驱动 (1) OCR 感知的相似度、(2) 训练用的真实合成噪声、(3) 置信度标定。它知道 未／末 长得像，因为它真的看过。
- **学习型、标定过的打分** —— 一个小逻辑回归在可解释的特征上取代手调权重与置信度切点，输出真概率来驱动四档置信度显示。只发 ~10 个系数；推理就是点积 + sigmoid，无重型 ML 运行时。
- **处处可插拔** —— 自带 OCR（Apple Vision 或任何东西）、自带候选存储（内存，或一个协议背后的 SQLite）、自带语料。

## 使用场景

任何"扫一个印刷的东西、匹配到一条短记录"的任务：

- 闪卡与题库
- 发票 / 收据行项
- 药品识别
- 菜单项与价签
- 图书馆书架查找
- "在我的笔记里找这一段"

## 架构速览

运行时匹配流水线（端侧，每次扫描）：

```
[OCR 文本 + bbox]              ← 你的 OCR（Vision 或任何引擎；引擎无关）
   │  预处理：归一化 / 分段 / 拆带权字段
   ▼
Stage 1 · 粗筛召回             滑窗子串 → CandidateSource → 候选池 ≤ 300
   │                          （CandidateSource 是唯一可插拔缝）
   ▼
Stage 2 · 精排打分            OCR 感知特征 → LogisticScorer → 校准概率
   ▼
[ top-k 记录 + 概率 + 四档置信度 ]
```

字形混淆表是共享枢纽：

```
                 渲染字形 → 比形状 → k-NN → cost ∈ [0,1]
                              字形混淆表
                ┌───────────────────┼───────────────────┐
        OCR 感知相似度        合成噪声 +          置信度
          （运行时）          难负样本            标定
                              （训练）           （评测）
```

完整细节、数据模型、训练流水线见 [docs/DESIGN.zh-CN.md](docs/DESIGN.zh-CN.md)。

## 快速上手

```swift
import GlyphScanCore

let corpus = [
    SimpleRecord(id: 1, stem: "光合作用的主要场所是叶绿体", options: ["线粒体", "叶绿体", "细胞核"]),
    // … 你的记录（任何遵循 MatchableRecord 的类型）
]

let matcher = GlyphScanMatcher(source: ArrayCandidateSource(corpus))

// 喂一段带噪声的 OCR——哪怕是一整页、正确记录埋在里面：
let hits = matcher.bestMatches(for: ocrText)
if let top = hits.first {
    print(top.record.id, top.score, top.confidence)   // 例如 1  0.92  .high
}
```

自带 OCR（Apple Vision 或任何能产出文本的东西）；大语料把 `CandidateSource` 接到 SQLite `LIKE` 查询上，而不是用内存版 `ArrayCandidateSource`。

## 构建与测试

```sh
swift build
swift test
```

## 设计原则

- **核心纯 Swift、零运行时依赖**（仅 Foundation）。学习模型是几个系数，不是一个框架。
- **能用你自己的数据复现** —— 合成数据 + 训练 CLI 用 `swift run` 从任意语料自举一个模型，无需人工标注。
- **CJK 优先。** 多数模糊匹配库以拉丁文为中心；GlyphScan 直接建模中文 OCR 的错误结构。

## 许可

[MIT](LICENSE)。
