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

13. 解析方式：按 session 注册 resolver 回调；客户端亦可推送当前页作为缓存。**插件不持有页表**，只缓存"最近一次答案"。
14. 调用点仅三处，且只在真正涉及页边界时调用：

| 按键动作 | resolver 调用 | 说明 |
| --- | --- | --- |
| `next_page` | 冷缓存 2（当前页 + 目标页），有已报告缓存时 1 | 先用 `Prepare(cur.end + 1)` 判定是否有下一页；末页则 0 次 |
| `previous_page` | 冷缓存 2（当前页 + 上一页），有已报告缓存时 1；`cur.start == 0` 时见下行 | `page(cur.start - 1)` |
| 选择键 | 1；当前页有有效缓存时 0 次 | `page(selected_index)` |
| `previous_candidate` / `next_candidate` | **0** | 跨页时仅把几何标为 stale |
| `home` / `end` | **0** | 同上 |
| 未命中动作的键 | **0** | 门闩后直接返回 |

**候选移动（最频繁的操作）与页面几何完全解耦**：插件不因移动候选而询问客户端。

15. **resolver 契约**：插件只以"确实存在候选"的索引调用；客户端返回该索引所在页 `[start, length)`（`length > 0`）；返回 false 表示"未知"，插件立即回退定长页算术。插件校验 `start <= index < start + length`，不满足同样视为未知。
16. **页应连续铺满候选表**（相邻页首尾相接）。这是任何真实布局的自然结果；插件不依赖它保证位置合法（`page(i)` 按定义包含 `i`，故目标位置恒合法），但用作 `next_page` 目标即"下一页首个候选"的解释依据。
17. **失效**：缓存条目形如 `{menu 指针, start, length}`，仅当三者与当前段一致且高亮落在区间内时有效；订阅 `update_notifier` / `select_notifier` 时**只作废、不调用 resolver**（避免通知风暴，且 `update_notifier` 由 `Context::Highlight` 触发，`engine.cc` 会据此重跑 `Compose`）。schema 切换经 `Context::Clear()` 触发 `update_notifier`，同样覆盖。

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

22. **发布**：解析或推送得到的几何写入会话 property（见 §5），使 Lua 与客户端可读同一份真相。发布的是**该动作实际使用的**几何，不是事后重新解析的结果——重新解析可能与放置高亮的几何不一致，而据此渲染的客户端会画出高亮并不在的那一页。
23. **一个按键只用一个模型**：翻页时"当前页"与"目标页"要么都来自 resolver，要么都由定长算术处理。混用会出问题：偏移量是在来源页里量的，落到另一模型的页面上可能把高亮**往回**移。因此客户端对"它已排版的每一页"都应当应答，而不是只应答可见页。
24. **回退链**：有效缓存 → 用它；否则有 resolver → 调用；否则 / 返回未知 / 目标页无法解析 → 整个按键走定长页算术。**无客户端参与时与内置 selector 行为等价**（第 2 条不变式）。
25. **UI 翻页入口**：暴露 `turn_page(backward)`，与键盘走同一代码路径（含 `raw` 段门闩、`page_down_cycle` 与 `paging` 标记），使 UI 按钮/手势获得与键盘一致的语义。这是必需的：C API 的 `change_page` 不经过任何 processor（`rime_api_impl.h:1007-1028`），只能由插件自备。

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
  bool (*set_page)(RimeSessionId, size_t start, size_t length); /* 渲染后推送 */
  bool (*turn_page)(RimeSessionId, bool backward);              /* UI 翻页 */
  bool (*query_page)(RimeSessionId, size_t index, RimeVarPage* out);
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
| `varpage.index` | 当前高亮绝对索引 |
| `varpage.start` | 当前页起点 |
| `varpage.length` | 当前页长度 |
| `varpage.source` | `client` / `fallback` / `stale` |

写入前先比较，值未变则不写，避免无意义通知。

## 6. 约束

### 6.1 插件必须

1. 继续打 `paging` 标记（第 11 条），参数与动作对应关系与上游完全一致。
2. 每个动作的返回值与上游一致，包括"高亮未变化但仍消费按键"的情形。
3. 兼容两处实例化（schema 引擎与 switcher），无 menu 时由门闩短路。
4. 提供 `rime_require_module_varpage` 符号，否则 `verify_merged_plugins` 会让构建失败（`scripts/build-one-arch.sh`）。

### 6.2 插件禁止

5. 禁止保存页表；只允许缓存"最近一次答案"，且必须按第 17 条校验有效性。
6. 禁止在 `update_notifier` / `select_notifier` 里回调客户端。
7. 禁止在构造时缓存 `select_keys`（第 10 条）。
8. 禁止改写 `menu.page_size` 等 C API 结构体字段，也禁止改写 `get_context` 返回的 `RimeContext`。
9. 禁止接管 `change_page` / `*_on_current_page`（那是 core 层，插件无从触及），须在文档与客户端清单中明确其仍走定长数学。

### 6.3 客户端必须

10. `destroy_session` 之前调用 `clear_resolver`。
11. 每次渲染后重新推送当前页（`set_page`）。index 不是稳定标识：filter（置顶、长词优先、降权、删词、去重）会重排候选，过期几何会被静默采纳。
12. 高亮/选中一律使用绝对索引的 `highlight_candidate` / `select_candidate`，并停用 `change_page` 与 `*_on_current_page`。
13. 渲染时自检：高亮索引若落在当前页之外，立即重算并推送（Lua 裸写 `segment.selected_index` 不触发任何通知，插件无法感知）。
14. 若通过 `traits.modules` 显式传模块列表，必须包含 `varpage`（否则 `kDefaultModules` 被整体替换，插件不加载）。
15. 若要 `select_labels`，把 `menu/page_size` 设为 UI 能显示的最大页容量——`select_labels` 的长度上限就是它，且只在 schema 列表长度 ≥ `page_size` 时给出。

### 6.4 客户端禁止

16. 不要在 resolver 内调用 `process_key`、`highlight`、`select`、`set_option`、`set_property`、`apply_schema`（第 19 条）。
17. 不在切换器打开时读写 `varpage.*`：此时活动引擎是 switcher（`service.cc:59-65`，`switcher.cc:247`），读写落在它的上下文。
18. 不要在 `process_key` 返回前依赖 `varpage.*` 的最终值：`set_page` / resolver 走 property 通道会**同步重入**你的通知处理函数。通知处理里不要调用 `process_key` 或 `get_context`。
19. 不要把 `varpage.*` 当稳定标识用；它描述的是"此刻"，且可能为 `stale`。

### 6.5 打包（本仓库）

20. `plugins.json` 加条目：`name` / `module` 均为 `varpage`、`path: plugins/varpage`、`local: true`、`license: BSD-3-Clause`。
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

1. **拦截方式**：`VarPageSelector::ProcessKeyEvent` 不调用 `Selector::ProcessKeyEvent` 走全程，而是自己重复那几行门闩与布局开关判断，然后**只**把命中 `Selector::PreviousPage` / `Selector::NextPage` 的按键接管（比较函数指针），其余按键（含 `previous_candidate` / `next_candidate` / `home` / `end`）原样委托基类。原因是上游对 selection 键调用的是 `this->SelectCandidateAt(...)`（非虚、非限定），派生类覆盖该方法不会被调用；与其依赖"派生成员指针转基类指针"这类隐晦技巧，不如让派生类显式接管选择键。代价是门闩那 8 行有重复——由 §3.3 第 8 条的语义测试锁定。
2. **`previous_page` 的偏移语义**：实现前先确认了 `Highlight` 会夹取（`context.cc:132-149`），因此上游 compact 写法 `selected < page_size ? 0 : selected - page_size` 与推广式 `prev.start + min(offset, prev.length - 1)` 在等长页下**始终**等价。实现采用推广式。
3. **`next_page` 的末页判定**：先用 `menu->Prepare(current.end() + 1)` 判断"下一页首个候选是否存在"，只有存在时才向 host 询问下一页几何；不存在时按 `page_down_cycle` 回卷（回卷分支不询问 host，落点用基类语义即"第 0 位"）。

**实现期发现的顺序约束（已修）**

`ctx->Highlight()` 会触发 `update_notifier` → 我们的 `OnContextChanged` 会据当前几何发布 property。因此**必须先把新几何存入表、再移动高亮**，否则那次通知会以"高亮已离开旧页、新页又还不知道"的状态发布一次 `stale`。`NextPage` / `PreviousPage` 均已按此顺序书写。

**未实现（有意）**

- `menu/alternative_select_labels` 不参与：它是渲染侧元数据，`select_labels` 由 C API 按 `page_size` 给出，与本插件的页模型无关（§8 第 2 条）。
- 无 enabled 开关、无关闭配置键（§4）。

**验证**

回归测试在仓库内：`tests/varpage/varpage_test.cc` + `scripts/test-varpage.sh`，对着一棵 `BUILD_SHARED_LIBS=ON` 且合并了本插件的构建树运行真实输入会话。CI 在 `build.yml` 的 `test` job 里跑它（仅 `macos-arm64`，其余四个 slice 是交叉构建，runner 执行不了）。

上游套件与它一起跑，但两者覆盖的东西不同：上游 `rime_test`（90 个用例）验证 patch + 插件没有破坏 librime 本身，而它对 `selector` **零覆盖**——正是本插件改动的部分，所以本插件的断言只能由这里提供。两者由同一条命令驱动：

```bash
BUILD_TESTS=1 VCPKG_ROOT=... scripts/build-one-arch.sh macos-arm64
```

`gtest` 藏在 `vcpkg.json` 的 `tests` feature 后面，且 `BUILD_TESTS` 配置自己的构建树（`.build/build-<platform>-test`）并在测试后停止，因此发布构建既不装测试框架，也不会把 gtest 的版权文件带进 `third-party-notices.zip`。细节与约束记在 `AGENTS.md` 的 Tests 一节。

已覆盖：模块注册与 `get_api`；resolver 答"未知"时 `Page_Down` 按 `page_size` 移动（未注册 resolver 的会话只断言"不发布 property"，因为无 host 时移动与否不影响本插件的行为）；resolver 答"未知"时回退且 `varpage.source` 报 `fallback`；注册 host 后同一按键落到 host 页首（3 而非 5）且发布 `client` 几何；`turn_page` 双向；选择键槽位受 host 页长约束（页长 3 时槽位 3 被消费但不选中）；`when: paging` 绑定在翻页后仍生效（`paging` 标记未丢）；推送路径（推送一个此前从未发布过的页长，否则断言无法失败）；`varpage.index` 与引擎自身高亮（`page_no * page_size + highlighted_candidate_index`）交叉核对；`clear_resolver` 在会话销毁后仍可调用。打包侧 `install_plugin_headers` 与 `verify_merged_plugins`（`rime_require_module_varpage`）均通过。

测试期间用两处反例校准过断言的有效性：把修复前的键位分发逻辑放回去，键位遮蔽测试立刻失败；把 `paging` 标记的写入删掉，翻页后 `minus` 落到 punctuator 上提交出 `你-`——这说明**只断言高亮索引会漏判**（提交与清空 composition 也会让索引回到 0），所以该断言额外要求"未提交文本"且"候选表仍存活"。
