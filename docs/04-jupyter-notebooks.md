# 模組 04：Jupyter Notebook 工作環境

## 學習目標
- 了解 RHOAI Workbench (JupyterHub) 運作機制
- 啟動不同規格的 Jupyter Notebook
- 設定 PVC 持久化儲存
- 申請 GPU 資源進行加速訓練

---

## 4.1 Workbench 與 Notebook 映像

RHOAI 提供多種預建映像，每種包含不同的 ML 框架：

| 映像名稱 | 包含框架 | 適用場景 |
|---------|---------|---------|
| **Standard Data Science** | NumPy, Pandas, Scikit-learn, Matplotlib | 資料分析、傳統 ML |
| **PyTorch** | PyTorch + CUDA | 深度學習、電腦視覺、NLP |
| **TensorFlow** | TensorFlow 2.x + Keras | 深度學習、Keras API |
| **CUDA** | CUDA Toolkit + 基礎工具 | 自訂 GPU 程式 |
| **Code Server** | VS Code in Browser | 完整開發環境 |
| **Minimal Python** | 只有 Python + pip | 輕量自訂環境 |

---

## 4.2 透過 RHOAI Dashboard 啟動 Notebook

1. 登入 RHOAI Dashboard
2. 點選 **Data Science Projects** → 選擇您的 Project
3. 點選 **Workbenches** → **Create workbench**
4. 填寫設定：

```yaml
Name: my-pytorch-workbench
Image selection: PyTorch
Version: 最新版本
Container size:
  - Small (1 CPU, 2 GB RAM)    → 一般使用
  - Medium (3 CPU, 8 GB RAM)   → 中等訓練
  - Large (7 CPU, 24 GB RAM)   → 大型模型
  - X Large (15 CPU, 56 GB RAM)→ 超大模型

GPU:
  Request GPU: ✔ (若有 GPU 節點)
  Number of GPUs: 1

Cluster storage:
  Create new PVC
  Name: my-work-data
  Size: 20 GB
```

5. 點選 **Create workbench**
6. 等待 Workbench 啟動（約 1-3 分鐘）
7. 點選 **Open** 開啟 Jupyter

---

## 4.3 透過 CLI 建立 Notebook

```bash
# 建立 Notebook
oc apply -f manifests/04-notebook.yaml -n weather-ml-project

# 確認 Notebook Pod 啟動
oc get pod -n weather-ml-project -l app=pytorch-notebook

# 取得 Notebook URL
oc get route pytorch-notebook \
  -n weather-ml-project \
  -o jsonpath='{.spec.host}'
```

---

## 4.4 Notebook 內的環境設定

```bash
# 在 Jupyter Terminal 中執行：

# 確認 GPU 可用
nvidia-smi

# 確認 PyTorch GPU 支援
python3 -c "import torch; print(torch.cuda.is_available())"

# 確認 CUDA 版本
python3 -c "import torch; print(torch.version.cuda)"

# 安裝額外套件
pip install transformers datasets accelerate
```

---

## 4.5 資料存取設定

### 連接 S3/MinIO 儲存

```python
import boto3
import os

# 方法一：從環境變數讀取（建議）
s3 = boto3.client(
    's3',
    endpoint_url=os.environ.get('AWS_S3_ENDPOINT'),
    aws_access_key_id=os.environ.get('AWS_ACCESS_KEY_ID'),
    aws_secret_access_key=os.environ.get('AWS_SECRET_ACCESS_KEY'),
)

# 列出 Bucket
response = s3.list_buckets()
for bucket in response['Buckets']:
    print(bucket['Name'])

# 下載資料集
s3.download_file('my-bucket', 'dataset/train.csv', '/opt/app-root/src/train.csv')
```

### 在 RHOAI Dashboard 設定 Data Connection
1. Dashboard → Data Science Projects → 您的 Project
2. **Data connections** → **Add data connection**
3. 填入 S3 連線資訊（Endpoint、Access Key、Secret Key、Bucket）
4. Workbench 啟動時會自動注入環境變數

---

## 4.6 在 Notebook 中訓練第一個模型

```python
# 範例：使用 PyTorch 訓練 MNIST 分類器
import torch
import torch.nn as nn
import torch.optim as optim
from torchvision import datasets, transforms
from torch.utils.data import DataLoader

# 設定設備（GPU 或 CPU）
device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
print(f"使用設備：{device}")

# 下載 MNIST 資料集
transform = transforms.Compose([
    transforms.ToTensor(),
    transforms.Normalize((0.5,), (0.5,))
])

train_dataset = datasets.MNIST('./data', 
                                train=True, 
                                download=True, 
                                transform=transform)
train_loader = DataLoader(train_dataset, batch_size=64, shuffle=True)

# 定義簡單的 CNN 模型
class SimpleCNN(nn.Module):
    def __init__(self):
        super(SimpleCNN, self).__init__()
        self.conv1 = nn.Conv2d(1, 32, 3, 1)
        self.conv2 = nn.Conv2d(32, 64, 3, 1)
        self.fc1 = nn.Linear(9216, 128)
        self.fc2 = nn.Linear(128, 10)
    
    def forward(self, x):
        x = torch.relu(self.conv1(x))
        x = torch.relu(self.conv2(x))
        x = torch.adaptive_avg_pool2d(x, (12, 12))
        x = x.view(-1, 9216)
        x = torch.relu(self.fc1(x))
        return self.fc2(x)

model = SimpleCNN().to(device)
optimizer = optim.Adam(model.parameters(), lr=0.001)
criterion = nn.CrossEntropyLoss()

# 訓練一個 Epoch
model.train()
for batch_idx, (data, target) in enumerate(train_loader):
    data, target = data.to(device), target.to(device)
    optimizer.zero_grad()
    output = model(data)
    loss = criterion(output, target)
    loss.backward()
    optimizer.step()
    
    if batch_idx % 100 == 0:
        print(f'Batch: {batch_idx}/{len(train_loader)}, Loss: {loss.item():.4f}')

# 儲存模型
torch.save(model.state_dict(), '/opt/app-root/src/mnist_model.pt')
print("模型已儲存！")
```

---

## 4.7 使用 GPU Accelerator Profile

若叢集有 GPU 節點，管理員需要先建立 Accelerator Profile：

```bash
# 查看可用的 Accelerator Profile
oc get acceleratorprofile -n redhat-ods-applications

# 套用 GPU Accelerator Profile（需要 GPU Operator 已安裝）
oc apply -f manifests/07-gpu-accelerator.yaml
```

---

## ✅ 模組 04 完成確認清單

- [ ] 成功在 Dashboard 建立 Workbench
- [ ] Notebook 開啟並可執行程式碼
- [ ] Data Connection 設定完成（S3/MinIO）
- [ ] 完成 MNIST 訓練範例（CPU 即可）
- [ ] 模型儲存到 PVC

**下一步** → [模組 05：Data Science Pipelines](05-pipelines.md)
