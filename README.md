# OCP AI 運算平台教學材料

> 📌 **目標**：學習如何在 OpenShift Container Platform 上建立企業級 AI/ML 運算平台，並提供給一般使用者進行 AI 計算。

## 🗂️ 目錄結構

```
OCP/
├── index.html                    # 教學入口網站（在瀏覽器開啟）
├── README.md                     # 本說明文件
│
├── docs/                         # 詳細教學文件
│   ├── 01-prerequisites.md       # 模組 01：環境準備
│   ├── 02-install-rhoai.md       # 模組 02：安裝 RHOAI Operator
│   ├── 03-user-management.md     # 模組 03：使用者管理
│   ├── 04-jupyter-notebooks.md   # 模組 04：Jupyter Notebook 工作環境
│   ├── 05-pipelines.md           # 模組 05：Data Science Pipelines
│   └── 06-model-serving.md       # 模組 06：模型部署與推論服務
│
├── manifests/                    # OCP YAML 設定檔
│   ├── 01-rhoai-subscription.yaml      # RHOAI Operator 訂閱
│   ├── 02-datasciencecluster.yaml      # DataScienceCluster 設定
│   └── 03-user-management.yaml        # 使用者/群組/專案/配額
│
└── scripts/
    └── quick-setup.sh            # 快速安裝腳本
```

---

## 🚀 快速開始

### 前置需求
```bash
# 確認 CRC 正在運行
crc status

# 設定 oc CLI 環境
eval $(crc oc-env)

# 以 admin 登入
oc login -u kubeadmin https://api.crc.testing:6443
```

### 一鍵快速安裝
```bash
cd /Users/chendengshun/OCP
chmod +x scripts/quick-setup.sh
bash scripts/quick-setup.sh
```

### 開啟教學網站
```bash
open index.html
```

---

## 📚 學習路徑

| 模組 | 主題 | 建議時間 |
|------|------|---------|
| [01](docs/01-prerequisites.md) | 環境準備與前置設定 | 30 分鐘 |
| [02](docs/02-install-rhoai.md) | 安裝 RHOAI Operator | 60 分鐘 |
| [03](docs/03-user-management.md) | 使用者管理與權限設定 | 45 分鐘 |
| [04](docs/04-jupyter-notebooks.md) | Jupyter Notebook 工作環境 | 60 分鐘 |
| [05](docs/05-pipelines.md) | Data Science Pipelines | 90 分鐘 |
| [06](docs/06-model-serving.md) | 模型部署與推論服務 | 90 分鐘 |

**估計總學習時間：7-8 小時**

---

## 🔑 常用指令速查

```bash
# 環境
eval $(crc oc-env)
oc login -u kubeadmin https://api.crc.testing:6443

# 查看 RHOAI Pod 狀態
oc get pods -n redhat-ods-applications

# 取得 RHOAI Dashboard URL
oc get route rhods-dashboard -n redhat-ods-applications \
  -o jsonpath='https://{.spec.host}'

# 查看 DataScienceCluster 狀態
oc get datasciencecluster

# 查看使用者 Notebook
oc get notebooks -A

# 查看模型服務
oc get inferenceservice -A
```

---

## 📖 參考資源

- [Red Hat OpenShift AI 官方文件](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed)
- [OpenShift Local (CRC) 文件](https://access.redhat.com/documentation/en-us/red_hat_openshift_local)
- [AI on OpenShift 社群](https://ai-on-openshift.io)
- [RHOAI GitHub](https://github.com/opendatahub-io)

---

*教學材料製作日期：2026-04-02 | 適用版本：RHOAI 2.x / OCP 4.14+*
