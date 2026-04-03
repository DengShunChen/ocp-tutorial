# 模組 03：使用者管理與權限設定

## 學習目標
- 設定 HTPasswd Identity Provider 新增使用者
- 建立 OpenShift Group 管理使用者分組
- 設定 RHOAI 資料科學使用者/管理員群組
- 建立 Data Science Project 並設定資源配額

---

## 3.1 OCP 使用者管理概念

```
OCP Identity Provider (OAuth)
    └── Users (實際使用者帳號)
         └── Groups (群組)
              ├── ds-admins → RHOAI 管理員
              └── ds-users  → RHOAI 一般使用者
                   └── Data Science Projects
                        └── RBAC Roles
```

---

## 3.2 設定 HTPasswd Identity Provider

### 步驟一：建立使用者密碼檔

```bash
# 安裝 htpasswd 工具（macOS）
brew install httpd

# 建立第一個使用者（-B 使用 bcrypt 加密）
htpasswd -c -B htpasswd.txt user1

# 新增更多使用者
htpasswd -B htpasswd.txt user2
htpasswd -B htpasswd.txt user3
htpasswd -B htpasswd.txt ds-admin1

# 查看密碼檔內容
cat htpasswd.txt
```

### 步驟二：建立 Secret

```bash
# 建立 HTPasswd Secret
oc create secret generic htpasswd-secret \
  --from-file=htpasswd=htpasswd.txt \
  -n openshift-config

# 確認 Secret 建立成功
oc get secret htpasswd-secret -n openshift-config
```

### 步驟三：設定 OAuth

```bash
# 套用 OAuth 設定
oc apply -f manifests/04-htpasswd-oauth.yaml

# 等待 OAuth Pod 重啟
oc rollout status deployment oauth-openshift -n openshift-authentication
```

---

## 3.3 建立使用者群組

```bash
# 建立資料科學使用者群組、Project、Quota 與 RBAC
oc apply -f manifests/03-user-management.yaml

# 驗證群組成員
oc get group ds-users -o yaml
oc get group ds-admins -o yaml
```

---

## 3.4 設定 RHOAI 使用者群組

在 RHOAI Dashboard 中設定授權群組：

### 方法一：透過 Dashboard UI（最簡單）
1. 登入 RHOAI Dashboard
2. 點選右上角 **Settings → User Management**
3. **Data science administrator groups**：新增 `ds-admins`
4. **Data science user groups**：新增 `ds-users`
5. 點選 **Save changes**

### 方法二：透過 CLI
```bash
# 查看目前的 OdhDashboardConfig
oc get odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications -o yaml

# 編輯設定
oc edit odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications
```

加入以下設定：
```yaml
spec:
  groupsConfig:
    adminGroups: 'ds-admins'
    allowedGroups: 'ds-users'
```

---

## 3.5 建立 Data Science Project

Data Science Project = OpenShift Namespace + RHOAI 特殊標籤

```bash
# 方法一：透過 RHOAI Dashboard
# Settings → Data Science Projects → Create project

# 方法二：透過 CLI
oc apply -f manifests/03-user-management.yaml

# 確認 Project 建立
oc get namespace weather-ml-project \
  --show-labels | grep opendatahub
```

---

## 3.6 設定資源配額（Resource Quota）

防止單一 Project 消耗過多叢集資源：

```bash
# 套用資源配額
oc apply -f manifests/03-user-management.yaml

# 查看配額使用情況
oc describe resourcequota ds-project-quota \
  -n weather-ml-project

# 預期輸出：
# Name:      ds-project-quota
# Resource   Used  Hard
# --------   ----  ----
# cpu        0     32
# memory     0     64Gi
# pods       0     20
```

---

## 3.7 Grant 使用者存取 Project 權限

```bash
# 給予 user1 edit 權限（可建立/修改資源）
oc adm policy add-role-to-user edit user1 \
  -n weather-ml-project

# 給予 user2 view 權限（唯讀）
oc adm policy add-role-to-user view user2 \
  -n weather-ml-project

# 給予 ds-admin1 admin 權限（可管理 Project）
oc adm policy add-role-to-user admin ds-admin1 \
  -n weather-ml-project

# 查看 Project 的角色綁定
oc get rolebinding -n weather-ml-project
```

---

## 3.8 測試使用者登入

```bash
# 切換到一般使用者身份
oc login -u user1 https://api.crc.testing:6443
# 輸入您設定的密碼

# 確認目前使用者
oc whoami

# 確認可存取的 Project
oc get projects

# 切換回 admin
oc login -u kubeadmin
```

---

## ✅ 模組 03 完成確認清單

- [ ] HTPasswd OAuth Provider 設定完成
- [ ] 使用者 user1、user2、user3 和 ds-admin1 建立成功
- [ ] `ds-users` 和 `ds-admins` 群組建立並包含使用者
- [ ] RHOAI Dashboard 的群組設定完成
- [ ] Data Science Project `weather-ml-project` 建立成功
- [ ] user1 可以 `oc login` 並看到 weather-ml-project

**下一步** → [模組 04：Jupyter Notebook 工作環境](04-jupyter-notebooks.md)
