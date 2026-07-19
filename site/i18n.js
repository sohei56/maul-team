/* Runtime i18n for the MaulTeam.app landing page.
 *
 * English lives inline in index.html and is the source of truth; other
 * languages are flat key→HTML dictionaries fetched from ./i18n/<lang>.json
 * on demand. Elements opt in via data-i18n="key" (innerHTML swap) or
 * data-i18n-attr="attr:key[,attr:key]" (attribute swap). Translations are
 * authored in-repo, so innerHTML assignment is trusted content.
 */
(function(){
  "use strict";

  var STORE = "mt-lang";
  var SHORT = { en: "EN", ja: "JA", fr: "FR", es: "ES", de: "DE", "zh-Hans": "ZH", ko: "KO" };
  var cache = {};          // lang -> dict
  var current = "en";
  var currentDict = null;  // null == English originals
  var textItems = [];      // {el, key}
  var attrItems = [];      // {el, attr, key}
  var origText, origAttr;  // Maps: el -> innerHTML / el -> {attr: value}

  function norm(code){
    code = String(code || "");
    if (SHORT[code]) return code;
    var p = code.toLowerCase().slice(0, 2);
    if (p === "zh") return "zh-Hans";
    return SHORT[p] ? p : null;
  }

  function store(get, val){
    try {
      if (get) return localStorage.getItem(STORE);
      localStorage.setItem(STORE, val);
    } catch (e) { return null; }
  }

  function snapshot(){
    origText = new Map();
    origAttr = new Map();
    [].forEach.call(document.querySelectorAll("[data-i18n]"), function(el){
      var key = el.getAttribute("data-i18n");
      textItems.push({ el: el, key: key });
      origText.set(el, el.innerHTML);
    });
    [].forEach.call(document.querySelectorAll("[data-i18n-attr]"), function(el){
      var saved = {};
      el.getAttribute("data-i18n-attr").split(",").forEach(function(pair){
        var i = pair.indexOf(":");
        if (i < 1) return;
        var attr = pair.slice(0, i).trim();
        var key = pair.slice(i + 1).trim();
        attrItems.push({ el: el, attr: attr, key: key });
        saved[attr] = el.getAttribute(attr);
      });
      origAttr.set(el, saved);
    });
  }

  function apply(lang, dict){
    textItems.forEach(function(it){
      var html = dict ? dict[it.key] : null;
      it.el.innerHTML = (html != null) ? html : origText.get(it.el);
    });
    attrItems.forEach(function(it){
      var val = dict ? dict[it.key] : null;
      if (val == null) val = origAttr.get(it.el)[it.attr];
      if (val != null) it.el.setAttribute(it.attr, val);
    });
    document.documentElement.lang = lang;
    current = lang;
    currentDict = dict;
    // fit-scale mockups and the loop panel measure themselves on resize
    window.dispatchEvent(new Event("resize"));
  }

  // JS-generated strings (copy button, video error) look up "js.<key>"
  window.__t = function(key, fallback){
    var v = currentDict && currentDict["js." + key];
    return (v != null) ? v : fallback;
  };

  function markCurrent(lang){
    var cur = document.getElementById("langCur");
    if (cur) cur.textContent = SHORT[lang] || lang.toUpperCase();
    [].forEach.call(document.querySelectorAll("#langSwitch button[data-lang]"), function(b){
      b.classList.toggle("on", b.getAttribute("data-lang") === lang);
    });
  }

  function syncUrl(lang){
    try {
      var url = new URL(location.href);
      if (lang === "en") url.searchParams.delete("lang");
      else url.searchParams.set("lang", lang);
      history.replaceState(null, "", url);
    } catch (e) { /* ignore */ }
  }

  function setLang(lang, explicit){
    lang = norm(lang) || "en";
    function finish(applied){
      markCurrent(applied);
      if (explicit) {
        store(false, applied);
        syncUrl(applied);
        if (window.umami && window.umami.track) window.umami.track("lang-switch", { lang: applied });
      }
    }
    if (lang === "en") { apply("en", null); finish("en"); return; }
    var got = cache[lang]
      ? Promise.resolve(cache[lang])
      : fetch("./i18n/" + lang + ".json").then(function(r){
          if (!r.ok) throw new Error("i18n " + r.status);
          return r.json();
        }).then(function(d){ cache[lang] = d; return d; });
    got.then(function(d){ apply(lang, d); finish(lang); })
       .catch(function(){ apply("en", null); finish("en"); });
  }

  function detect(){
    try {
      var q = new URLSearchParams(location.search).get("lang");
      if (q && norm(q)) return norm(q);
    } catch (e) { /* ignore */ }
    var s = store(true);
    if (s && SHORT[s]) return s;
    var nav = (navigator.languages && navigator.languages[0]) || navigator.language || "";
    return norm(nav) || "en";
  }

  function wireSwitcher(){
    var dd = document.getElementById("langSwitch");
    if (!dd) return;
    dd.addEventListener("click", function(e){
      var btn = e.target && e.target.closest && e.target.closest("button[data-lang]");
      if (!btn) return;
      setLang(btn.getAttribute("data-lang"), true);
      dd.removeAttribute("open");
    });
    document.addEventListener("click", function(e){
      if (dd.open && !dd.contains(e.target)) dd.removeAttribute("open");
    });
    document.addEventListener("keydown", function(e){
      if (e.key === "Escape") dd.removeAttribute("open");
    });
  }

  function init(){
    snapshot();
    wireSwitcher();
    var lang = detect();
    markCurrent("en");
    if (lang !== "en") setLang(lang, false);
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
