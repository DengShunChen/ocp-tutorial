# Module 08: 生產環境 GPU 叢集規劃

> **硬體配置**: Login Node + 8 × GPU Node (每節點 8 × NVIDIA A100 80GB)
> **總 GPU 數量**: 64 × A100 = 5,120 GB GPU Memory
> **適用場景**: 大型語言模型訓練 (LLM)、分散式深度學習、多租戶 AI 平台

---

## 目錄

1. [叢集架構總覽](#1-叢集架構總覽)
2. [節點角色與硬體規格](#2-節點角色與硬體規格)
3. [網路架構設計](#3-網路架構設計)
4. [OpenShift 叢集規劃](#4-openshift-叢集規劃)
5. [NVIDIA GPU Operator 部署](#5-nvidia-gpu-operator-部署)
6. [RHOAI 完整部署配置](#6-rhoai-完整部署配置)
7. [儲存架構設計](#7-儲存架構設計)
8. [多租戶與 GPU 排程策略](#8-多租戶與-gpu-排程策略)
9. [監控與告警](#9-監控與告警)
10. [與 CRC 環境的差異對照](#10-與-crc-環境的差異對照)

---

## 1. 叢集架構總覽

### 1.1 架構拓撲圖

```
                         ┌─────────────────────────────────┐
                         │         External Network         │
                         │       (使用者 / API 存取)        │
                         └──────────────┬──────────────────┘
                                        │
                         ┌──────────────▼──────────────────┐
                         │      Login Node (Bastion)        │
                         │   跳板機 / 管理入口 / CLI 操作    │
                         └──────────────┬──────────────────┘
                                        │
                    ┌───────────────────┼───────────────────┐
                    │           Management Network          │
                    │          (10 GbE / 25 GbE)           │
         ┌──────────┼──────────┬───────────┬───────────┐
         ▼          ▼          ▼           ▼           ▼
    ┌─────────┐┌─────────┐┌─────────┐          ┌──────────┐
    │Control-1││Control-2││Control-3│   ...     │ Infra-1  │
    │ Master  ││ Master  ││ Master  │          │(optional)│
    └─────────┘└─────────┘└─────────┘          └──────────┘
                    │
         ┌──────────┼──────────────────────────────────┐
         │         High-Speed GPU / Storage Network     │
         │        (100 GbE / InfiniBand HDR 200 Gb/s)  │
    ┌────┼────┬────┼────┬────┼────┬────┼────┐
    ▼         ▼         ▼         ▼         ▼
┌────────┐┌────────┐┌────────┐┌────────┐┌────────┐
│ GPU-01 ││ GPU-02 ││ GPU-03 ││ GPU-04 ││  ...   │  × 8 nodes
│8×A100  ││8×A100  ││8×A100  ││8×A100  ││8×A100  │
└────────┘└────────┘└────────┘└────────┘└────────┘
                    │
         ┌──────────┼──────────┐
         ▼                     ▼
    ┌──────────┐         ┌──────────┐
    │ Storage  │         │ Storage  │
    │ Server 1 │         │ Server 2 │
    │(Ceph/NFS)│         │(Lustre)  │
    └──────────┘         └──────────┘
```

### 1.2 設計原則

| 原則 | 說明 |
|:---|:---|
| **分離關注點** | Control Plane 與 GPU Worker 完全分離，避免管理負載影響訓練任務 |
| **高可用性** | 3 Master 確保 etcd 仲裁 (quorum)，避免單點故障 |
| **網路分層** | 管理流量 (10/25G) 與 GPU 通訊 (100G/IB) 走不同網路 |
| **可擴展性** | GPU Worker 可隨需增減，不影響 Control Plane |
| **資源隔離** | 透過 Namespace + ResourceQuota + Priority 實現多租戶隔離 |

---

## 2. 節點角色與硬體規格

### 2.1 Login Node (Bastion / 跳板機)

```
用途：管理入口、CLI 操作、kubectl/oc 代理
不加入 OpenShift 叢集，僅作為外部存取的安全閘道
```

| 項目 | 建議規格 |
|:---|:---|
| **CPU** | 8 核 (Intel Xeon / AMD EPYC) |
| **RAM** | 32 GB |
| **Disk** | 500 GB SSD |
| **Network** | 10 GbE × 2 (管理 + 備援) |
| **OS** | RHEL 9.x |
| **軟體** | oc CLI, helm, podman, ssh, VPN |

**關鍵配置：**
```bash
# Login Node 上設定 kubeconfig
export KUBECONFIG=/path/to/cluster/kubeconfig

# 驗證叢集連通
oc cluster-info
oc get nodes

# 透過 SSH Tunnel 存取 Dashboard (如果無 Public Route)
ssh -L 8443:api.cluster.example.com:6443 admin@login-node
```

### 2.2 Control Plane Nodes (Master × 3)

```
用途：運行 API Server, etcd, Scheduler, Controller Manager
不執行使用者工作負載，專責叢集管理
```

| 項目 | 建議規格 |
|:---|:---|
| **CPU** | 16 核 (Intel Xeon Gold / AMD EPYC) |
| **RAM** | 64 GB |
| **System Disk** | 500 GB NVMe SSD |
| **etcd Disk** | 500 GB NVMe SSD (**獨立磁碟！**) |
| **Network** | 25 GbE × 2 (Bond) |
| **OS** | RHCOS (Red Hat CoreOS) |

> ⚠️ **重要**：etcd 對磁碟延遲極其敏感。**務必使用獨立的 NVMe SSD**，不可與系統磁碟共用。etcd 延遲超過 10ms 會導致 Leader 選舉風暴。

### 2.3 GPU Worker Nodes (× 8)

```
用途：執行 AI/ML 訓練、推論、Jupyter Notebook 等 GPU 工作負載
這是叢集中最核心的運算資源
```

| 項目 | 建議規格 |
|:---|:---|
| **CPU** | 128 核 (AMD EPYC 9654 / Intel Xeon w9-3495X) |
| **RAM** | 1 TB (1024 GB) DDR5 |
| **GPU** | 8 × NVIDIA A100 80GB SXM4 |
| **GPU Interconnect** | NVSwitch (節點內 GPU-GPU 600 GB/s) |
| **System Disk** | 2 TB NVMe SSD |
| **Local Scratch** | 4 × 3.84 TB NVMe SSD (RAID0, 用於暫存) |
| **Network** | 25 GbE (管理) + 100 GbE / InfiniBand HDR (GPU 通訊) |
| **OS** | RHCOS (Red Hat CoreOS) |

> 💡 **為什麼 1 TB RAM？** 大型模型訓練時，數據載入 (DataLoader) 會大量使用 CPU 記憶體做預處理。RAM 不足會成為 GPU 利用率的瓶頸。

### 2.4 資源總覽

| 資源 | 單節點 | 全叢集 (8 Node) |
|:---|:---|:---|
| **GPU** | 8 × A100 80GB | **64 × A100 = 5,120 GB VRAM** |
| **CPU** | 128 核 | **1,024 核** |
| **RAM** | 1 TB | **8 TB** |
| **NVMe Scratch** | ~15 TB | **~120 TB** |
| **GPU 通訊頻寬** | 600 GB/s (NVSwitch 節點內) | 100/200 Gb/s (跨節點 IB/RoCE) |

---

## 3. 網路架構設計

### 3.1 多網路設計

生產環境 GPU 叢集需要 **至少 3 個獨立網路**：

```
┌────────────────────────────────────────────────────────┐
│                   Network Architecture                  │
├──────────────┬─────────────┬───────────────────────────┤
│  Management  │   Storage   │    GPU Interconnect       │
│   Network    │   Network   │    Network                │
├──────────────┼─────────────┼───────────────────────────┤
│  10/25 GbE   │  25/100 GbE │  100 GbE / IB HDR 200G   │
├──────────────┼─────────────┼───────────────────────────┤
│ API Server   │ Ceph / NFS  │ NCCL AllReduce            │
│ Dashboard    │ PVC Mount   │ Distributed Training      │
│ SSH / Admin  │ Dataset I/O │ Gradient Sync             │
│ Monitoring   │ Model Store │ Multi-node GPU Comm       │
└──────────────┴─────────────┴───────────────────────────┘
```

### 3.2 OpenShift 多網路配置 (Multus)

OpenShift 使用 **Multus CNI** 支援多網路附掛，讓 GPU Pod 同時連接管理網路和高速網路：

```yaml
# NetworkAttachmentDefinition - GPU 高速網路
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: gpu-rdma-network
  namespace: ai-training
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "host-device",
      "device": "ib0",
      "ipam": {
        "type": "static",
        "addresses": [
          { "address": "10.10.0.0/24" }
        ]
      }
    }
```

```yaml
# Pod 掛載雙網路
apiVersion: v1
kind: Pod
metadata:
  name: gpu-training
  annotations:
    k8s.v1.cni.cncf.io/networks: gpu-rdma-network
spec:
  containers:
  - name: trainer
    resources:
      limits:
        nvidia.com/gpu: 8        # 使用全部 8 GPU
        rdma/rdma_shared_device_a: 1  # RDMA 裝置
```

### 3.3 GPUDirect RDMA

A100 支援 **GPUDirect RDMA**，允許 GPU 直接透過 InfiniBand 讀寫遠端 GPU 記憶體，跳過 CPU：

```
傳統路徑：  GPU → CPU → NIC → Network → NIC → CPU → GPU
GPUDirect：  GPU → NIC → Network → NIC → GPU  (CPU 不參與!)
```

> 這對大型分散式訓練 (如 Megatron-LM, DeepSpeed) 的效能至關重要。需要在 GPU Operator 中啟用 `driver.rdma.enabled: true`。

---

## 4. OpenShift 叢集規劃

### 4.1 安裝方式選擇

| 安裝方式 | 適用場景 | 建議 |
|:---|:---|:---|
| **IPI (Installer-Provisioned)** | 公有雲 / 虛擬化平台 | AWS, Azure, vSphere |
| **UPI (User-Provisioned)** | 裸機 GPU 叢集 | ✅ **推薦用於 A100 叢集** |
| **Agent-Based** | 離線 / Air-Gap 環境 | 安全隔離的 GPU 叢集 |

### 4.2 Node Label 與 Taint 策略

```bash
# 為 GPU 節點打標籤
oc label node gpu-worker-{01..08} \
  node-role.kubernetes.io/gpu-worker="" \
  nvidia.com/gpu.product="A100-SXM4-80GB" \
  cluster.example.com/node-type=gpu

# 設定 Taint 防止非 GPU 工作負載調度到 GPU 節點
oc adm taint nodes gpu-worker-{01..08} \
  nvidia.com/gpu=present:NoSchedule

# 確認標籤
oc get nodes -l nvidia.com/gpu.product=A100-SXM4-80GB
```

> 🔑 **Taint 的意義**：確保昂貴的 GPU 節點不會被一般的 Web 服務或監控 Pod 佔用。只有帶有 `tolerations` 的 GPU 工作負載才能被調度上來。

### 4.3 MachineSet 定義 (如使用 IPI)

```yaml
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  name: gpu-worker
  namespace: openshift-machine-api
spec:
  replicas: 8
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-machineset: gpu-worker
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-machineset: gpu-worker
    spec:
      metadata:
        labels:
          node-role.kubernetes.io/gpu-worker: ""
      taints:
        - key: nvidia.com/gpu
          value: present
          effect: NoSchedule
      providerSpec:
        # 根據您的平台 (vSphere, Bare Metal, AWS) 填寫
        # 裸機環境通常使用 BareMetalHost CR
```

---

## 5. NVIDIA GPU Operator 部署

### 5.1 安裝流程

```bash
# Step 1: 安裝 Node Feature Discovery (NFD) Operator
# 用於自動偵測節點上的 GPU 硬體
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: "stable"
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Step 2: 建立 NFD Instance
oc apply -f - <<EOF
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    image: registry.redhat.io/openshift4/ose-node-feature-discovery
EOF

# Step 3: 安裝 NVIDIA GPU Operator
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: "v24.6"
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
EOF
```

### 5.2 ClusterPolicy 配置

```yaml
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    defaultRuntime: crio
  
  driver:
    enabled: true
    rdma:
      enabled: true        # 啟用 GPUDirect RDMA
      useHostMofed: true    # 使用宿主機的 MOFED 驅動
    version: "550.127.05"   # 指定驅動版本
  
  devicePlugin:
    enabled: true
    config:
      name: device-plugin-config
      default: a100-config
  
  dcgmExporter:
    enabled: true           # DCGM 監控 GPU 指標
  
  dcgm:
    enabled: true
  
  gfd:                      # GPU Feature Discovery
    enabled: true
  
  mig:                      # Multi-Instance GPU (可選)
    strategy: mixed         # none / single / mixed
  
  toolkit:
    enabled: true
  
  validator:
    plugin:
      env:
        - name: WITH_WORKLOAD
          value: "true"     # 部署時自動驗證 GPU 可用性
```

### 5.3 驗證 GPU 可用

```bash
# 檢查 NFD 是否偵測到 GPU
oc get nodes -o json | jq '.items[].metadata.labels' | grep nvidia

# 檢查 GPU Operator Pod 狀態
oc get pods -n nvidia-gpu-operator

# 驗證 GPU 資源已註冊
oc describe node gpu-worker-01 | grep -A 5 "nvidia.com/gpu"
# 預期輸出:
#   nvidia.com/gpu: 8
#   nvidia.com/gpu.memory: 81920
#   nvidia.com/gpu.product: A100-SXM4-80GB

# 使用 nvidia-smi 驗證
oc exec -n nvidia-gpu-operator $(oc get pods -n nvidia-gpu-operator -l app=nvidia-driver-daemonset -o name | head -1) -- nvidia-smi
```

### 5.4 MIG (Multi-Instance GPU) — 切割 A100

A100 支援 **MIG** 技術，可將一張 GPU 切割成最多 7 個獨立實例：

```
┌───────────────────────── A100 80GB ──────────────────────────┐
│                                                               │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐            │
│  │ 1g.10gb │ │ 1g.10gb │ │ 1g.10gb │ │ 1g.10gb │  7 × 1g   │
│  └─────────┘ └─────────┘ └─────────┘ └─────────┘            │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐                        │
│  │ 1g.10gb │ │ 1g.10gb │ │ 1g.10gb │                        │
│  └─────────┘ └─────────┘ └─────────┘                        │
│                    或                                         │
│  ┌─────────────────────┐ ┌─────────────────────┐            │
│  │     3g.40gb         │ │      4g.40gb        │   2 大切割  │
│  └─────────────────────┘ └─────────────────────┘            │
│                    或                                         │
│  ┌───────────────────────────────────────────────┐          │
│  │              7g.80gb (完整 GPU)                 │  不切割  │
│  └───────────────────────────────────────────────┘          │
└───────────────────────────────────────────────────────────────┘
```

**使用場景建議**：

| 模式 | 切割方式 | 適用場景 |
|:---|:---|:---|
| **不切割** | 7g.80gb | LLM 訓練、大模型推論 |
| **2 切割** | 3g.40gb + 4g.40gb | 中型模型開發 + 推論 |
| **7 切割** | 7 × 1g.10gb | Jupyter Notebook、教學環境 |

```bash
# 啟用 MIG 模式 (在特定節點)
oc label node gpu-worker-08 nvidia.com/mig.config=all-1g.10gb

# 查看 MIG 裝置
oc describe node gpu-worker-08 | grep "nvidia.com/mig"
# nvidia.com/mig-1g.10gb: 56  (8 GPU × 7 切割)
```

---

## 6. RHOAI 完整部署配置

### 6.1 DataScienceCluster (全功能啟用)

與 CRC 精簡版不同，生產環境應**啟用所有組件**：

```yaml
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    workbenches:
      managementState: Managed
    datasciencepipelines:
      managementState: Managed
    modelmeshserving:
      managementState: Managed      # ✅ 啟用 (CRC 環境為 Removed)
    kserve:
      managementState: Managed      # ✅ 啟用 (CRC 環境為 Removed)
      serving:
        ingressGateway:
          certificate:
            type: SelfSigned
        managementState: Managed
    ray:
      managementState: Managed      # ✅ 啟用 (CRC 環境為 Removed)
    trustyai:
      managementState: Managed      # ✅ 啟用 (CRC 環境為 Removed)
    trainingoperator:
      managementState: Managed      # ✅ 啟用 (CRC 環境為 Removed)
    kueue:
      managementState: Managed      # ✅ GPU 排程佇列
    modelregistry:
      managementState: Managed
```

### 6.2 Notebook Image 配置

生產環境建議預建 **GPU 專屬映像**：

| 映像名稱 | 內含框架 | GPU 支援 |
|:---|:---|:---|
| `CUDA Data Science` | Python 3.11, CUDA 12.4, pandas, scikit-learn | ✅ |
| `PyTorch` | PyTorch 2.3, CUDA 12.4, transformers | ✅ |
| `TensorFlow` | TensorFlow 2.16, CUDA 12.4 | ✅ |
| `Code Server (VS Code)` | VS Code Server, Python, CUDA | ✅ |
| `Habana (Gaudi)` | Intel Gaudi SDK | Gaudi 專用 |

### 6.3 Workbench GPU 配額配置

```yaml
# 允許使用者在 Notebook 中申請 GPU
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota-team-a
  namespace: ds-project-team-a
spec:
  hard:
    requests.nvidia.com/gpu: "8"    # 最多 8 GPU
    requests.cpu: "64"
    requests.memory: "256Gi"
    persistentvolumeclaims: "10"
    pods: "20"
```

---

## 7. 儲存架構設計

### 7.1 儲存需求分析

| 用途 | 存取模式 | 容量需求 | I/O 特性 | 建議方案 |
|:---|:---|:---|:---|:---|
| **模型訓練數據集** | ReadOnlyMany (ROX) | 10~100 TB | 高吞吐量、循序讀取 | Lustre / GPFS / BeeGFS |
| **模型 Checkpoint** | ReadWriteOnce (RWO) | 1~10 TB/job | 突發大檔寫入 | NVMe Local Scratch |
| **Notebook 工作目錄** | ReadWriteOnce (RWO) | 50~200 GB/user | 隨機 I/O | Ceph RBD |
| **模型儲存/Registry** | ReadWriteMany (RWX) | 5~50 TB | 低 I/O、長期保存 | S3 (MinIO/Ceph RGW) |
| **Pipeline Artifacts** | ReadWriteMany (RWX) | 1~5 TB | 中等 I/O | Ceph FS / NFS |

### 7.2 StorageClass 配置

```yaml
# 高效能 NVMe 本地儲存 (訓練 Scratch)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nvme-scratch
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer  # 確保 Pod 和 PV 在同一節點
reclaimPolicy: Delete

---
# Ceph RBD (Notebook 持久化)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: openshift-storage.rbd.csi.ceph.com
parameters:
  clusterID: openshift-storage
  pool: ocs-storagecluster-cephblockpool
  imageFormat: "2"
  imageFeatures: layering
reclaimPolicy: Delete
allowVolumeExpansion: true

---
# S3 Compatible (MinIO) for Model Registry
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: model-store
  namespace: rhoai-model-registries
spec:
  bucketName: rhoai-models
  storageClassName: openshift-storage.noobaa.io
```

### 7.3 資料流架構

```
                    ┌──────────────────┐
                    │   Object Store   │
                    │  (S3 / MinIO)    │
                    │  模型存放、Pipeline │
                    └────────┬─────────┘
                             │ S3 API
         ┌───────────────────┼──────────────────────┐
         ▼                   ▼                      ▼
    ┌──────────┐      ┌──────────┐          ┌──────────────┐
    │  Model   │      │ Pipeline │          │   Jupyter     │
    │  Serving │      │  Server  │          │  Notebooks    │
    │ (KServe) │      │  (KFP)   │          │  (Workbench)  │
    └──────────┘      └──────────┘          └──────┬───────┘
                                                    │
                                            ┌───────▼────────┐
                                            │  Ceph RBD PVC  │
                                            │ (用戶工作目錄)  │
                                            └────────────────┘
         ┌─────────────────────────────────────────┐
         │     Shared Dataset (Lustre / GPFS)      │
         │   /mnt/datasets  (ReadOnlyMany)          │
         │   ImageNet, Common Crawl, Custom Data    │
         └─────────────────────────────────────────┘
```

---

## 8. 多租戶與 GPU 排程策略

### 8.1 Kueue 排程系統

RHOAI 使用 **Kueue** 做為 GPU 工作負載的排程與佇列系統：

```yaml
# ClusterQueue - 定義叢集級 GPU 資源池
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: gpu-cluster-queue
spec:
  namespaceSelector: {}
  resourceGroups:
    - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
      flavors:
        - name: a100-80gb
          resources:
            - name: "nvidia.com/gpu"
              nominalQuota: 64       # 全叢集 64 GPU
            - name: "cpu"
              nominalQuota: 1024
            - name: "memory"
              nominalQuota: "8Ti"

---
# LocalQueue - 團隊級配額
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: team-a-queue
  namespace: ds-project-team-a
spec:
  clusterQueue: gpu-cluster-queue

---
# ResourceFlavor - A100 GPU 定義
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: a100-80gb
spec:
  nodeLabels:
    nvidia.com/gpu.product: "A100-SXM4-80GB"
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
```

### 8.2 多團隊 GPU 分配範例

```
Total: 64 × A100
├── Team A (研究團隊):   24 GPU (37.5%)  ← 大型 LLM 訓練
├── Team B (產品團隊):   16 GPU (25.0%)  ← 模型微調 + 推論
├── Team C (資料團隊):    8 GPU (12.5%)  ← 資料處理 + 小模型
├── Shared Pool:         16 GPU (25.0%)  ← 搶佔式、任何團隊可用
```

```yaml
# Team A - 大配額
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-a-gpu-quota
  namespace: ds-project-team-a
spec:
  hard:
    requests.nvidia.com/gpu: "24"
    limits.nvidia.com/gpu: "24"

---
# Team B - 中配額
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-b-gpu-quota
  namespace: ds-project-team-b
spec:
  hard:
    requests.nvidia.com/gpu: "16"
    limits.nvidia.com/gpu: "16"
```

### 8.3 Priority Class (優先權等級)

```yaml
# 高優先權 - 生產推論服務
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: production-serving
value: 1000000
globalDefault: false
description: "生產環境推論服務，不可被搶佔"
preemptionPolicy: Never

---
# 中優先權 - 訓練任務
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: training-job
value: 100000
globalDefault: false
description: "訓練任務，可搶佔低優先權工作"
preemptionPolicy: PreemptLowerPriority

---
# 低優先權 - Jupyter Notebook (可被搶佔)
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: interactive-notebook
value: 10000
globalDefault: true
description: "互動式 Notebook，可被訓練任務搶佔"
preemptionPolicy: PreemptLowerPriority
```

---

## 9. 監控與告警

### 9.1 DCGM (Data Center GPU Manager) 指標

GPU Operator 會自動部署 **DCGM Exporter**，將 GPU 指標暴露給 Prometheus：

| 指標名稱 | 說明 | 告警閾值 |
|:---|:---|:---|
| `DCGM_FI_DEV_GPU_UTIL` | GPU 核心使用率 (%) | < 10% 持續 30min (閒置告警) |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | 記憶體頻寬使用率 (%) | > 95% (瓶頸告警) |
| `DCGM_FI_DEV_FB_USED` | 已使用的 GPU 記憶體 (MB) | > 95% (OOM 風險) |
| `DCGM_FI_DEV_GPU_TEMP` | GPU 溫度 (°C) | > 85°C (過熱告警) |
| `DCGM_FI_DEV_POWER_USAGE` | GPU 功耗 (W) | > 350W (接近 400W TDP) |
| `DCGM_FI_DEV_XID_ERRORS` | GPU XID 錯誤 | > 0 (硬體異常告警) |

### 9.2 Grafana Dashboard

```bash
# 匯入 NVIDIA DCGM Dashboard (ID: 12239)
# OpenShift 已內建 Grafana，透過 ConfigMap 匯入

oc create configmap gpu-dashboard \
  --from-file=gpu-dashboard.json \
  -n openshift-monitoring
```

### 9.3 PrometheusRule 告警範例

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-alerts
  namespace: openshift-monitoring
spec:
  groups:
    - name: gpu.rules
      rules:
        - alert: GPUHighTemperature
          expr: DCGM_FI_DEV_GPU_TEMP > 85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "GPU 溫度過高 {{ $labels.gpu }} on {{ $labels.node }}"
            description: "GPU 溫度 {{ $value }}°C，超過 85°C 閾值"

        - alert: GPUMemoryAlmostFull
          expr: DCGM_FI_DEV_FB_USED / DCGM_FI_DEV_FB_TOTAL > 0.95
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "GPU 記憶體即將耗盡"

        - alert: GPUIdleWaste
          expr: DCGM_FI_DEV_GPU_UTIL < 10
          for: 30m
          labels:
            severity: info
          annotations:
            summary: "GPU 閒置超過 30 分鐘，可能造成資源浪費"

        - alert: GPUXidError
          expr: DCGM_FI_DEV_XID_ERRORS > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "GPU 硬體錯誤 (XID {{ $value }})"
            description: "節點 {{ $labels.node }} 偵測到 GPU XID 錯誤，可能需要更換 GPU"
```

---

## 10. 與 CRC 環境的差異對照

| 項目 | CRC (開發環境) | 生產 GPU 叢集 |
|:---|:---|:---|
| **節點數** | 1 (單節點) | 11+ (3 Master + 8 GPU Worker) |
| **CPU** | 8 vCPU | 1,024+ 核 |
| **RAM** | 20 GiB | 8+ TiB |
| **GPU** | ❌ 無 | 64 × A100 80GB |
| **磁碟** | 31 GiB | 120+ TB NVMe |
| **網路** | NAT (單一) | 3 層分離 (管理/儲存/GPU) |
| **儲存** | hostpath-provisioner | Ceph + NVMe + S3 |
| **DSC 組件** | 精簡 (5 組件) | 全功能 (10+ 組件) |
| **KServe** | Removed | ✅ Managed |
| **Ray** | Removed | ✅ Managed |
| **Kueue** | 不需要 | ✅ GPU 排程佇列 |
| **MIG** | N/A | 可選 (Jupyter 共享 GPU) |
| **監控** | 基礎 | DCGM + Prometheus + Grafana |
| **多租戶** | 單一使用者 | ResourceQuota + Priority + Kueue |
| **安裝方式** | `crc start` | UPI / Agent-Based |
| **除錯重點** | 記憶體/磁碟不足 | GPU 排程、NCCL 通訊、驅動相容 |

---

## 附錄 A: 生產環境除錯指令速查

```bash
# === GPU 狀態 ===
# 查看所有節點的 GPU 資源
oc get nodes -o custom-columns=\
  NAME:.metadata.name,\
  GPU:.status.allocatable.'nvidia\.com/gpu',\
  CPU:.status.allocatable.cpu,\
  MEM:.status.allocatable.memory

# 查看 GPU 使用率 (需先 exec 進 DCGM Pod)
oc exec -n nvidia-gpu-operator \
  $(oc get pod -n nvidia-gpu-operator -l app=nvidia-dcgm-exporter -o name | head -1) \
  -- dcgmi dmon -e 155,150,204 -c 5

# === 排程問題 ===
# 為什麼 Pod 沒排上？
oc describe pod <gpu-pod> | grep -A 10 Events

# 查看 Kueue 佇列狀態
oc get workloads -A
oc get clusterqueues
oc get localqueues -A

# === GPU Operator 健康 ===
oc get pods -n nvidia-gpu-operator
oc get clusterpolicy -o yaml

# === 分散式訓練除錯 ===
# NCCL 除錯 (設定環境變數)
env:
  - name: NCCL_DEBUG
    value: INFO
  - name: NCCL_DEBUG_SUBSYS
    value: INIT,NET
```

---

## 附錄 B: 成本估算參考

| 項目 | 單位成本 (USD) | 數量 | 總計 |
|:---|:---|:---|:---|
| NVIDIA A100 80GB SXM4 | ~$15,000 | 64 | $960,000 |
| GPU 伺服器 (DGX A100 等級) | ~$200,000 | 8 | $1,600,000 |
| Control Plane 伺服器 | ~$15,000 | 3 | $45,000 |
| Login Node | ~$5,000 | 1 | $5,000 |
| InfiniBand HDR Switch | ~$30,000 | 2 | $60,000 |
| 儲存系統 (100 TB) | ~$100,000 | 1 | $100,000 |
| Red Hat OpenShift 授權 | ~$5,000/node/yr | 11 | $55,000/yr |
| NVIDIA AI Enterprise 授權 | ~$4,500/GPU/yr | 64 | $288,000/yr |
| **硬體總計** | | | **~$2,770,000** |
| **年度軟體授權** | | | **~$343,000/yr** |

> 💡 **替代方案**：如果預算有限，可考慮 A100 40GB 版本 (約半價) 或 NVIDIA L40S (推論優化、更低功耗)。

---

> 📌 **下一步**：完成此規劃後，建議先在 CRC 環境驗證 RHOAI 的操作流程 (Module 01-07)，確認團隊熟悉操作後，再正式部署生產 GPU 叢集。
