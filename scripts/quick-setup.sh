#!/usr/bin/env bash
# =============================================================
# OCP AI Platform 快速安裝腳本
# 用法：eval $(crc oc-env) && bash scripts/quick-setup.sh
# =============================================================
set -euo pipefail

# ── 顏色定義 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}===== $* =====${NC}\n"; }

# ── 前置確認 ──
header "OCP AI Platform 安裝工具"

# 確認 oc 可用
command -v oc &>/dev/null || error "請先執行: eval \$(crc oc-env)"
command -v htpasswd &>/dev/null || warn "htpasswd 未安裝，使用者建立步驟將略過 (brew install httpd)"

# 確認登入狀態
CURRENT_USER=$(oc whoami 2>/dev/null) || error "請先執行 'oc login'"

if [[ "$CURRENT_USER" != "kubeadmin" && "$CURRENT_USER" != "system:admin" ]]; then
  error "需要 cluster-admin 權限，目前使用者：$CURRENT_USER"
fi
success "登入確認：$CURRENT_USER"

# 確認節點狀態
NODE_COUNT=$(oc get nodes --no-headers | grep -c Ready)
success "叢集節點：$NODE_COUNT 個 Ready"
ㄋㄠ
# ── STEP 1：確認 StorageClass ──
header "Step 1: StorageClass 設定"

DEFAULT_SC=$(oc get storageclass \
  -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

if [[ -z "$DEFAULT_SC" ]]; then
  warn "未找到預設 StorageClass，嘗試自動設定..."
  FIRST_SC=$(oc get storageclass -o jsonpath='{.items[0].metadata.name}')
  if [[ -n "$FIRST_SC" ]]; then
    oc patch storageclass "$FIRST_SC" \
      -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
    success "已設定 $FIRST_SC 為預設 StorageClass"
  else
    error "找不到任何 StorageClass！"
  fi
else
  success "預設 StorageClass：$DEFAULT_SC"
fi

# ── STEP 2：安裝 RHOAI Operator ──
header "Step 2: 安裝 RHOAI Operator"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$SCRIPT_DIR/../manifests"

if oc get namespace redhat-ods-operator &>/dev/null; then
  warn "redhat-ods-operator namespace 已存在，略過安裝"
else
  info "套用 RHOAI Operator Subscription..."
  oc apply -f "$MANIFEST_DIR/01-rhoai-subscription.yaml"
  
  info "等待 Operator 安裝（最多 5 分鐘）..."
  timeout 300 bash -c '
    until oc get csv -n redhat-ods-operator 2>/dev/null | grep -q "Succeeded"; do
      echo "  等待 RHOAI CSV Succeeded..."
      sleep 15
    done
  ' || warn "Operator 安裝逾時，請手動確認"
  success "RHOAI Operator 安裝完成"
fi

# ── STEP 3：建立 DataScienceCluster ──
header "Step 3: 建立 DataScienceCluster"

if oc get datasciencecluster default-dsc &>/dev/null; then
  warn "DataScienceCluster 已存在"
else
  info "建立 DataScienceCluster..."
  oc apply -f "$MANIFEST_DIR/02-datasciencecluster.yaml"
  
  info "等待 DataScienceCluster Ready（最多 10 分鐘）..."
  timeout 600 bash -c '
    until oc get datasciencecluster default-dsc \
      -o jsonpath="{.status.phase}" 2>/dev/null | grep -q "Ready"; do
      PHASE=$(oc get datasciencecluster default-dsc \
        -o jsonpath="{.status.phase}" 2>/dev/null || echo "Unknown")
      echo "  目前狀態：$PHASE"
      sleep 20
    done
  ' || warn "DataScienceCluster 未達到 Ready，請手動確認"
  success "DataScienceCluster Ready"
fi

# ── STEP 4：設定使用者與群組 ──
header "Step 4: 使用者與群組設定"

# 建立使用者（若 htpasswd 可用）
if command -v htpasswd &>/dev/null; then
  HTPASSWD_FILE="/tmp/ocp-htpasswd.txt"
  
  if [[ ! -f "$HTPASSWD_FILE" ]]; then
    info "建立測試使用者..."
    htpasswd -c -b -B "$HTPASSWD_FILE" user1 'Password123!'
    htpasswd -b -B "$HTPASSWD_FILE" user2 'Password123!'
    htpasswd -b -B "$HTPASSWD_FILE" ds-admin1 'Password123!'
    success "使用者建立完成 (user1, user2, ds-admin1 / 密碼: Password123!)"
  fi

  # 建立/更新 Secret
  if oc get secret htpasswd-secret -n openshift-config &>/dev/null; then
    oc create secret generic htpasswd-secret \
      --from-file=htpasswd="$HTPASSWD_FILE" \
      -n openshift-config \
      --dry-run=client -o yaml | oc apply -f -
  else
    oc create secret generic htpasswd-secret \
      --from-file=htpasswd="$HTPASSWD_FILE" \
      -n openshift-config
  fi
  success "HTPasswd Secret 更新完成"
fi

# 套用使用者管理 manifests
info "建立群組和 Data Science Project..."
oc apply -f "$MANIFEST_DIR/03-user-management.yaml"
success "使用者管理設定完成"

# ── STEP 5：取得 Dashboard URL ──
header "Step 5: 取得存取資訊"

info "等待 Dashboard Route 建立..."
timeout 120 bash -c '
  until oc get route rhods-dashboard \
    -n redhat-ods-applications &>/dev/null; do
    sleep 10
  done
' || warn "Dashboard Route 尚未就緒"

DASHBOARD_URL=$(oc get route rhods-dashboard \
  -n redhat-ods-applications \
  -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "尚未就緒")

OCP_CONSOLE_URL=$(oc get route console \
  -n openshift-console \
  -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")

# ── 完成摘要 ──
header "✅ 安裝完成！存取資訊"

echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           OCP AI Platform 存取資訊                      ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  🖥️  OCP Console:    $OCP_CONSOLE_URL"
echo "║  🤖 RHOAI Dashboard: $DASHBOARD_URL"
echo "║                                                          ║"
echo "║  👤 管理員帳號:      kubeadmin (見 crc console --credentials)"
echo "║  👤 測試使用者:      user1 / user2 / ds-admin1"
echo "║  🔑 測試密碼:        Password123!"
echo "║                                                          ║"
echo "║  📁 Data Science Project: weather-ml-project            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo ""
echo "下一步："
echo "  1. 以 kubeadmin 登入 RHOAI Dashboard"
echo "  2. 至 Settings → User Management 設定使用者群組"
echo "  3. 在 weather-ml-project 建立 Workbench"
echo "  4. 參考 docs/04-jupyter-notebooks.md 開始訓練模型"
echo ""
