# Qwen3.8-Flash-Next 可攜接口（Strata NVFP4）

在單張 16 GB 以上的 NVIDIA RTX 顯卡加 64 GB RAM 的 Windows 電腦上，一鍵部署 Qwen3.8-Flash-Next（125B MoE；預設用 ISTA-DASLab 的 GSQ-RCO IQ3_S 量化，也可改用 NVFP4），並提供 OpenAI／Anthropic 相容 API。推理引擎是 [strata-nvfp4](https://github.com/sergqwer/strata-nvfp4)，本專案負責可攜封裝、啟動流程與 API 入口。

**一鍵啟動：缺什麼自動下載什麼，全部都在就直接離線啟動。** 所有東西都裝在這個資料夾裡，唯一無法可攜的是 NVIDIA 驅動。本儲存庫只有啟動腳本（約 50 KB），模型與引擎在第一次啟動時才下載。

| 元件 | 位置 |
|---|---|
| 一鍵啟動器 | `START.bat` → `start_next.ps1` |
| 推理引擎與模型 API | Strata（`strata-nvfp4\`，只聽 `127.0.0.1:8080`） |
| 區網入口 | `next_gateway.py`（`<內網IP>:8000` 與 `127.0.0.1:8000`，金鑰檢查，請求原樣轉發） |
| 模型 | `Strata-data\`（預設約 90 GB，NVFP4 約 130 GB；首次啟動自動下載） |
| Python | `strata-nvfp4\.venv\Scripts\`（嵌入式 Python，首次啟動自動下載） |

## 一鍵啟動

把整個資料夾放到要跑模型的電腦上，**建議放在純英文路徑**（例如 `D:\QwenNext`，原生引擎常不支援中文路徑），然後雙擊：

```text
START.bat
```

每次啟動都依序檢查，只補缺少的部分：

| 步驟 | 已存在 | 不存在 |
|---|---|---|
| 1. Strata 原始碼 `strata-nvfp4\` | 版本相同就略過；`-Tag` 不同就原地更新（模型保留） | 有 git 就 clone，沒有就下載 zip（釘在 `v0.2.0-beta-nvfp4.3`） |
| 2. 可攜 Python `strata-nvfp4\.venv\Scripts\` | 略過 | 下載 python.org 嵌入式 3.12.10 與 pip（不需安裝、不寫登錄檔） |
| 3. 引擎＋模型 `Strata-data\` | 略過（看 `portable_state\installed.json`） | 交給 Strata 自己的下載器（預設約 90 GB，中斷後再按一次 START.bat 會續傳） |
| 4. 啟動 | Strata（`127.0.0.1:8080`）＋閘道（`<內網IP>:8000`、`127.0.0.1:8000`） | |

- **搬移：** 裝好之後可以整個資料夾搬到別的磁碟或別台電腦。下次啟動時會偵測位置改變，自動改寫 Strata 設定檔裡的絕對路徑。
- **改參數：** 換模型家族、context 或 vision 時，會自動重跑 Strata 安裝，已下載的檔案會保留。換金鑰不需要重跑安裝。
- **崩潰：** Strata 或閘道任一方結束，另一方會一起停掉，視窗會停住讓你看到錯誤。

需求：Windows 10/11 原生（不支援 WSL2）、NVIDIA RTX 20–50 系 **16 GB 以上**（啟動器會檢查，不足就停止）、驅動 580 以上、RAM 64 GB 以上、硬碟約 150 GB（NVMe）、固定 65536 MB 的分頁檔（可用 `START.bat -SetPageFile` 設定，見下方「分頁檔」）。

參數都加在 `START.bat` 後面（各項預設值見下一節「模型設定」）：

```powershell
.\START.bat -ClientKey mykey                          # 建議：區網連線需要金鑰
.\START.bat -Family qwen-nvfp4-gptq                   # 換成 NVFP4（RAM 96 GB 以上建議；會自動補裝）
.\START.bat -Model IQ3_XXS -Context 32768             # 換量化大小／context（會自動補裝）
.\START.bat -CheckOnly                                # 只檢查硬體與 Strata 的 --check（會下載約 30 MB 的原始碼與 Python，不下載模型）
.\START.bat -SetPageFile                              # 設定固定 64 GB 分頁檔（需系統管理員，設完要重開機）
.\setup_next.ps1                                      # 只下載不啟動（例如先在網路快的地方下載）
.\START.bat -Reinstall                                # 強制重跑安裝，並把舊的系統 venv 換成可攜 Python
```

### 分頁檔

Windows 規定所有程式加起來能申請的記憶體不能超過「RAM＋分頁檔」。Strata 的引擎在低 RAM 模式約需 80 GiB（一般模式約 100 GiB），其中約 30 GiB 是 Windows 為顯示卡驅動計入的。系統自動管理的分頁檔常常來不及長大，所以 Strata 要求**固定 65536 MB**。不夠時引擎會縮小顯存裡的專家快取而明顯變慢，最壞的情況是無法啟動。

```powershell
.\START.bat -SetPageFile                 # 放在模型資料夾所在的磁碟，系統碟維持系統管理大小
.\START.bat -SetPageFile -PageFileDrive E
.\set_pagefile.ps1 -DryRun               # 只顯示會寫入什麼，不改任何東西
.\set_pagefile.ps1 -Restore              # 還原成改動前的設定
```

`-SetPageFile` 會：

1. 跳出 Windows 的系統管理員確認。
2. 檢查目標磁碟：拒絕 USB 和傳統硬碟，並確認剩餘空間足夠。
3. 把目前設定備份到 `portable_state\`。
4. 寫入新設定。

**設定要重新開機才會生效。** 下載中的模型會在下次啟動時續傳。之後啟動器開頭會顯示 `Page file: 65536 MB fixed`；如果已設定但還沒重開機，會提醒你先重開。

固定 64 GB 只會佔用該磁碟的空間。平常不會變慢，只有 RAM 真的不夠時才會寫入。

載入模型需要數分鐘；`/health` 回 200 才代表可用，載入中回 503。啟動時會印出實際網址，例如：

```text
-- API: http://192.168.1.50:8000/v1   readiness: http://192.168.1.50:8000/health
-- On this PC also: http://127.0.0.1:8000/v1
```

- 端點：`/v1/chat/completions`、`/v1/messages`（Anthropic 格式）、`/v1/models`、`/health`。`/v1/responses` 取決於 Strata 是否提供，沒有驗證過。
- 模型名稱隨意填，API Key 填 `-ClientKey` 的值（沒設就填 `local`）。
- **閘道綁這台的內網 IP 與 `127.0.0.1`**，區網其他電腦用內網 IP 連，本機的程式用 `127.0.0.1`。Strata 本體只聽 `127.0.0.1:8080`。**建議一定要設 `-ClientKey`。**
  - **內網 IP 怎麼找：** 每次啟動自動偵測，取「預設路由那張網卡」上的私有 IPv4（10.x、172.16–31.x、192.168.x）。VMware、WSL 等虛擬網卡不會被選到，也不會對它們開放；DHCP 換了 IP，重新啟動就會跟著更新。
  - **其他選擇：** `-HostAddress 127.0.0.1` 只限本機，`-HostAddress 192.168.1.50` 指定某個 IP，`-HostAddress 0.0.0.0` 開放所有網卡。找不到內網 IP 時，會自動改成只限本機並提示你。
- 區網連不進來時，在可信任的網路上用系統管理員 PowerShell 開放 TCP 8000（先用 `Get-NetConnectionProfile` 確認網路設定檔是 Private）：

  ```powershell
  New-NetFirewallRule -DisplayName "Qwen Next API 8000" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Private
  ```

```python
from openai import OpenAI
client = OpenAI(base_url="http://<內網IP>:8000/v1", api_key="local")   # 同一台電腦也可用 127.0.0.1
print(client.chat.completions.create(model="Qwen3.8-Flash-Next",
      messages=[{"role": "user", "content": "請只回答 OK"}], max_tokens=2048).choices[0].message.content)
```

傳圖片（預設已開啟讀圖）：

```python
import base64
image = base64.b64encode(open("photo.jpg", "rb").read()).decode()
answer = client.chat.completions.create(model="Qwen3.8-Flash-Next", max_tokens=2048, messages=[{
    "role": "user",
    "content": [
        {"type": "text", "text": "這張圖裡有什麼？"},
        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image}"}},
    ],
}])
print(answer.choices[0].message.content)
```

### 搭配 Codex

Codex 只知道內建模型的 context 上限。對自訂模型，要自己告訴它，否則它不會在快滿之前自動壓縮對話；請求一旦超過 128K，Strata 就會回 400（`request exceeds the context window`）。

在 `%USERPROFILE%\.codex\config.toml` 的**最上方、任何 `[...]` 區段之前**加入：

```toml
model_context_window = 131072
model_auto_compact_token_limit = 110000
```

意思是：模型有 128K，對話到 110K 時自動壓縮，留約 20K 給思考、回答和工具結果。改完要重開 Codex。如果用 `-Context` 改了大小，這兩個數字也要跟著改。

## 模型設定

原則是**以 Strata 和 Qwen 官方設定為準，本包只補可攜與連線需要的部分**。

| 項目 | 設定 | 來源與理由 |
|---|---|---|
| 模型 | `qwen` 家族、`IQ3_S` 大小（`-Family`、`-Model` 可改） | ISTA-DASLab 的 GSQ-RCO 量化（3.5-bit），下載 83.6 GB，另加 Strata 抓的 MTP 草稿層約 5 GB。執行時約 52 GiB RAM，**能整個放進 64 GB RAM**，不必進低 RAM 模式讀 SSD；Strata 也把它列為 64 GB 電腦的預設，但要求「其他程式少開」。精度與速度的取捨見下表。 |
| Context | **131072（128K）**（`-Context` 可改；`-Context 0` 交給 Strata 依顯存決定） | Codex 這類代理客戶端光是系統提示詞加工具定義就很大，64K 很快就會超過上限（Strata 會回 400，不會偷偷截斷）。Strata 對 16 GB 卡建議 64K；128K 的代價是 KV cache 會隨對話變長才在顯存裡長大，短對話不受影響，對話很長時能放在顯卡上的專家會變少、速度略降。搭配 Codex 的設定見下方「搭配 Codex」。 |
| 取樣預設 | Strata 依模型卡，按「是否思考」套用 | 思考時是 `temperature 1.0 / top_p 0.95 / top_k 20`，與 Qwen3.8-Flash-Next 官方 `generation_config.json` 一致。只套用在請求沒帶的欄位，請求自帶的值優先。舊版 Strata 寫在設定檔裡的固定取樣區塊會蓋過這個行為，啟動器會依 Strata 的升級說明移除它。閘道預設不改任何取樣欄位。 |
| `fit_max_tokens` | `true`（本包加的） | Strata 預設在 `max_tokens` 超過剩餘 context 時回 HTTP 400，代理類客戶端常送很大的值。開啟後會夾到剩餘空間，回應的 `finish_reason` 照常標示 `length`。 |
| `host` | 固定 `127.0.0.1`（本包加的） | Strata 本體不對外，區網一律經閘道與金鑰。 |
| `api_key` | `-UpstreamKey` 有設才寫入，沒設就移除 | 每次啟動重新套用，換金鑰不用重跑安裝。 |
| 低 RAM 模式 | Strata 自動判斷 | 低於約 92 GiB RAM 時，部分專家從硬碟讀取。 |
| 讀圖（Vision） | `yes`（預設開啟） | 額外下載約 0.9 GB 的編碼器，交給 Strata 決定放在哪裡：顯存低於 24 GB 時放在 **CPU**，不佔顯存，顯存全部留給專家快取；每張圖約 2–6 秒，約佔 1–2 GiB RAM。安裝輸出的 `images: on (encoder on the …)` 會顯示實際位置。`-Vision gpu` 可強制放顯卡（約佔 1.4 GB 顯存），`-Vision no` 關閉。 |

標「本包加的」項目，由 `portable\strata_config.py` 在每次啟動時寫入 `strata-*.json`。之所以每次都寫，是因為 Strata 重跑 setup 時會重寫它自己管理的欄位。

### 可選的量化版本

以下是 Strata README 的官方實測：RTX 5090、Ryzen 9 9950X3D、128 GB RAM。「與 Q8_0 一致」是逐 token 和最高精度 Q8_0 版本比對的一致率。「所需 RAM」是達到該速度需要的電腦 RAM。

| 指定方式 | 與 Q8_0 一致 | 速度 | 執行時 RAM | 所需 RAM |
|---|---|---|---|---|
| 預設（`qwen` + `IQ3_S`） | 90.0% | 228 tok/s | 52 GiB | 64 GB |
| `-Model IQ3_XXS` | 87.3% | 239 tok/s | 45 GiB | 64 GB |
| `-Family qwen-nvfp4-gptq` | 93.6% | 177 tok/s | 69 GiB | 96 GB |
| `-Family qwen-nvidia-nvfp4` | 92.9% | 167 tok/s | 69 GiB | 96 GB |
| `-Family qwen-nvfp4-mix` | 95.0% | 91 tok/s | 105 GiB | 128 GB |

- **64 GB 的電腦：** NVFP4 會進入低 RAM 模式，Strata 文件寫的速度約 115 tok/s，同一台參考機上約是 IQ3_S 的一半。所以 64 GB 預設用 IQ3_S，96 GB 以上建議改用 GPTQ NVFP4。
- **IQ3_S 的精度：** 逐 token 一致率比 GPTQ NVFP4 低 3.6 個百分點；但 ISTA-DASLab 公布的基準測試，平均分數與原始 BF16 模型持平（100.3%–101.4%，在誤差範圍內）。
- **換版本：** 會補下載該版本的檔案，舊檔保留，可隨時切回。

## 嚴格格式輸出

自架模型 API 常見的格式問題，多半出在 API 層，而不是溫度：

- 沒處理結構化輸出欄位。
- 對話模板與模型官方模板不一致。
- `max_tokens` 被默默壓低，導致截斷。

本包的做法：

- **結構化輸出交給引擎。** `response_format`（含 `json_schema`）、`stop`、`seed`、`logit_bias`、`min_p`、penalties 等欄位一律原樣轉發。Strata 的 `serve/` 內建結構化輸出模組（`structured.py`）。
- **完整的 schema 檢查。** Strata 要裝了 `jsonschema` 套件，才會依 schema 檢查欄位和型別；沒裝時只檢查「是一個 JSON 物件」。它自己的 setup 不會裝這個套件，所以由啟動器補上。
- **對話模板由 Strata 處理。** 沿用 Qwen 官方 `chat_template.jinja` 的 reasoning 句子，閘道不自行組提示詞。
- **取樣用官方值。** 由 Strata 依家族補上，閘道不改動客戶端送來的任何值（`next_config.json` 全部是 `null`）。
- **不截斷。** `max_tokens` 只在超過剩餘 context 時才被夾住（`fit_max_tokens`），沒有固定上限。

**格式不穩時，不要憑感覺調低溫度，先實測。** 在模型載入後執行：

```powershell
python format_probe.py --temps 0.3,0.7,1.0 --trials 5 --verbose
```

它會對「純 JSON」「json_schema 結構化輸出」「只回 OK」「固定三行」「工具呼叫」五種格式各跑幾次，印出各溫度的通過率與失敗原因（例如 `finish_reason=length` 代表是被截斷，不是格式問題）。如果低溫明顯較好，才在 `next_config.json` 填 `sampling.temperature`（只影響沒帶溫度的請求），或啟動時加 `-TemperatureCap 0.6`（連客戶端明確送來的高溫也壓下來）。

## 速度

實測：RTX 5070 Ti 16 GB、64 GB RAM、i5-14600K、PCIe 5.0、NVMe，Windows 11，Strata v0.1.44.1-nvfp4.2，客戶端是 Codex。

| 項目 | 預設 IQ3_S | NVIDIA NVFP4（`-Family qwen-nvidia-nvfp4`） |
|---|---|---|
| 記憶體模式 | 整個放進 RAM | 低 RAM 模式（部分專家從 SSD 讀） |
| 顯卡裡的專家快取 | 4,028 個（7.69 GiB） | 2,292 個（5.90 GiB） |
| 載入模型 | 約 2–3 分鐘 | 約 1–2 分鐘 |
| 讀提示詞 | 60.8K tokens 約 40 秒（伺服器啟動後第一輪，要讀完整對話歷史） | 23.9K tokens 約 49 秒（第一輪）；之後每輪只讀新增部分，約 17–20 秒 |
| 產生文字 | **36.8–45 tok/s** | 暖機後 10.5–12 tok/s |
| 專家快取命中率 | 80% | 54–63% |

IQ3_S 的數字只量了一輪，而且是在 60K token 的長對話中、邊呼叫工具邊量的；NVFP4 的數字是連續約 10 輪的結果。

### 跟網路上的數字比較

公開的 16 GB 顯卡＋64 GB RAM 實測（IQ3_S 或相近量化）：

| 來源 | 系統 | 產生速度 |
|---|---|---|
| Strata issue #2453 的社群測試 | Linux、RTX 5070 Ti | 70–95 tok/s（短對話） |
| note.com 部落格 | Linux、RTX 5070 Ti、IQ3_XXS、128K | 50–70 tok/s |
| note.com 部落格 | Ubuntu、RTX 5070 Ti、Ryzen 5 9600X、256K | 50–90 tok/s |
| Strata issue #2453 回報者 | **Windows**、i9-14900K、RTX 5060 Ti 16 GB | 55–69 tok/s（短對話） |

比較時要注意：

- **對話長度：** 對話越長，每個 token 越慢。網路上的數字多半是短提示詞；上表本機的 36.8–45 tok/s 是在 60K token 的對話裡量的。
- **作業系統：** 公開數字以 Linux 居多。Windows 的 WDDM 驅動會保留一部分顯存給桌面，鎖定記憶體也有限制。
- **CPU：** 快取沒命中的專家在 CPU 上算。支援 AVX-512 的 CPU（例如 Ryzen 7000/9000 系列）較快；Intel 12 代以後的消費級 CPU 只有 AVX2。
- **公平比較：** 模型執行中時，在 `strata-nvfp4\` 跑 Strata 附的 `BENCH.bat`，約 10 分鐘會產生一份可分享的報告，跟別人的報告比才有意義。

### 能做什麼

- **用新版 Strata（預設已是 `v0.2.0-beta-nvfp4.3`）。** 官方在 RTX 5090 上實測產生速度 203.3 對 179.5 tok/s（5 組交錯測試，中位數 +8%）。新版也會在顯存低於 24 GB 時把讀圖編碼器放到 CPU，約 1.4 GB 顯存還給專家快取；CPU 工作執行緒改依實體核心設定，混合架構 CPU 用「大核＋一半小核」。
- **螢幕接主機板的顯示輸出。** 有內建顯示晶片的 CPU（例如 i5-14600K）可以讓桌面改由內顯負責，獨立顯卡不必為桌面保留顯存，能放更多專家。
- **64 GB 的電腦用預設的 IQ3_S。** 它能整個放進 RAM，不必進低 RAM 模式；以下幾點主要針對 NVFP4。
- **剛啟動最慢。** 64 GB 的電腦用 NVFP4 時會進入低 RAM 模式：大部分專家第一次用到時才從 SSD 讀進來，再由 Windows 留在 RAM 裡；顯示卡的專家快取也會依實際用到的專家自動調整。多跑幾個請求，速度和命中率都會上升。
- **跑模型時關掉其他程式（尤其是瀏覽器）。** 低 RAM 模式能留在 RAM 的專家是「可用 RAM 減 6 GiB」，其他程式吃掉的 RAM 都會變成 SSD 讀取。
- **代理類客戶端（如 Codex）第一輪特別慢。** 它們每次都會送上萬 token 的系統提示詞和工具定義。Strata 會在每一輪結束時記下檢查點，同一段對話的下一輪只讀新增的 token，所以只有第一輪要付完整的讀取時間。
- **不需要讀圖時可用 `-Vision no`。** 圖片編碼器放在 GPU 時佔約 1.4 GB 顯存，放在 CPU 時佔 1–2 GiB RAM；關掉可以把這些空間還給專家。
- **加 RAM 效果最大。** 92 GiB 以上時，所有專家都常駐 RAM，不再讀 SSD。

## 與網路上流傳的部署教學的差異

有篇流傳的中文教學推薦「NVIDIA ModelOpt NVFP4 + strata-nvfp4」方案。Qwen3.8-Flash-Next 與 `sergqwer/strata-nvfp4` 都是真的，但教學裡的指令不是：`python -m strata.serve`、`--adapt-async` 作為獨立指令、`--offload-device cpu`、`--gpu-memory-utilization`、`STRATA_PIN_BY_NEED`、`pip install -r requirements.txt` 在 Strata 的 README 與 setup.py 裡都查不到。實際流程是 `START-HERE.bat`（setup.py）→ `serve/server.py --engine strata --config …`，本包照這個做。另外「近乎無損」沒有找到佐證：Strata README 只給了 GPTQ 版對 Q8_0 的 top-token 一致率 93.6%（RTX 5090 / 128 GB 實測），NVIDIA 版沒有對應數字。要比較請改用 `-Family qwen-nvfp4-gptq` 並用 `format_probe.py` 自行測。16 GB 顯卡配 64 GB RAM 會走 low-RAM 模式（從硬碟讀部分專家），速度請以實測為準，教學裡的 40–55 tok/s 沒有出處。

## 可攜 Python 的做法

Strata 的 `START-HERE.bat` 只要看到 `.venv\Scripts\python.exe` 存在就直接拿來跑 `setup.py`。`setup.py` 只用 `sys.executable -m pip install` 裝套件，不檢查是否為 venv。所以本包把**嵌入式 Python** 放在那個位置，Strata 的流程完全不變，但不需要 winget，也不需要系統 Python。

嵌入式 Python 的 `._pth` 會讓腳本找不到同資料夾的模組。這點已用本機實測確認：不處理的話 `tools\*.py`、`serve\server.py` 會出現 `ModuleNotFoundError`。`portable\sitecustomize.py` 會補回這個行為，補上後實測三種腳本都正常。

## 已驗證與未驗證

**已在沒有 GPU 的 Windows 11 上用假 Strata 測過**（假 setup.py、假 server.py、用系統 Python 模擬可攜 Python）：

- 首次安裝、第二次跳過。改家族／context 會重跑 setup；換金鑰不會重跑，但會寫入設定檔。
- 沒指定 context 時不傳 `--context`；setup 實際寫出的設定檔名會記錄下來，不靠檔名猜。
- 設定檔的 `host`、`fit_max_tokens`、`api_key` 會被套用，Strata 自己的 `sampling` 不被動到。
- 啟動後經閘道打到 Strata，請求內容原封不動（含 `response_format`、超大 `max_tokens`），client key 檢查正常。
- Strata 崩潰時連帶關閉並回傳錯誤碼，結束後不殘留程序。
- 搬到含空白與中文的路徑後，自動改寫設定檔的絕對路徑（不分大小寫）。
- `next_gateway.py`：預設原樣轉發、選用的補值與溫度上限、SSE 逐段轉發、上游不通回 502。
- `format_probe.py` 的判定邏輯。
- `set_pagefile.ps1 -DryRun`：
  - 新設定的計算：從自動管理轉換、保留其他磁碟、取代既有設定、設在系統碟本身。
  - 已設定時不重寫、找不到磁碟、空間不足、還原備份。
  - 對磁碟類型的辨識（NVMe / SSD）。

**已在真機（RTX 5070 Ti、64 GB RAM）上確認：**

- **安裝：** 可攜 Python 與 pip、setup.py 參數全部被接受且不會停下來詢問、git clone 路線。
- **下載：** 引擎、模型、圖片編碼器全部下載完成並通過 SHA-256 驗證。
- **分頁檔：** 設為固定 65536 MB 並重開機後，啟動器的檢查顯示 `65536 MB fixed`，Strata 的警告也消失。
- **執行（Strata v0.1.44.1-nvfp4.2）：** IQ3_S 與 NVIDIA NVFP4 都能載入，經閘道使用 `/v1/responses` 推理與工具呼叫，Strata 套用了官方取樣預設。
- **超過 context：** Strata 回 400 而不截斷；這就是預設用 128K、並在「搭配 Codex」寫明壓縮設定的原因。

**未驗證（尚未在有 GPU 的真機上跑過，歡迎回報）：**

- 預設的 Strata `v0.2.0-beta-nvfp4.3` 在真機上的升級、安裝與速度。已對照它的原始碼確認：啟動器用到的安裝參數都還在，伺服器仍以 `serve/server.py --engine strata --config … --port …` 啟動。
- 實際傳圖片給模型讀圖。
- 啟動器自動安裝 `jsonschema`，以及之後 `json_schema` 的完整檢查。
- `set_pagefile.ps1` 實際寫入登錄檔：寫入格式與 Windows「虛擬記憶體」對話框相同，但只測過 dry run。
- 用 zip（而非 git）取得原始碼時，Strata 選引擎版本的方式是否依賴 git 資訊。有裝 git 的電腦會走 git clone，不受影響。

## 疑難排解

- **回覆全是 `!`**：Strata README 有專門章節，通常與 RAM／分頁檔或驅動有關，請依該章節處理。
- **啟動很久沒回應**：首次載入與 low-RAM 模式都慢，看 Strata 視窗輸出；`/health` 503 屬正常。
- **下載中斷**：再按一次 `START.bat`，已完成的步驟會略過，模型會續傳。
- **換 Strata 版本**：`.\START.bat -Tag <版本標籤>`。啟動器會記住已安裝的版本，標籤不同就原地更新：git 安裝用 git 切換，zip 安裝則換成新版資料夾、保留可攜 Python，舊資料夾改名留著。接著重跑一次 Strata 安裝更新引擎（約 0.5 GB）。模型在 `Strata-data\` 裡，不會重新下載。
- **Linux**：Strata 支援 Linux（`./setup.sh`），但本包的啟動器只寫了 Windows 版。

## 授權

本儲存庫的腳本以 [MIT 授權](LICENSE)釋出。首次啟動時下載的元件**不在此授權範圍內**，各自依原始授權使用：

- [strata-nvfp4](https://github.com/sergqwer/strata-nvfp4)：MIT。
- Python（python.org 嵌入式版）：PSF License。
- 模型權重：依 Hugging Face 上各模型頁面的授權。Strata README 註明，`qwen-nvidia-nvfp4` 的授權禁止移除安全限制。
