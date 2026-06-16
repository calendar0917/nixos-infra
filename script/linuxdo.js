// ==UserScript==
// @name         LINUX DO Timeline
// @namespace    https://linux.do/
// @version      2.2
// @description  按发帖时间排序的时间线视图，支持分类/标签筛选+拖拽排序，可折叠面板
// @author       ccc9527-c (modified)
// @match        https://linux.do/*
// @grant        GM_addStyle
// @grant        GM_setValue
// @grant        GM_getValue
// @license      MIT
// @downloadURL https://update.greasyfork.org/scripts/564655/LINUX%20DO%20Timeline.user.js
// @updateURL https://update.greasyfork.org/scripts/564655/LINUX%20DO%20Timeline.meta.js
// ==/UserScript==

(function () {
  "use strict";

  // ---------- 状态 ----------
  let isDrawerOpen = false;
  let isLoading = false;
  let allTopics = [];
  let usersMap = {};
  let currentPage = 0;
  let hasMorePages = true;
  let isLoadingMore = false;
  let loadedTopicIds = new Set();
  let selectedCategories = new Set();
  let filterTags = [];        // 有序数组，用于拖拽排序和筛选
  let cachedHotTags = [];     // 热门标签缓存

  // ---------- 分类数据映射 ----------
  const CATEGORY_MAP = {
    4: "开发调优", 20: "开发调优, Lv1", 31: "开发调优, Lv2", 88: "开发调优, Lv3",
    98: "国产替代", 99: "国产替代, Lv1", 100: "国产替代, Lv2", 101: "国产替代, Lv3",
    14: "资源荟萃", 83: "资源荟萃, Lv1", 84: "资源荟萃, Lv2", 85: "资源荟萃, Lv3",
    94: "网盘资源", 95: "网盘资源, Lv1", 96: "网盘资源, Lv2", 97: "网盘资源, Lv3",
    42: "文档共建", 75: "文档共建, Lv1", 76: "文档共建, Lv2", 77: "文档共建, Lv3",
    10: "跳蚤市场",
    106: "积分乐园", 107: "积分乐园, Lv1", 108: "积分乐园, Lv2", 109: "积分乐园, Lv3",
    27: "非我莫属", 72: "非我莫属, Lv1", 73: "非我莫属, Lv2", 74: "非我莫属, Lv3",
    32: "读书成诗", 69: "读书成诗, Lv1", 70: "读书成诗, Lv2", 71: "读书成诗, Lv3",
    46: "扬帆起航", 66: "扬帆起航, Lv1", 67: "扬帆起航, Lv2", 68: "扬帆起航, Lv3",
    34: "前沿快讯", 78: "前沿快讯, Lv1", 79: "前沿快讯, Lv2", 80: "前沿快讯, Lv3",
    36: "福利羊毛", 60: "福利羊毛, Lv1", 61: "福利羊毛, Lv2", 62: "福利羊毛, Lv3",
    11: "搞七捻三", 35: "搞七捻三, Lv1", 89: "搞七捻三, Lv2", 21: "搞七捻三, Lv3",
    102: "社区孵化", 103: "社区孵化, Lv1", 104: "社区孵化, Lv2", 105: "社区孵化, Lv3",
    110: "虫洞广场", 113: "人类之光", 114: "游戏人生", 115: "二次元", 116: "音乐", 117: "我爱我车", 118: "桌面GNU/Linux", 119: "嵌天嵌地", 121: "美拍",
    2: "运营反馈", 63: "运营反馈, Lv1", 64: "运营反馈, Lv2", 65: "运营反馈, Lv3",
    45: "深海幽域", 57: "深海幽域, Lv1", 58: "深海幽域, Lv2", 59: "深海幽域, Lv3",
  };

  const CATEGORY_ICON_MAP = {
    4: "code", 20: "code", 31: "code", 88: "code",
    98: "seedling", 99: "seedling", 100: "seedling", 101: "seedling",
    14: "square-share-nodes", 83: "square-share-nodes", 84: "square-share-nodes", 85: "square-share-nodes",
    94: "hard-drive", 95: "hard-drive", 96: "hard-drive", 97: "hard-drive",
    42: "book", 75: "book", 76: "book", 77: "book",
    10: "coins",
    106: "credit-card", 107: "credit-card", 108: "credit-card", 109: "credit-card",
    27: "briefcase", 72: "briefcase", 73: "briefcase", 74: "briefcase",
    32: "book-open-reader", 69: "book-open-reader", 70: "book-open-reader", 71: "book-open-reader",
    46: "rocket", 66: "rocket", 67: "rocket", 68: "rocket",
    34: "newspaper", 78: "newspaper", 79: "newspaper", 80: "newspaper",
    36: "piggy-bank", 60: "piggy-bank", 61: "piggy-bank", 62: "piggy-bank",
    11: "droplet", 35: "droplet", 89: "droplet", 21: "droplet",
    102: "lightbulb", 103: "lightbulb", 104: "lightbulb", 105: "lightbulb",
    110: "hurricane", 113: "hurricane", 114: "hurricane", 115: "hurricane", 116: "hurricane", 117: "hurricane", 118: "hurricane", 119: "hurricane", 121: "hurricane",
    2: "comments", 63: "comments", 64: "comments", 65: "comments",
    45: "water", 57: "water", 58: "water", 59: "water",
  };

  const CATEGORY_COLOR_MAP = {
    4: "#32c3c3", 20: "#32c3c3", 31: "#32c3c3", 88: "#32c3c3",
    98: "#D12C25", 99: "#D12C25", 100: "#D12C25", 101: "#D12C25",
    14: "#12A89D", 83: "#12A89D", 84: "#12A89D", 85: "#12A89D",
    94: "#16b176", 95: "#16b176", 96: "#16b176", 97: "#16b176",
    42: "#9cb6c4", 75: "#9cb6c4", 76: "#9cb6c4", 77: "#9cb6c4",
    10: "#ED207B",
    106: "#fcca44", 107: "#fcca44", 108: "#fcca44", 109: "#fcca44",
    27: "#a8c6fe", 72: "#a8c6fe", 73: "#a8c6fe", 74: "#a8c6fe",
    32: "#e0d900", 69: "#e0d900", 70: "#e0d900", 71: "#e0d900",
    46: "#ff9838", 66: "#ff9838", 67: "#ff9838", 68: "#ff9838",
    34: "#BB8FCE", 78: "#BB8FCE", 79: "#BB8FCE", 80: "#BB8FCE",
    36: "#E45735", 60: "#E45735", 61: "#E45735", 62: "#E45735",
    11: "#3AB54A", 35: "#3AB54A", 89: "#3AB54A", 21: "#3AB54A",
    102: "#ffbb00", 103: "#ffbb00", 104: "#ffbb00", 105: "#ffbb00",
    110: "#ff00f7", 113: "#ff00f7", 114: "#ff00f7", 115: "#ff00f7", 116: "#ff00f7", 117: "#ff00f7", 118: "#ff00f7", 119: "#ff00f7", 121: "#ff00f7",
    2: "#808281", 63: "#808281", 64: "#808281", 65: "#808281",
    45: "#45B7D1", 57: "#45B7D1", 58: "#45B7D1", 59: "#45B7D1",
  };

  // 主分类名 → 父级分类 ID（用于 API 拉取，Discourse 会自动包含子分类）
  const MAIN_CATEGORY_PARENT_ID_MAP = {};
  (function buildParentIdMap() {
    for (const [id, name] of Object.entries(CATEGORY_MAP)) {
      const main = name.split(",")[0].trim();
      if (!(main in MAIN_CATEGORY_PARENT_ID_MAP)) {
        MAIN_CATEGORY_PARENT_ID_MAP[main] = parseInt(id);
      }
    }
  })();

  function getMainCategories() {
    const mainSet = new Set();
    for (const val of Object.values(CATEGORY_MAP)) mainSet.add(val.split(",")[0].trim());
    return Array.from(mainSet).sort();
  }
  function getCategoryName(id) {
    const nid = typeof id === "number" ? id : (id?.id || parseInt(id) || 0);
    return CATEGORY_MAP[nid] || `分类${nid}`;
  }
  function getTagNames(topic) {
    if (!topic.tags) return [];
    return topic.tags.map(t => typeof t === "string" ? t : (t.name || t.id || ""));
  }
  function getCategoryIcon(id) { return CATEGORY_ICON_MAP[id] || "folder"; }
  function getCategoryColor(id) { return CATEGORY_COLOR_MAP[id] || "#888888"; }
  function getMainCat(topic) {
    return getCategoryName(topic.category_id).split(",")[0].trim();
  }
  function getColorByMainCat(mainName) {
    for (const [id, name] of Object.entries(CATEGORY_MAP))
      if (name.startsWith(mainName)) return CATEGORY_COLOR_MAP[id] || "#888";
    return "#888";
  }

  // ---------- 全局样式 ----------
  GM_addStyle(`
    .timeline-float-btn {
      position: fixed; width: 50px; height: 50px; border-radius: 50%;
      background: var(--tertiary, #08c); color: white; border: none; cursor: move;
      box-shadow: 0 4px 12px rgba(0,0,0,.3); z-index: 10002; display: flex;
      align-items: center; justify-content: center; font-size: 20px;
      transition: transform .2s; user-select: none;
    }
    .timeline-float-btn:hover { transform: scale(1.1); }
    .timeline-drawer {
      position: fixed; top: 0; right: -420px; width: 400px; max-width: 90vw; height: 100vh;
      background: var(--secondary, #fff); z-index: 10001; box-shadow: -4px 0 20px rgba(0,0,0,.2);
      transition: right .3s ease; display: flex; flex-direction: column; overflow: hidden;
    }
    .timeline-drawer.open { right: 0; }
    body.timeline-drawer-open {
      padding-right: 400px !important; transition: padding-right .3s ease;
    }
    @media (max-width: 450px) {
      body.timeline-drawer-open { padding-right: 90vw !important; }
    }
    .timeline-drawer-header {
      padding: 12px 20px; border-bottom: 1px solid var(--primary-low, #e9e9e9);
      display: flex; align-items: center; justify-content: space-between; flex-shrink: 0;
    }
    .timeline-drawer-title { font-size: 17px; font-weight: 600; color: var(--primary, #222); display: flex; align-items: center; gap: 8px; }
    .timeline-drawer-actions { display: flex; align-items: center; gap: 8px; }
    .timeline-drawer-refresh, .timeline-drawer-close {
      width: 30px; height: 30px; border: none; background: transparent; cursor: pointer; border-radius: 4px;
      display: flex; align-items: center; justify-content: center; color: var(--primary-medium, #666); transition: background .2s;
    }
    .timeline-drawer-refresh { font-size: 15px; }
    .timeline-drawer-close { font-size: 18px; }
    .timeline-drawer-refresh:hover, .timeline-drawer-close:hover { background: var(--primary-very-low, #f0f0f0); }

    /* ===== 可折叠面板 ===== */
    .timeline-collapse-panel {
      border-bottom: 1px solid var(--primary-very-low, #f0f0f0); flex-shrink: 0;
    }
    .timeline-collapse-header {
      display: flex; align-items: center; gap: 6px; padding: 8px 16px;
      cursor: pointer; user-select: none; font-size: 13px;
      color: var(--primary, #222); transition: background .15s;
    }
    .timeline-collapse-header:hover { background: var(--primary-very-low, #f8f8f8); }
    .timeline-collapse-arrow {
      font-size: 10px; transition: transform .25s; color: var(--primary-medium, #888);
    }
    .timeline-collapse-arrow.open { transform: rotate(90deg); }
    .timeline-collapse-label { font-weight: 500; }
    .timeline-collapse-count {
      font-size: 11px; color: var(--primary-medium, #888); margin-left: auto;
      background: var(--primary-very-low, #f0f0f0); padding: 1px 7px; border-radius: 10px;
    }
    .timeline-collapse-body {
      max-height: 0; overflow: hidden; transition: max-height .3s ease;
    }
    .timeline-collapse-body.open { max-height: 800px; overflow-y: auto; }

    /* ===== 分类水平栏 + 下拉菜单 ===== */
    .timeline-cat-bar {
      display: flex; align-items: center; gap: 0; padding: 6px 12px;
      border-bottom: 1px solid var(--primary-very-low, #f0f0f0); flex-shrink: 0;
      position: relative; min-height: 36px;
    }
    .timeline-cat-dropdown { position: relative; flex-shrink: 0; }
    .timeline-cat-dropdown-btn {
      display: inline-flex; align-items: center; gap: 4px; padding: 3px 10px;
      border: 1px solid var(--primary-low, #dcdcdc); border-radius: 6px;
      background: var(--secondary, #fff); color: var(--primary, #222);
      font-size: 12px; cursor: pointer; white-space: nowrap; transition: all .15s;
      user-select: none;
    }
    .timeline-cat-dropdown-btn:hover {
      border-color: var(--tertiary, #08c); color: var(--tertiary, #08c);
    }
    .timeline-cat-dropdown-btn .count-badge {
      font-size: 10px; background: var(--tertiary, #08c); color: white;
      padding: 0 5px; border-radius: 8px; min-width: 16px; text-align: center;
    }
    .timeline-cat-dropdown-menu {
      display: none; position: absolute; top: 100%; left: 0; margin-top: 4px;
      background: var(--secondary, #fff); border: 1px solid var(--primary-low, #dcdcdc);
      border-radius: 8px; box-shadow: 0 4px 16px rgba(0,0,0,.15); z-index: 100;
      min-width: 240px; max-height: 360px; overflow-y: auto; padding: 8px;
    }
    .timeline-cat-dropdown-menu.open { display: block; }
    .timeline-cat-dropdown-item {
      display: flex; align-items: center; gap: 8px; padding: 5px 10px;
      border-radius: 4px; cursor: pointer; font-size: 12px; transition: background .12s;
      user-select: none;
    }
    .timeline-cat-dropdown-item:hover { background: var(--primary-very-low, #f0f0f0); }
    .timeline-cat-dropdown-item.checked {
      background: var(--tertiary-very-low, #e6f7ff);
    }
    .timeline-cat-dropdown-item .timeline-category-dot {
      width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0;
    }
    .timeline-cat-dropdown-item .check-mark {
      margin-left: auto; color: var(--tertiary, #08c); font-size: 12px; visibility: hidden;
    }
    .timeline-cat-dropdown-item.checked .check-mark { visibility: visible; }
    .timeline-cat-dropdown-actions {
      display: flex; gap: 4px; padding-top: 6px; border-top: 1px solid var(--primary-very-low, #f0f0f0);
      margin-top: 4px;
    }
    .timeline-cat-dropdown-action {
      flex: 1; font-size: 11px; padding: 4px 0; border: 1px solid var(--primary-low, #dcdcdc);
      border-radius: 4px; background: var(--secondary, #fff); cursor: pointer;
      color: var(--primary-medium, #666); text-align: center; transition: all .15s;
    }
    .timeline-cat-dropdown-action:hover {
      border-color: var(--tertiary, #08c); color: var(--tertiary, #08c);
    }
    .timeline-cat-chips {
      display: flex; flex-wrap: nowrap; gap: 4px; overflow-x: auto;
      -webkit-overflow-scrolling: touch; scrollbar-width: thin; flex: 1; margin-left: 8px;
      padding: 2px 0;
    }
    .timeline-cat-chips::-webkit-scrollbar { height: 3px; }
    .timeline-cat-chips::-webkit-scrollbar-thumb { background: var(--primary-low, #ccc); border-radius: 2px; }
    .timeline-cat-chip {
      display: inline-flex; align-items: center; gap: 4px; padding: 3px 8px; border-radius: 12px;
      font-size: 11px; cursor: pointer; white-space: nowrap;
      transition: all .15s; user-select: none; flex-shrink: 0;
      background: var(--primary-very-low, #e8e8e8);
      color: var(--primary-medium, #888);
      border: 1px solid var(--primary-low, #ddd);
    }
    .timeline-cat-chip:hover { opacity: .85; }
    .timeline-cat-chip.selected {
      color: #fff; border-color: transparent; font-weight: 500;
    }
    .timeline-cat-chip.dragging { opacity: 0.35; }
    .timeline-cat-chip.drag-over { box-shadow: 0 0 0 2px var(--tertiary, #08c); }
    .timeline-cat-chip .chip-drag-handle { font-size: 9px; opacity: 0.5; cursor: grab; }
    .timeline-cat-chip .chip-drag-handle:hover { opacity: 1; }
    .timeline-cat-chips-empty {
      font-size: 11px; color: var(--primary-low-mid, #bbb); font-style: italic; white-space: nowrap;
    }

    .timeline-panel-actions {
      display: flex; gap: 6px; padding: 0 16px 6px;
    }
    .timeline-panel-action-btn {
      font-size: 11px; padding: 2px 10px; border: 1px solid var(--primary-low, #dcdcdc);
      border-radius: 4px; background: var(--secondary, #fff); cursor: pointer;
      color: var(--primary-medium, #666); transition: all .15s;
    }
    .timeline-panel-action-btn:hover {
      border-color: var(--tertiary, #08c); color: var(--tertiary, #08c); background: var(--tertiary-very-low, #e6f7ff);
    }

    /* ===== 标签排序区域 ===== */
    .timeline-tag-sort-area { padding: 6px 16px 8px; }
    .timeline-tag-sort-input-row {
      display: flex; align-items: center; gap: 6px; margin-bottom: 6px;
    }
    .timeline-tag-sort-input-row input {
      flex: 1; padding: 4px 8px; border: 1px solid var(--primary-low, #dcdcdc); border-radius: 4px;
      font-size: 12px; outline: none;
    }
    .timeline-tag-sort-input-row input:focus { border-color: var(--tertiary, #08c); }
    .timeline-tag-add-btn {
      font-size: 12px; padding: 4px 10px; border: 1px solid var(--tertiary, #08c);
      border-radius: 4px; background: var(--tertiary, #08c); color: white; cursor: pointer;
      white-space: nowrap; transition: opacity .15s;
    }
    .timeline-tag-add-btn:hover { opacity: .85; }
    .timeline-active-tags {
      display: flex; flex-wrap: wrap; gap: 4px; align-items: center; min-height: 22px;
    }
    .timeline-tag-chip {
      display: inline-flex; align-items: center; gap: 4px; padding: 2px 8px; border-radius: 12px;
      background: var(--tertiary-very-low, #e6f7ff); color: var(--tertiary, #08c);
      font-size: 11px; border: 1px solid var(--tertiary-low, #b3e0ff); cursor: grab;
      transition: opacity .15s, box-shadow .15s; user-select: none;
    }
    .timeline-tag-chip:active { cursor: grabbing; }
    .timeline-tag-chip.dragging { opacity: 0.35; }
    .timeline-tag-chip.drag-over { box-shadow: 0 0 0 2px var(--tertiary, #08c); background: var(--tertiary-low, #b3e0ff); }
    .timeline-tag-chip .drag-handle { font-size: 10px; opacity: 0.5; cursor: grab; }
    .timeline-tag-chip .remove-tag { font-weight: bold; cursor: pointer; opacity: 0.6; margin-left: 2px; }
    .timeline-tag-chip .remove-tag:hover { opacity: 1; }
    .timeline-tag-empty {
      font-size: 11px; color: var(--primary-low-mid, #bbb); font-style: italic;
    }
    .timeline-hot-tags {
      display: flex; flex-wrap: wrap; gap: 4px; margin-top: 6px; align-items: center;
    }
    .timeline-hot-tags-label {
      font-size: 11px; color: var(--primary-medium, #888); margin-right: 2px;
    }
    .timeline-hot-tag {
      padding: 1px 8px; border-radius: 10px; background: var(--primary-very-low, #f0f0f0);
      color: var(--primary-medium, #666); font-size: 11px; cursor: pointer; transition: background .15s;
    }
    .timeline-hot-tag:hover { background: var(--primary-low, #e0e0e0); }
    .timeline-hot-tag.used { opacity: 0.4; pointer-events: none; }

    /* ===== 帖子列表 ===== */
    .timeline-drawer-content { flex: 1; overflow-y: auto; padding: 0; min-height: 200px; }
    .timeline-topic-list { list-style: none; margin: 0; padding: 0; }
    .timeline-topic-item {
      padding: 12px 20px; border-bottom: 1px solid var(--primary-very-low, #f0f0f0);
      cursor: pointer; transition: background .2s; position: relative;
    }
    .timeline-topic-item:hover { background: var(--primary-very-low, #f8f8f8); }
    .timeline-unseen-dot { position: absolute; top: 12px; right: 12px; width: 8px; height: 8px; background: var(--tertiary, #08c); border-radius: 50%; }
    .timeline-topic-header { display: flex; align-items: center; gap: 10px; margin-bottom: 6px; }
    .timeline-topic-avatar { width: 28px; height: 28px; border-radius: 50%; flex-shrink: 0; cursor: pointer; }
    .timeline-topic-meta { display: flex; flex-direction: column; min-width: 0; }
    .timeline-topic-user-info { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
    .timeline-topic-username { font-size: 13px; color: var(--primary, #222); font-weight: 500; cursor: pointer; }
    .timeline-topic-username:hover { color: var(--tertiary, #08c); }
    .timeline-topic-name { font-size: 12px; color: var(--primary-medium, #888); }
    .timeline-topic-time { font-size: 12px; color: var(--primary-medium, #888); }
    .timeline-topic-title { font-size: 14px; color: var(--primary, #222); line-height: 1.4; margin: 0; word-break: break-word; }
    .timeline-topic-title:hover { color: var(--tertiary, #08c); }
    .timeline-topic-stats { display: flex; gap: 12px; margin-top: 8px; font-size: 12px; color: var(--primary-medium, #888); }
    .timeline-topic-stat { display: flex; align-items: center; gap: 4px; }
    .timeline-loading-2 { display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 40px 20px; color: var(--primary-medium, #888); width: 100%; box-sizing: border-box; }
    .timeline-spinner { width: 32px; height: 32px; border: 3px solid var(--primary-low, #e9e9e9); border-top-color: var(--tertiary, #08c); border-radius: 50%; animation: timeline-spin .8s linear infinite; margin-bottom: 12px; }
    @keyframes timeline-spin { to { transform: rotate(360deg); } }
    .timeline-load-more { padding: 16px 20px; text-align: center; color: var(--primary-medium, #888); font-size: 14px; }
    .timeline-load-more-spinner { display: inline-block; width: 16px; height: 16px; border: 2px solid var(--primary-low, #e9e9e9); border-top-color: var(--tertiary, #08c); border-radius: 50%; animation: timeline-spin .8s linear infinite; margin-right: 8px; vertical-align: middle; }
    .timeline-no-more { padding: 16px 20px; text-align: center; color: var(--primary-low-mid, #aaa); font-size: 13px; }
    .timeline-error { padding: 40px 20px; text-align: center; color: var(--danger, #e45735); display: flex; flex-direction: column; align-items: center; gap: 12px; }
    .timeline-error-icon { font-size: 40px; }
    .timeline-error-msg { font-size: 16px; font-weight: 600; }
    .timeline-error-detail { font-size: 12px; color: var(--primary-medium, #888); max-width: 300px; word-break: break-word; }
    .timeline-retry-btn { margin-top: 8px; padding: 8px 20px; background: var(--tertiary, #08c); color: white; border: none; border-radius: 6px; cursor: pointer; font-size: 14px; transition: opacity .2s; }
    .timeline-retry-btn:hover { opacity: .85; }
    .timeline-empty-state { padding: 40px 20px; text-align: center; color: var(--primary-medium, #888); font-size: 13px; }
    .timeline-category { display: inline-flex; align-items: center; gap: 4px; font-size: 11px; padding: 2px 6px; border-radius: 3px; background: var(--primary-very-low, #f0f0f0); color: var(--primary-medium, #666); margin-right: 6px; }
    .timeline-category-icon { width: 12px; height: 12px; fill: var(--category-color, #888); }
    .timeline-topic-category-tags { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; margin-top: 6px; }
    .timeline-tags { display: flex; flex-wrap: wrap; gap: 4px; }
    .timeline-tag { display: inline-block; font-size: 11px; padding: 2px 6px; border-radius: 3px; background: var(--primary-very-low, #f0f0f0); color: var(--primary-medium, #666); }
    .timeline-sort-info {
      padding: 6px 20px; font-size: 11px; color: var(--primary-low-mid, #bbb);
      background: var(--primary-very-low, #fafafa); border-bottom: 1px solid var(--primary-low, #e9e9e9);
    }
  `);

  // ==================== 悬浮按钮 ====================
  const BALL_SIZE = 50;
  let isDragging = false, dragOffset = { x: 0, y: 0 }, dragStartPos = { x: 0, y: 0 }, wasDragged = false;
  let snapTimer = null, btn = null;

  function createFloatButton() {
    if (document.querySelector(".timeline-float-btn")) return;
    btn = document.createElement("button");
    btn.className = "timeline-float-btn";
    btn.innerHTML = "\u{1F4F0}";
    btn.title = "顺序看帖 (ESC)";
    const savedPos = GM_getValue("timeline_btn_pos", { top: "100px", left: "20px" });
    Object.assign(btn.style, savedPos);
    document.body.appendChild(btn);
    snapToEdge();

    btn.addEventListener("mouseenter", () => { if (snapTimer) clearTimeout(snapTimer); undockFromEdge(); });
    btn.addEventListener("mouseleave", () => { if (!isDragging && !isDrawerOpen) snapTimer = setTimeout(snapToEdge, 1000); });
    btn.addEventListener("mousedown", (e) => {
      isDragging = true; dragOffset = { x: e.clientX - btn.offsetLeft, y: e.clientY - btn.offsetTop };
      dragStartPos = { x: e.clientX, y: e.clientY }; wasDragged = false;
      btn.style.transition = "none"; btn.dataset.isDocked = "false";
      if (snapTimer) clearTimeout(snapTimer);
    });
    document.addEventListener("mousemove", (e) => {
      if (!isDragging) return;
      btn.style.left = `${e.clientX - dragOffset.x}px`; btn.style.top = `${e.clientY - dragOffset.y}px`;
      if (Math.abs(e.clientX - dragStartPos.x) > 5 || Math.abs(e.clientY - dragStartPos.y) > 5) wasDragged = true;
      if (snapTimer) clearTimeout(snapTimer);
    });
    document.addEventListener("mouseup", () => {
      if (!isDragging) return;
      isDragging = false; btn.style.transition = "transform 0.2s";
      GM_setValue("timeline_btn_pos", { top: btn.style.top, left: btn.style.left });
      if (!isDrawerOpen) snapTimer = setTimeout(snapToEdge, 1000);
    });
    btn.addEventListener("click", () => { if (!wasDragged) toggleDrawer(); });

    btn.addEventListener("touchstart", (e) => {
      const t = e.touches[0]; isDragging = true; dragOffset = { x: t.clientX - btn.offsetLeft, y: t.clientY - btn.offsetTop };
      dragStartPos = { x: t.clientX, y: t.clientY }; wasDragged = false; btn.style.transition = "none"; btn.dataset.isDocked = "false";
    }, { passive: true });
    document.addEventListener("touchmove", (e) => {
      if (!isDragging) return; const t = e.touches[0];
      btn.style.left = `${t.clientX - dragOffset.x}px`; btn.style.top = `${t.clientY - dragOffset.y}px`;
      if (Math.abs(t.clientX - dragStartPos.x) > 5 || Math.abs(t.clientY - dragStartPos.y) > 5) wasDragged = true;
    }, { passive: true });
    document.addEventListener("touchend", () => {
      if (!isDragging) return; isDragging = false; btn.style.transition = "transform 0.2s";
      GM_setValue("timeline_btn_pos", { top: btn.style.top, left: btn.style.left });
      if (!isDrawerOpen) snapTimer = setTimeout(snapToEdge, 1000);
    });
  }

  function getSnapPosition() {
    if (!btn) return { left: 0, top: 100 };
    const vw = window.innerWidth, vh = window.innerHeight;
    const left = btn.offsetLeft, top = btn.offsetTop;
    const distLeft = left, distRight = vw - left - BALL_SIZE, distTop = top, distBottom = vh - top - BALL_SIZE;
    const minDist = Math.min(distLeft, distRight, distTop, distBottom);
    let edge = "left";
    if (minDist === distLeft) edge = "left";
    else if (minDist === distRight) edge = "right";
    else if (minDist === distTop) edge = "top";
    else edge = "bottom";
    btn.dataset.dockedEdge = edge;
    const half = BALL_SIZE / 2;
    if (edge === "left") return { left: -half, top };
    if (edge === "right") return { left: vw - half, top };
    if (edge === "top") return { left, top: -half };
    return { left, top: vh - half };
  }

  function snapToEdge() {
    if (!btn) return;
    const pos = getSnapPosition();
    btn.style.transition = "all 0.3s ease-out";
    btn.style.left = `${pos.left}px`; btn.style.top = `${pos.top}px`;
    btn.dataset.isDocked = "true";
    setTimeout(() => {
      if (!btn) return;
      GM_setValue("timeline_btn_pos", { top: btn.style.top, left: btn.style.left });
      btn.style.transition = "transform 0.2s";
    }, 300);
  }

  function undockFromEdge() {
    if (!btn || btn.dataset.isDocked !== "true") return;
    const vw = window.innerWidth, vh = window.innerHeight;
    const edge = btn.dataset.dockedEdge, margin = 8;
    let newLeft = btn.offsetLeft, newTop = btn.offsetTop;
    if (edge === "left") newLeft = margin;
    else if (edge === "right") newLeft = vw - BALL_SIZE - margin;
    else if (edge === "top") newTop = margin;
    else if (edge === "bottom") newTop = vh - BALL_SIZE - margin;
    btn.style.transition = "all 0.3s ease-out";
    btn.style.left = `${newLeft}px`; btn.style.top = `${newTop}px`;
    btn.dataset.isDocked = "false";
    setTimeout(() => { if (btn) btn.style.transition = "transform 0.2s"; }, 300);
  }

  // ==================== 侧边栏创建 ====================
  function createDrawer() {
    if (document.querySelector(".timeline-drawer")) return;
    const drawer = document.createElement("div");
    drawer.className = "timeline-drawer";
    drawer.innerHTML = `
      <div class="timeline-drawer-header">
        <div class="timeline-drawer-title"><span>\u{1F4F0}</span><span>顺序看帖</span></div>
        <div class="timeline-drawer-actions">
          <button class="timeline-drawer-refresh" title="刷新">\u{1F504}</button>
          <button class="timeline-drawer-close" title="关闭">&times;</button>
        </div>
      </div>

      <div class="timeline-cat-bar" id="timeline-cat-bar">
        <div class="timeline-cat-dropdown">
          <button class="timeline-cat-dropdown-btn">
            <span>\u{1F4C2} \u5206\u7C7B</span>
            <span class="count-badge timeline-cat-count">0</span>
          </button>
          <div class="timeline-cat-dropdown-menu">
            <div class="timeline-category-list"></div>
            <div class="timeline-cat-dropdown-actions">
              <button class="timeline-cat-dropdown-action timeline-cat-select-all">\u5168\u9009</button>
              <button class="timeline-cat-dropdown-action timeline-cat-clear-all">\u6E05\u9664</button>
            </div>
          </div>
        </div>
        <div class="timeline-cat-chips">
          <span class="timeline-cat-chips-empty">\u5168\u7AD9\u5E16\u5B50</span>
        </div>
      </div>

      <div class="timeline-collapse-panel" id="timeline-tag-panel">
        <div class="timeline-collapse-header" data-toggle="tag">
          <span class="timeline-collapse-arrow">\u25B6</span>
          <span class="timeline-collapse-label">\u{1F3F7} 标签筛选</span>
          <span class="timeline-collapse-count timeline-tag-count">0</span>
        </div>
        <div class="timeline-collapse-body">
          <div class="timeline-tag-sort-area">
            <div class="timeline-tag-sort-input-row">
              <input type="text" placeholder="输入标签，回车添加" class="timeline-tag-input">
              <button class="timeline-tag-add-btn">添加</button>
            </div>
            <div class="timeline-active-tags"></div>
            <div class="timeline-panel-actions" style="padding:0;margin-top:4px;">
              <button class="timeline-panel-action-btn timeline-tag-clear-all">清除标签</button>
            </div>
            <div class="timeline-hot-tags">
              <span class="timeline-hot-tags-label">\u{1F525} 热门：</span>
            </div>
          </div>
        </div>
      </div>

      <div class="timeline-drawer-content">
        <div class="timeline-loading-2"><div class="timeline-spinner"></div><span>加载中...</span></div>
      </div>
    `;

    setupCollapsePanels(drawer);
    buildCategoryBar(drawer);
    setupTagPanel(drawer);

    drawer.querySelector(".timeline-drawer-close").addEventListener("click", closeDrawer);
    drawer.querySelector(".timeline-drawer-refresh").addEventListener("click", () => loadTimelineTopics());
    drawer.querySelector(".timeline-drawer-content").addEventListener("scroll", () => {
      if (!isDrawerOpen || isLoadingMore || !hasMorePages) return;
      const el = drawer.querySelector(".timeline-drawer-content");
      if (el.scrollTop + el.clientHeight >= el.scrollHeight - 100) loadMoreTopics();
    });

    document.body.appendChild(drawer);
  }

  // ==================== 折叠面板（仅标签） ====================
  function setupCollapsePanels(drawer) {
    drawer.querySelectorAll(".timeline-collapse-header").forEach(header => {
      header.addEventListener("click", () => {
        const panel = header.parentElement;
        const body = panel.querySelector(".timeline-collapse-body");
        const arrow = header.querySelector(".timeline-collapse-arrow");
        const isOpen = body.classList.toggle("open");
        if (isOpen) arrow.classList.add("open");
        else arrow.classList.remove("open");
      });
    });
  }

  // ==================== 分类下拉 + 水平胶囊栏 ====================
  let orderedCats = []; // 拖拽排序后的分类顺序

  function buildCategoryBar(drawer) {
    const dropdownBtn = drawer.querySelector(".timeline-cat-dropdown-btn");
    const dropdownMenu = drawer.querySelector(".timeline-cat-dropdown-menu");
    const list = drawer.querySelector(".timeline-category-list");
    const mainCategories = getMainCategories();
    orderedCats = [...mainCategories];

    // ---- 构建下拉菜单项 ----
    mainCategories.forEach(cat => {
      const item = document.createElement("div");
      item.className = "timeline-cat-dropdown-item";
      item.dataset.cat = cat;
      const color = getColorByMainCat(cat);
      item.innerHTML = `
        <span class="timeline-category-dot" style="background:${color}"></span>
        <span>${escapeHtml(cat)}</span>
        <span class="check-mark">\u2713</span>
      `;
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        toggleCategory(cat);
      });
      list.appendChild(item);
    });

    // ---- 下拉菜单开/关 ----
    dropdownBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      dropdownMenu.classList.toggle("open");
    });
    document.addEventListener("click", (e) => {
      const btn = document.querySelector(".timeline-cat-dropdown-btn");
      if (!dropdownMenu.contains(e.target) && e.target !== btn && !btn.contains(e.target)) {
        dropdownMenu.classList.remove("open");
      }
    });

    // ---- 全选 / 清除 ----
    drawer.querySelector(".timeline-cat-select-all").addEventListener("click", () => {
      mainCategories.forEach(cat => selectedCategories.add(cat));
      syncDropdownUI();
      renderCatChips();
      loadTimelineTopics();
    });
    drawer.querySelector(".timeline-cat-clear-all").addEventListener("click", () => {
      selectedCategories.clear();
      syncDropdownUI();
      renderCatChips();
      loadTimelineTopics();
    });

    renderCatChips();
  }

  function toggleCategory(cat) {
    if (selectedCategories.has(cat)) selectedCategories.delete(cat);
    else selectedCategories.add(cat);
    syncDropdownUI();
    renderCatChips();
    loadTimelineTopics();
  }

  function syncDropdownUI() {
    document.querySelectorAll(".timeline-cat-dropdown-item").forEach(item => {
      if (selectedCategories.has(item.dataset.cat)) item.classList.add("checked");
      else item.classList.remove("checked");
    });
    updateCategoryCount();
  }

  function renderCatChips() {
    const chipsEl = document.querySelector(".timeline-cat-chips");
    if (!chipsEl) return;
    chipsEl.innerHTML = "";

    orderedCats.forEach(cat => {
      const selected = selectedCategories.has(cat);
      const color = getColorByMainCat(cat);
      const chip = document.createElement("span");
      chip.className = "timeline-cat-chip" + (selected ? " selected" : "");
      chip.draggable = true;
      chip.dataset.cat = cat;
      chip.style.background = selected ? color : "var(--primary-very-low, #e8e8e8)";
      chip.style.color = selected ? "#fff" : "var(--primary-medium, #888)";
      chip.style.border = selected ? "1px solid transparent" : "1px solid var(--primary-low, #ddd)";
      chip.innerHTML = `<span class="chip-drag-handle">\u2630</span>${escapeHtml(cat)}`;

      chip.addEventListener("click", (e) => {
        if (e.target.classList.contains("chip-drag-handle")) return;
        toggleCategory(cat);
      });

      chip.addEventListener("dragstart", (e) => {
        e.dataTransfer.setData("text/plain", cat);
        e.dataTransfer.effectAllowed = "move";
        chip.classList.add("dragging");
      });
      chip.addEventListener("dragend", () => {
        chip.classList.remove("dragging");
        chipsEl.querySelectorAll(".timeline-cat-chip").forEach(c => c.classList.remove("drag-over"));
      });
      chip.addEventListener("dragover", (e) => {
        e.preventDefault();
        e.dataTransfer.dropEffect = "move";
        if (!chip.classList.contains("dragging")) chip.classList.add("drag-over");
      });
      chip.addEventListener("dragleave", () => chip.classList.remove("drag-over"));
      chip.addEventListener("drop", (e) => {
        e.preventDefault();
        chip.classList.remove("drag-over");
        const fromCat = e.dataTransfer.getData("text/plain");
        if (fromCat === cat) return;
        const fromIdx = orderedCats.indexOf(fromCat);
        const toIdx = orderedCats.indexOf(cat);
        if (fromIdx !== -1 && toIdx !== -1) {
          orderedCats.splice(fromIdx, 1);
          orderedCats.splice(toIdx, 0, fromCat);
        }
        renderCatChips();
      });

      chipsEl.appendChild(chip);
    });

    updateCategoryCount();
  }

  function updateCategoryCount() {
    const el = document.querySelector(".timeline-cat-count");
    if (el) el.textContent = selectedCategories.size;
  }

  // ==================== 标签面板（含拖拽排序） ====================
  function setupTagPanel(drawer) {
    const input = drawer.querySelector(".timeline-tag-input");
    const addBtn = drawer.querySelector(".timeline-tag-add-btn");
    const tagsContainer = drawer.querySelector(".timeline-active-tags");

    addBtn.addEventListener("click", () => {
      addFilterTag(input.value);
      input.value = "";
    });

    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        addFilterTag(input.value);
        input.value = "";
      }
    });

    drawer.querySelector(".timeline-tag-clear-all").addEventListener("click", () => {
      filterTags.length = 0;
      updateActiveTagsUI(tagsContainer);
      refreshHotTagsUI();
      updateTagCountEl();
      renderTopics();
    });

    updateActiveTagsUI(tagsContainer);
    refreshHotTagsUI();
    updateTagCountEl();
  }

  function getHotTags(limit = 12) {
    const counter = new Map();
    allTopics.forEach(t => {
      getTagNames(t).forEach(tag => counter.set(tag, (counter.get(tag) || 0) + 1));
    });
    return [...counter.entries()].sort((a, b) => b[1] - a[1]).slice(0, limit).map(e => e[0]);
  }

  function addFilterTag(tag) {
    const val = tag.trim();
    if (!val || filterTags.includes(val)) return;
    filterTags.push(val);
    updateActiveTagsUI(document.querySelector(".timeline-active-tags"));
    refreshHotTagsUI();
    updateTagCountEl();
    renderTopics();
  }

  function removeFilterTag(index) {
    filterTags.splice(index, 1);
    updateActiveTagsUI(document.querySelector(".timeline-active-tags"));
    refreshHotTagsUI();
    updateTagCountEl();
    renderTopics();
  }

  function refreshHotTagsUI() {
    const container = document.querySelector(".timeline-hot-tags");
    if (!container) return;
    const hot = getHotTags(12);
    container.querySelectorAll(".timeline-hot-tag").forEach(el => el.remove());
    hot.forEach(tag => {
      if (filterTags.includes(tag)) return;
      const span = document.createElement("span");
      span.className = "timeline-hot-tag";
      span.textContent = tag;
      span.addEventListener("click", () => addFilterTag(tag));
      container.appendChild(span);
    });
  }

  function updateActiveTagsUI(container) {
    if (!container) return;
    container.innerHTML = "";
    if (filterTags.length === 0) {
      container.innerHTML = '<span class="timeline-tag-empty">\u{1F446} 拖拽可排序</span>';
      return;
    }
    filterTags.forEach((tag, idx) => {
      const chip = document.createElement("span");
      chip.className = "timeline-tag-chip";
      chip.draggable = true;
      chip.innerHTML = `<span class="drag-handle">\u2630</span>${escapeHtml(tag)} <span class="remove-tag">&times;</span>`;

      chip.addEventListener("dragstart", (e) => {
        e.dataTransfer.setData("text/plain", idx.toString());
        e.dataTransfer.effectAllowed = "move";
        chip.classList.add("dragging");
      });
      chip.addEventListener("dragend", () => {
        chip.classList.remove("dragging");
        container.querySelectorAll(".timeline-tag-chip").forEach(c => c.classList.remove("drag-over"));
      });
      chip.addEventListener("dragover", (e) => {
        e.preventDefault();
        e.dataTransfer.dropEffect = "move";
        chip.classList.add("drag-over");
      });
      chip.addEventListener("dragleave", () => {
        chip.classList.remove("drag-over");
      });
      chip.addEventListener("drop", (e) => {
        e.preventDefault();
        chip.classList.remove("drag-over");
        const fromIdx = parseInt(e.dataTransfer.getData("text/plain"));
        if (fromIdx === idx) return;
        const [moved] = filterTags.splice(fromIdx, 1);
        filterTags.splice(idx, 0, moved);
        updateActiveTagsUI(container);
        refreshHotTagsUI();
        renderTopics();
      });

      chip.querySelector(".remove-tag").addEventListener("click", (e) => {
        e.stopPropagation();
        const pos = filterTags.indexOf(tag);
        if (pos !== -1) removeFilterTag(pos);
      });

      container.appendChild(chip);
    });
  }

  function updateTagCountEl() {
    const el = document.querySelector(".timeline-tag-count");
    if (el) el.textContent = filterTags.length;
  }

  // ==================== 筛选与排序 ====================
  function filterAndSort(topics) {
    let result = topics;
    if (filterTags.length > 0) {
      result = result.filter(t =>
        filterTags.every(ft => getTagNames(t).includes(ft))
      );
    }
    result.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    return result;
  }

  function getActiveCategoryIds() {
    if (selectedCategories.size === 0) return null;
    return [...selectedCategories].map(cat => MAIN_CATEGORY_PARENT_ID_MAP[cat]).filter(Boolean);
  }

  // ==================== 渲染 ====================
  function renderTopics() {
    const content = document.querySelector(".timeline-drawer-content");
    if (!content) return;

    const filtered = filterAndSort(allTopics);

    // 更新排序信息行
    let sortInfo = document.querySelector(".timeline-sort-info");
    if (filtered.length > 0) {
      const parts = [];
      if (selectedCategories.size > 0) parts.push(`${selectedCategories.size}个分类`);
      if (filterTags.length > 0) parts.push(`标签: ${filterTags.join(", ")}`);
      parts.push(`${filtered.length}条帖子`);
      const infoText = parts.join("  ·  ");
      if (!sortInfo) {
        sortInfo = document.createElement("div");
        sortInfo.className = "timeline-sort-info";
        content.insertBefore(sortInfo, content.firstChild);
      }
      sortInfo.textContent = infoText;
    } else if (sortInfo) {
      sortInfo.remove();
    }

    if (filtered.length === 0) {
      const hasFilters = selectedCategories.size > 0 || filterTags.length > 0;
      content.innerHTML = `
        <div class="timeline-empty-state">
          ${hasFilters
            ? "\u{1F50D} 当前筛选条件下暂无帖子<br><small>试试放宽分类或标签条件</small>"
            : "\u{1F4AD} 暂无帖子"}
        </div>
      `;
      return;
    }

    const scrollTop = content.scrollTop;
    const fragment = document.createDocumentFragment();
    if (sortInfo) fragment.appendChild(sortInfo);
    filtered.forEach(t => fragment.appendChild(createTopicItem(t)));

    content.innerHTML = "";
    content.appendChild(fragment);
    content.scrollTop = scrollTop;
    refreshHotTagsUI();
  }

  // ==================== 帖子项创建 ====================
  function createTopicItem(topic) {
    const item = document.createElement("li");
    item.className = "timeline-topic-item";

    let avatarUrl = "", name = "", username = "";

    if (topic.posters && topic.posters.length > 0) {
      const userId = topic.posters[0].user_id;
      const user = usersMap[userId];
      if (user) {
        name = user.name;
        username = user.username;
        if (user.avatar_template) {
          avatarUrl = user.avatar_template.replace("{size}", "45");
          if (!avatarUrl.startsWith("http")) avatarUrl = "https://linux.do" + avatarUrl;
        }
      }
    }

    const createdTime = formatRelativeTime(new Date(topic.created_at));
    const views = topic.views >= 1000 ? (topic.views / 1000).toFixed(1) + "k" : topic.views;
    const replies = topic.posts_count - 1;

    const categoryName = getCategoryName(topic.category_id);
    const categoryIcon = getCategoryIcon(topic.category_id);
    const categoryColor = getCategoryColor(topic.category_id);

    let categoryHtml = "";
    if (categoryName) {
      categoryHtml = `<span class="timeline-category" style="--category-color: ${categoryColor}">
        <svg class="timeline-category-icon"><use href="#${categoryIcon}"></use></svg>
        ${escapeHtml(categoryName)}
      </span>`;
    }

    let tagsHtml = "";
    if (topic.tags && topic.tags.length > 0) {
      const tagItems = getTagNames(topic).map(tag => `<span class="timeline-tag">${escapeHtml(tag)}</span>`).join("");
      tagsHtml = `<div class="timeline-tags">${tagItems}</div>`;
    }

    const unseenDot = topic.unseen ? '<span class="timeline-unseen-dot"></span>' : "";

    const displayName = name && name !== username
      ? `<span class="timeline-topic-name" data-user-card="${username}">${escapeHtml(name)}</span>`
      : "";

    item.innerHTML = `
      ${unseenDot}
      <div class="timeline-topic-header">
        ${avatarUrl ? `<img class="timeline-topic-avatar" src="${avatarUrl}" alt="${escapeHtml(username)}" data-user-card="${username}">` : ""}
        <div class="timeline-topic-meta">
          <div class="timeline-topic-user-info">
            ${displayName}
            <span class="timeline-topic-username" data-user-card="${username}">${escapeHtml(username)}</span>
          </div>
          <span class="timeline-topic-time">${createdTime}</span>
        </div>
      </div>
      <h4 class="timeline-topic-title">${escapeHtml(topic.title)}</h4>
      <div class="timeline-topic-category-tags">
        ${categoryHtml}
        ${tagsHtml}
      </div>
      <div class="timeline-topic-stats">
        <span class="timeline-topic-stat">\u{1F4AC} ${replies}</span>
        <span class="timeline-topic-stat">\u{1F441} ${views}</span>
        <span class="timeline-topic-stat">\u2764\uFE0F ${topic.like_count || 0}</span>
      </div>
    `;

    item.querySelectorAll("[data-user-card]").forEach(el => {
      el.addEventListener("click", (e) => {
        e.stopPropagation();
        showUserCard(el.getAttribute("data-user-card"));
      });
    });

    item.addEventListener("click", (e) => {
      if (e.button !== 0) return;
      navigateTo(`/t/${topic.slug}/${topic.id}`);
    });

    item.addEventListener("mousedown", (e) => { if (e.button === 1) e.preventDefault(); });
    item.addEventListener("mouseup", (e) => {
      if (e.button === 1) {
        e.preventDefault();
        window.open(`https://linux.do/t/${topic.slug}/${topic.id}`, "_blank");
      }
    });

    return item;
  }

  // ==================== 数据加载 ====================
  async function loadTimelineTopics(retryCount = 0) {
    const MAX_RETRIES = 3;
    if (isLoading) return;
    isLoading = true;
    currentPage = 0;
    hasMorePages = true;
    allTopics = [];
    loadedTopicIds.clear();

    const content = document.querySelector(".timeline-drawer-content");
    if (!content) { isLoading = false; return; }

    content.innerHTML = `
      <div class="timeline-loading-2">
        <div class="timeline-spinner"></div>
        <span>${retryCount > 0 ? `重试中 (${retryCount}/${MAX_RETRIES})...` : "加载中..."}</span>
      </div>
    `;

    try {
      const catIds = getActiveCategoryIds();

      if (!catIds) {
        // 无分类选择 → 拉取全站最新
        const response = await fetch("/latest.json?order=created");
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const data = await response.json();
        if (data?.users) data.users.forEach(u => usersMap[u.id] = u);
        if (data?.topic_list?.topics) {
          allTopics = data.topic_list.topics.filter(t => !loadedTopicIds.has(t.id));
          allTopics.forEach(t => loadedTopicIds.add(t.id));
          allTopics.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
        }
      } else {
        // 有分类选择 → 分别拉取每个分类
        const fetches = catIds.map(id =>
          fetch(`/latest.json?category=${id}&order=created`)
            .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
            .catch(err => { console.error(`[时间线] 分类 ${id} 加载失败`, err); return null; })
        );

        const results = await Promise.all(fetches);
        for (const data of results) {
          if (!data) continue;
          if (data?.users) data.users.forEach(u => usersMap[u.id] = u);
          if (data?.topic_list?.topics) {
            for (const t of data.topic_list.topics) {
              if (!loadedTopicIds.has(t.id)) {
                loadedTopicIds.add(t.id);
                allTopics.push(t);
              }
            }
          }
        }
        allTopics.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
      }

      renderTopics();
    } catch (e) {
      console.error("[时间线] 加载失败", e);
      if (retryCount < MAX_RETRIES) {
        isLoading = false;
        await new Promise(r => setTimeout(r, 500));
        return loadTimelineTopics(retryCount + 1);
      }
      showError(e.message || "未知错误");
    } finally {
      isLoading = false;
    }
  }

  async function loadMoreTopics() {
    if (isLoadingMore || !hasMorePages) return;
    isLoadingMore = true;
    currentPage++;

    const content = document.querySelector(".timeline-drawer-content");
    if (!content) { isLoadingMore = false; return; }

    let loadingEl = document.querySelector(".timeline-load-more");
    if (!loadingEl) {
      loadingEl = document.createElement("div");
      loadingEl.className = "timeline-load-more";
      loadingEl.innerHTML = '<span class="timeline-load-more-spinner"></span>加载更多...';
      content.appendChild(loadingEl);
    }

    try {
      const catIds = getActiveCategoryIds();

      if (!catIds) {
        const data = await fetch(`/latest.json?order=created&page=${currentPage}`).then(r => r.json());
        loadingEl?.remove();
        if (!data?.topic_list?.topics?.length) { hasMorePages = false; showNoMore(); isLoadingMore = false; return; }
        if (data?.users) data.users.forEach(u => usersMap[u.id] = u);
        const newTopics = data.topic_list.topics.filter(t => !loadedTopicIds.has(t.id));
        if (!newTopics.length) { hasMorePages = false; showNoMore(); isLoadingMore = false; return; }
        newTopics.forEach(t => loadedTopicIds.add(t.id));
        allTopics = allTopics.concat(newTopics);
      } else {
        const fetches = catIds.map(id =>
          fetch(`/latest.json?category=${id}&order=created&page=${currentPage}`)
            .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
            .catch(() => null)
        );
        const results = await Promise.all(fetches);
        loadingEl?.remove();

        let anyNew = false;
        for (const data of results) {
          if (!data) continue;
          if (data?.users) data.users.forEach(u => usersMap[u.id] = u);
          if (data?.topic_list?.topics) {
            for (const t of data.topic_list.topics) {
              if (!loadedTopicIds.has(t.id)) {
                loadedTopicIds.add(t.id);
                allTopics.push(t);
                anyNew = true;
              }
            }
          }
        }
        if (!anyNew) { hasMorePages = false; showNoMore(); isLoadingMore = false; return; }
      }

      renderTopics();
    } catch (e) {
      console.error("[时间线] 加载更多失败", e);
      loadingEl?.remove();
    } finally {
      isLoadingMore = false;
    }
  }

  function showNoMore() {
    const content = document.querySelector(".timeline-drawer-content");
    if (content && !content.querySelector(".timeline-no-more")) {
      const noMore = document.createElement("div");
      noMore.className = "timeline-no-more";
      noMore.textContent = "没有更多了";
      content.appendChild(noMore);
    }
  }

  function showError(msg) {
    const content = document.querySelector(".timeline-drawer-content");
    if (!content) return;
    content.innerHTML = `
      <div class="timeline-error">
        <div class="timeline-error-icon">\u26A0\uFE0F</div>
        <div class="timeline-error-msg">加载失败</div>
        <div class="timeline-error-detail">${escapeHtml(msg)}</div>
        <button class="timeline-retry-btn">重试</button>
      </div>
    `;
    content.querySelector(".timeline-retry-btn")?.addEventListener("click", () => loadTimelineTopics());
  }

  // ==================== 打开/关闭 ====================
  function openDrawer() {
    createDrawer();
    isDrawerOpen = true;
    document.querySelector(".timeline-drawer")?.classList.add("open");
    document.body.classList.add("timeline-drawer-open");

    selectedCategories.clear();
    filterTags.length = 0;
    orderedCats = getMainCategories();

    // 重置分类栏
    syncDropdownUI();
    renderCatChips();

    // 关闭下拉菜单
    const dropdownMenu = document.querySelector(".timeline-cat-dropdown-menu");
    if (dropdownMenu) dropdownMenu.classList.remove("open");

    // 重置标签
    const tagContainer = document.querySelector(".timeline-active-tags");
    const tagInput = document.querySelector(".timeline-tag-input");
    const tagCount = document.querySelector(".timeline-tag-count");
    if (tagInput) tagInput.value = "";
    if (tagCount) tagCount.textContent = "0";
    if (tagContainer) tagContainer.innerHTML = '<span class="timeline-tag-empty">\u{1F446} 拖拽可排序</span>';

    // 默认展开标签面板
    const tagBody = document.querySelector("#timeline-tag-panel .timeline-collapse-body");
    const tagArrow = document.querySelector("#timeline-tag-panel .timeline-collapse-arrow");
    if (tagBody) { tagBody.classList.add("open"); }
    if (tagArrow) { tagArrow.classList.add("open"); }

    loadTimelineTopics();
  }

  function closeDrawer() {
    isDrawerOpen = false;
    document.querySelector(".timeline-drawer")?.classList.remove("open");
    document.body.classList.remove("timeline-drawer-open");
  }

  function toggleDrawer() { isDrawerOpen ? closeDrawer() : openDrawer(); }

  // ==================== 工具函数 ====================
  function formatRelativeTime(date) {
    const now = new Date();
    const diff = now - date;
    const seconds = Math.floor(diff / 1000);
    const minutes = Math.floor(seconds / 60);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);
    if (seconds < 60) return "刚刚";
    if (minutes < 60) return `${minutes}分钟前`;
    if (hours < 24) return `${hours}小时前`;
    if (days < 30) return `${days}天前`;
    const months = Math.floor(days / 30);
    if (months < 12) return `${months}个月前`;
    return `${Math.floor(months / 12)}年前`;
  }

  function escapeHtml(text) {
    if (!text) return "";
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
  }

  function showUserCard(username) {
    navigateTo(`/u/${username}/summary`);
  }

  function navigateTo(path) {
    const script = document.createElement("script");
    script.textContent = `window.require("discourse/lib/url").default.routeTo("${path}");`;
    document.documentElement.appendChild(script);
    script.remove();
  }

  // ==================== 键盘事件 ====================
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") toggleDrawer(); });

  // ==================== 启动 ====================
  createFloatButton();
  console.log("[时间线] 已加载 v2.2 - 分类拉取, 标签拖拽排序, 可折叠面板");
})();
