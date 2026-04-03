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

wait_for_operator_success() {
  local waited=0
  local timeout_seconds=300
  local interval=15
  local phase=""

  while (( waited < timeout_seconds )); do
    phase=$(oc get csv -n redhat-ods-operator \
      -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"\n"}{end}' 2>/dev/null \
      | awk -F= '/rhods-operator/ {print $2; exit}')

    if [[ "$phase" == "Succeeded" ]]; then
      return 0
    fi

    echo "  等待 RHOAI CSV Succeeded... 目前狀態：${phase:-Unknown}"
    sleep "$interval"
    waited=$((waited + interval))
  done

  return 1
}

wait_for_dsc_ready() {
  local waited=0
  local timeout_seconds=600
  local interval=20
  local phase=""

  while (( waited < timeout_seconds )); do
    phase=$(oc get datasciencecluster default-dsc \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)

    if [[ "$phase" == "Ready" ]]; then
      return 0
    fi

    echo "  目前狀態：${phase:-Unknown}"
    sleep "$interval"
    waited=$((waited + interval))
  done

  return 1
}

# ── 前置確認 ──
header "OCP AI Platform 安裝工具"

# 確認 oc 可用
command -v oc &>/dev/null || error "請先執行: eval \$(crc oc-env)"
HTPASSWD_AVAILABLE=true
if ! command -v htpasswd &>/dev/null; then
  HTPASSWD_AVAILABLE=false
  warn "htpasswd 未安裝，將略過 HTPasswd 身分提供者設定 (可執行: brew install httpd)"
fi

# 確認登入狀態
CURRENT_USER=$(oc whoami 2>/dev/null) || error "請先執行 'oc login'"

if [[ "$CURRENT_USER" != "kubeadmin" && "$CURRENT_USER" != "system:admin" ]]; then
  error "需要 cluster-admin 權限，目前使用者：$CURRENT_USER"
fi
success "登入確認：$CURRENT_USER"

# 確認節點狀態
NODE_COUNT=$(oc get nodes --no-headers | awk '$2 == "Ready" {count++} END {print count + 0}')
(( NODE_COUNT > 0 )) || error "沒有 Ready 節點，請先確認叢集狀態"
success "叢集節點：$NODE_COUNT 個 Ready"

# ── STEP 1：確認 StorageClass ──
header "Step 1: StorageClass 設定"

DEFAULT_SC=$(oc get storageclass \
  -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

if [[ -z "$DEFAULT_SC" ]]; then
  warn "未找到預設 StorageClass，嘗試自動設定..."
  FIRST_SC=$(oc get storageclass -o jsonpath='{.items[0].metadata.name}')
  if [[ -n "$FIRST_SC" ]]; then
    oc patch storageclass "$FIRST_SC" \
      --type=merge \
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
  if wait_for_operator_success; then
    success "RHOAI Operator 安裝完成"
  else
    warn "Operator 安裝逾時，請手動確認 redhat-ods-operator namespace 中的 CSV 狀態"
  fi
fi

# ── STEP 3：建立 DataScienceCluster ──
header "Step 3: 建立 DataScienceCluster"

if oc get datasciencecluster default-dsc &>/dev/null; then
  warn "DataScienceCluster 已存在"
else
  info "建立 DataScienceCluster..."
  oc apply -f "$MANIFEST_DIR/02-datasciencecluster.yaml"
  
  info "等待 DataScienceCluster Ready（最多 10 分鐘）..."
  if wait_for_dsc_ready; then
    success "DataScienceCluster Ready"
  else
    warn "DataScienceCluster 未達到 Ready，請手動確認 default-dsc 狀態"
  fi
fi

# ── STEP 4：設定使用者與群組 ──
header "Step 4: 使用者與群組設定"

TEST_USER_PASSWORD="${TEST_USER_PASSWORD:-Password123!}"

# 建立使用者（若 htpasswd 可用）
if [[ "$HTPASSWD_AVAILABLE" == true ]]; then
  HTPASSWD_FILE="$(mktemp /tmp/ocp-htpasswd.XXXXXX)"
  trap 'rm -f "$HTPASSWD_FILE"' EXIT

  info "建立測試使用者..."
  htpasswd -c -b -B "$HTPASSWD_FILE" user1 "$TEST_USER_PASSWORD"
  htpasswd -b -B "$HTPASSWD_FILE" user2 "$TEST_USER_PASSWORD"
  htpasswd -b -B "$HTPASSWD_FILE" user3 "$TEST_USER_PASSWORD"
  htpasswd -b -B "$HTPASSWD_FILE" ds-admin1 "$TEST_USER_PASSWORD"
  success "使用者建立完成 (user1, user2, user3, ds-admin1)"

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

  oc apply -f "$MANIFEST_DIR/04-htpasswd-oauth.yaml"
  success "HTPasswd OAuth 設定完成"
else
  warn "略過 HTPasswd OAuth 設定；仍會建立群組、專案與配額資源"
fi

# 套用使用者管理 manifests
info "建立群組、Project 與 RBAC..."
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
echo "║  👤 測試使用者:      user1 / user2 / user3 / ds-admin1"
echo "║  🔑 測試密碼:        $TEST_USER_PASSWORD"
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
