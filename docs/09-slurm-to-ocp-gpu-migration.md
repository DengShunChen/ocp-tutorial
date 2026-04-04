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

### 1.1 背後的邏輯（為什麼這樣設計）

- **為什麼不能「在 SLURM 節點上疊一層 kubelet」**  
  SLURM 與 Kubernetes 都會把 GPU 當成獨占資源：前者透過 cgroup／GRES 綁程序，後者透過 device plugin 把整張卡配給某個容器。兩套排程器若共存，會出現「雙方都認為 GPU 空閒」的競態，導致 OOM、驅動錯誤或靜默損壞。**正規做法是單一控制平面**：要嘛整台機器給 SLURM，要嘛重灌成 RHCOS 給 OCP。

- **為什麼文件走 UPI 裸機**  
  IPI 需要雲端或特定 bare metal 自動化（如紅帽輔助安裝）；許多既有 SLURM 機房只有 **BMC + 手動／PXE 裝機**，沒有對應的 Machine API 供應商。**UPI** 把「誰在什麼時候開機、餵哪一份 Ignition」交給你，與機房流程對齊；代價是你要自己維護 **DNS、LB、CSR**。

- **為什麼後面一定要 GPU Operator +（通常）RHOAI**  
  裸 RHCOS 上的 NVIDIA 驅動若手動裝在節點上，升級與節點替換會變成不可重現的「雪花機」。**GPU Operator** 把驅動、device plugin、DCGM 等收成 **DaemonSet／Operand**，版本與叢集生命週期一致。**RHOAI** 則把 Notebook、Pipeline、模型服務與 RBAC 疊在標準 OCP 之上，對應 SLURM 環境裡「登入節點 + 自架 Jupyter + 排隊腳本」的組合。

---

## 2. SLURM 與 OCP 概念對照

| SLURM | OCP / Kubernetes | 邏輯差異（精簡） |
|:---|:---|:---|
| `sbatch` / `srun` | `Job` / `Pod` / Training CRD / Pipeline | SLURM 以 **批次工作**為中心；K8s 以 **長生命週期控制迴圈**（ReplicaSet、Job controller）驅動 Pod。訓練可對應 `Job`（跑完即停）或 Operator 管理的 CRD（狀態機較豐富）。 |
| Partition、QOS | `Namespace`、`ResourceQuota`、**Kueue** | Partition 是 **排程器內建**的佇列；K8s 預設只有 **節點篩選 + 優先級**，多租戶公平性常靠 **ResourceQuota + LimitRange**，進階 GPU 佇列則靠 **Kueue**（或自訂 scheduler）。 |
| 登入節點 | **Bastion** + `oc` + **Console** | Bastion **不參與**叢集排程，只放安裝產物與管理憑證；實際「使用者入口」多半是 **Console／Route／OAuth**。 |
| NFS／Lustre 掛載 | **CSI** + **PVC** | 傳統 HPC 在節點上 `mount`；K8s 要求 **儲存聲明式**：Pod 透過 **PVC → PV（由 CSI 動態建）** 掛載，便於遷移與多副本，**不在**每台 Worker 手寫 `fstab`（除少數基礎設施用 LocalVolume）。 |
| GRES GPU | `nvidia.com/gpu`（**GPU Operator**） | SLURM 的 GRES 由 **slurm.conf + 節點狀態**描述；K8s 的 `nvidia.com/gpu` 來自 **Device Plugin 回報**，必須與節點上實際驅動／MIG 切分一致。 |

### 2.1 排程心智模型

- **SLURM**：使用者提交 → `slurmctld` 決定節點與時間片 → `slurmd` 在運算節點執行。  
- **OCP**：使用者建立 Pod spec → **kube-scheduler** 找滿足 requests/affinity/taint 的節點 → **kubelet** 起容器；GPU 數量由 **Extended Resource** 與 device plugin 共同保證「不超賣」（在正確配置下）。

---

## 3. 遷移策略與注意事項

- **建議**：新裝一組 OCP（或先拿幾台空機），與 SLURM **並行**，驗證後再關 SLURM。
- **離線叢集**：需要 **mirror registry** + `ImageContentSourcePolicy`，步驟遠比下文長，請改走官方 *Disconnected* 與 **Agent-based Installer** 手冊。
- 以下假設：**可連 Red Hat Registry／OperatorHub**（或已事先建好 mirror 並在 `install-config` 內設定好）。

### 3.1 為什麼建議並行而非「一刀切換」

- **風險隔離**：OCP 安裝、GPU Operator、RHOAI 任一環節出問題時，生產訓練仍可留在 SLURM。  
- **資料與網路對齊**：並行期可驗證 **同一套 NFS／物件儲存** 在 PVC 路徑下的 IO 行為，避免切換當天才發現權限或效能問題。  
- **人員與流程**：使用者需適應 `oc`、映像建置、Pipeline；並行可邊跑邊遷移工作負載。

### 3.2 離線／鏡像為何大幅改變步驟

- 連網安裝時，節點與 Operator 直接拉 **registry.redhat.io**、**quay.io** 等。  
- 離線時**沒有**這條路徑，必須預先 **mirror 映像**、在叢集上宣告 **ImageContentSourcePolicy／ImageDigestMirrorSet**（依版本），且 `install-config` 要指向內部 registry。**Agent-based** 則把「發現節點、套 Ignition」的流程包成另一套安裝體驗，與本文的純 UPI 指令順序不同，故需改讀官方斷線手冊。

---

## 4. 總覽：你會經過哪些步驟

**依賴關係（因果鏈）**：Bastion 與工具（0～1）→ **DNS 與 LB 必須在節點開機前可用**（2～3），否則節點無法完成 bootstrap／註冊。接著 **Ignition 決定第一台機器變成什麼角色**（4～5）。**Bootstrap 完成**代表暫時控制平面已可移交；**install-complete** 代表正式 API／etcd 拓撲就緒（6）。之後才是 **叢集內** 能力：**GPU 可調度資源**（7）→ **PVC 可綁定**（8）→ **RHOAI 控制面**（9）→ **使用者工作負載驗證**（10）。

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

### 5.4 這一步在整體中的角色

- **Bootstrap 為單次性**：它只在安裝期提供臨時控制平面與資源，安裝完成後應下線，否則可能分流 API／machine-config 流量，造成詭異錯誤。  
- **Control Plane 與 Worker 分離**：etcd 與 API 對延遲與穩定度敏感，**不建議**在 master 上跑訓練；GPU 應放在 **worker**（或專用機種），與 SLURM 裡「登入／管理節點不跑大 job」的慣例一致。  
- **API_VIP / INGRESS_VIP**：在部分拓撲會寫進安裝設定或 LB 設定，用來讓節點與客戶端**穩定指向**「虛擬入口」，而非某一台實體 IP（實體機故障時 VIP 漂到別台）。

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

### 6.5 邏輯說明

- **`openshift-install` 的角色**：讀取 `install-config`，產生 **Kubernetes 清單（manifests）**，再編成 **Ignition**（給 RHCOS 的第一啟動配置）。它**不**替你裝作業系統；裝機仍由你透過 ISO／PXE 完成。  
- **版本對齊**：`oc` 與 `openshift-install` **小版本應一致**，否則可能出現 API 版本不相容或誤用已棄用旗標。  
- **pull secret**：讓叢集節點與後續 Operator 能**認證** Red Hat Registry；沒有它，安裝期拉取 RHCOS／核心映像會失敗。  
- **SSH 公鑰**：寫入 Ignition 後，可用對應私鑰以 `core` 使用者登入 RHCOS 節點除錯（生產上仍應配合稽核與金鑰輪替）。

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

### 7.1 為什麼這三組名稱缺一不可

- **`api.*`**：Kubernetes API Server 對外（及管理端 `oc`）的 DNS 名稱；憑證的 **SAN** 通常包含此名稱，解析錯誤會導致 TLS 驗證失敗或節點無法加入。  
- **`api-int.*`**：叢集**內部**元件（節點、內部 Operator）存取 API 時使用；常與 `api` 同 VIP，也可能分開，**以你環境的官方拓撲為準**。內外部拆開時，錯誤配置會出現「節點 NotReady 但從 Bastion 看 API 正常」這類現象。  
- **`*.apps.*`**：OpenShift **Router（Ingress）** 的萬用字元；Console、RHOAI Dashboard、Route 都依賴此解析。若只對 `api` 正確而 `apps` 錯誤，會出現 **叢集已裝好但網頁打不開**。

### 7.2 常見錯誤

- TTL 過長導致改 VIP 後舊 IP 快取很久。  
- 內部 DNS 與外部 DNS **分裂視圖**不一致（節點用的 resolver 解析到錯誤目標）。

---

## 8. 第 3 步：負載平衡器後端

你必須依官方 **bare metal UPI** 手冊設定 LB，後端大致為：

| 前端（VIP） | 後端節點 | 埠 |
|:---|:---|:---|
| API | 3 × Control Plane | **6443** |
| Machine Config Server | 3 × Control Plane | **22623** |
| Ingress（HTTP/HTTPS） | Worker（或官方允許的節點） | **80 / 443** |
| Bootstrap（僅安裝期） | 1 × Bootstrap | 6443、22623（完成後移除） |

實際是否要 **Keepalived + HAProxy**、還是 F5／硬體 LB，依你機房標準。**在各節點依上文第 5 步開機安裝 RHCOS 前，LB 必須已通**，否則節點無法完成註冊。

### 8.1 各埠在安裝流程中的用途

| 埠 | 誰連誰 | 用途 |
|:---|:---|:---|
| **6443** | 節點、使用者、`openshift-install` → API | Kubernetes API；bootstrap 階段先由 bootstrap 節點提供，之後由三台 master 後端分擔。 |
| **22623** | Worker／master → Machine Config Server | 節點拉取 **machine-config**（Ignition 合併後的節點設定），錯誤時常見 **無法完成節點配置** 或 CSR 卡死。 |
| **80 / 443** | 使用者 → Ingress | 應用與 Console；**安裝後期**才強依賴，但若你早期就用 Console 驗證，也需正確。 |

### 8.2 Bootstrap 在 LB 上的生命週期

安裝初期，**6443 / 22623 的後端必須包含 Bootstrap**（與 master 並列，依官方圖示調整權重）。當 `wait-for bootstrap-complete` 成功後，應**從池內移除 Bootstrap**，只留三台 master，避免流量打到已下線的節點。

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

### 9.1.1 `install-config` 關鍵欄位的邏輯

- **`compute.replicas: 0`（UPI 典型）**：代表 **不由安裝程式自動建立雲端 Worker**。實體 Worker 是你稍後用 `worker.ign` 裝機再加入；若這裡填了正數，在 `platform: none` 下常與實際供應方式不符，造成 **Machine 一直 Pending**。  
- **`machineNetwork`**：須涵蓋節點實際 IP 所在網段，供安裝程式產生正確的 **節點與網路物件**；與 SLURM 時代的「管理網」通常一致。  
- **`networkType: OVNKubernetes`**：OpenShift 預設 CNI；Pod 與 Service CIDR 勿與機房既有網段衝突，否則會出現**路由黑洞**或 DNS 異常。  
- **`pullSecret` / `sshKey`**：前者給叢集拉映像；後者寫入各節點，供緊急除錯與部分自動化。

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

### 9.4 manifests → Ignition 的資料流

1. **`create manifests`**：把 `install-config` 展開成多份 YAML（叢集版本、網路、Operator 清單種子等）。**進階調整**（Proxy、自訂 CA、MTU）通常在此步之後改檔，再進下一步。  
2. **`create ignition-configs`**：將 manifests **編譯**成三份二進位／壓縮的 Ignition，分別對應 **bootstrap / master / worker** 的**首次開機行為**。  
3. **為何常見刪除 master Machine 清單**：UPI 下 master 也是你手動裝的，若留下會讓 **Machine API 以為**還要再建 master，產生幽靈物件；是否刪除**以該版官方 UPI 文件為準**。

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

### 10.1 Ignition 與 `coreos-install` 在做什麼

- **Ignition** 在**第一次開機**時執行：寫入檔案、建立 systemd 單元、設定網路與 **kubelet 註冊所需憑證路徑** 等；之後由 **Machine Config Operator** 接手滾動更新。  
- **三份檔不可混用**：`bootstrap.ign` 內含安裝期專用邏輯；`master.ign` / `worker.ign` 決定節點加入叢集時的**角色與標籤**。餵錯檔會導致節點無法加入或角色錯亂。  
- **`--copy-network`**：把安裝當下的網路設定帶進磁碟系統，避免第一次開機沒網路而拉不到後續設定（實際參數以你使用的安裝文件為準）。

### 10.2 與 SLURM 節點重灌的差異

原 SLURM 運算節點上的 **本地 OS、模組、掛載** 會被 RHCOS **整碟取代**；之後**唯一**受支援的變更路徑是 **MachineConfig、Operator、CSI**，而非 SSH 進去手改驅動（除 troubleshooting）。

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

### 11.5 兩段 `wait-for` 的意義

| 指令 | 通過時代表 |
|:---|:---|
| `wait-for bootstrap-complete` | Bootstrap 節點已把**暫時控制平面**與關鍵資源推到正式 master；可安全**關閉並從 LB 移除** bootstrap。 |
| `wait-for install-complete` | 叢集安裝程式認定**安裝成功**（含預設 Operator 就緒度等條件，依版本而定）；此時可取得 **kubeadmin** 與 **kubeconfig**。 |

### 11.6 為什麼會有一堆 CSR

手動加入的節點會向 API 申請 **kubelet 客戶端／伺服器憑證**。預設流程下，這些 CSR 需管理員 **approve**（或透過自動化核准）。若長期不批，節點會維持 **NotReady** 或無法報告狀態。核准前應**確認**申請來自你擁有的機器，避免惡意節點加入。

### 11.7 常見卡點

- DNS／LB 在安裝中途被改錯。  
- 節點時間與 NTP 嚴重漂移導致憑證無效。  
- 防火牆擋住 **6443 / 22623** 或 registry。

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

### 12.4 元件順序與互動邏輯

1. **自訂 label（如 `node-role.kubernetes.io/gpu-worker`）**  
   方便你用 `nodeSelector`／`affinity` 把 GPU 工作負載**只排到**這批節點；與 SLURM 的 partition 類似，但是 **宣告式** 的。

2. **Taint `nvidia.com/gpu=present:NoSchedule`**  
   **邏輯**：沒有 GPU 需求的 Pod 預設不會被排上來，避免一般服務吃掉 GPU 機的 CPU／記憶體。GPU Pod 必須帶對應 **toleration**（見第 15 步）。若你希望「整叢集只有 GPU worker、無一般服務」，也可評估是否省略 taint，改純靠 nodeSelector。

3. **NFD（Node Feature Discovery）**  
   掃描 CPU／PCI／內核模組等，為節點加上**標準化 feature label**。GPU Operator 可依這些 label **選擇性**在對的節點上部署 operand（實際規則以 Operator 版本與 `ClusterPolicy` 為準），避免在無卡節點上無意義地跑驅動安裝。

4. **GPU Operator**  
   在節點上協調 **驅動（常為 containerized）**、**device plugin**、**DCGM** 等。Device plugin 向 **kubelet** 註冊 `nvidia.com/gpu`，scheduler 才會在 `resources.limits` 裡**計數** GPU；**describe node** 的 `Allocatable` 出現數量即代表鏈路大致打通。

### 12.5 `installPlanApproval: Manual` 的用途

生產環境可強制**人工審閱** Operator 將要升級到的 CSV 版本與權限，避免自動升到未驗證版本。核准後 Subscription 才會繼續安裝 CRD 與 Operand。

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

### 13.1 為什麼 RHOAI 強依賴「預設 StorageClass」

許多上層元件（Notebook、Pipeline 成品、模型儲存）會建立 **PVC** 但不指定 `storageClassName`，此時會用 **cluster 預設**。若未設定，PVC 會卡在 **Pending**，Dashboard 與工作負載會表現為「無法建立磁碟」。

### 13.2 ODF 與 NFS 的取捨（概念）

| 路徑 | 邏輯 |
|:---|:---|
| **ODF** | 叢集內自建分散式儲存（常搭配本地碟），適合希望**儲存與叢集生命週期綁定**、且要 **RWO／RWX** 等完整模式的團隊。 |
| **NFS CSI** | 後端沿用現有檔案伺服器，遷移成本低；需注意 **效能、鎖行為、備份** 與 SLURM 時代是否同一套 export。 |

無論哪種，Pod 看到的都是 **掛載點由 CSI 注入**；**不要**依賴在 RHCOS 上為每個 Worker 手動 mount 同一路徑，否則節點替換時狀態會不一致。

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

### 14.4 Operator 與 DataScienceCluster 的關係

- **Subscription → InstallPlan → CSV**：宣告「要安裝哪個 Operator、哪個 channel」；CSV 成功後，Operator **Pod** 才會在對應 namespace 跑起來，並在 API 內註冊 **CRD**（如 `DataScienceCluster`）。  
- **DataScienceCluster（DSC）**：是 RHOAI 的**總開關** CR，描述要啟用哪些子元件（Workbench、Pipelines、KServe、ModelMesh、Kueue 等）。**`.status.phase`** 變成 `Ready` 代表控制面自洽；個別元件仍可能依 GPU／儲存／網路設定而需額外除錯。  
- **與 GPU 步驟的順序**：實務上常先完成 **第 7～8 步**（節點可分配 GPU、PVC 可綁定），再裝 RHOAI，可避免 DSC 子元件因資源不足而長時間 **Degraded**。

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

### 15.1 從 `oc apply` 到「Test PASSED」的鏈路

1. **Scheduler** 讀取 Pod 的 `resources.limits.nvidia.com/gpu` 與 **tolerations**，篩出帶有足夠 **Allocatable GPU** 且能容忍 taint 的節點。  
2. **kubelet** 啟動容器前，由 **Container Runtime** 透過 **NVIDIA container toolkit**（通常由 GPU Operator 鋪好）注入 GPU 裝置節點。  
3. 若 **Pending**，依序查：`oc describe pod` 的 Events（資源不足、taint、映像拉取失敗）、節點 `Allocatable`、命名空間 **ResourceQuota**、以及 ** SCC**（OpenShift 安全上下文）是否允許該映像權限。

### 15.2 與 `sbatch` 的對照

SLURM 下你會指定 `--gres=gpu:1`；在 OCP 中等價於 **Pod spec 的 limits** 加上正確 **toleration**／**nodeSelector**。兩者都表達「這個工作單元需要一塊 GPU」，但 K8s **不**幫你排隊等別人釋放 GPU（除非再加 **Kueue** 或自訂佇列）；預設是「有資源就排，沒有就 Pending」。

---

## 16.（可選）高速網、Kueue、工作負載遷移

- **InfiniBand / RoCE、Multus、SR-IOV、GPUDirect**：步驟長且依機型差異大，請在 GPU Operator 穩定後，依 [08 第 3 節](08-gpu-cluster-planning.md#3-網路架構設計) 與官方 *Secondary networks*、*SR-IOV* 文件實作。  
- **Kueue / ResourceQuota**：範例 YAML 見 [08 第 8 節](08-gpu-cluster-planning.md#8-多租戶與-gpu-排程策略)。  
- **`sbatch` → 容器**：把環境寫進 `Containerfile`，訓練改 `Job` 或 Training Operator／Ray；互動改 RHOAI Workbench。見 [03-user-management.md](03-user-management.md) 做專案與 RBAC。

### 16.1 為什麼這些主題放在「可選」

- **高速網（IB／RoCE、Multus、SR-IOV）**：不影響「GPU 能不能被看到」，但強影響 **多節點訓練／NCCL** 的穩定度與效能；設定與韌體、交換器、網卡驅動綁在一起，無法在通用步驟裡一次寫死。  
- **Kueue**：補上 Kubernetes **預設排程器沒有的「佇列與公平性」**；若你的 SLURM 重度依賴 partition／QOS，遷移後應優先設計 **ResourceFlavor、ClusterQueue、LocalQueue** 與專案對應關係。  
- **工作負載遷移**：重點不是語法一對一翻譯，而是 **映像化**（相依套件、CUDA 版本）、**資料路徑**（NFS → PVC）、**分散式啟動方式**（srun → MPI Operator／Ray／TorchX 等）三條線同時對齊。

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

### 17.1.1 清單背後的邏輯（為什麼這個順序驗證）

建議大致**由下而上**：網路名稱與 LB（節點能否註冊）→ 節點 **Ready**（算力與儲存附著點存在）→ **Allocatable GPU**（裝置鏈路）→ **預設 StorageClass**（上層應用能否要磁碟）→ **DSC Ready**（RHOAI 控制面）→ **GPU Pod**（端到端使用者路徑）。若在某一層失敗，**不必**急著往後跳；例如沒有 `nvidia.com/gpu` 時先回到第 7 步與節點 `describe`，而不是重裝 RHOAI。

### 17.2 官方文件（請選你的 OCP 小版本）

- [OpenShift Container Platform 文件](https://docs.redhat.com/en/documentation/openshift_container_platform/) → *Installing on bare metal* → *User-provisioned infrastructure*  
- [Red Hat OpenShift AI](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed)  
- 本 repo：[08-gpu-cluster-planning.md](08-gpu-cluster-planning.md)、[02-install-rhoai.md](02-install-rhoai.md)

---

> **你問的「從無到有」**：依 **第 5～15 節**順序執行，即完成「空機 → OCP 叢集 → GPU 驅動與排程 → 儲存 → RHOAI → 一支 GPU Pod 驗證」。SLURM 遷移的差異僅在 **Worker 來源**（原 SLURM 節點重灌 RHCOS）與 **資料／網路**需對齊第 8、16 節。
