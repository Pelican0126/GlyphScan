# GlyphScan — 设计文档

[English](DESIGN.md) | **中文**

| | |
|---|---|
| 状态 | Draft（设计阶段） |
| 日期 | 2026-06-16 |
| 作者 | Pelican0126 + Claude |

---

## 1. 一句话定位

> **GlyphScan** —— 端侧、相机 OCR、大海捞针式的**短记录模糊匹配引擎**：给一帧充满噪声的 OCR 文本和一个短记录语料库，实时找出相机正对着的是哪条记录，并给出一个**可信的概率**。纯 Swift、零运行时依赖，匹配核心**理解中文 OCR 到底怎么错的**——因为它真的盯着字形看过。

这不是 OCR 库（OCR 谁都能调 Vision）。难的、值得做的是后半段：一页几百个字里把正确那条记录的分顶上去、对真机 OCR 噪声鲁棒、还能给出校准过的置信度——而且这套"噪声感"是从字形里**自动学出来的**，不是手列规则。

## 2. 背景与动机

相机 OCR 短记录匹配是个被低估的难问题：把手机对准印刷页跑 OCR，吐回来的是几百个字的 blob——页眉页脚、好几条记录的文本混在一起、平均每 10 个字错 1 个。要在本地语料里**实时、端侧**地定位出用户究竟对着哪一条，并告诉他该信几分。

朴素方案的三处痛点：

1. **相似度崩塌**：Jaccard / 编辑距离在这个 regime 直接失效——噪声撑爆集合并集，正确记录逐字命中却被稀释到 ~0.2 分；一个认错的 CJK 字把最长连续匹配拦腰砍断。
2. **手调魔数**：相似度权重、字段加权、置信度切点、罚分全靠拍脑袋，没有数据支撑，也无法随语料自适应。
3. **对头号失效束手无策**：真机 OCR 约每 10 个 CJK 字错 1 个，而朴素相似度对所有认错的字一视同仁——一个被认错的形近字（未→末）会把真命中从 0.7 拖到 0.4。

GlyphScan 用两个设计正面回应：

- **字形混淆驱动的 OCR 感知相似度**（§7、§8）：把"OCR 怎么错"变成主角。
- **学习型标定打分器**（§9）：用一个小逻辑回归取代全部手调魔数，输出真概率。

## 3. 目标与非目标

### 目标
- 匹配核心为独立 SwiftPM 包，**仅依赖 Foundation**（运行时核心）。
- 通过 `CandidateSource` 协议与具体存储（SQLite 等）解耦，留一道唯一可替换缝。
- 以通用 `Record` 为中心，让引擎适用于卡片 / 题库 / 发票行项 / 药品 / 菜单 / 笔记检索等场景。
- 引入字形混淆表，统一驱动**相似度打分、合成噪声、置信度标定**三处。
- 引入学习型标定打分器，取代手调权重与置信度切点，输出校准概率。
- 合成数据自举 + 纯 Swift 训练/评测 CLI，**任何人拿自己语料都能复现**、开箱即用。

### 非目标（YAGNI）
- ❌ 不打包 OCR 引擎。BYO-OCR；只提供一个可选、极薄的 Vision 适配 target。
- ❌ 不含相机 / UI。
- ❌ 流式跨帧追踪状态机本期**不做**（作为未来可选模块 `GlyphScanStream`）。
- ❌ 不上 GBT / 神经网络排序器（本期就逻辑回归）。
- ❌ 无在线学习 / bandit（端侧反馈本期只做"采集钩子"，离线重训；在线自适应留作未来）。
- ❌ 无服务器、无云训练。

## 4. 核心定位：通用记录匹配基元

引擎以通用 `Record` 为中心，不绑任何具体领域：

```swift
public typealias RecordID = Int64                 // 由消费方定义，库不关心其含义

public enum FieldRole { case primary, secondary } // 字段角色：主字段权重高，次字段次之

public struct MatchField {
    public let text: String
    public let role: FieldRole
}

public protocol MatchableRecord {
    var id: RecordID { get }
    var fields: [MatchField] { get }               // 一条记录的可检索字段
}
```

- 字段按 primary/secondary 加权（默认 0.4/0.6，可配，最终交给学习器）。
- 切分单元（按编号标记把一帧切成多条单元）、字段角色标注等**领域特异逻辑降级成"可插拔策略"**（§6 `Segmenter` 协议）；通用核心默认"整帧即一条单元"。
- 消费方写一个 `YourType: MatchableRecord` 适配即可接入（主字段→primary，次字段→secondary）。

> 这个泛化让核心更简洁：核心只懂"带权字段的记录 + OCR 感知相似度 + 学习打分"，所有领域特异性都在适配层。

## 5. 总体架构

两条流水线，外加一个共享枢纽（字形混淆表）。

### 5.1 运行时匹配流水线（端侧，每次扫描）

```
[OCR 文本 + bbox]            ← 消费方：Vision 或任意 OCR（核心引擎无关）
   │
   ▼  GlyphScanCore
预处理：normalize / cleanForMatching / Segmenter 切单元 / 拆 primary·secondary 字段
   │
   ▼  Stage 1 · 粗筛召回
生成滑窗子串（5 字 stride 1，3 字 / 前 4 字兜底）
   │  └──▶ CandidateSource 协议 ──▶ 有界候选池 ≤ 300   ← 唯一可替换缝（消费方注入存储实现）
   │
   ▼  Stage 2 · 精排打分                                    ← ML
对每个候选抽特征向量（OCR 感知 soft bigramRecall / twin-LCS / 数字重叠 / 长度比 + 旧公式分）
   │  └──▶ LogisticScorer（加载 default-coefficients.json）──▶ 校准概率
   │
   ▼  输出                                                  ← ML
top-k(record, probability) + Confidence 四档（切点由数据学出）
```

### 5.2 离线训练流水线（开发 / CI，`swift run`，进 CI 不进发布产物）

```
[语料库（你的 Record）]
   │  GlyphScanLearn
   ├─▶ 字形混淆表生成：CoreText 渲染每个字 → 比形状 → k-NN → cost∈[0,1]
   │        │（同一张表也供运行时相似度使用，见 §8）
   ▼        ▼
OCR 噪声生成（按混淆表 corrupt + 邻条串扰 + 难负样本挖掘）
   │
   ▼
合成带标签集 (noisyScan, trueRecordID) 正负样本
   │
   ▼
LogisticTrainer（纯 Swift 梯度下降 + 温度标定）
   │
   ▼
default-coefficients.json  ──系数注入──▶ LogisticScorer（运行时 Stage 2）
   │
   ▼
Benchmark（top-1 / top-3 / AUC / ECE / 各档精度）── CI 质量闸门
```

### 5.3 共享枢纽：一张混淆表，三处用

| 消费方 | 用法 |
|---|---|
| 运行时 · OCR 感知相似度 | soft bigram recall + twin-aware LCS：认错的形近字只扣一点，不再砍半 |
| 训练 · 合成噪声 + 难负样本 | 按真实形近概率 corrupt；专挑"只差形近字"的记录当最难负样本 |
| 评测 · 置信度标定 | twin 命中作为特征参与标定，四档切点更稳 |

## 6. 包结构与仓库布局

```
GlyphScan/
├── Package.swift
├── Sources/
│   ├── GlyphScanCore/                  # 运行时核心，仅 Foundation
│   │   ├── Record.swift                # MatchableRecord / MatchField / FieldRole / RecordID
│   │   ├── Normalize.swift             # normalize / cleanForMatching
│   │   ├── Segmenter.swift             # Segmenter 协议 + WholeFrameSegmenter（默认）
│   │   ├── GlyphConfusion.swift        # ConfusionTable（加载/查询，sparse）
│   │   ├── Similarity.swift            # OCR 感知 softBigramRecall / twinLCS / pairSim
│   │   ├── Features.swift              # (input, candidate) → FeatureVector
│   │   ├── Scorer.swift                # Scorer 协议 + HeuristicScorer + LogisticScorer
│   │   ├── CandidateSource.swift       # 协议 + ArrayCandidateSource（内存暴力版）
│   │   ├── GlyphScanMatcher.swift      # 两阶段编排（滑窗生成在此）
│   │   └── Confidence.swift            # 四档 tier（概率切，切点来自系数文件）
│   ├── GlyphScanLearn/                 # 训练/评测工具，进 CI 不进发布产物
│   │   ├── GlyphRenderer.swift         # CoreText 渲染字 → 归一化位图（#if canImport(CoreText)）
│   │   ├── ConfusionBuilder.swift      # 位图 → k-NN → ConfusionTable 生成
│   │   ├── OCRNoiseModel.swift         # 形近字替换 / 丢字 / 全半角 / 邻条串扰
│   │   ├── SyntheticDataset.swift      # 语料 → (noisyScan, trueID) 带标签样本
│   │   ├── LogisticTrainer.swift       # 梯度下降拟合 + 温度标定
│   │   └── Metrics.swift               # top-1/top-3 / AUC / ECE / 各档精度
│   └── glyphscan-cli/                  # 可执行：build-confusion / gen / train / bench
├── Sources/GlyphScanVision/            # 可选 Apple-only：VNRecognizedText → [Observation]
├── Tests/
│   ├── GlyphScanCoreTests/             # 相似度/特征/打分器/解耦端到端
│   └── GlyphScanLearnTests/            # 混淆表断言（未/末是 twin、我/你不是）+ 噪声模型 + 训练收敛
├── Resources/
│   ├── default-coefficients.json       # 随包默认系数 + 各档切点（在样例库上训出）
│   ├── default-confusions.json         # 默认形近字混淆表（样例库 charset + 常见 seed）
│   └── sample-corpus.csv               # 小样例库（测试 + 开箱训练演示）
├── Benchmarks/                         # 基准 fixtures + 期望指标阈值
├── README.md / docs/DESIGN.md
└── LICENSE（MIT）
```

要点：
- `GlyphScanCore` **零第三方依赖**；逻辑回归推理 = 点积 + sigmoid，纯 Swift，不引 CoreML，可每帧对几百候选跑、成本可忽略。
- `GlyphScanLearn` 用 CoreText 渲染字形——这正是把训练放在 Swift 而非 Python 的原因：渲染就在 Apple 平台手边，`swift run` 一条龙、零外部依赖。
- 混淆表运行时只**加载**（sparse JSON），生成在离线。

## 7. 数据模型与输出

```swift
public struct MatchResult {
    public let record: MatchableRecord
    public let probability: Double          // LogisticScorer 输出的校准概率 [0,1]
    public let confidence: Confidence
}

public enum Confidence: Equatable {         // 切点来自系数文件，不再硬编码
    case high, medium, low, veryLow
    // 永远展示 top-1，用颜色/caveat 表达可信度
}
```

## 8. 字形混淆模型（核心巧思）

### 8.1 生成（离线，`GlyphScanLearn` / `glyphscan-cli build-confusion`）

1. **确定 charset**：语料库出现过的全部字符 ∪ 可选常见形近 seed 集。典型语料几千个 distinct 字，可行。
2. **渲染**：用 CoreText 把每个字渲染成 N×N（默认 32×32）灰度位图，居中、按墨迹归一化（消除字面大小差异）。
3. **特征**：归一化位图展平为向量（默认 32×32=1024 维；可选降采样到 16×16）。
4. **近邻**：对每个字求视觉最近邻。朴素 O(n²) 在几千字规模秒级可接受；更大 charset 用墨迹密度 / 包围盒纵横比分桶剪枝，只在邻桶内比较。
5. **距离 → cost**：`cost = clamp(1 - cosine(a,b), 0, 1)`；每字只保留 top-k（默认 8）、且 `cost ≤ τ`（默认 0.35）的近邻。
6. **输出** sparse 表：`char → [(neighbor, cost)]`，写 `default-confusions.json`。

确定性：固定字体、字号、渲染参数 → 构建可复现（CI 可校验哈希）。

可选 **on-device 重生成**：用当前 UI 字体在端侧跑同一流程，得到与本机渲染一致的混淆表（"它看的是你这台机器上的字形"）。默认仍发预生成表，端侧重生成为 opt-in。

### 8.2 校验（一个会让人会心一笑的单测）

```
assert twin(未, 末) && twin(已, 己) && twin(田, 由) && twin(干, 千)
assert !twin(我, 你) && !twin(山, 海)
```

把"它真的懂形近字"变成 CI 里跑的断言，而非 README 里的吹嘘。

### 8.3 数字例外（重要纠偏）

形近软化**只用于 CJK 与字母，不用于数字**。3 与 8 即便不形近，它们的**值**也必须精确区分——把数字的认错软化掉会让 "3/4" 与 "8/4" 误判为同条。因此：
- 相似度里数字按**精确**匹配。
- false-twin 数字守卫（候选独有 ≥2 个数字 ∧ 占比 ≥50% 才罚分）保留，作为离散特征喂给学习器（§9）。

## 9. OCR 感知相似度

定义 `twinCost(a,b)`：`a==b → 0`；`(a,b)` 在表中 → 表 cost；否则 → 1（数字之间恒为精确，见 §8.3）。

- **soft bigram recall**：把输入的每个 bigram 连同其形近变体（带 `1-cost` 权重）展开进一个加权多重映射；对候选的每个 bigram 取最佳命中权重之和 ÷ |候选 bigram|。展开受 k² 上界（k≈8 → ≤64）约束，仍廉价。精确逐字命中 → 1.0；全靠形近命中 → ≈∏(1-cost)。
- **twin-aware LCS**：连续子串 DP，匹配条件放宽为 `twinCost ≤ τ`，累积 `1-cost` 而非整数 1。一个被认错的形近字不再把连续段拦腰砍断——直接打中 §2 的头号失效。
- **合成**：`pairSim = 0.65·softBigramRecall + 0.35·softLcsRatio`（这俩权重最终也作为特征交给学习器，不再是定死的魔数）。
- primary/secondary 字段分别算 `pairSim` 再加权（默认 0.4/0.6）。

### 9.1 学习型标定打分器（取代全部手调魔数）

**特征向量**，每个 `(input, candidate)` 一条（全部复用上面已算的量，无新增重活）：

| 特征 | 含义 |
|---|---|
| `softBigramRecall_primary` | primary 字段 OCR 感知 bigram 召回 |
| `softLcsRatio_primary` | primary 字段 twin-aware LCS ÷ 长度 |
| `softBigramRecall_secondary` / `softLcsRatio_secondary` | secondary 字段同上 |
| `numberOverlap` | 抽取数字的 Jaccard（精确，见 §8.3） |
| `falseTwinFired` | 数字守卫是否触发（离散 0/1） |
| `lengthRatio` | `log(cleaned候选 ÷ cleaned输入)` |
| `hasSecondary` | 候选是否有 secondary 字段 |
| `inputLen` | 输入长度（区分整页扫描 vs 单条截图） |
| `heuristicScore` | **现有 OCR 感知公式 blended 分（作为一个特征）** |

**模型：逻辑回归** → `p(候选就是正确记录 | 特征)`。
- **排序** = 按 `p` 排。
- **置信度** = 对 top-1 的 `p` 切档；切点按"每档目标精度"在留出集上学出（如 high = 精度 ≥ 0.95 处的 p），写进系数文件，取代硬编码切点。
- **标定**：逻辑回归本身较好标定，再在留出集上做一次温度缩放（Platt），用 ECE / 可靠性图验收。

**关键决策：把 `heuristicScore` 也喂进去** → 学习器是手调公式的**严格超集**。最差等于公式（下限锁死、永不更差），又能在公式之上再榨准确率。默认值风险最低。

**为什么逻辑回归而非 GBT/NN**：约 10 个系数，JSON 几行；纯 Swift 推理在热路径零负担；系数可解释；小数据也稳；**无模型时回退 `HeuristicScorer`**，默认永不崩。

```swift
public protocol Scorer {
    func score(input: String, candidate: MatchableRecord) -> Double   // OCR 文本 vs 候选 → 可比较分
    func confidence(forTopScore p: Double) -> Confidence
}
// HeuristicScorer：现 OCR 感知公式 + 旧式切点（兜底 / A-B 基线）
// LogisticScorer：加载系数 → 特征点积 + sigmoid + 学出来的切点
```

`GlyphScanMatcher` 持有一个 `Scorer`，默认 `.bundledLearned`，可切 `.heuristic` / `.custom(coeffs)`。

## 10. 两阶段匹配器 + CandidateSource 解耦

```swift
public protocol CandidateSource {
    /// 给定核心生成的滑窗子串，返回 primary 字段可能包含它们的有界候选池。
    func candidates(matchingAnyOf windows: [String], limit: Int) -> [MatchableRecord]
}
```

- 滑窗策略（5 字 / stride 1 / 3 字兜底 / 前 4 字兜底 / 池上限 300 / 长度比 [0.3,3.0] 过滤）留在核心 `GlyphScanMatcher`；它只把"要查的窗口"交给 source；"按窗口取行"是唯一可替换点。
- 包内自带 `ArrayCandidateSource`（内存子串扫描，适合小库 + 测试 + 开箱即用）。
- 大库消费方提供 SQLite/GRDB 版 `CandidateSource`，把滑窗 `LIKE` SQL 包进去即可。

## 11. 合成数据 + 纯 Swift 训练

- **OCRNoiseModel**：字符级（查混淆表的形近替换、丢字、插杂字、全/半角互换）+ 版面级（次字段乱序、尾部截断、页眉页脚杂串、编号前缀多形态）+ **邻条串扰**（拼接相邻记录文本模拟"整页"场景）。
- **难负样本挖掘**：用混淆表找出"只差形近字/数字"的记录对，专门生成最难负样本，逼模型学会精细区分。
- **SyntheticDataset**：自动标注（已知来源 id），产出正负样本，零人工。
- **LogisticTrainer**：纯 Swift batch/mini-batch 梯度下降（~10 特征 × 几千样本，几十行即可），含 L2 正则与温度标定。
- **CLI**：`build-confusion`（建混淆表）、`gen`（生成合成集）、`train`（拟合 → 写系数）、`bench`（出指标）。
- **Metrics**：top-1 准确率、top-3 召回、AUC、ECE、各档精度。

## 12. 可选端侧反馈回路（二期）

- 库暴露钩子：消费方在用户**采纳/否决/纠正**某条结果时，回吐 `(featureVector, label)`；存储由消费方掌握（全本地）。
- 一期只做采集 + 离线重训；二期再考虑端侧用同一个 Swift LR 增量微调（合成先验 + 真实反馈混合）。隐私：全本地、可选开启、无网络。

## 13. 公开 API（消费者视角）

```swift
let matcher = GlyphScanMatcher(
    source: myCandidateSource,        // 或内置 ArrayCandidateSource(records)
    scorer: .bundledLearned           // 或 .heuristic / .custom(coeffs)
)

// 一次性（文本框 / 单帧 OCR 文本）：
let hits = matcher.bestMatches(for: ocrText, limit: 3)
// hits: [MatchResult]  —— record + probability + confidence

// 纯工具也都 public：normalize / segment / pairSim / ConfusionTable.query ……
```

## 14. 测试与质量闸门

- 混淆表断言（§8.2）。
- **CI 基准闸门**：合成基准必须达到 top-1 ≥ X% / top-3 ≥ Y% / ECE ≤ Z，回归即 fail build——对匹配库这是防止悄悄变差的命根子。（X/Y/Z 在首版基准跑通后定基线。）
- **不劣于公式**测试：`LogisticScorer` 在基准上必须 ≥ `HeuristicScorer`，保证永不发更差的默认值。
- OCR 感知 vs 精确相似度的消融测试：证明 twin 软化在含形近噪声的集上确有增益。

## 15. 接入 GlyphScan（采用指南）

- 给你的记录类型实现 `MatchableRecord`（主字段→primary、次字段→secondary）。
- 实现 `CandidateSource`：小库用内置 `ArrayCandidateSource`；大库用 SQLite/GRDB 包一层滑窗 `LIKE`。
- 选 `Scorer`：默认 `.bundledLearned`；想要确定性基线用 `.heuristic`；用自己语料重训得 `.custom(coeffs)`。
- 流式/相机场景：消费 `MatchResult.record.id` 做跨帧身份判断（流式追踪器作为未来可选模块 `GlyphScanStream`）。

## 16. 分期实施

1. **P0 打平**：`GlyphScanCore` 通用 Record + `CandidateSource` 解耦 + 公式版相似度/测试（`HeuristicScorer`）。以 `HeuristicScorer` 打平作为基线。
2. **P1 字形混淆 + OCR 感知相似度**：`GlyphRenderer` / `ConfusionBuilder` / soft 相似度 + 混淆表断言 + 消融。
3. **P2 学习型标定打分器**：特征 + `LogisticTrainer` + 合成数据 + 基准闸门 + `default-coefficients.json`。
4. **P3 打磨开源**：英文 README、`GlyphScanVision` 可选 target、`sample-corpus`、CI、LICENSE。
5. **（未来）** 端侧反馈在线学习、`GlyphScanStream`（流式追踪器）、网页 playground。

## 17. 风险与权衡

| 风险 | 缓解 |
|---|---|
| 混淆表生成 O(n²) 在大 charset 爆炸 | charset 限定到语料 + seed；分桶剪枝；离线一次性 |
| 形近软化误伤（把真不同的记录拉近） | 数字精确不软化；τ / k 保守；公式分作特征锁死下限；消融验收 |
| 合成噪声与真机 OCR 分布有 gap | 噪声模型直接由真实字形混淆驱动；二期用端侧真实反馈校正 |
| 学习器过拟合小样例库 | L2 正则；公式分超集兜底；消费方可用自己语料重训 |
| CoreText 仅 Apple 平台 | 训练工具 `#if canImport(CoreText)`；预生成表随包发，非 Apple 平台仍可加载使用 |

## 18. 仓库元信息

- **名称**：GlyphScan（突出"看字形"的核心巧思，通用、不绑领域）。
- **License**：MIT。
- **文档语言**：README 与设计文档均提供中英双份。

## 19. 待解决 / 首版需定基线
- §14 基准阈值 X/Y/Z 待首版基准跑通后写死。
- 混淆表 N（位图分辨率）、k、τ 的默认值待小规模实验定档（初值 32 / 8 / 0.35）。
