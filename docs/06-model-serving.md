# 模組 06：模型部署與推論服務

## 學習目標
- 了解 KServe 和 ModelMesh 的差異與選擇
- 部署訓練好的模型為推論 API
- 測試和驗證模型推論端點
- 設定模型監控

---

## 6.1 選擇部署方式

| 特性 | KServe (Single-Model) | ModelMesh (Multi-Model) |
|-----|----------------------|------------------------|
| 適用場景 | 大型模型、LLM | 大量中小型模型 |
| 資源隔離 | 每個模型獨立 Pod | 多模型共享 Pod |
| Scale-to-zero | ✅ 支援 | ❌ 不支援 |
| GPU 支援 | ✅ 完整支援 | ✅ 有限支援 |
| 延遲 | 較低（無冷啟動時）| 較低（常駐服務）|
| 成本效率 | 低流量模型較浪費 | 高密度部署效率高 |
| 支援框架 | sklearn, ONNX, PyTorch, TF, HuggingFace | OpenVINO, ONNX, scikit-learn, XGBoost |

---

## 6.2 準備模型（以 scikit-learn 為例）

### 在 Notebook 中訓練並匯出模型

```python
# train_model.py
import numpy as np
import joblib
from sklearn.ensemble import RandomForestClassifier
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score
import boto3
import os

# 建立範例資料集
X, y = make_classification(n_samples=1000, n_features=20, random_state=42)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2)

# 訓練模型
model = RandomForestClassifier(n_estimators=100, random_state=42)
model.fit(X_train, y_train)

# 評估
y_pred = model.predict(X_test)
accuracy = accuracy_score(y_test, y_pred)
print(f"模型準確度：{accuracy:.4f}")

# 儲存模型到本地
joblib.dump(model, '/tmp/model.joblib')
print("模型已儲存到 /tmp/model.joblib")

# 上傳到 S3/MinIO
s3 = boto3.client(
    's3',
    endpoint_url=os.environ.get('AWS_S3_ENDPOINT', 'http://minio:9000'),
    aws_access_key_id=os.environ.get('AWS_ACCESS_KEY_ID', 'minio'),
    aws_secret_access_key=os.environ.get('AWS_SECRET_ACCESS_KEY', 'minio123'),
)

# 建立 bucket（若不存在）
try:
    s3.create_bucket(Bucket='models')
except:
    pass

# 上傳模型
s3.upload_file('/tmp/model.joblib', 'models', 'rf-classifier/1/model.joblib')
print("模型已上傳到 S3!")
```

---

## 6.3 使用 ModelMesh 部署 scikit-learn 模型

```bash
# 確認 ServingRuntime 可用
oc get servingruntimes -n weather-ml-project

# 若沒有，請先在叢集內建立對應 ServingRuntime，或透過 Dashboard 啟用預設執行環境
```

```bash
# 部署 InferenceService（請依模型儲存位置調整）
cat <<'EOF' | oc apply -n weather-ml-project -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: rf-classifier
spec:
  predictor:
    model:
      modelFormat:
        name: sklearn
      runtime: mlserver-1.x
      storage:
        key: aws-connection-models
        path: rf-classifier/1/model.joblib
EOF

# 監看部署狀態
oc get inferenceservice rf-classifier -n weather-ml-project

# 等待 Ready 狀態
oc wait --for=condition=Ready inferenceservice/rf-classifier \
  -n weather-ml-project \
  --timeout=300s
```

---

## 6.4 使用 KServe 部署（單模型）

```bash
# 建立 KServe InferenceService
cat <<'EOF' | oc apply -n weather-ml-project -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: rf-classifier-kserve
spec:
  predictor:
    sklearn:
      storageUri: s3://models/rf-classifier/1/
EOF

# 查看部署狀態
oc get inferenceservice -n weather-ml-project

# 取得推論 URL
INFERENCE_URL=$(oc get inferenceservice rf-classifier-kserve \
  -n weather-ml-project \
  -o jsonpath='{.status.url}')
echo "推論 URL: $INFERENCE_URL"
```

---

## 6.5 測試推論 API

### REST API 測試

```bash
# 取得推論 Endpoint
ROUTE=$(oc get route -n istio-system -l serving.knative.openshift.io/ingressGateway \
  -o jsonpath='{.items[0].spec.host}')

# ModelMesh 推論（v2 protocol）
curl -X POST \
  "https://$ROUTE/v2/models/rf-classifier/infer" \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": [{
      "name": "predict",
      "shape": [1, 20],
      "datatype": "FP64",
      "data": [[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0,
                 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0]]
    }]
  }'
```

### Python 客戶端測試

```python
import requests
import numpy as np

# 產生測試資料
test_data = np.random.randn(1, 20).tolist()

# 發送推論請求
inference_url = "https://YOUR_ROUTE/v2/models/rf-classifier/infer"
payload = {
    "inputs": [{
        "name": "predict",
        "shape": [1, 20],
        "datatype": "FP64",
        "data": test_data
    }]
}

response = requests.post(
    inference_url, 
    json=payload,
    verify=False  # CRC 使用自簽憑證
)

result = response.json()
print(f"預測結果：{result['outputs'][0]['data']}")
```

---

## 6.6 透過 Dashboard 部署模型（最簡單）

1. 登入 RHOAI Dashboard
2. 選擇您的 Data Science Project
3. 點選 **Models** → **Add server**
4. 選擇 **Multi-model serving platform** 或 **Single-model serving platform**
5. 設定 ServingRuntime
6. 點選 **Deploy model**
7. 選擇模型來源（從 Data Connection 或上傳）
8. 設定模型名稱和路徑
9. 點選 **Deploy**

---

## 6.7 監控推論服務

```bash
# 查看 InferenceService 狀態
oc get inferenceservice -n weather-ml-project -o wide

# 查看推論 Pod 日誌
oc logs -n weather-ml-project \
  -l serving.kserve.io/inferenceservice=rf-classifier \
  -f

# 查看 Prometheus 指標
oc get servicemonitor -n weather-ml-project
```

---

## ✅ 模組 06 完成確認清單

- [ ] 模型訓練並上傳到 S3/MinIO
- [ ] InferenceService 建立並達到 Ready 狀態
- [ ] 使用 curl/Python 成功呼叫推論 API 並取得結果
- [ ] 瞭解 KServe 和 ModelMesh 的差異

---

## 🎉 恭喜完成 OCP AI Platform 學習！

您已掌握：
1. ✅ 環境準備與 CRC 設定
2. ✅ 安裝 RHOAI Operator
3. ✅ 使用者管理與權限設定
4. ✅ Jupyter Notebook 工作環境
5. ✅ Data Science Pipelines
6. ✅ 模型部署與推論服務

### 下一步學習方向
- 🔹 [NVIDIA GPU Operator 安裝](07-gpu-setup.md)
- 🔹 [Ray 分散式訓練](08-distributed-training.md)
- 🔹 [TrustyAI 模型可信度](09-trustyai.md)
- 🔹 [Model Registry 模型版本管理](10-model-registry.md)
