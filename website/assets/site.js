// 中英切换：?lang=en / ?lang=zh > 上次的选择 > 浏览器语言。
// <head> 里的内联脚本已经先设好 data-lang（避免闪烁），这里只负责按钮。
(function () {
  var root = document.documentElement;
  function apply(lang) {
    root.setAttribute('data-lang', lang);
    root.setAttribute('lang', lang === 'en' ? 'en' : 'zh-CN');
    var t = document.querySelector('title[data-en]');
    if (t) {
      if (!t.dataset.zh) t.dataset.zh = t.textContent;
      document.title = lang === 'en' ? t.dataset.en : t.dataset.zh;
    }
  }
  apply(root.getAttribute('data-lang') || 'zh');
  var btn = document.getElementById('lang');
  if (btn) {
    btn.addEventListener('click', function () {
      var next = root.getAttribute('data-lang') === 'en' ? 'zh' : 'en';
      try { localStorage.setItem('lang', next); } catch (e) {}
      apply(next);
    });
  }
  var y = document.getElementById('year');
  if (y) y.textContent = String(Math.max(2026, new Date().getFullYear()));
})();
