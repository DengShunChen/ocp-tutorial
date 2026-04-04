# 模組 09：從 SLURM GPU 叢集遷移至 OpenShift (OCP) — 安裝與遷移指南

> **前提**：你已有一台或多台在 **SLURM** 下運作的 GPU 叢集，目標改以 **OpenShift Container Platform (OCP)** 承載 GPU，並用 **Red Hat OpenShift AI (RHOAI)** 提供 Notebook／Pipeline／模型服務。  
> **配套**：[08-gpu-cluster-planning.md](08-gpu-cluster-planning.md)（架構、GPU Operator、Kueue、網路細節）。

---

## 目錄

**概念速覽**

1. [這份文件解決什麼問題](#1-這份文件解決什麼問題)
2. [SLURM 與 OCP 概念對照](#2-slurm-與-ocp-概念對照)
3. [遷移策略與注意事項](#3-遷移策略與注意事項)

**手把手：從無到有（建議照順序做）**

4. [總覽：你會經過哪些步驟](#4-總覽你會經過哪些步驟)
5. [第 0 步：演練假設與事前準備](#5-第-0-步演練假設與事前準備)
6. [第 1 步：準備 Bastion 與安裝工具](#6-第-1-步準備-bastion-與安裝工具)
7. [第 2 步：DNS 記錄（一定要對）](#7-第-2-步dns-記錄一定要對)
8. [第 3 步：負載平衡器後端](#8-第-3-步負載平衡器後端)
9. [第 4 步：建立 install-config 與 Ignition](#9-第-4-步建立-install-config-與-ignition)
10. [第 5 步：替各節點安裝 RHCOS（Bootstrap／Master／Worker）](#10-第-5-步替各節點安裝-rhcosbootstrapmasterworker)
11. [第 6 步：等待安裝完成並讓 Worker 加入](#11-第-6-步等待安裝完成並讓-worker-加入)
12. [第 7 步：GPU Worker 標籤、Taint、安裝 NFD 與 GPU Operator](#12-第-7-步gpu-worker-標籤taint安裝-nfd-與-gpu-operator)
13. [第 8 步：儲存與預設 StorageClass](#13-第-8-步儲存與預設-storageclass)
14. [第 9 步：安裝 RHOAI 與 DataScienceCluster](#14-第-9-步安裝-rhoai-與-datasciencecluster)
15. [第 10 步：跑一支 GPU 測試 Pod（從無到有最後一哩）](#15-第-10-步跑一支-gpu-測試-pod從無到有最後一哩)
16. [（可選）高速網、Kueue、工作負載遷移](#16可選高速網kueue工作負載遷移)
17. [驗證清單與官方文件](#17-驗證清單與官方文件)

---

## 1. 這份文件解決什麼問題

- **不是**在現有 SLURM 節點上「加裝」OCP Worker：實務上節點要改成 **RHCOS**，由 OCP 管理；**同一台機器同時給 SLURM 與 kubelet 排 GPU 強烈不建議**。
- **是**一條 **UPI 裸機常見路徑** 的逐步操作：從準備 Bastion → 產生 Ignition → 裝 RHCOS → 叢集就緒 → GPU Operator → RHOAI → 驗證 GPU Pod。
- **版本以你訂閱的 OCP 為準**：下列 YAML／指令結構適用 4.12+ 慣例；欄位名稱若與你下載的 `openshift-install` 說明不符，**以官方安裝手冊該版本為準**。

---

## 2. SLURM 與 OCP 概念對照

| SLURM | OCP / Kubernetes |
|:---|:---|
| `sbatch` / `srun` | `Job` / `Pod` / Training CRD / Pipeline |
| Partition、QOS | `Namespace`、`ResourceQuota`、**Kueue** |
| 登入節點 | **Bastion** + `oc` + **Console** |
| NFS／Lustre 掛載 | **CSI** + **PVC** |
| GRES GPU | `nvidia.com/gpu`（**GPU Operator**） |

---

## 3. 遷移策略與注意事項

- **建議**：新裝一組 OCP（或先拿幾台空機），與 SLURM **並行**，驗證後再關 SLURM。
- **離線叢集**：需要 **mirror registry** + `ImageContentSourcePolicy`，步驟遠比下文長，請改走官方 *Disconnected* 與 **Agent-based Installer** 手冊。
- 以下假設：**可連 Red Hat Registry／OperatorHub**（或已事先建好 mirror 並在 `install-config` 內設定好）。

---

## 4. 總覽：你會經過哪些步驟

| 順序 | 你做什麼 | 結果 |
|:---:|:---|:---|
| 0～1 | 準備機器與 Bastion、下載 `openshift-install` / `oc` | 可在 Bastion 上執行安裝程式 |
| 2～3 | DNS + Load Balancer | API／Ingress 網址可被叢集與使用者解析 |
| 4 | `install-config.yaml` → `manifests` → `ignition-configs` | 得到 `bootstrap.ign`、`master.ign`、`worker.ign` |
| 5 | 各台機器安裝 **RHCOS** 並餵對應 Ignition | Bootstrap、Control Plane、Worker 開機 |
| 6 | `wait-for`、刪 Bootstrap、**核准 CSR** | `oc get nodes` 全部 **Ready** |
| 7 | Label／Taint、NFD、GPU Operator | `oc describe node` 出現 `nvidia.com/gpu` |
| 8 | ODF 或 NFS CSI、設 **default StorageClass** | PVC 可綁定 |
| 9 | RHOAI Subscription、`DataScienceCluster` | RHOAI **Ready** |
| 10 | 跑 CUDA vectoradd 或 `nvidia-smi` Pod | 確認排程與驅動正常 |

---

## 5. 第 0 步：演練假設與事前準備

### 5.1 示範用命名（請改成你的環境）

在 Bastion 上建議先設環境變數，後續指令可直接貼：

```bash
# --- 請全部改成你的真實值 ---
export CLUSTER_NAME="ocp-gpu"
export BASE_DOMAIN="lab.example.com"           # 你已擁有的 DNS zone
export API_VIP="192.168.10.5"                  # 可選：部分拓撲需要，依官方 bare metal 文件
export INGRESS_VIP="192.168.10.6"             # 可選
# 完整 API 會是 api.${CLUSTER_NAME}.${BASE_DOMAIN}
```

### 5.2 你需要準備好的機器（最小生產形狀）

| 角色 | 數量 | 說明 |
|:---|:---:|:---|
| **Bastion** | 1 | RHEL 9 等，放 `openshift-install`、`oc`、Ignition 檔、HTTP 服務（若用 HTTP 餵 Ignition） |
| **Bootstrap** | 1 | 安裝完成後**刪除** |
| **Control Plane** | 3 | etcd + API，**不要**在上面跑 GPU 訓練 |
| **Worker（GPU）** | ≥1 | 原 SLURM 運算節點**重灌**成 RHCOS 後擔任 |

> 單節點叢集（SNO）與「3 master 可調度工作負載」屬進階拓撲，此文以 **3 control + N worker** 為主流程。

### 5.3 網路與防火牆

Bastion 要能 SSH 到各節點 BMC／終端；安裝過程中節點需依官方文件存取 **registry**、**時間同步（chrony）**、以及 LB 上的 **6443、22623、80、443** 等。細節請對照 [OpenShift 安裝網路需求](https://docs.redhat.com/en/documentation/openshift_container_platform/) 內 *Installing on bare metal* 一節。

---

## 6. 第 1 步：準備 Bastion 與安裝工具

### 6.1 建立工作目錄

```bash
mkdir -p ~/ocp-install/${CLUSTER_NAME}
cd ~/ocp-install/${CLUSTER_NAME}
```

### 6.2 取得 `openshift-install` 與 `oc`

1. 登入 [Red Hat Hybrid Cloud Console](https://console.redhat.com/) → 下載與你 **訂閱相符**的 **OpenShift 安裝程式**與 **OpenShift CLI**（版本務必一致）。  
2. 解壓縮後：

```bash
chmod +x openshift-install oc
sudo mv openshift-install oc /usr/local/bin/   # 或放在 ~/bin 並加入 PATH

openshift-install version
oc version --client
```

### 6.3 取得 pull secret

在 Hybrid Cloud Console → **OpenShift Cluster Manager** → *Download pull secret*，存成檔案：

```bash
# 檔案內容為 JSON，後面會整段貼進 install-config
ls -l ~/pull-secret.json
```

### 6.4（建議）準備 SSH 金鑰

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/ocp_cluster_ed25519
```

---

## 7. 第 2 步：DNS 記錄（一定要對）

以下為 **最常見**需要解析的名稱（將 IP 改成你的 **Load Balancer VIP** 或實際拓撲；若用手動 LB，通常指向 LB 而非單一 master）。

| 類型 | 名稱 | 指向 |
|:---|:---|:---|
| A | `api.${CLUSTER_NAME}.${BASE_DOMAIN}` | API Load Balancer VIP |
| A | `api-int.${CLUSTER_NAME}.${BASE_DOMAIN}` | 內部 API（常同 VIP 或內網 LB，依文件） |
| A | `*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}` | Ingress Load Balancer VIP（萬用字元） |

驗證（在 Bastion 上）：

```bash
dig +short api.${CLUSTER_NAME}.${BASE_DOMAIN}
dig +short test.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
```

---

## 8. 第 3 步：負載平衡器後端

你必須依官方 **bare metal UPI** 手冊設定 LB，後端大致為：

| 前端（VIP） | 後端節點 | 埠 |
|:---|:---|:---|
| API | 3 × Control Plane | **6443** |
| Machine Config Server | 3 × Control Plane | **22623** |
| Ingress（HTTP/HTTPS） | Worker（或官方允許的節點） | **80 / 443** |
| Bootstrap（僅安裝期） | 1 × Bootstrap | 6443、22623（完成後移除） |

實際是否要 **Keepalived + HAProxy**、還是 F5／硬體 LB，依你機房標準。**在執行第 10 步開機前，LB 必須已通**，否則節點無法完成註冊。

---

## 9. 第 4 步：建立 install-config 與 Ignition

### 9.1 產生 `install-config.yaml`

**做法 A（互動精靈，適合第一次）**

```bash
cd ~/ocp-install/${CLUSTER_NAME}
mkdir install
openshift-install create install-config --dir install
```

依提示輸入：平台類型、base domain、cluster name、pull secret、SSH key 等。

**做法 B（自行建立檔案）** — 下列為 **UPI、`platform: none`** 常見骨架；**machine CIDR、副本數**請依你的網路與拓撲調整，並與官方範例交叉檢查：

```yaml
# 儲存為 install/install-config.yaml
apiVersion: v1
baseDomain: lab.example.com          # 改成 ${BASE_DOMAIN}
metadata:
  name: ocp-gpu                       # 改成 ${CLUSTER_NAME}
compute:
  - hyperthreading: Enabled
    name: worker
    replicas: 0                       # UPI：先 0，Worker 手動裝機再加入
controlPlane:
  hyperthreading: Enabled
  name: master
  replicas: 3
networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 192.168.10.0/24           # 改成你節點所在 L2/L3 網段
  networkType: OVNKubernetes
  serviceNetwork:
    - cidr: 172.30.0.0/16
platform:
  none: {}
pullSecret: '{"auths":{...}}'        # 整段貼上 pull-secret.json 內容（單行 JSON）
sshKey: |
  ssh-ed25519 AAAA... your-comment    # cat ~/.ssh/ocp_cluster_ed25519.pub
```

> 若你的環境使用 **bare metal IPI 輔助**（如 Virtual media + BMC），`platform` 區塊會是 `baremetal:` 而非 `none`，請勿硬套本節。

### 9.2 產生 manifests 與 Ignition

```bash
cd ~/ocp-install/${CLUSTER_NAME}

# 若你要改網路 MTU、Proxy、mirror 等，在這一步之後改 manifests，再下一步
openshift-install create manifests --dir install

# （可選）若不想由 Machine API 管 master，可刪除 control plane machineset
# rm -f install/openshift/99_openshift-cluster-api_master-machines-*.yaml

openshift-install create ignition-configs --dir install
```

完成後應有：

```bash
ls -1 install/*.ign
# bootstrap.ign
# master.ign
# worker.ign
```

把這三個檔案**安全地**送到安裝媒體可讀的位置：

- 常見：**Bastion 上跑小型 HTTP**（僅安裝期、內網、防火牆限縮），安裝程式用 URL 抓取；或  
- **Red Hat CoreOS ISO + 嵌入 ignition**（依官方 *User-provisioned* 步驟）。

### 9.3（重要）備份 cluster 目錄內機密

```bash
# install 目錄內含 auth/kubeadmin-password、kubeconfig — 權限等同叢集 root
chmod -R go-rwx install/auth
```

---

## 10. 第 5 步：替各節點安裝 RHCOS（Bootstrap／Master／Worker）

此步沒有單一指令適用所有機房；**請以你取得的 OCP 版本所附「在裸機安裝 RHCOS」章節為主**。概念順序如下：

1. **Bootstrap 節點**：開機 RHCOS ISO，執行 `coreos-install`（或等效流程），指定 **`bootstrap.ign`**。  
2. **三個 Master**：各用 **`master.ign`**。  
3. **Worker（含未來 GPU 節點）**：各用 **`worker.ign`**。

典型 `coreos-install` 形式（**範例**，裝置名與 URL 請改你的）：

```bash
# 在 RHCOS live 環境的 shell（非 Bastion！）
sudo coreos-install install /dev/sda \
  --copy-network \
  --ignition-url http://192.168.10.2:8080/bootstrap.ign
sudo reboot
```

對 **GPU 機器**，BIOS 請開啟 **Above 4G decoding、Resizable BAR（若建議）**，並關閉會干擾 PCIe 的選項（依伺服器廠牌說明）。

---

## 11. 第 6 步：等待安裝完成並讓 Worker 加入

**全程在 Bastion、且 `install` 目錄未刪**的前提下執行。

### 11.1 監控 Bootstrap

```bash
cd ~/ocp-install/${CLUSTER_NAME}
openshift-install wait-for bootstrap-complete --dir install --log-level=info
```

成功後依官方說明 **關機並從 LB 移除 Bootstrap**，避免誤導流量。

### 11.2 等待叢集安裝完成

```bash
openshift-install wait-for install-complete --dir install --log-level=info
```

完成後會提示 Console URL；管理員密碼在：

```bash
cat install/auth/kubeadmin-password
```

### 11.3 設定 `oc` 並登入

```bash
export KUBECONFIG=~/ocp-install/${CLUSTER_NAME}/install/auth/kubeconfig
oc whoami
oc get nodes
```

### 11.4 若 Worker 卡在 `NotReady`：核准 CSR

UPI 手動加入的 Worker 常出現待簽憑證：

```bash
oc get csr
```

對 `Pending` 的逐一核准，或（確認環境安全、無未授權節點時）批次：

```bash
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | \
  xargs --no-run-if-empty oc adm certificate approve
```

重複直到：

```bash
oc get nodes
# 全部 Ready，且 Worker 角色正確
```

---

## 12. 第 7 步：GPU Worker 標籤、Taint、安裝 NFD 與 GPU Operator

假設 GPU 節點名稱為 `gpu-worker-01`（`oc get nodes` 看實際名稱）。

### 12.1 標籤與 Taint

```bash
NODE=gpu-worker-01   # 改成你的節點名

oc label node "$NODE" node-role.kubernetes.io/gpu-worker="" --overwrite
oc label node "$NODE" cluster.example.com/node-type=gpu --overwrite

oc adm taint nodes "$NODE" nvidia.com/gpu=present:NoSchedule --overwrite
```

多節點可用迴圈或腳本對每一台 GPU worker 重複執行。

### 12.2 安裝 Node Feature Discovery（NFD）

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nfd
  namespace: openshift-nfd
spec:
  targetNamespaces:
    - openshift-nfd
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

建立 NFD 實例（名稱與 API 版本請以 Operator 頁面為準；下列與 [08](08-gpu-cluster-planning.md) 一致）：

```bash
oc apply -f - <<'EOF'
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    image: registry.redhat.io/openshift4/ose-node-feature-discovery
EOF
```

### 12.3 安裝 NVIDIA GPU Operator

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
    - nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: v24.6
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
EOF
```

若 `installPlanApproval: Manual`，需核准 InstallPlan：

```bash
oc get installplan -n nvidia-gpu-operator
# 將 <installplan-name> 換成上一行輸出的名稱
oc patch installplan <installplan-name> -n nvidia-gpu-operator \
  -p '{"spec":{"approved":true}}' --type merge
```

接著建立 **ClusterPolicy**（驅動版本、RDMA、MIG 等請依硬體與 [08 第 5.2 節](08-gpu-cluster-planning.md#52-clusterpolicy-配置) 調整）。最小可行思路：**先**用 Operator 預設或文件建議的 `ClusterPolicy`，**再**開 RDMA／MIG。

驗證：

```bash
oc get pods -n nvidia-gpu-operator
oc describe node "$NODE" | grep -A 20 Allocatable
# 應看到 nvidia.com/gpu: <數量>
```

---

## 13. 第 8 步：儲存與預設 StorageClass

RHOAI 與多數元件需要 **可動態配置**的預設儲存。

**路徑 A：OpenShift Data Foundation（ODF）**  
在 Console：**Operators → OperatorHub** 安裝 **ODF**，依精靈建立 **StorageCluster**，完成後通常會有 `openshift-storage` 相關 StorageClass。將其一設為 default：

```bash
oc get storageclass
oc patch storageclass ocs-storagecluster-ceph-rbd \
  -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

（實際 StorageClass 名稱以 `oc get sc` 為準。）

**路徑 B：既有 NFS**  
安裝 **NFS CSI**（或檔案系統廠商 CSI），建立 **StorageClass**，再設為 default。SLURM 時代的 NFS export 可繼續當後端，但 **掛載改由 PVC 綁到 Pod**，不是再在 RHCOS 上 `/etc/fstab`。

驗證：

```bash
oc get storageclass
oc get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}'
```

---

## 14. 第 9 步：安裝 RHOAI 與 DataScienceCluster

### 14.1 用本 repo 的 Subscription（可自動核准）

```bash
cd /path/to/OCP   # 你的 git clone 路徑
oc apply -f manifests/01-rhoai-subscription.yaml
```

等待 Operator 就緒：

```bash
oc get csv -n redhat-ods-operator -w
# 直到 rhods-operator 的 PHASE = Succeeded
```

### 14.2 建立 DataScienceCluster

生產 GPU 叢集建議啟用 KServe、Ray、Training Operator、Kueue 等，**請以 [08 第 6.1 節](08-gpu-cluster-planning.md#61-datasciencecluster-全功能啟用) 的 YAML 為準**；若先求通，可暫用本 repo 精簡版再擴充：

```bash
oc apply -f manifests/02-datasciencecluster.yaml
```

監看直到 Ready：

```bash
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}{"\n"}'
watch oc get datasciencecluster
```

### 14.3 開啟 Dashboard

```bash
oc get route rhods-dashboard -n redhat-ods-applications \
  -o jsonpath='https://{.spec.host}{"\n"}'
```

---

## 15. 第 10 步：跑一支 GPU 測試 Pod（從無到有最後一哩）

建立命名空間與測試 Pod（映像來自 NVIDIA 公開 registry；若環境不能連外，請改推到你內部 mirror）：

```bash
oc new-project gpu-test --display-name="GPU Test"

oc apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
  namespace: gpu-test
spec:
  restartPolicy: OnFailure
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: cuda
      # 標籤會更新；若拉取失敗請到 https://catalog.ngc.nvidia.com 搜尋 cuda-sample vectoradd
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubi8
      resources:
        limits:
          nvidia.com/gpu: "1"
EOF
```

查看結果：

```bash
oc logs -n gpu-test cuda-vectoradd
# 預期看到 Test PASSED 或類似成功訊息

oc describe pod -n gpu-test cuda-vectoradd
# Events 不應長期 Pending（若 Pending，檢查 GPU 數量、taint、toleration、節點 Ready）
```

清理：

```bash
oc delete pod -n gpu-test cuda-vectoradd
```

---

## 16.（可選）高速網、Kueue、工作負載遷移

- **InfiniBand / RoCE、Multus、SR-IOV、GPUDirect**：步驟長且依機型差異大，請在 GPU Operator 穩定後，依 [08 第 3 節](08-gpu-cluster-planning.md#3-網路架構設計) 與官方 *Secondary networks*、*SR-IOV* 文件實作。  
- **Kueue / ResourceQuota**：範例 YAML 見 [08 第 8 節](08-gpu-cluster-planning.md#8-多租戶與-gpu-排程策略)。  
- **`sbatch` → 容器**：把環境寫進 `Containerfile`，訓練改 `Job` 或 Training Operator／Ray；互動改 RHOAI Workbench。見 [03-user-management.md](03-user-management.md) 做專案與 RBAC。

---

## 17. 驗證清單與官方文件

### 17.1 從無到有建議勾選

- [ ] DNS：`api` / `api-int` / `*.apps` 解析正確  
- [ ] LB：6443、22623、80、443 在安裝期行為符合官方圖示  
- [ ] `wait-for bootstrap-complete` 成功，Bootstrap 已下線  
- [ ] `wait-for install-complete` 成功  
- [ ] 所有 Worker **Ready**，CSR 已處理  
- [ ] GPU 節點 **Allocatable** 含 `nvidia.com/gpu`  
- [ ] 有 **default StorageClass**  
- [ ] `DataScienceCluster` **Ready**  
- [ ] `cuda-vectoradd`（或等效）**成功完成**  

### 17.2 官方文件（請選你的 OCP 小版本）

- [OpenShift Container Platform 文件](https://docs.redhat.com/en/documentation/openshift_container_platform/) → *Installing on bare metal* → *User-provisioned infrastructure*  
- [Red Hat OpenShift AI](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed)  
- 本 repo：[08-gpu-cluster-planning.md](08-gpu-cluster-planning.md)、[02-install-rhoai.md](02-install-rhoai.md)

---

> **你問的「從無到有」**：依 **第 5～15 節**順序執行，即完成「空機 → OCP 叢集 → GPU 驅動與排程 → 儲存 → RHOAI → 一支 GPU Pod 驗證」。SLURM 遷移的差異僅在 **Worker 來源**（原 SLURM 節點重灌 RHCOS）與 **資料／網路**需對齊第 8、16 節。
