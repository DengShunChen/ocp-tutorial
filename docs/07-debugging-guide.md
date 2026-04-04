# Module 07: Troubleshooting and Debugging

在本章中，我們將學習如何針對 OpenShift AI (RHOAI) 平台進行除錯與疑難排解。當 Workbench 無法啟動、Pipeline 失敗或模型部署出錯時，你可以依照以下標準程序進行診斷。

## 1. 基礎診斷工作流 (Standard Diagnostic Workflow)

當發生問題時，請遵循以下步驟：

1.  **檢查 Pod 狀態**：查看相關 Namespace 中的 Pod 是否正常執行。
    ```bash
    oc get pods -n <namespace>
    ```
2.  **查看錯誤事件 (Events)**：這是找出為什麼 Pod 無法啟動（如 `FailedScheduling`）最快的方法。
    ```bash
    oc describe pod <pod-name> -n <namespace>
    ```
3.  **檢查節點資源**：確認叢集是否有足夠的 CPU 和記憶體。
    ```bash
    oc describe node <node-name>
    # 或使用 top 指令 (需安裝 Metrics Server)
    oc adm top nodes
    ```
4.  **讀取運算日誌 (Logs)**：如果 Pod 已啟動但出現錯誤，請查看日誌。
    ```bash
    oc logs <pod-name> -n <namespace>
    ```

---

## 2. 案例分析：Insufficient Memory (記憶體不足)

這是 OpenShift Local (CRC) 環境中最常遇到的問題。

### 現象
- Workbench 狀態一直顯示 `Pending`。
- Pod Events 顯示：`0/1 nodes are available: 1 Insufficient memory.`

### 原因
RHOAI 預設開啟了許多進階組件（KServe, Ray, TrustyAI 等），這些組件的 **Resource Requests** 總和超過了單機節點的負荷。

### 解決方法：精簡化架構
修改 `DataScienceCluster` 並設定 `managementState: Removed` 來停用不需要的組件。

```yaml
# manifests/02-datasciencecluster.yaml
spec:
  components:
    kserve:
      managementState: Removed
    ray:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    trustyai:
      managementState: Removed
```

---

## 3. 案例分析：Node Eviction (節點驅逐 - 硬碟不足)

### 現象
- Pod 狀態顯示 `Failed`。
- `Reason` 為 `Evicted`。
- `Message` 顯示 `The node was low on resource: ephemeral-storage.`。

### 原因
OpenShift Local (CRC) 預設磁碟空間有限。當硬碟剩餘空間低於閾值（通常是 10% 或 15%）時，Kubelet 會為了保護核心系統而「驅逐」使用者 Pod。這通常是因為暫存環境 (`emptyDir`)、日誌或容器映像層過大。

### 解決方法
1.  **清理映像檔**：執行 `oc adm prune images` 刪除未使用的映像檔。
2.  **檢查 PVC 使用率**：確保不是因為某個 Pod 持續寫入大量暫存檔。
3.  **增加 CRC 磁碟**：在啟動 CRC 前執行 `crc config set disk-size <size_in_gb>`（需要刪除並重新建立實例）。

---

## 4. 案例分析：FailedMount (儲存驅動未就緒)

### 現象
- Pod 卡在 `ContainerCreating`。
- `oc describe pod` 顯示 `FailedMount`。
- 訊息包含 `driver name <name> not found in the list of registered CSI drivers`。

### 原因
在 CRC 中，本地磁碟是由 `hostpath-provisioner` 提供。如果負責該功能的 Pod 正處於 `Restarting` 或 `Creating` 狀態，所有掛載該磁碟的任務都會失敗。

### 解決方法
1.  **檢查驅動 Pod**: `oc get pods -A | grep hostpath-provisioner`。
2.  **等待就緒**: 確認 Pod 狀態是否為 `4/4` (或該驅動對應的 Ready 數)。
3.  **重新觸發**: 有時刪除掛掉的驅動 Pod 讓其重啟即可解決。

---

## 5. 案例分析：Image Pulling Latency (映像檔下載延遲)

### 現象
- Pod 狀態顯示 `ContainerCreating`。
- `oc describe pod` 的 Events 最後一行為 `Normal: Pulling image`。

### 原因
OpenShift 基礎設施所使用的映像檔 (如 CSI Driver 或 Operator Image) 通常較大。在網路速度受限或磁碟 I/O 頻繁時，下載過程可能長達數分鐘。這在 CRC 這種本機單機環境尤其明顯。

### 解決方法
- **判斷標誌**: 只要 Reason 是 `Normal` 且 Message 是 `Pulling image`，就代表系統正在正常運作中，只需 **等待**。
- **異常判斷**: 如果經過 5 分鐘以上仍未完成，或 Reason 變成 `Warning: Failed` 或 `ErrImagePull`，才需要介入檢查網路連線或 Pull Secret。

---

## 6. 案例分析：Node Taints 連鎖反應 (節點污點)

### 現象
- 新的 Pod 一直卡在 `Pending` 狀態。
- `oc describe pod` 的 Events 顯示 `0/1 nodes are available: 1 node(s) had untolerated taint(s)`。
- 進一步檢查節點 (`oc describe node crc`) 發現 `DiskPressure: True`，且有 `node.kubernetes.io/disk-pressure` 標記。

### 診斷思路與真因
這是一個經典的**連鎖反應 (Chain Reaction)**：
1. 某個基礎組件 (如 CSI Driver) 下載了巨大的映像檔，導致節點硬碟空間到達極限 (通常是 > 85%)。
2. Kubelet 觸發警報，將節點標示為 **DiskPressure (硬碟壓力)**，並打上「禁止調度 (NoSchedule)」的污點 (Taint)。
3. 當使用者的 Jupyter Pod 嘗試啟動時，因為它無法「容忍 (Tolerate)」這個污點，就被拒絕進入節點，永遠卡在 `Pending`。

### 解決方法
這需要執行這三個步驟：
1. **大掃除 (對治硬碟)**：執行 `oc adm prune images --confirm` 強制清除未使用的映像層與系統快取。
2. **驗證消腫 (等待警報解除)**：靜待 1-3 分鐘，持續觀察 `oc describe node crc | grep -A 5 "Conditions:"`，確保 `DiskPressure` 恢復為 `False`。
3. **強制重啟 (對治 Pod)**：因為舊的 Pod 已經卡在 Pending，最快的做法是直接刪除它 (`oc delete pod <pod-name> -n <namespace>`)，讓 OpenShift 在乾淨的環境下重新分配一個新的 Pod。

---

## 7. 檢查 Operator 健康狀況

如果 RHOAI Dashboard 打不開，或者組件沒有按預期建立，請檢查 Operator 的狀態。

- **檢查 Operator Pods**:
  ```bash
  oc get pods -n redhat-ods-operator
  ```
- **檢查 DataScienceCluster (DSC) 狀態**:
  ```bash
  oc get dsc default-dsc -o yaml
  ```
  查看 `status.phase` 是否為 `Ready`，以及 `status.conditions` 中的錯誤訊息。

---

## 8. 常見錯誤代碼與對策

| 錯誤訊息 | 可能原因 | 解決對策 |
| :--- | :--- | :--- |
| `ImagePullBackOff` | 映像檔路徑錯誤或權限不足 | 檢查 `ImageStream` 或 `registry` 認證 |
| `CrashLoopBackOff` | 程式碼報錯或環境變數缺失 | 查看 `oc logs <pod>` |
| `Pending` (Generic) | 資源不足或 PVC 無法綁定 | 檢查 `oc describe pod` 及 `oc get pvc` |
| `FailedScheduling` | 資源不足 (CPU/GPU/RAM) | 減少資源請求或增加節點/關閉組件 |
| `Evicted` | 節點壓力 (Disk/Memory/PID) | 檢查 `ephemeral-storage` 或 Node Conditions |
| `... had untolerated taint` | 節點發生異常或壓力過大 | 檢查 `oc describe node` 的 Conditions |

---

## 9. 使用者權限問題

如果使用者登入後看不到某些功能：
1.  確認使用者是否在 `rhoai-users` 或 `rhoai-admins` 群組中。
2.  確認 `Data Science Project` 的權限設定是否包含該使用者。

```bash
# 檢查群組成員
oc get groups rhoai-users -o yaml
```

---

## 10. 案例分析：OpenShift Local (CRC) 本機 kubeconfig 空白

### 現象

- `crc start` 末尾出現：`Failed to update kubeconfig file: Not able to get user CA: admin user is not found in kubeconfig ~/.crc/machines/crc/kubeconfig`。
- `crc status` 顯示 **OpenShift: Unreachable**，但 **CRC VM: Running**。
- `crcd.log` 可能出現：`cannot get OpenShift status: invalid configuration: no configuration has been provided`。
- `~/.crc/machines/crc/kubeconfig` 內容異常：`clusters`、`contexts`、`users` 為 `null`（空殼）。

### 真因（精要）

問題在 **Mac 上的 kubeconfig 檔損壞或被清空**，不是叢集一定掛了。CRC 在 VM 內仍使用 **`/opt/kubeconfig`** 透過 SSH 操作；若該檔正常，API 與 `oc get nodes` 在 VM 內可成功，但本機因沒有有效 `admin` user 無法合併／更新 kubeconfig，`crc status` 與 `crc generate-kubeconfig` 都會讀到空檔而失敗。

### 快速修復（無需 `crc delete`）

VM 能 SSH 時，從 VM 拉回官方 kubeconfig 覆寫本機路徑：

```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i ~/.crc/machines/crc/id_ed25519 -p 2222 core@127.0.0.1 \
  'sudo cat /opt/kubeconfig' > ~/.crc/machines/crc/kubeconfig
chmod 600 ~/.crc/machines/crc/kubeconfig
crc status
```

預期 `OpenShift` 變回 **Running**。

### 日誌與指令備忘

- 目前 CRC CLI **沒有** `crc logs`；改看本機檔案：
  - `~/.crc/crc.log`
  - `~/.crc/crcd.log`
  - `~/.crc/machines/crc/vfkit.log`
- 需要更細輸出時：`crc start --log-level debug`（或全域 `crc --log-level debug …`）。

### 相關線索（可並行追）

- `crc.log` 裡若出現 **ClusterVersion** 訊息如 `image-registry is not available`，屬叢集內 Operator 問題，與「本機 kubeconfig 空白」分開處理（`oc get co image-registry` 等）。
- `crcd.log` 若出現 **crc-admin-helper** `input rejected`，可能與本機 `/etc/hosts` 或 helper 權限有關；仍應先確認 `api.crc.testing` 是否解析到 `127.0.0.1`。

### 仍無法恢復時

依序考慮：`crc stop` 後再 `crc start`；仍失敗則 `crc delete` 後重建實例（會清空 VM 狀態）。

---

> [!TIP]
> 在開發環境中，**「先求有再求好」**。先關閉不需要的組件，確保核心功能（如 Jupyter）能跑起來，再逐步啟用其他功能。
