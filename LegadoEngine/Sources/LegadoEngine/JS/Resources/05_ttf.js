var __ttfMap = function(id, kind){ return {
  get: function(k){ return __native.ttfMapGet(id, kind, k == null ? null : (kind == 'glyphToUnicode' ? String(k) : Number(k))); },
  containsKey: function(k){ return this.get(k) != null; },
  size: function(){ return __native.ttfMapSize(id, kind); } }; };
var __ttfWrap = function(id){ if (id == null || id === '') return null;
  var t = { __ttfId: id };
  t.getGlyfIdByUnicode = function(u){ return __native.ttfCall(id, 'glyfIdByUnicode', Number(u)); };
  t.getGlyfByUnicode = function(u){ return __native.ttfCall(id, 'glyfByUnicode', Number(u)); };
  t.getGlyfById = function(g){ return __native.ttfCall(id, 'glyfById', Number(g)); };
  t.getUnicodeByGlyf = function(s){ return __native.ttfCall(id, 'unicodeByGlyf', s == null ? null : String(s)); };
  t.isBlankUnicode = function(u){ return __native.ttfCall(id, 'isBlank', Number(u)); };
  t.unicodeToGlyph = __ttfMap(id, 'unicodeToGlyph');
  t.glyphToUnicode = __ttfMap(id, 'glyphToUnicode');
  t.unicodeToGlyphId = __ttfMap(id, 'unicodeToGlyphId');
  t.toString = function(){ return 'QueryTTF@' + id.substring(0, 8); };
  return t; };
java.queryTTF = function(d, c){ if (d == null) return null; return __ttfWrap(__native.ttfQuery(d, c == null ? true : !!c)); };
java.queryBase64TTF = function(d){
  java.log('queryBase64TTF(String)方法已过时,并将在未来删除；请无脑使用queryTTF(Any)替代，新方法支持传入 url、本地文件、base64、ByteArray 自动判断&自动缓存，特殊情况需禁用缓存请传入第二可选参数false:Boolean');
  return java.queryTTF(d); };
java.replaceFont = function(text, e, c, f){
  var s = text == null ? '' : String(text);
  if (e == null || c == null || e.__ttfId == null || c.__ttfId == null) return s;
  return __native.ttfReplace(s, e.__ttfId, c.__ttfId, !!f); };