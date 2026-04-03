# 模組 05：Data Science Pipelines

## 學習目標
- 了解 RHOAI Pipelines 與 Kubeflow Pipelines 的關係
- 建立可重複執行的訓練流程
- 透過 Dashboard 與 Python SDK 啟動與觀察 Pipeline
- 理解在 CRC 與正式叢集中的差異

---

## 5.1 這個模組在做什麼

Data Science Pipelines 是 RHOAI 中用來編排機器學習流程的元件。你可以把資料前處理、模型訓練、評估、模型匯出拆成多個步驟，讓它們可以重跑、版本化、被團隊共享。

在這份教材裡，Pipelines 的定位是：

- 把 Notebook 中手動執行的流程，整理成可重複執行的步驟
- 讓訓練流程可觀察、可追蹤、可重跑
- 為後續的模型部署建立一致的產出物

---

## 5.2 前置條件

開始前請先確認：

- `default-dsc` 已是 `Ready`
- RHOAI Dashboard 可正常登入
- 您至少有一個可用的 Data Science Project，例如 `weather-ml-project`
- Workbench 已可正常啟動

可用以下指令快速確認：

```bash
oc get datasciencecluster default-dsc
oc get pods -n redhat-ods-applications
oc get notebooks -n weather-ml-project
```

---

## 5.3 透過 Dashboard 觀看 Pipelines 元件

1. 登入 RHOAI Dashboard
2. 進入您的 Data Science Project
3. 點選 **Pipelines**
4. 確認頁面可正常載入 Pipeline Runs / Pipeline Servers

如果看不到 Pipelines 頁面，通常代表：

- `datasciencepipelines` 元件尚未 Ready
- 叢集資源不足，相關 Pod 尚未成功啟動
- 使用者沒有對應專案權限

可先檢查：

```bash
oc get pods -n redhat-ods-applications | grep pipeline
oc describe datasciencecluster default-dsc
```

---

## 5.4 用 Python SDK 建立第一個 Pipeline

以下範例示範一個最小可執行流程：載入資料、輸出訊息、模擬訓練完成。

```python
from kfp import dsl
from kfp import compiler

@dsl.component(base_image="registry.access.redhat.com/ubi9/python-311")
def preprocess() -> str:
    return "dataset-ready"

@dsl.component(base_image="registry.access.redhat.com/ubi9/python-311")
def train(data_tag: str) -> str:
    print(f"training with {data_tag}")
    return "model-v1"

@dsl.pipeline(name="weather-training-pipeline")
def weather_training_pipeline():
    data = preprocess()
    train(data_tag=data.output)

compiler.Compiler().compile(
    pipeline_func=weather_training_pipeline,
    package_path="weather-training-pipeline.yaml",
)
```

產生後會得到 `weather-training-pipeline.yaml`，可透過 UI 上傳或在 Workbench 中繼續整合。

---

## 5.5 建議的學習流程

最穩定的練習方式是：

1. 先在 Notebook 中把訓練程式跑通
2. 再把它拆成 `preprocess`、`train`、`evaluate` 三個步驟
3. 先用小資料集驗證 Pipeline 可以完成
4. 最後才加入模型匯出與部署銜接

這樣做可以避免一開始就同時卡在資料、映像、權限和 Pipeline 設定。

---

## 5.6 CRC 與正式叢集的差異

在 CRC 上學習時，請預期以下限制：

- 資源較少，Pipeline 元件啟動會比較慢
- 長時間訓練容易因記憶體不足而失敗
- 若缺少外部物件儲存，建議先以最小範例為主

在正式叢集上，則應再補強：

- 專用 S3/MinIO 儲存
- 更清楚的命名空間與 RBAC 邊界
- CI/CD 與模型註冊整合

---

## 5.7 常見問題排除

### 問題：Pipelines 頁面打不開

```bash
oc get pods -n redhat-ods-applications
oc describe datasciencecluster default-dsc
```

先確認 `datasciencepipelines` 元件是否正常啟動。

### 問題：Pipeline 編譯失敗

```bash
pip install kfp==2.7.0
python your_pipeline.py
```

請先確認 Workbench 內已安裝 `kfp`，且元件函式都有明確輸入輸出。

### 問題：Run 啟動後卡住

通常是：

- 容器映像拉取失敗
- 權限不足
- 叢集資源不足

這時候先檢查相關 Pod 與事件最有效：

```bash
oc get pods -A
oc get events -A --sort-by=.metadata.creationTimestamp
```

---

## ✅ 模組 05 完成確認清單

- [ ] 可在 Dashboard 中看到 Pipelines 頁面
- [ ] 成功用 SDK 產生一份 Pipeline YAML
- [ ] 至少完成一次最小 Pipeline Run
- [ ] 知道如何把 Notebook 訓練流程拆成多步驟 Pipeline

**下一步** → [模組 06：模型部署與推論服務](06-model-serving.md)
