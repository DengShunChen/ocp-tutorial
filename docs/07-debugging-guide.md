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

## 3. 檢查 Operator 健康狀況

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

## 4. 常見錯誤代碼與對策

| 錯誤訊息 | 可能原因 | 解決對策 |
| :--- | :--- | :--- |
| `ImagePullBackOff` | 映像檔路徑錯誤或權限不足 | 檢查 `ImageStream` 或 `registry` 認證 |
| `CrashLoopBackOff` | 程式碼報錯或環境變數缺失 | 查看 `oc logs <pod>` |
| `Pending` (Generic) | 資源不足或 PVC 無法綁定 | 檢查 `oc describe pod` 及 `oc get pvc` |
| `FailedScheduling` | 資源不足 (CPU/GPU/RAM) | 減少資源請求或增加節點/關閉組件 |

---

## 5. 使用者權限問題

如果使用者登入後看不到某些功能：
1.  確認使用者是否在 `rhoai-users` 或 `rhoai-admins` 群組中。
2.  確認 `Data Science Project` 的權限設定是否包含該使用者。

```bash
# 檢查群組成員
oc get groups rhoai-users -o yaml
```

---

> [!TIP]
> 在開發環境中，**「先求有再求好」**。先關閉不需要的組件，確保核心功能（如 Jupyter）能跑起來，再逐步啟用其他功能。
