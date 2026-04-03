# 模組 09：從 SLURM GPU 叢集遷移至 OpenShift (OCP) — 安裝與遷移指南

> **前提**：你已有一台或多台在 **SLURM** 下運作的 GPU 叢集（含登入節點、運算節點、共享儲存、可選 InfiniBand），目標是改以 **OpenShift Container Platform (OCP)** 承載 GPU 工作負載，並搭配 **Red Hat OpenShift AI (RHOAI)** 提供 Notebook、Pipeline、模型服務等能力。  
> **配套文件**：硬體／網路／GPU Operator／Kueue 等生產級規劃請一併閱讀 [08-gpu-cluster-planning.md](08-gpu-cluster-planning.md)。

---

## 目錄

1. [這份文件解決什麼問題](#1-這份文件解決什麼問題)
2. [SLURM 與 OCP 概念對照](#2-slurm-與-ocp-概念對照)
3. [遷移策略：硬體與並行期](#3-遷移策略硬體與並行期)
4. [安裝與遷移總流程](#4-安裝與遷移總流程)
5. [階段 A：先決條件與盤點](#5-階段-a先決條件與盤點)
6. [階段 B：安裝 OCP（裸機 GPU 叢集建議 UPI）](#6-階段-b安裝-ocp裸機-gpu-叢集建議-upi)
7. [階段 C：GPU 節點與 NVIDIA GPU Operator](#7-階段-cgpu-節點與-nvidia-gpu-operator)
8. [階段 D：儲存與資料遷移](#8-階段-d儲存與資料遷移)
9. [階段 E：高速網路（IB / RoCE）與訓練 Pod](#9-階段-e高速網路-ib--roce與訓練-pod)
10. [階段 F：安裝 RHOAI 與生產級 DataScienceCluster](#10-階段-f安裝-rhoai-與生產級-datasciencecluster)
11. [階段 G：排程、配額與多租戶（對應 SLURM Partition / QOS）](#11-階段-g排程配額與多租戶對應-slurm-partition--qos)
12. [階段 H：從 `sbatch` 工作流到容器化工作負載](#12-階段-h從-sbatch-工作流到容器化工作負載)
13. [驗證清單與切換建議](#13-驗證清單與切換建議)
14. [官方文件與延伸閱讀](#14-官方文件與延伸閱讀)

---

## 1. 這份文件解決什麼問題

- **不是**把 SLURM「套件升級」成 OCP：OCP 是完整的 Kubernetes 發行版，**SLURM 與 OCP 排程器並存於同一批 GPU 節點上通常不建議**（資源雙重調度、驅動／cgroup 衝突風險高）。實務上多為：
  - **重建節點**為 RHCOS Worker，僅跑 OCP；或  
  - **新硬體**先裝 OCP，再逐步把作業遷過去。
- **是**一條從「現有 SLURM 維運經驗」出發的 **OCP + GPU + RHOAI 安裝順序與檢核點**，讓你知道每一步對應以前 SLURM 環境裡的哪一塊，並指向本 repo 與 Red Hat 官方安裝文件。

---

## 2. SLURM 與 OCP 概念對照

| SLURM 世界 | OCP / Kubernetes 世界 | 備註 |
|:---|:---|:---|
| `slurmctld` / `slurmd` | 控制平面（API、etcd、Scheduler、Controller）+ 各節點 `kubelet` | 排程語意不同，但都是「把任務放到節點上」 |
| Partition、QOS、FairShare | `Namespace`、`ResourceQuota`、`LimitRange`、**Kueue**（`ClusterQueue` / `LocalQueue`） | RHOAI 整合 Kueue 做 GPU 佇列；見 [08 第 8 節](08-gpu-cluster-planning.md#8-多租戶與-gpu-排程策略) |
| `sbatch` / `srun` | `Pod`、`Job`、`CronJob`，或 **Training Operator** / **Ray** / **MPIJob** 等 CRD | 互動式開發以往用 `salloc`+SSH；OCP 上常用 **Workbench (Jupyter)** |
| 登入節點 | **Bastion** + `oc` / `kubectl` + **OpenShift Console** | 權限透過 OAuth / RBAC，而非僅 OS 帳號 |
| 共享檔案系統（NFS/Lustre/GPFS） | **CSI**（如 NFS、Lustre CSI）、**ODF/Ceph**、S3 相容物件儲存 | PVC 存取模式需符合 ROX/RWO/RWX |
| GPU 排程（GRES、`CUDA_VISIBLE_DEVICES`） | `nvidia.com/gpu` 資源、`DevicePlugin`、可選 **MIG** | 由 **GPU Operator** 統一驅動與裝置宣告 |
| MPI / NCCL 多機 | 同樣用 NCCL，但網路需 **Multus / SR-IOV / RDMA** 等 CNI 與權限設定 | 見 [08 第 3 節](08-gpu-cluster-planning.md#3-網路架構設計) |

---

## 3. 遷移策略：硬體與並行期

### 3.1 常見三種做法

1. **整批切換（Big Bang）**  
   停機或維護窗內將原 GPU 節點重灌為 RHCOS，加入新 OCP。風險集中，適合節點同型、劇本成熟時。
2. **平行叢集（建議）**  
   新裝一組 OCP（可先用部分節點），SLURM 與 OCP **各用不同機器**，驗證訓練／推論、儲存、監控後再汰換 SLURM 節點。
3. **僅遷「平台」、保留 HPC 排程**  
   若組織仍要 SLURM：可在**獨立叢集**保留 SLURM，另建 OCP 給雲原生 AI 平台；同一節點混跑需極謹慎設計，一般不推薦作為第一步。

### 3.2 你需要先決定的問題

- **API 網域與憑證**：OCP 需要穩定的 `api.<cluster>.<base>`、`*.apps.<cluster>.<base>`（或自訂 Ingress）。
- **節點 OS**：OCP Worker / Master 為 **RHCOS**（或符合官方支援的架構），**不是**你在 SLURM 上慣用的 CentOS/RHEL「一般安裝」直接當 Worker。
- **離線需求**：若無法連公網 OperatorHub，需 **mirror registry** 與 **ImageContentSourcePolicy**，安裝複雜度顯著上升（可選 **Agent-based Installer**）。

---

## 4. 安裝與遷移總流程

建議順序（細節見後續章節）：

```
盤點 SLURM 環境（網路、儲存、GPU 型號、作業型態）
        ↓
安裝 OCP（裸機多為 UPI 或 Agent-based）
        ↓
加入 GPU Worker → 安裝 NFD + NVIDIA GPU Operator → 驗證 nvidia.com/gpu
        ↓
儲存：CSI / ODF、資料複製、StorageClass 預設值
        ↓
（可選）Multus / SR-IOV / RDMA for 多機訓練
        ↓
安裝 RHOAI Operator → 建立 DataScienceCluster（生產建議見 08）
        ↓
Kueue、Namespace、Quota、RBAC（對齊原 Partition / 團隊配額）
        ↓
工作負載改為容器映像 + Pod/CRD，逐步切流量
```

---

## 5. 階段 A：先決條件與盤點

### 5.1 從現有 SLURM 叢集盤點的欄位（建議做成表）

| 項目 | 說明 |
|:---|:---|
| GPU 型號與驅動版本 | 對應 GPU Operator `driver.version`、是否 MIG |
| 每節點 GPU 數、CPU、記憶體 | 對應 `MachineSet` / `Node` capacity、Quota |
| 管理網 vs 高速網（IB/RoCE）IP 與介面 | 對應 Multus NAD、SR-IOV policy |
| 共享儲存類型與掛載點 | 對應 CSI、PVC、是否 ROX 資料集 |
| 使用者如何送作業（批次腳本、互動、容器） | 對應 Pipeline、Training、Workbench |
| 身分驗證（LDAP、AD） | 對應 OCP **OAuth**、`OAuth`/`Group`/`RoleBinding` |

### 5.2 與本教學 repo 的對齊

- 開發機上的 `oc`、登入方式：見 [01-prerequisites.md](01-prerequisites.md)（CRC 段落可略讀，重點是 **`oc` 與叢集存取概念**）。
- RHOAI 訂閱與 `DataScienceCluster`：見 [02-install-rhoai.md](02-install-rhoai.md)；**生產 GPU 叢集**請改用 [08 第 6 節](08-gpu-cluster-planning.md#6-rhoai-完整部署配置) 的全開元件與 Kueue。

---

## 6. 階段 B：安裝 OCP（裸機 GPU 叢集建議 UPI）

> 下列為 **必做事項清單**，具體 YAML、ISO、PXE 步驟請以當前 OCP 版本的 **Red Hat 官方安裝文件**為準（版本需與訂閱一致）。

### 6.1 安裝路徑選擇（與 [08 第 4.1 節](08-gpu-cluster-planning.md#41-安裝方式選擇) 一致）

| 方式 | 何時用 |
|:---|:---|
| **UPI（User-Provisioned）** | 自有裸機、vSphere 等，你已準備好 VM/實體機與網路 |
| **Agent-based** | 離線、大量節點、想用 Agent ISO 自動裝 RHCOS |
| **IPI** | 雲上由安裝程式建立機器（較少用在傳統內部 GPU 裸機） |

### 6.2 UPI 裸機高層步驟（Checklist）

1. **準備基礎設施**  
   - DNS：`api`、`api-int`、`* .apps`（依官方指引）。  
   - Load balancer：API、Ingress（或官方允許的拓撲）。  
   - **Bastion**：安裝 `openshift-install`、`oc`，放置 `pull-secret`。
2. **產生 `install-config.yaml`**  
   - 設定 `baseDomain`、`metadata.name`、`networking`、`compute`/`controlPlane` 副本數、平台類型（如 `baremetal` 或 `none`）。  
   - **SSH 公鑰**、**pull secret**。
3. **建立 manifest（若需）**  
   - 例如自訂 `Network`、`ImageContentSourcePolicy`（離線）、或 **schedulable masters** 等進階需求。
4. **產生 Ignition**  
   - `openshift-install create ignition-configs`（實際子命令依流程為 `create cluster` 前準備 bootstrap/master/worker ignition）。
5. **裝機**  
   - 透過 **Red Hat CoreOS ISO + Ignition** 或 PXE 開機，依序完成 **bootstrap → 控制平面 → Worker**。  
6. **安裝完成**  
   - `openshift-install wait-for install-complete`（或對應指令）。  
   - 取得 `kubeadmin` 密碼與 Console URL。  
7. **Day-2：Worker 擴充**  
   - 將原「SLURM 運算節點」改裝為 RHCOS 後，以 **Worker** 身分加入（具體機制依 bare metal：如 **Metal3 / ZTP** 或手動核准 `CSR` 等，請依官方 bare metal 流程）。

### 6.3 GPU 節點專用 Day-2 設定

安裝完成後儘早做（細節見 [08 第 4.2 節](08-gpu-cluster-planning.md#42-node-label-與-taint-策略)）：

- 為 GPU Worker 加上 **label**（例如 `node-role.kubernetes.io/gpu-worker`、產品標籤）。  
- 加上 **Taint**（例如 `nvidia.com/gpu=present:NoSchedule`），避免一般 Pod 佔用 GPU 機。

---

## 7. 階段 C：GPU 節點與 NVIDIA GPU Operator

1. 安裝 **Node Feature Discovery (NFD)** Operator。  
2. 安裝 **NVIDIA GPU Operator**（Certified Operator），並套用 **ClusterPolicy**（驅動、DCGM、device plugin、可選 **RDMA**）。  
3. 驗證節點出現 **`nvidia.com/gpu`** 可分配量。

完整 YAML 範例與驗證指令見 **[08 第 5 節：NVIDIA GPU Operator 部署](08-gpu-cluster-planning.md#5-nvidia-gpu-operator-部署)**。

**與 SLURM 的差異**：以前你在節點上裝 NVIDIA driver + 用 SLURM GRES 宣告 GPU；在 OCP 上由 **GPU Operator DaemonSet** 管理驅動與裝置外掛版本，**務必**與硬體、CUDA 需求對表測試。

---

## 8. 階段 D：儲存與資料遷移

### 8.1 對照 SLURM 常用掛載

| 用途 | SLURM 典型做法 | OCP 典型做法 |
|:---|:---|:---|
| 家目錄 / 專案目錄 | NFS auto-mount | **RWX** PVC（NFS CSI、CephFS）或 S3 |
| 唯讀大數據集 | Lustre/GPFS 全叢集掛載 | **CSI** 掛進 Pod；或 S3 + 資料管線 |
| Checkpoint（大量小檔／大檔） | 節點本機 SSD | **Local SSD** PV（`local` / LSO）或 RWO 高速 StorageClass |

### 8.2 資料遷移實務

- **離線複製**：`rsync`、`rclone`、儲存廠商工具，目標為 PVC 後端或物件桶。  
- **同時維運期**：新資料寫雙邊或「以 OCP 為準」訂一個 cut-over 日。  
- **預設 StorageClass**：RHOAI 與許多 Operator 需要明確的 **default StorageClass**（概念同 [01 第 1.3 節](01-prerequisites.md#13-確認叢集狀態)）。

---

## 9. 階段 E：高速網路（IB / RoCE）與訓練 Pod

若你在 SLURM 上已用 **InfiniBand** 跑多機 NCCL：

- OCP 需 **Multus** 第二網路、`NetworkAttachmentDefinition`，並視環境啟用 **SR-IOV Network Operator**、**RDMA**（GPU Operator `ClusterPolicy` 內 `driver.rdma`）。  
- Pod 安全上下文與 **capabilities** 需符合叢集政策（常見為 `IPC_LOCK`、Huge pages 等，依工作負載調整）。

概念與範例見 **[08 第 3 節：網路架構設計](08-gpu-cluster-planning.md#3-網路架構設計)** 與 **GPUDirect RDMA** 小節。

---

## 10. 階段 F：安裝 RHOAI 與生產級 DataScienceCluster

1. 在 **OperatorHub** 訂閱 **Red Hat OpenShift AI**（或 CLI 套用 `Subscription`），等待 CSV 成功。  
2. 建立 **`DataScienceCluster`**：生產 GPU 叢集建議啟用 **KServe、Ray、Training Operator、Kueue** 等（與 CRC 精簡版不同）。  

步驟可跟 [02-install-rhoai.md](02-install-rhoai.md)；**元件開關**請對照 [08 第 6.1 節](08-gpu-cluster-planning.md#61-datasciencecluster-全功能啟用) 的 `DataScienceCluster` 範例。

---

## 11. 階段 G：排程、配額與多租戶（對應 SLURM Partition / QOS）

- **Namespace**：對應不同團隊或專案（類似不同 partition 的邏輯隔離）。  
- **ResourceQuota / LimitRange**：硬上限 GPU/CPU/記憶體。  
- **Kueue**：`ClusterQueue`、`LocalQueue`、`ResourceFlavor`，對應叢集級資源池與團隊佇列；範例見 [08 第 8 節](08-gpu-cluster-planning.md#8-多租戶與-gpu-排程策略)。  
- **PriorityClass**：對應不同 QOS（互動 vs 批次可被搶占）；見 [08 第 8.3 節](08-gpu-cluster-planning.md#83-priority-class-優先權等級)。

使用者與 RBAC 可沿用本 repo [03-user-management.md](03-user-management.md) 的思維，在生產環境改接企業 IdP。

---

## 12. 階段 H：從 `sbatch` 工作流到容器化工作負載

### 12.1 遷移思維

| SLURM | OCP 上常見做法 |
|:---|:---|
| 單節點 GPU 訓練腳本 | `Deployment` / `Job` + 映像內 `python train.py` |
| 多節點 MPI | `MPIJob`（若已啟用相關元件）或官方支援的分散式訓練 CRD |
| PyTorch / TF 分散式 | **Training Operator**（`PyTorchJob` 等）或 **Ray** |
| 互動除錯 | **RHOAI Workbench**（Jupyter）申請 GPU，取代 `salloc`+SSH |
| 定期批次 | `CronJob` 或 **Data Science Pipelines** |

### 12.2 映像

- 將原本在 SLURM 登入節點上的 **module load** 環境，改為 **Containerfile** 內固定 CUDA / 框架版本。  
- 映像需與 **節點驅動**相容（NVIDIA Container Toolkit 由 GPU Operator 處理 runtime）。

---

## 13. 驗證清單與切換建議

### 13.1 技術驗證（建議逐項勾選）

- [ ] 所有節點 `Ready`，無異常 `MachineHealthCheck`（若使用）  
- [ ] `oc describe node <gpu-node>` 可見 **`nvidia.com/gpu`**  
- [ ] 測試 Pod 可執行 `nvidia-smi` 與短程訓練（單卡／多卡）  
- [ ] （若有）多節點 NCCL 測試通過，延遲與頻寬符合預期  
- [ ] **RHOAI** `DataScienceCluster` Phase **Ready**  
- [ ] 試建 **Workbench**（GPU）與一條 **Pipeline** 或 **InferenceService**  
- [ ] **Kueue** 佇列與 **Quota** 符合團隊配置  

### 13.2 切換建議

- 先讓 **非關鍵作業**在 OCP 跑 1～2 個月，保留 SLURM 跑關鍵路徑（若採平行叢集）。  
- 訂定 **rollback**：僅在仍有 SLURM 叢集或備援容量時才有意義。  
- 文件化：**映像版本**、**StorageClass**、**GPU Operator channel**、**RHOAI channel**，便於災難復原。

---

## 14. 官方文件與延伸閱讀

- [Installing OpenShift on bare metal (官方)](https://docs.redhat.com/en/documentation/openshift_container_platform/) — 請選你的 OCP 小版本對應書冊中的 *Installing on bare metal* / *User-provisioned*。  
- [Red Hat OpenShift AI 文件](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed)  
- NVIDIA GPU Operator（與 OpenShift 相容矩陣以 Operator 說明為準）  
- 本 repo：[08-gpu-cluster-planning.md](08-gpu-cluster-planning.md)（架構與 YAML）、[02-install-rhoai.md](02-install-rhoai.md)（RHOAI 安裝流程）

---

> **總結**：從 SLURM 改 OCP **不是換一個排程器套件**，而是 **以 RHCOS Worker 重建叢集**，再疊加 **GPU Operator → 儲存/網路 → RHOAI → Kueue/Quota**，最後把作業改成 **容器映像 + Kubernetes/RHOAI 工作負載**。依 [第 4 節](#4-安裝與遷移總流程) 順序執行並用 [第 13 節](#13-驗證清單與切換建議) 驗證，即可有節奏地完成遷移。
