#!/bin/bash
set -e

# ============================================
# nanobot Docker 多架构编译脚本
# ============================================
# 用法:
#   ./build-docker.sh main              # 编译 nightly 版本
#   ./build-docker.sh release           # 编译缺失的 release 版本
#   ./build-docker.sh release v0.1.4    # 编译指定版本
# ============================================

# 配置
SOURCE_OWNER="HKUDS"
REPO="nanobot"
IMAGE_NAME="ghcr.io/yojigenserver/nanobot"
PLATFORMS="linux/amd64,linux/arm64"
MIN_RELEASE_VERSION="v0.1.4.post4"

# 分支参数
BRANCH="${1:-main}"
SPECIFIC_TAG="${2:-}"

# 颜色输出
info() { echo "🔵 $*"; }
success() { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
error() { echo "❌ $*"; }

# ============================================
# 编译函数
# ============================================
build_image() {
  local tag="$1"
  local image_tags="$2"

  info "开始编译：$tag → $image_tags"

  # 清理旧目录
  rm -rf "$REPO"

  # 克隆源码
  info "克隆源码 $tag ..."
  git clone --branch "$tag" --depth 1 "https://github.com/${SOURCE_OWNER}/${REPO}.git" "$REPO"

  # 编译多架构镜像
  info "编译多架构镜像..."

  # 构建 -t 参数数组
  local -a tags_args=()
  IFS=',' read -ra TAGS_ARRAY <<< "$image_tags"
  for t in "${TAGS_ARRAY[@]}"; do
    tags_args+=("-t" "$t")
  done

  if docker buildx build \
    --platform "$PLATFORMS" \
    --push \
    --cache-from type=gha \
    --cache-to type=gha,mode=max \
    "${tags_args[@]}" \
    .; then
    success "编译完成：$image_tags"
    rm -rf "$REPO"
    return 0
  else
    error "编译失败：$tag"
    rm -rf "$REPO"
    return 1
  fi
}

# ============================================
# Main 分支 - Nightly 编译
# ============================================
build_nightly() {
  info "编译 nightly 版本..."

  DATE=$(date +%Y%m%d)
  IMAGE_TAG="${IMAGE_NAME}:nightly"
  DATE_TAG="${IMAGE_NAME}:nightly-${DATE}"

  # 清理旧目录
  rm -rf "$REPO"

  # 克隆 main 分支
  info "克隆 main 分支..."
  git clone --branch main --depth 1 "https://github.com/${SOURCE_OWNER}/${REPO}.git" "$REPO"

  # 编译
  info "编译 nightly 镜像..."
  if docker buildx build \
    --platform "$PLATFORMS" \
    --push \
    --cache-from type=gha \
    --cache-to type=gha,mode=max \
    -t "$IMAGE_TAG" \
    -t "$DATE_TAG" \
    .; then
    success "nightly 编译完成"
    success "标签：$IMAGE_TAG, $DATE_TAG"
  else
    error "nightly 编译失败"
  fi

  rm -rf "$REPO"
}

# ============================================
# Release 分支 - 检查并编译缺失版本
# ============================================
build_releases() {
  info "检查 release 版本..."

  # 获取 GitHub 所有 releases（按发布时间排序，从旧到新）
  info "获取 GitHub releases..."
  GITHUB_TAGS=$(curl -s "https://api.github.com/repos/${SOURCE_OWNER}/${REPO}/releases?per_page=100" | jq -r '.[].tag_name' | tac)

  # 获取第一个（最新）release tag
  LATEST_TAG=$(echo "$GITHUB_TAGS" | tail -n1)
  info "最新 release: $LATEST_TAG"

  # 获取 GHCR 已有 tags
  info "获取 GHCR 已有镜像..."
  if [ -n "$GITHUB_TOKEN" ]; then
    GHCR_TAGS=$(curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      "https://ghcr.io/v2/yojigenserver/${REPO}/tags/list" | jq -r '.tags[]' 2>/dev/null || echo "")
  else
    warn "GITHUB_TOKEN 未设置，跳过 GHCR 检查"
    GHCR_TAGS=""
  fi

  # 编译计数器
  TOTAL=0
  SKIPPED=0
  FAILED=0

  # 遍历检查
  for tag in $GITHUB_TAGS; do
    TOTAL=$((TOTAL + 1))

    # 检查是否 >= 最小版本
    if [[ "$tag" < "$MIN_RELEASE_VERSION" ]]; then
      info "跳过旧版本：$tag (< $MIN_RELEASE_VERSION)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    # 检查 GHCR 是否已有
    if [ -n "$GHCR_TAGS" ] && echo "$GHCR_TAGS" | grep -q "^${tag}$"; then
      info "已存在，跳过：$tag"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    info "需要编译：$tag"

    # 构建标签列表
    if [ "$tag" == "$LATEST_TAG" ]; then
      # 最新版本：添加 :latest 标签
      IMAGE_TAGS="${IMAGE_NAME}:${tag},${IMAGE_NAME}:latest"
      info "最新版本，添加 :latest 标签"
    else
      IMAGE_TAGS="${IMAGE_NAME}:${tag}"
    fi

    # 编译（失败不中断）
    if build_image "$tag" "$IMAGE_TAGS"; then
      : # 成功
    else
      FAILED=$((FAILED + 1))
      warn "继续处理下一个版本..."
    fi
  done

  # 输出统计
  echo ""
  info "===== 编译完成 ====="
  info "总计：$TOTAL 个版本"
  info "跳过：$SKIPPED 个"
  info "失败：$FAILED 个"
}

# ============================================
# 编译指定版本
# ============================================
build_specific() {
  local tag="$1"

  info "编译指定版本：$tag"

  # 获取最新 release tag
  LATEST_TAG=$(curl -s "https://api.github.com/repos/${SOURCE_OWNER}/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')

  # 构建标签列表
  if [ "$tag" == "$LATEST_TAG" ]; then
    IMAGE_TAGS="${IMAGE_NAME}:${tag},${IMAGE_NAME}:latest"
    info "最新版本，添加 :latest 标签"
  else
    IMAGE_TAGS="${IMAGE_NAME}:${tag}"
  fi

  # 编译
  if build_image "$tag" "$IMAGE_TAGS"; then
    success "指定版本编译完成"
  else
    error "指定版本编译失败"
    exit 1
  fi
}

# ============================================
# 主逻辑
# ============================================
main() {
  info "nanobot Docker 编译脚本"
  info "镜像名称：$IMAGE_NAME"
  info "平台：$PLATFORMS"
  info "最小版本：$MIN_RELEASE_VERSION"
  echo ""

  case "$BRANCH" in
    main)
      build_nightly
      ;;
    release)
      if [ -n "$SPECIFIC_TAG" ]; then
        build_specific "$SPECIFIC_TAG"
      else
        build_releases
      fi
      ;;
    *)
      error "未知分支：$BRANCH"
      echo "用法：$0 {main|release} [tag]"
      exit 1
      ;;
  esac
}

# 执行
main
