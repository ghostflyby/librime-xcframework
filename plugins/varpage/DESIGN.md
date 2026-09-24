# varpage — 变长候选页 selector 插件设计

状态：设计已实现（`plugins/varpage/`），实现细节见 §10。
插件目录、模块名、头文件、property 前缀统一为 `varpage`。
本文件是唯一的设计参考。

上游依据：`librime` 1.17.0（本仓库 `vendor/librime`），行号引用该版本。

---

## 1. 目标

用插件替换内置 `selector` 处理器，使候选页的长度不再由 `menu/page_size` 固定，而由客户端按实际视觉布局决定（候选宽度不同 ⇒ 每行容量不同 ⇒ 每页长度不同），同时保持既有配置的兼容。

**职责边界**

| 事项 | 归属 |
| --- | --- |
| 键盘语义（候选移动、翻页动作、选择键映射）、配置读取、`paging` 标记 | 插件 |
| 页几何（每页放几个、边界在哪） | 客户端，按实际渲染布局计算 |
| 高亮/选中的绝对索引语义 | librime 既有 C API（`highlight_candidate` / `select_candidate`） |
| 候选标签显示（`select_labels`） | 客户端自行渲染 |

一句话：**插件把"页"从引擎里抽掉，只保留"键盘动作 → 绝对索引"的映射；页几何由客户端回答。**

## 2. 设计不变式

上游三处页运算（`gear/selector.cc:159-193, 255-265`）的推广。推广在"所有页等长"时与上游逐字节等价，这是兼容性的形式依据：

| 动作 | 上游 | 推广 | 等长时等价性 |
| --- | --- | --- | --- |
| `next_page` | `align_down(sel + ps)` = 下一页页首 | `page(cur.end).start` | 完全一致（`cur.end` 即 `align_down(sel+ps)`） |
| `previous_page` | `sel < ps ? 0 : sel - ps` | `prev.start + min(offset, prev.length - 1)` | 恒等式：页内必有 `offset ≤ length-1`，故 `min` 恒取 `offset` |
| 选择键槽位 | `page_start + slot`，`slot < ps` | `cur.start + slot`，`slot < cur.length` | 满页等价；末页 `slot ≥ length` 时上游 `Select` 亦失败 |

**唯一故意放宽**：某页短于 `page_size` 且其后仍有候选时（仅客户端布局会产生），插件拒绝槽位选择，不再选中屏幕外的候选。该情形在无客户端参与时不存在，故回退模式与内置实现**完全一致**。

后端唯一原语：`page(index) → [start, start + length)`。其余全部由此推导。

## 3. 功能

### 3.1 装配与替换

1. 以组件名 `selector` 注册。模块在 `gears` 之后加载（`kDefaultModules = {"default", <plugins>}`，`default` 组展开为 core/dict/gears，`src/rime/setup.cc:36-45`），`Registry::Register` 覆盖同名组件（`src/rime/registry.cc:13-20`）。所有 schema 的 `engine/processors: - selector` **无需改动**。
2. 同时服务两处实例化：schema 引擎，与 `Switcher::InitializeComponents()`（`src/rime/switcher.cc:296-306`，其 schema 为 `.default`）。switcher 场景必须安全退化，不得依赖页面语义。
3. 以 `RIME_REGISTER_CUSTOM_MODULE` 暴露自定义 API，客户端经 `rime->find_module("varpage")->get_api()` 获取（同 `plugins/logsink` 的做法）。

### 3.2 配置兼容面（全部保持）

4. 四段 keymap，索引为 `orientation | layout`：`selector`(H+Stacked=0)、`selector/vertical`(V+Stacked=1)、`selector/linear`(H+Linear=2)、`selector/vertical/linear`(V+Linear=3)。四段无条件加载（`selector.cc:101-105`）。
5. 七动作词表 `previous_candidate` / `next_candidate` / `previous_page` / `next_page` / `home` / `end` / `noop`；四段各自的默认键位；增量覆盖合并；`noop` 解绑；非法动作名或不可解析键仅告警跳过（`key_binding_processor_impl.h:70-105`）。
6. 布局开关**运行时按键读取**：`_vertical`、`_linear`、废弃的 `_horizontal`（= linear + horizontal，`selector.cc:108-116`）。
7. 其它配置：`menu/page_size`（退化为回退页长）、`menu/page_down_cycle`、`menu/alternative_select_keys`。

### 3.3 动作语义

8. **完全保留（不涉页）**：
   - `previous_candidate` / `next_candidate`：±1；linear 且光标不在输入末尾时交还 navigator；`index<=0` 时 stacked 吞键、linear 放行；无更多候选时吞键。
   - `home`：仅当 `index>0` 时动，否则放行；`end`：光标不在末尾时放行，否则等价 `home`。
   - 门闩：release / alt / super → noop；composition 空 → noop；末段无 menu 或带 `raw` → noop（`selector.cc:119-126`）。
9. **改为按页边界**：`previous_page` / `next_page`。保留：`page_down_cycle` 回卷、末页吞键不动、（`Get` 语义上）目标位置高亮、`paging` 标记。**返回值与上游一致**：即使高亮未变化（如已在第 0 位按上一页），也返回"已消费"。
10. **选择键**：`schema->select_keys()` **按键时读取，禁止构造时缓存**（Lua 的 `sbxlm/selector.lua` 会临时改写它）。非空时按字符位置取槽位；为空时回退主键盘 `1..9,0` 与 `KP_1..KP_9,KP_0`。槽位基址为当前页起点，上界为当前页长度。**槽位失败仍返回 `kAccepted`**（保留上游吞键怪癖，`selector.cc:151-154`）。选择**不打** `paging` 标记（同上游）。
11. `paging` 标记：每次候选移动与翻页都打；`home`/`end` 不打。这是用户配置 `{when: paging, ...}` 绑定的唯一开关（`gear/key_binder.cc:246-266`；`data/minimal/default.yaml:116-119`），漏打会**静默失效**。
12. Lua 包装兼容：`rime.Processor(engine, "", "selector")` 拿到的必须是本插件；由第 10、11 条，`gaboolic/rime-shuangpin-fuzhuma` 那类"临时改 `select_keys` + 按 `paging` 分支"的脚本可继续工作。

### 3.4 页解析：调用点与成本

13. 解析方式：按 session 注册 resolver 回调。**插件不持有任何页几何**——不保存页表，也不缓存客户端的答案。客户端拥有布局，插件每次需要时就问。
14. 调用点仅三处，且只在真正涉及页边界时调用：

| 按键动作 | resolver 调用 | 说明 |
| --- | --- | --- |
| `next_page` | 2（当前页 + 下一页） | `page(cur.end)`；末页则不问第二页 |
| `previous_page` | 2（当前页 + 上一页）；`cur.start == 0` 时 0 次 | `page(cur.start - 1)` |
| 选择键 | 1 | `page(selected_index)`，用来取槽位基址 |
| `previous_candidate` / `next_candidate` | **0** | 跨页时仅把几何标为 stale |
| `home` / `end` | **0** | 同上 |
| 未命中动作的键 | **0** | 门闩后直接返回 |

**候选移动（最频繁的操作）与页面几何完全解耦**：插件不因移动候选而询问客户端。

15. **resolver 契约**：插件只以"确实存在候选"的索引调用；客户端返回该索引所在页 `[start, length)`（`length > 0`）；返回 false 表示"未知"，插件立即回退定长页算术。插件校验 `start <= index < start + length`，不满足同样视为未知。
16. **页应连续铺满候选表**（相邻页首尾相接）。这是任何真实布局的自然结果，但 Page Down 依赖它：翻页问的是"当前页结束处的那个候选属于哪一页"，并用这个答案当作下一页的起点；只包含该索引、却从更早处开始的答案会被拒绝（否则带着页内偏移落进去会让高亮**后退**）。Page Up 不需要这条检查——它问的是当前页起点之前一个候选，`Contains` 已强制答案不会更晚开始。
17. **通知**：订阅 `update_notifier` / `select_notifier`，只做一件事——把当前高亮写进 `varpage.index`。**不在通知里调用 resolver**：`update_notifier` 由 `Context::Highlight` 触发，`engine.cc` 会据此重跑 `Compose`，在其中回调客户端既无必要也会放大开销。

### 3.5 resolver 的执行环境（安全边界）

18. 插件在**按键处理路径内同步**调用 resolver。resolver **可以**：
    - 读候选：`candidate_list_from_index` / `candidate_list_next` / `candidate_list_end`，**包括按需物化**（`Menu::Prepare` 会驱动 translation 前进）；
    - 读 session / schema / context 的只读状态；
    - 自行缓存、预取、做布局计算。

    按需物化是安全的：内置 selector 本身就在按键路径里调用 `Menu::Prepare`（`selector.cc:178, 224`）。

19. resolver **不可以**：`process_key`、`highlight` / `select` / `delete_candidate`、`set_option` / `set_property`、`apply_schema`，或任何触发 `Compose` 的操作——`Context::Highlight` 与 `set_option` 会触发 notifier，进而重跑 `Compose`，形成重入。
20. **预取还是现场取，完全由客户端决定，插件不感知也不要求。** 插件只保证两件事：问得少（第 14 条成本表）、问得安全（第 18/19 条边界）。
21. 已知上游特性（非本插件引入）：`Menu::Prepare` 是增量驱动的，filter 看到的是"已物化"的候选向量（`menu.cc:22-24`，`gear/uniquifier.cc`），因此逐候选物化与整页物化的可见窗口不同。内置 selector 同样增量 Prepare，故非新增风险；若客户端关心候选身份跨时刻稳定，宜一次性物化整页窗口。

### 3.6 通道与回退

22. **发布**：插件把自己移动到的位置写入会话 property（见 §5），使 Lua 与客户端可读同一份真相。属性只包含**插件自身能确定**的东西——高亮位置与它所依据的模型；页几何归客户端，插件不再抄一份。
23. **一个按键只用一个模型**：翻页时"当前页"与"目标页"要么都来自 resolver，要么都由定长算术处理。混用会出问题：偏移量是在来源页里量的，落到另一模型的页面上可能把高亮**往回**移。因此客户端对"它已排版的每一页"都应当应答，而不是只应答可见页。
24. **回退链**：有 resolver 且答案有效 → 用它；否则 / 返回未知 / 目标页无法解析 → 整个按键走定长页算术。**无客户端参与时与内置 selector 行为等价**（第 2 条不变式）。
25. **不做这些事**（每条都曾是接口的一部分，后来删掉，理由记在 §10）：不接收客户端报送的页（`set_page`）、不代客户端翻页（`turn_page`）、不提供"某索引在哪一页"的查询（`query_page`）。三者的共同点是**答案本来就在客户端手里**——它拥有布局。插件只做客户端做不到的那部分：在按键路径里询问、校验答案、回退，以及维护只有引擎内部能写的段标记。

## 4. 公开 API

`plugins/varpage/include/rime_varpage_api.h`，纯 C、无 flavor 变体（与 `rime_logsink_api.h` 同构），客户端经 `rime->find_module("varpage")->get_api()` 获取。

```c
typedef struct rime_varpage_page {
  size_t start;   /* 该页第一个候选的绝对索引 */
  size_t length;  /* 该页候选数，> 0 */
} RimeVarPage;

/* 返回 true 并填充 page；返回 false 表示"未知"，插件回退到定长页。
 * 仅在按键处理路径内同步调用，索引保证存在候选。 */
typedef bool (*RimeVarPageResolver)(void* user_data,
                                    RimeSessionId session_id,
                                    size_t index,
                                    RimeVarPage* page);

typedef struct rime_varpage_api_t {
  int data_size;
  bool (*set_resolver)(RimeSessionId, RimeVarPageResolver, void* user_data);
  bool (*clear_resolver)(RimeSessionId);
} RimeVarPageApi;
```

**没有 enabled 开关**，也**没有关闭用的配置键**。理由：

- 关闭权必须只属于渲染方。配置作者（schema/主题）若能关闭，而客户端仍预期变长页，会产生**静默错位**——这是最难诊断的一类故障。
- 会话级关闭即 `clear_resolver`（本就是生命周期所需：`destroy_session` 之前必须调用）。它只能由客户端调用，因此不会与客户端预期脱节。
- 单次请求级关闭即 resolver 返回 `false`（"我不知道"）。粒度更细、无状态、无重复注册的竞争。
- 独立的 enabled 标志会引入一个**能与回调答案相矛盾**的状态，故不设。

## 5. 通道约定（property）

键名前缀 `varpage.`，**不带 `_`**（`_` 前缀的选项/property 在切换 schema 时被清除，`context.cc:313-325`）。会话级，Lua 经 `ctx:get_property` 可读，客户端经 `get_property` 可读并可收通知。

| 键 | 值 |
| --- | --- |
| `varpage.index` | 当前高亮绝对索引（组合结束时清空） |
| `varpage.source` | 最近一次翻页所依据的模型：`client` / `fallback`（组合结束时清空） |

`source` 只由翻页动作写入，所以它**不做诊断之外的事**：它回答"上一次翻页走的是谁"，不描述当前页。

写入前先比较，值未变则不写，避免无意义通知。

## 6. 约束

### 6.1 插件必须

1. 继续打 `paging` 标记（第 11 条），参数与动作对应关系与上游完全一致。
2. 每个动作的返回值与上游一致，包括"高亮未变化但仍消费按键"的情形。
3. 兼容两处实例化（schema 引擎与 switcher），无 menu 时由门闩短路。
4. 提供 `rime_require_module_varpage` 符号，否则 `verify_merged_plugins` 会让构建失败（`scripts/build-one-arch.sh`）。

### 6.2 插件禁止

5. 禁止保存页表，也不要把布局抄一份给插件——插件不再接收报送的几何，客户端自己的布局就是唯一真相。
6. 禁止在 `update_notifier` / `select_notifier` 里回调客户端。
7. 禁止在构造时缓存 `select_keys`（第 10 条）。
8. 禁止改写 `menu.page_size` 等 C API 结构体字段，也禁止改写 `get_context` 返回的 `RimeContext`。
9. 禁止接管 `change_page` / `*_on_current_page`（那是 core 层，插件无从触及），须在文档与客户端清单中明确其仍走定长数学。

### 6.3 客户端必须

10. `destroy_session` 之前调用 `clear_resolver`。
11. 每次渲染后刷新自己的布局，并保证 resolver 对**已排版的每一页**都能回答，而不只是可见那一页——翻页问的是下一页的首个候选，它可能还没上屏；答不出来该次翻页会整体退回定长算术。
12. 高亮/选中一律使用绝对索引的 `highlight_candidate` / `select_candidate`，并停用 `change_page` 与 `*_on_current_page`。
13. 渲染时自检：高亮索引若落在已知页之外，立即重算布局（filter 会重排候选，Lua 也可能裸写 `segment.selected_index`，插件无从感知）。
14. 若通过 `traits.modules` 显式传模块列表，必须包含 `varpage`（否则 `kDefaultModules` 被整体替换，插件不加载）。
15. 若要 `select_labels`，把 `menu/page_size` 设为 UI 能显示的最大页容量——`select_labels` 的长度上限就是它，且只在 schema 列表长度 ≥ `page_size` 时给出。

### 6.4 客户端禁止

16. 不要在 resolver 内调用 `process_key`、`highlight`、`select`、`set_option`、`set_property`、`apply_schema`（第 19 条）。
17. 面板打开期间**注册**是被支持的（会记到组合引擎上），但**读写 `varpage.*` 仍不安全**：`get_property` 走的是 `active_engine()`（`service.cc:59-65`，`switcher.cc:247`），此时落在面板自己的上下文。要读就等面板关闭。
18. 不要在 `process_key` 返回前依赖 `varpage.*` 的最终值：插件写 property 会**同步重入**你的通知处理函数（在 librime 持有 service 锁的状态下）。通知处理里不要调用 librime 任何入口。
19. 不要把 `varpage.*` 当稳定标识用；它描述的是"此刻"。特别地，`varpage.source` 只记录最近一次翻页所依据的模型，不描述当前页。
20. 若接受"`-` / `,` 这类键在翻页后应转为翻页键"这一行为，请注意它由**键盘**翻页点亮（段上的 `paging` 标记），客户端自己用 `highlight_candidate` 移动高亮不会点亮它——内置 selector 的候选移动同样不点亮。C API 的 `change_page` 会点亮，所以从它迁移过来等于放弃该行为。

### 6.5 打包（本仓库）

21. `plugins.json` 加条目：`name` / `module` 均为 `varpage`、`path: plugins/varpage`、`local: true`、`license: BSD-3-Clause`。
21. 头文件放 `plugins/varpage/include/*.h`，由 `install_plugin_headers` 自动进入导出 include（只收 `local: true` 条目的 `include/*.h`）；在 `Sources/RimeHeaders/include/RimeShim.h` 加一行 `#include "rime_varpage_api.h"`。无 flavor 声明 ⇒ 无需改 `Rime.apinotes`。
22. CMake 遵守上游插件契约（`plugin_name` / `plugin_objs` / `plugin_deps` / `plugin_modules`），并声明 `plugin_modules "varpage"`。

## 7. 兼容性矩阵（现实实例）

| 类别 | 实例 | 变长页下的结果 |
| --- | --- | --- |
| 只读当前高亮 | `lua/select_character.lua`（以词定字）、`melt_oo_processor.lua` | 原样兼容，无需改动 |
| 自算定长页 | `kp_number_processor.lua`、`super_processor.lua`、`sbxlm/select_key_to_comment.lua`、`liu_common.lua`、`xmjd6_tools.lua`、`shortcut_processor.lua` | 会算错（选错候选 / 键标错误 / 页号错误）；需迁移或改读 `varpage.*` |
| 包装内置 selector | `sbxlm/selector.lua`（及其下游 vendor） | 兼容，前提是第 10 条（运行时读 `select_keys`）与第 11 条（`paging` 标记）两条满足 |
| 改 page_size | `flypy_switcher.lua`、`shewer .../tran.lua` | 运行期无效（`Schema::page_size_` 无 setter）；`apply_schema` 重载会重置会话状态 |

上游结论一致：rime/librime#996（"Variable page_size"）由 lotem 答复 "Use candidate iteration API"，即**引擎不分页、客户端自行分页**，与本设计同向。

## 8. 不改动项（core 层，客户端需知）

1. `get_context` 的 `menu.page_no` / `highlighted_candidate_index` / `num_candidates` / `is_last_page` 仍按 `page_size` 切窗口，语义与客户端页无关。可用 `page_no * page_size + highlighted_candidate_index` 还原绝对索引。
2. `context->select_labels` 上限为 `page_size`。
3. `free_context` 用 `menu.page_size` 释放 `select_labels`，故获取后到释放前**不得改写** `menu.page_size`；同一结构体不得连续 `get_context` 两次。
4. `change_page` 与 `*_on_current_page` 不受本插件影响。
5. `page_size` 运行期不可改（Schema 无 setter），仅作回退页长。

## 9. 待定

1. 客户端布局的物化窗口（逐候选 vs 整页）——不影响插件契约，由客户端按第 21 条自行取舍。
2. `varpage.*` 是否需要附带候选总数供诊断（目前无公开 API 提供总数，需迭代到穷尽）。

## 10. 实现记录

实现落在 `plugins/varpage/`，与本文的差异与关键取舍如下。

**文件构成**

| 文件 | 内容 |
| --- | --- |
| `include/rime_varpage_api.h` | 公开 C API（`RimeVarPage` / `RimeVarPageResolver` / `RimeVarPageApi`），无 flavor 变体 |
| `src/varpage_pages.{h,cc}` | 页几何、按 session 的 resolver 表、页动作实现、property 发布、notifier 挂接 |
| `src/varpage_selector.{h,cc}` | `VarPageSelector : Selector`，拦截三个涉页入口，其余动作交给基类 |
| `src/varpage_module.cc` | `RIME_REGISTER_CUSTOM_MODULE(varpage)`，注册组件名 `selector`，暴露 `get_api` |
| `CMakeLists.txt` | 上游插件契约；`plugin_deps` 含 `${rime_gears_library}`（`Selector` 在 gears 库） |

**与设计的三处实现取舍**

1. **拦截方式**：`VarPageSelector::ProcessKeyEvent` 不调用 `Selector::ProcessKeyEvent` 走全程，而是自己重复那几行门闩与布局开关判断，然后**只**把命中 `Selector::PreviousPage` / `Selector::NextPage` 的按键接管（比较函数指针），其余按键（含 `previous_candidate` / `next_candidate` / `home` / `end`）原样委托基类。原因是上游对 selection 键调用的是 `this->SelectCandidateAt(...)`（非虚、非限定），派生类覆盖该方法不会被调用；与其依赖"派生成员指针转基类指针"这类隐晦技巧，不如让派生类显式接管选择键。代价是门闩那 8 行有重复。这条约束由测试锁定：`varpage_test.cc` 部署一个把数字键 `2` 绑到 `next_candidate` 的用户 patch，断言该键执行动作而非选中候选——把修复前的分发逻辑放回去，该断言立刻失败（已在 scratch 树验证）。
2. **`previous_page` 的偏移语义**：实现前先确认了 `Highlight` 会夹取（`context.cc:132-149`），因此上游 compact 写法 `selected < page_size ? 0 : selected - page_size` 与推广式 `prev.start + min(offset, prev.length - 1)` 在等长页下**始终**等价。实现采用推广式。
3. **`next_page` 的末页判定**：先用 `menu->Prepare(current.end() + 1)` 判断"下一页首个候选是否存在"，只有存在时才向 host 询问下一页几何；不存在时按 `page_down_cycle` 回卷（回卷分支不询问 host，落点用基类语义即"第 0 位"）。

**实现期发现的顺序约束（已修）**

`ctx->Highlight()` 会触发 `update_notifier` → 我们的 `OnContextChanged` 会据当前几何发布 property。因此**必须先把新几何存入表、再移动高亮**，否则那次通知会以"高亮已离开旧页、新页又还不知道"的状态发布一次 `stale`。`NextPage` / `PreviousPage` 均已按此顺序书写。

**删掉的三个接口（及其理由）**

第一版暴露了 `set_page`（客户端报送当前页，插件缓存）、`turn_page`（代客户端翻页）、`query_page`（问某索引在哪一页）。三者都删了，因为**答案本来就在客户端手里**——它拥有布局：

- `set_page` 让插件抄一份客户端的状态，于是要维护 `menu` 指针校验、报送失效、`stale` 状态、组合结束时的清除，而收益只是"翻页时 resolver 少问一次"。客户端在自己的结构里存布局，resolver 直接查，等价且无副本。
- `turn_page` 的调用者只有客户端，而客户端自己就能算出目标索引（它有布局），再用 `highlight_candidate` 落位。它唯一多给的是段上的 `paging` 标记——但那是**引擎内部状态**，不是翻页服务。剔除之后它剩下的只是标记。
- `query_page` 让插件代表客户端去问客户端自己。客户端既然算出了布局，就已经知道答案。

收敛后的判据是：**凡是客户端能自己回答的，都不进接口**。插件保留的只有客户端做不到的两件事——在按键路径里询问并决定回退，以及写引擎内部的段标记（那是插件自己移动的结果，自动写入）。

**修掉的两个切换器相关缺陷**（研究阶段实测确认，非读码推断）

面板打开时 `Session::context()` 返回的是**切换器自己的** context（`active_engine()`），而按键走 `engine_->context()`（组合引擎自己的）。由此产生两个 bug：

1. **面板期间注册会丢失。** `set_resolver` 把注册记到面板 context 上，返回 `true`；面板关闭后组合引擎在自己的 context 上找不到，此后整个会话静默回退定长页。
2. **面板会调用宿主回调。** 那份注册恰好能被面板自己的 selector 实例找到，于是宿主被问了一个它从未排版过的组合（索引来自方案列表）。

修法（不需要 patch 上游）：selector 实例构造时用 `dynamic_cast<Switcher*>(engine_)` 识别自己是否属于切换器（上游自己的惯用法，见 `switch_translator.cc:268`、`schema_list_translator.cc:133`），若是则把自己的 context 与 `switcher->attached_engine()->context()` 登记进一张发布表，析构时撤销；`set_resolver` 命中发布表就改记到组合引擎的 context 上。附加一道结构性门闩：切换器实例的 `allow_host` 为 false，根本不去问宿主。

实测（面板期间注册）：修复前 `set_resolver` 返回 1、面板按键调用宿主 1 次、面板关闭后高亮 5（内置）、`source` 为空；修复后面板调用 0 次、面板关闭后高亮 3（宿主页）、`source=client`。

注意：**结构性门闩并未被测试单独覆盖**——去掉它套件仍全绿，因为改记之后面板的 context 上本来就没有条目可查。它是第二道防线，保留的理由是代价只有一个 bool，而它挡住的失败是"宿主被问了一个它没排版过的菜单"。这一点在本文件和 `varpage_pages.h` 里都写明了，不假装有覆盖。

**未实现（有意）**

- `menu/alternative_select_labels` 不参与：它是渲染侧元数据，`select_labels` 由 C API 按 `page_size` 给出，与本插件的页模型无关（§8 第 2 条）。
- 无 enabled 开关、无关闭配置键（§4）。

**验证**

回归测试随插件放在一起：`plugins/varpage/tests/varpage_test.cc` + `tests/run.sh`（自定位，不依赖仓库根，插件被搬走或 vendor 出去时测试跟着走），对着一棵 `BUILD_SHARED_LIBS=ON` 且合并了本插件的构建树运行真实输入会话。它以 `add_test` 注册进 ctest（条件为 `BUILD_TEST AND BUILD_SHARED_LIBS`），因此与上游 `rime_test` 同一次 ctest 运行、同一份报告；`run_tests` 在信任该次运行前会先确认注册确实发生（条件注册若静默失效，剩下的就只是上游套件的一份"干净"报告）。注册的是测试**命令**而非 CMake 目标——插件目录由 `add_subdirectory(plugins)` 处理，早于 `add_subdirectory(src)` 创建 rime 目标，在这里定义的可执行文件链接不到它，这也是它测试时才自行编译、而非做成 gtest 二进制的原因。CI 在 `build.yml` 的 `test` job 里跑它（仅 `macos-arm64`，其余四个 slice 是交叉构建，runner 执行不了）。

上游套件与它一起跑，但两者覆盖的东西不同：上游 `rime_test`（90 个用例）验证 patch + 插件没有破坏 librime 本身，而它对 `selector` **零覆盖**——正是本插件改动的部分，所以本插件的断言只能由这里提供。两者由同一条命令驱动：

```bash
BUILD_TESTS=1 VCPKG_ROOT=... scripts/build-one-arch.sh macos-arm64
```

`gtest` 藏在 `vcpkg.json` 的 `tests` feature 后面，且 `BUILD_TESTS` 配置自己的构建树（`.build/build-<platform>-test`）并在测试后停止，因此发布构建既不装测试框架，也不会把 gtest 的版权文件带进 `third-party-notices.zip`。细节与约束记在 `AGENTS.md` 的 Tests 一节。

52 条断言，覆盖：模块注册与 `get_api`；未注册时无 property 流量；无 host 时 `Page_Down` 按 `page_size` 移动；resolver 答"未知"时回退且 `varpage.source` 报 `fallback`；注册 host 后同一按键落到 host 页首（3 而非 5）；选择键槽位受 host 页长约束（页长 3 时槽位 3 被消费但不选中）；数字键被配置绑定时执行动作而非选中；`when: paging` 绑定在翻页后仍生效（标记未丢，且用"未提交文本 + 候选表存活"区分于落在 punctuator 上）；不 tile 的答案被拒绝且整次退回；注册在切换器面板打开后仍生效；两个会话互不干扰；组合结束清空属性；`clear_resolver` 在会话销毁后仍能找到注册。

断言的有效性用反例校准过：去掉 tiling 守卫 → 高亮从 5 退回 1，3 条失败；不写 `paging` 标记 → 3 条失败；按"活跃 context"判定注册失效（切换器回归）→ 3 条失败。

测试期间用反例校准过每一条断言的有效性——把修复放回去或删掉，对应断言必须失败。有几条最初是**无效的**，已改写：只断言"`minus` 被消费"证明不了 `paging` 标记存在（没标记时 punctuator 同样消费它并提交 `你-`，且清空 composition 也让索引回到 0）；"高亮未后退"在起点为 0 时恒真。改写后的版本各自验证过：删掉 `paging` 写入 → 提交断言失败；删掉 `next.start == probe` 的 tiling 守卫 → 高亮从 5 退回 1，断言失败。

**关于会话回收**：条目里存了 `weak_ptr<Session>` 作见证。会话 id 就是会话对象地址，因此被销毁的会话的 id 可能被下一个会话复用、任何数值比较都会说"同一个"；控制块不会，这才是让残留注册**可被识别**而不是被继承的机制。顺带两个好处：按键路径不再调用 `GetSession`（那会 `Activate()` 改动 `last_active_time`、并且无锁读 `sessions_`），以及过期条目会在注册/注销时被扫掉。

`clear_resolver` 仍按 id 查找，因此在"id 被复用且调用者拿的是旧 id"这一种情况下无法区分——这是 API 形状决定的，头文件里写明。

**一处曾引入又移除、又按新理由重新引入的机制**：`weak_ptr<Session>` 最早用来判断"还是不是同一个会话对象"，当时实测会话回收行为出现变化（同一 create/destroy 循环下回收次数 9/9 → 0/9），我误判为代价而放弃。现在明白那是 `make_shared` 的控制块被 weak 保活导致地址不再复用——**良性副作用**，而且正是"防继承"想要的效果。已重新引入，并在注册/注销时扫掉过期条目以免泄漏钉住一个会话大小的分配。

**注册的失效判定只依据"会话是否还存在"**：不能改用"会话当前的活动 context 是否就是注册时那个"，因为切换器面板打开时活动引擎变成切换器本身，那样判定会在用户每次按 F4 后丢弃注册。这条有测试锁定（`varpage_test.cc` 的 switcher 用例）：把判定改回按活动 context 比较，该用例立即失败。
