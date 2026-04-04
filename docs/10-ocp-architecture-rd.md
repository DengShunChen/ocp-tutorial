# 模組 10：OCP 架構下如何研發

> **前提**：叢集已完成 **GPU Operator** 與 **Red Hat OpenShift AI (RHOAI)** 部署，且使用者能以 **Data Science Project** 建立資源。若尚未就緒，請先依 [08-gpu-cluster-planning.md](08-gpu-cluster-planning.md)（規劃與元件）或 [09-slurm-to-ocp-gpu-migration.md](09-slurm-to-ocp-gpu-migration.md)（自 SLURM 遷移）完成安裝。  
> **本模組目的**：把「在 OCP 上實際做研發」拆成五條常見路線，對應到 **Namespace／Workbench／Pipeline／Job／模型服務** 等慣用落點，避免與裸機 SLURM「直接 SSH 上節點」的心智模型脫節。

---

## 目錄

1. [總覽：五條路線在平台上的落點](#1-總覽五條路線在平台上的落點)
2. [CorrDiff](#2-corrdiff)
3. [LLM（大型語言模型）](#3-llm大型語言模型)
4. [GPU computing（廣義 GPU 運算）](#4-gpu-computing廣義-gpu-運算)
5. [ML developing（一般機器學習研發流程）](#5-ml-developing一般機器學習研發流程)
6. [OpenClaw](#6-openclaw)
7. [橫切議題（每條路線都會碰到）](#7-橫切議題每條路線都會碰到)

---

## 1. 總覽：五條路線在平台上的落點

| 路線 | 你在做什麼 | 在 OCP／RHOAI 上典型承載 | 建議再讀 |
|:---|:---|:---|:---|
| **CorrDiff** | 氣象／氣候類生成式修正擴散模型（PyTorch、重資料、重 GPU） | GPU **Workbench** 做實驗；**Pipeline** 固定前處理與評估；長訓練用 **Job** 或 **Training Operator**（若已啟用） | [04](04-jupyter-notebooks.md)、[05](05-pipelines.md)、[08 §8](08-gpu-cluster-planning.md#8-多租戶與-gpu-排程策略) |
| **LLM** | 預訓練／微調／對齊／評測 | Workbench 微調；大規模分散式訓練走 **Job／CRD**；上線用 **KServe／推論路由** | [06](06-model-serving.md)、[08](08-gpu-cluster-planning.md) |
| **GPU computing** | CUDA／科學運算／非典型 DL 框架 | 自訂 **Container Image**，`resources.limits` 申請 `nvidia.com/gpu`；需要多節點時評估 **MPI Operator** 或批次模板 | [09 §15](09-slurm-to-ocp-gpu-migration.md#15-第-10-步跑一支-gpu-測試-pod從無到有最後一哩) |
| **ML developing** | 從 EDA 到可重現訓練與交付 | **Workbench + PVC**；**Pipelines**；產出模型後接 **Model Serving** | [04](04-jupyter-notebooks.md)、[05](05-pipelines.md)、[06](06-model-serving.md) |
| **OpenClaw** | 自主代理（Agent）編排、工具呼叫、長時執行 | 多數團隊先在 **工作站／Bastion** 跑；若要進叢集則以 **Deployment + Secret +（內部）Route** 包裝，並嚴格限制權限 | 本節 §6 |

**一句話**：OCP 把「研發」變成 **可聲明的映像 + 可配額的 GPU + 可掛載的儲存 + 可發佈的路由**；你的工作是把互動式實驗（Notebook）與批次／服務（Job／InferenceService）分開設計。

---

## 2. CorrDiff

**CorrDiff** 在此指 **以擴散模型做區域氣象／氣候場景生成或修正** 這類工作負載（典型實作為 **PyTorch + CUDA**，輸入輸出張量與資料管線體積大）。在 OCP 上研發時，建議依成熟度分三層：

### 2.1 互動式實驗（算法／小規模）

- 在 **Data Science Project** 開 **Workbench**，映像選 **PyTorch** 或自訂 **CUDA** 映像（需已含與叢集驅動匹配的 CUDA 使用者空間版本，細節依你們的 GPU Operator 與基底映像政策）。
- **PVC** 掛在 `/data` 或專案慣用路徑，放：原始場資料、中繼特徵、checkpoint；避免把大量資料塞進容器層。
- **GPU**：在 Workbench 上明確 **Request** 與 **Limit** 的 `nvidia.com/gpu`；若節點使用 **MIG**，請與叢集管理員對齊可用資源名稱與切分策略（見 [08](08-gpu-cluster-planning.md)）。

### 2.2 可重現管線（前處理、評估、批次推論）

- 將「固定步驟」從 Notebook 抽到 **Data Science Pipelines**（[05](05-pipelines.md)）：例如資料切片、正規化、指標計算、小批次推論；產物寫回 **物件儲存（S3 相容）** 或 **共享 PVC**（視 IO 與併發模型而定）。
- 管線步驟映像建議放在團隊可治理的 **internal registry**，並在 `ImageStream`／CI 中版本化，避免「只在某一臺 Notebook 裝得到套件」。

### 2.3 長時訓練與多卡／多節點

- 單 Pod 內多 GPU：常見為 **`torchrun`** 包在 **Kubernetes `Job`**（`completion`/`parallelism` 依需求）或 RHOAI 生態中已啟用的 **Training Operator** 所管理的 CRD（實際 CRD 名稱與版本以你們 `DataScienceCluster` 為準，規劃見 [08 §6](08-gpu-cluster-planning.md#6-rhoai-完整部署配置)）。
- 多節點：除了 GPU，還要設計 **跨 Pod 網路**（一般 Service DNS）、**共享讀取** 的資料來源，以及與 **Kueue／PriorityClass** 一致的佇列策略（[08 §8](08-gpu-cluster-planning.md#8-多租戶與-gpu-排程策略)）。

### 2.4 合規與資料

- 模型與資料集授權、下載路徑、是否可離線鏡像，需依上游釋出條款與貴單位資安政策執行；OCP 層面則用 **Secret** 管理憑證、用 **NetworkPolicy** 限制出站（若政策要求）。

---

## 3. LLM（大型語言模型）

### 3.1 研發階段

- **互動與小實驗**：Workbench（GPU／大記憶體規格）執行微調腳本（如 LoRA／QLoRA），權重與 tokenizer 放在 **PVC** 或透過工作負載掛載的唯讀儲存。
- **分散式訓練**：以 **Job** 或訓練相關 CRD 承載；注意 **NCCL／環境變數**、**節點親和性**（同機櫃、同網段）與 **RDMA** 是否開啟（高階議題見 [08 §3](08-gpu-cluster-planning.md#3-網路架構設計)）。
- **評測與基準**：可仍在 Notebook 或獨立 **Job**；產出報告與 artifact 建議寫入物件儲存以便版本比對。

### 3.2 服務與對內 API

- 上線與內部共用推論，優先對齊 [06-model-serving.md](06-model-serving.md)：**KServe**（單一大模型、scale-to-zero 等）與 **ModelMesh**（多模型密度）的取捨依延遲、併發與成本而定。
- 常見推論後端（**vLLM、TGI** 等）以 **自訂映像 + InferenceService** 或平台支援的 runtime 整合；對外是否暴露 **Route**、是否僅 **ClusterIP + 內部 JWT**，由資安與多租戶模型決定。

### 3.3 秘鑰與模型倉儲

- Hugging Face／私有 registry 的 token 用 **Secret** 注入；不要在映像或 Notebook 硬編碼。
- 大型權重快取可搭配節點本地快取或唯讀共享儲存，避免每個 Pod 全量下載；實作依儲存後端與頻寬調整。

---

## 4. GPU computing（廣義 GPU 運算）

此節涵蓋「**不一定是 PyTorch／TF 的標準訓練**」，例如自寫 **CUDA**、**cuBLAS／cuDNN**、或科學運算套件。

### 4.1 最小可行：單 Pod

- 使用 **GPU Operator** 暴露的 `nvidia.com/gpu` 資源；Pod spec 中設定 `resources.requests/limits`（與 [09 GPU 測試 Pod](09-slurm-to-ocp-gpu-migration.md#15-第-10-步跑一支-gpu-測試-pod從無到有最後一哩) 同一邏輯）。
- 映像需帶齊 **使用者空間 CUDA** 與你的二進位或套件；版本與節點驅動相容性由集群管理員把關。

### 4.2 多節點與 MPI 類工作負載

- 若從 SLURM **`srun` + MPI** 遷移，可評估 **MPI Operator** 或維持 **批次 Job + 固定 Service 發現**；重點是 **SSH 無密鑰依賴** 改為 **Kubernetes 網路與啟動器** 模型。
- 高效能網路（**RoCE／IB**）在 OCP 上屬進階題，需與 [08](08-gpu-cluster-planning.md) 的網路章節與官方 Secondary network／SR-IOV 文件對齊。

### 4.3 排程與公平性

- 與純 CPU 不同，GPU 節點常是瓶頸；團隊層級應約定 **ResourceQuota**、**LimitRange**、**Kueue** 或 **PriorityClass**，避免互搶（[08 §8](08-gpu-cluster-planning.md#8-多租戶與-gpu-排程策略)）。

---

## 5. ML developing（一般機器學習研發流程）

### 5.1 日常研發迴圈

1. **Workbench** 做 EDA、特徵試驗、Notebook 級訓練（[04](04-jupyter-notebooks.md)）。  
2. 將穩定步驟固化為 **Pipeline** 元件與參數（[05](05-pipelines.md)）。  
3. 產出模型檔與 metadata，進入 **部署與監控**（[06](06-model-serving.md)）。

### 5.2 映像與依賴治理

- 團隊自訂環境以 **Containerfile** 建置，推送到內部 registry，在 Workbench／Pipeline 指定映像 digest 或受控 tag；與「只在 Notebook `pip install`」相比，更利於稽核與重現。

### 5.3 可觀測性

- 訓練與推論的日誌走 **stdout**；指標可接叢集既有的 **Prometheus／User Workload Monitoring**（依貴叢集是否對租戶開放為準）。進階實驗追蹤（如 MLflow）通常以 **獨立 Deployment** 或外部受管服務銜接，並注意資料落地位置與 RBAC。

---

## 6. OpenClaw

**OpenClaw** 在此指 **第三方開源／社群的自主 AI Agent 平台**（長時執行、工具呼叫、與多種 LLM 後端整合）。它**不是** RHOAI 內建元件；在 OCP 架構下研發與導入時，建議分兩種部署哲學：

### 6.1 建議預設：叢集外或開發者工作站

- Agent 常需 **廣泛檔案與程序權限**；與企業 OCP 的 **SCC、RBAC、稽核** 預設假設容易衝突。實務上許多團隊讓研發者在 **Bastion／筆電** 跑 OpenClaw，僅把 **LLM 推論** 接到叢集內已存在的 **對內端點**（例如 KServe 提供的 HTTP API）。

### 6.2 若必須跑在叢集內

- 以 **Deployment**（或 **StatefulSet**，若需穩定儲存身份）包裝程序映像；**Secret** 管理 LLM API key 與工具憑證；**PVC** 保存長期記憶或工作區（若產品設計為檔案型記憶）。  
- **Route** 僅在需要對外時開啟，並應搭配 **OAuth／mTLS／IP allowlist** 等你們平台標準；內部試用優先 **ClusterIP**。  
- **安全**：Agent 能執行 shell 或改檔案時，等同在叢集內執行任意程式；務必 **最小權限 ServiceAccount**、隔離 **Namespace**、並由資安／平台團隊審核 **NetworkPolicy** 與出站網段。

### 6.3 與本叢集 LLM 的銜接

- 將 OpenClaw 的 LLM **base URL** 指到叢集內 **OpenAI 相容** 推論服務（實作依 [06](06-model-serving.md)）；好處是 **金鑰與模型權重** 留在受控環境，Agent 層只拿內網 API。

---

## 7. 橫切議題（每條路線都會碰到）

| 議題 | 實務要點 |
|:---|:---|
| **Namespace 與配額** | 一專案一 Namespace（或依組織切分）；`ResourceQuota` 限制 GPU／PVC 數量，避免單一專案占滿叢集。 |
| **儲存** | 互動式用 **RWX** 與否視儲存類別；大量唯讀權重可考 **物件儲存**；高效能訓練需與儲存團隊確認 **IOPS 與延遲**（[08 §7](08-gpu-cluster-planning.md#7-儲存架構設計)）。 |
| **映像來源** | 連網與離線叢集的 **mirror／ICSP／IDMS** 策略會直接影響你能否拉第三方映像；離線環境需預先同步（見 [09 §3.2](09-slurm-to-ocp-gpu-migration.md#32-離線鏡像為何大幅改變步驟)）。 |
| **除錯** | Pod 起不來、GPU 看不到、PVC 綁不上，先走 [07-debugging-guide.md](07-debugging-guide.md) 的系統化檢查清單。 |

---

## 參考與延伸閱讀（外部）

- Red Hat OpenShift AI 與 **KServe／Pipeline** 等元件，以 [Red Hat 官方文件](https://docs.redhat.com/) 當前版本為準。  
- **CorrDiff** 類模型與授權說明請以上游釋出專案（例如 NVIDIA 相關公開倉儲與模型卡）為準。  
- **OpenClaw** 產品與文件以社群官方站點為準（名稱與功能迭代快，導入前請自行核對最新安裝與安全建議）。
