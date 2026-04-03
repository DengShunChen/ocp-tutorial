# 模組 02：安裝 Red Hat OpenShift AI (RHOAI) Operator

## 學習目標
- 透過 OperatorHub 安裝 RHOAI Operator
- 建立 DataScienceCluster 自定義資源
- 驗證所有核心元件正常啟動
- 取得並存取 RHOAI Dashboard

---

## 2.1 RHOAI 安裝架構

RHOAI 安裝後會建立以下 Namespace：

| Namespace | 用途 |
|-----------|------|
| `redhat-ods-operator` | RHOAI Operator 本體 |
| `redhat-ods-applications` | RHOAI 應用程式（Dashboard、Notebook、KServe 等）|
| `redhat-ods-monitoring` | Prometheus 監控元件 |
| `rhods-notebooks` | 使用者 Jupyter Notebook 預設 namespace |

---

## 2.2 方法一：透過 Web Console 安裝（推薦新手）

1. 開啟 OCP Console：`https://console-openshift-console.apps-crc.testing`
2. 使用 `kubeadmin` 帳號登入
3. 左側選單點選 **Operators → OperatorHub**
4. 搜尋 `Red Hat OpenShift AI`
5. 點選 **Install**
6. 設定：
   - Update channel: `stable` 或 `fast`
   - Installed Namespace: `redhat-ods-operator`（建議預設）
7. 點選 **Install** 開始安裝

---

## 2.3 方法二：透過 CLI 安裝（推薦自動化/進階）

建立以下 YAML 檔案並套用：

```bash
# 套用 manifests 目錄中的設定
oc apply -f manifests/01-rhoai-subscription.yaml

# 等待 Operator 安裝完成
oc wait --for=condition=Installed csv \
  -l operators.coreos.com/rhods-operator.redhat-ods-operator \
  -n redhat-ods-operator \
  --timeout=300s

# 或手動監看狀態
watch oc get csv -n redhat-ods-operator
```

---

## 2.4 建立 DataScienceCluster

安裝 Operator 後，必須建立 `DataScienceCluster` 資源來啟動 RHOAI 服務：

```bash
# 套用 DataScienceCluster 設定
oc apply -f manifests/02-datasciencecluster.yaml

# 監看安裝進度（等待 Phase 變為 Ready）
watch oc get datasciencecluster
```

### DataScienceCluster 狀態說明
| Phase | 意義 |
|-------|------|
| `Progressing` | 元件正在安裝中 |
| `Ready` | 所有元件已就緒 ✅ |
| `Degraded` | 某些元件有問題，需要排查 ❌ |

---

## 2.5 驗證安裝

```bash
# 1. 確認所有 RHOAI Pod 運行正常
oc get pods -n redhat-ods-applications

# 預期輸出中應包含（Pod 名稱可能略有差異）：
# rhods-dashboard-xxx            Running
# notebook-controller-xxx        Running
# modelmesh-controller-xxx       Running
# data-science-pipelines-xxx     Running

# 2. 確認 DataScienceCluster 狀態
oc get datasciencecluster -o yaml | grep -A 5 "conditions:"

# 3. 取得 RHOAI Dashboard URL
DASHBOARD_URL=$(oc get route rhods-dashboard \
  -n redhat-ods-applications \
  -o jsonpath='https://{.spec.host}')
echo "RHOAI Dashboard: $DASHBOARD_URL"

# 4. 在瀏覽器開啟
open $DASHBOARD_URL
```

---

## 2.6 初次登入 RHOAI Dashboard

1. 開啟 Dashboard URL（例如：`https://rhods-dashboard-redhat-ods-applications.apps-crc.testing`）
2. 點選 **Log in with OpenShift**
3. 使用 `kubeadmin` 帳號登入
4. 授權 `rhods-dashboard` 存取您的帳號
5. 您將看到 RHOAI Dashboard 首頁

### Dashboard 主要功能區塊
- **Data Science Projects** — 建立和管理 AI 專案
- **Model Serving** — 部署和管理模型服務
- **Data Science Pipelines** — 管理 ML 工作流程
- **Accelerators** — GPU 設定和 Toleration

---

## 2.7 進階設定：啟用/停用特定元件

若需要客製化 DataScienceCluster，可修改元件的 `managementState`：

```yaml
# 可用值：Managed (啟用)、Removed (停用)
spec:
  components:
    dashboard:
      managementState: Managed      # RHOAI Dashboard
    workbenches:
      managementState: Managed      # Jupyter Notebooks
    datasciencepipelines:
      managementState: Managed      # Kubeflow Pipelines
    kserve:
      managementState: Managed      # KServe 單模型服務
    modelmeshserving:
      managementState: Managed      # ModelMesh 多模型服務
    trustyai:
      managementState: Managed      # TrustyAI 可信度工具
    ray:
      managementState: Managed      # Ray 分散式訓練
    trainingoperator:
      managementState: Managed      # Kubeflow Training Operator
```

---

## 2.8 常見安裝問題

### 問題：Pod 一直 Pending
```bash
# 查看 Pod 事件
oc describe pod <pod-name> -n redhat-ods-applications | grep -A 10 Events

# 常見原因：資源不足
oc describe node | grep -A 5 "Allocatable"
```

### 問題：Dashboard 無法存取
```bash
# 確認 Route 存在
oc get route -n redhat-ods-applications

# 確認 CRC DNS 正常
nslookup rhods-dashboard-redhat-ods-applications.apps-crc.testing
```

### 問題：CRC 資源不足導致 Pod Evicted
```bash
# 增加 CRC 資源後重建
crc stop && crc start --cpus 8 --memory 20480
```

---

## ✅ 模組 02 完成確認清單

- [ ] RHOAI Operator 安裝完成（CSV Phase: Succeeded）
- [ ] DataScienceCluster Phase: Ready
- [ ] `oc get pods -n redhat-ods-applications` 所有 Pod 為 Running
- [ ] 可成功登入 RHOAI Dashboard

**下一步** → [模組 03：使用者管理](03-user-management.md)
