<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>ClickDollar - منصة التعارف الفاخرة</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <link href="https://fonts.googleapis.com/css2?family=Cairo:wght@400;600;700;800&family=Plus+Jakarta+Sans:wght@400;600;700&display=swap" rel="stylesheet">
  <style>
    body { font-family: 'Cairo', 'Plus Jakarta Sans', sans-serif; background-color: #0d0a0e; color: #f8fafc; }
    .glass-dark { background: rgba(20, 15, 25, 0.85); backdrop-filter: blur(16px); border: 1px solid rgba(255, 46, 126, 0.15); }
    .pink-glow { box-shadow: 0 0 25px rgba(255, 46, 126, 0.25); }
    .vip-glow { box-shadow: 0 0 25px rgba(245, 158, 11, 0.3); border: 1px solid rgba(245, 158, 11, 0.6); }
    .chat-box::-webkit-scrollbar { width: 4px; }
    .chat-box::-webkit-scrollbar-thumb { background: #ff2e7e; border-radius: 4px; }
    .story-ring { background: linear-gradient(45deg, #ff2e7e, #f59e0b); padding: 2px; border-radius: 9999px; }
  </style>
</head>
<body class="pb-28 min-h-screen flex flex-col">

  <!-- الشريط العلوي الفاخر -->
  <header class="glass-dark sticky top-0 z-50 px-4 py-3 shadow-xl">
    <div class="max-w-md mx-auto flex justify-between items-center">
      <div class="flex items-center gap-2">
        <span class="text-2xl">💎</span>
        <h1 class="text-xl font-extrabold bg-gradient-to-r from-pink-500 to-amber-400 bg-clip-text text-transparent">ClickDollar</h1>
      </div>

      <div class="flex items-center gap-2">
        <!-- مبدل اللغات -->
        <select id="lang-switcher" onchange="changeLanguage(this.value)" class="bg-neutral-900 text-xs text-white border border-neutral-800 rounded-lg px-2 py-1.5 outline-none">
          <option value="ar">🇸🇦 العربية</option>
          <option value="en">🇺🇸 English</option>
          <option value="fr">🇫🇷 Français</option>
        </select>

        <!-- معلومات العضو -->
        <div id="user-header-info" class="hidden flex items-center gap-2">
          <div class="bg-amber-500/20 border border-amber-500/40 text-amber-300 px-2 py-1 rounded-full text-xs font-bold flex items-center gap-1">
            <span>⭐</span> <span id="header-points">0</span>
          </div>
          <button onclick="openVipModal()" class="bg-gradient-to-r from-amber-500 to-yellow-600 text-neutral-950 font-extrabold text-xs px-2.5 py-1.5 rounded-lg shadow" data-i18n="btn_vip">
            VIP 👑
          </button>
          <button onclick="logoutUser()" class="bg-pink-600/20 text-pink-400 hover:bg-pink-600 hover:text-white text-xs px-2 py-1.5 rounded-lg transition" data-i18n="btn_logout">
            خروج
          </button>
        </div>
      </div>
    </div>
  </header>

  <!-- مساحة إعلانية علوية (Adsterra Banner) -->
  <div class="max-w-md mx-auto w-full px-4 mt-3">
    <div id="adsterra-top-banner" class="w-full min-h-[50px] bg-neutral-900/60 border border-dashed border-neutral-800 rounded-xl flex items-center justify-center text-[11px] text-neutral-500 overflow-hidden p-1">
      <!-- الصق كود إعلان بانر Adsterra العلوي هنا -->
      <span>Adsterra Top Banner (728x90 / 320x50)</span>
    </div>
  </div>

  <main class="max-w-md mx-auto w-full px-4 mt-3 flex-1">

    <!-- 1. واجهة تسجيل الدخول والإنشاء -->
    <section id="auth-section" class="glass-dark p-6 rounded-3xl mt-6 shadow-2xl">
      <div
