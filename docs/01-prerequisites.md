# 模組 01：環境準備與前置設定

## 學習目標
- 確認 CRC 叢集正常運作
- 掌握基本 `oc` CLI 操作
- 設定必要的儲存與網路資源
- 了解 RHOAI 安裝所需的系統需求

---

## 1.1 系統需求確認

### 最低配置（開發/學習用 CRC）
| 資源 | 最低需求 | 建議需求 |
|------|---------|---------|
| CPU | 8 vCPU | 16 vCPU |
| RAM | 16 GB | 32 GB |
| 磁碟 | 50 GB | 150 GB |
| OS | macOS 12+ / RHEL 8+ | — |

### 生產環境 OCP 叢集
| 節點類型 | 數量 | 規格 |
|---------|------|------|
| Master | 3 | 8 vCPU / 32 GB RAM |
| Worker (CPU) | 3+ | 16 vCPU / 64 GB RAM |
| Worker (GPU) | 1+ | 8 vCPU / 64 GB RAM + NVIDIA A100/H100 |

---

## 1.2 CRC 環境設定

```bash
# 查看 CRC 狀態
crc status

# 啟動 CRC（若未啟動）
crc start --cpus 8 --memory 16384 --disk-size 100

# 設定環境變數（每次開新 terminal 都需要執行）
eval $(crc oc-env)

# 或加入 ~/.zshrc 自動載入
echo 'eval $(crc oc-env)' >> ~/.zshrc
source ~/.zshrc
```

### 取得登入資訊
```bash
# 查看 kubeadmin 密碼
crc console --credentials

# 範例輸出：
# To login as a regular user, run 'oc login -u developer -p developer https://api.crc.testing:6443'.
# To login as an admin, run 'oc login -u kubeadmin -p <PASSWORD> https://api.crc.testing:6443'.

# 以 admin 身份登入
oc login -u kubeadmin https://api.crc.testing:6443
```

---

## 1.3 確認叢集狀態

```bash
# 確認節點狀態（全部應為 Ready）
oc get nodes

# 確認 StorageClass（RHOAI 需要 default StorageClass）
oc get storageclass

# CRC 預設 StorageClass 為 crc-csi-hostpath-provisioner
# 若未設為 default，執行以下指令
oc patch storageclass crc-csi-hostpath-provisioner \
  -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'

# 確認 Operator Hub 可用
oc get operatorhub cluster -o jsonpath='{.spec}'
```

---

## 1.4 安裝必要工具

```bash
# 安裝 Helm (用於部署 MinIO)
brew install helm

# 安裝 jq (JSON 處理）
brew install jq

# 確認 oc 版本
oc version
# 建議：Client Version 4.14+

# 安裝 Python 工具（用於 Kubeflow Pipelines SDK）
pip install kfp==2.7.0
pip install kubernetes
pip install boto3  # 用於 S3/MinIO 操作
```

---

## 1.5 調整 CRC 資源配置（RHOAI 需要較多資源）

> ⚠️ **重要**：RHOAI 需要至少 14 GB RAM。請先停止 CRC 並重新設定。

```bash
# 停止 CRC
crc stop

# 重新啟動並分配更多資源
crc start --cpus 8 --memory 16384 --disk-size 100

# 確認資源分配
crc config view
```

---

## 1.6 常見問題排除

### 問題：`oc` 指令找不到
```bash
# 確認 PATH 設定
eval $(crc oc-env)
which oc
```

### 問題：StorageClass 不存在
```bash
# 查詢可用的 StorageClass
oc get sc

# 手動標記為 default
oc annotate storageclass <sc-name> \
  storageclass.kubernetes.io/is-default-class=true
```

### 問題：CRC 記憶體不足
```bash
crc stop
crc delete  # 注意：這會刪除當前 CRC 環境！
crc start --cpus 8 --memory 20480
```

---

## ✅ 模組 01 完成確認清單

- [ ] `crc status` 顯示 Running
- [ ] `oc get nodes` 所有節點為 Ready
- [ ] `oc get storageclass` 有 default StorageClass
- [ ] `oc whoami` 顯示 kubeadmin
- [ ] Python 工具安裝完成

**下一步** → [模組 02：安裝 RHOAI Operator](02-install-rhoai.md)
