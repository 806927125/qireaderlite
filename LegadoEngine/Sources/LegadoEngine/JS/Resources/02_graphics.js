var __Bmp = function(id){ if (id == null || id < 0) return null;
  var b = { __bmpId: id, isRecycled: false };
  b.getWidth = function(){ return __native.bmpW(id); };
  b.getHeight = function(){ return __native.bmpH(id); };
  b.getByteCount = function(){ return b.getWidth() * b.getHeight() * 4; };
  b.recycle = function(){ b.isRecycled = true; };
  b.isMutable = function(){ return true; };
  b.getConfig = function(){ return 'ARGB_8888'; };
  b.copy = function(){ return __Bmp(__native.bmpCrop(id, 0, 0, -1, -1)); };
  b.compress = function(fmt, q, out){ var bytes = __native.bmpEncode(id, String(fmt == null ? 'PNG' : fmt), Number(q == null ? 100 : q));
    if (out && out.write) out.write(bytes); return bytes != null; };
  try { Object.defineProperty(b, 'width', { get: b.getWidth }); Object.defineProperty(b, 'height', { get: b.getHeight }); } catch (e) {}
  return b; };
var __BmpConfig = { ARGB_8888: 'ARGB_8888', RGB_565: 'RGB_565', ARGB_4444: 'ARGB_4444', ALPHA_8: 'ALPHA_8' };
var __BmpFormat = { PNG: 'PNG', JPEG: 'JPEG', WEBP: 'WEBP', WEBP_LOSSY: 'JPEG', WEBP_LOSSLESS: 'PNG' };
var __bytesOf = function(x){ if (x == null) return null; if (x.__bytes != null) return x.__bytes; if (x.toByteArray) return x.toByteArray(); return x; };
var __Bitmap = { __name: 'Bitmap', Config: __BmpConfig, CompressFormat: __BmpFormat,
  createBitmap: function(a, x, y, w, h){
    if (typeof a == 'number') return __Bmp(__native.bmpCreate(a, Number(x)));
    if (a == null || a.__bmpId == null) return null;
    if (arguments.length >= 5) return __Bmp(__native.bmpCrop(a.__bmpId, Number(x), Number(y), Number(w), Number(h)));
    return __Bmp(__native.bmpCrop(a.__bmpId, 0, 0, -1, -1)); },
  createScaledBitmap: function(a, w, h, f){ return a ? __Bmp(__native.bmpScale(a.__bmpId, Number(w), Number(h))) : null; } };
var __BitmapFactory = { __name: 'BitmapFactory',
  decodeByteArray: function(b, off, len){ return __Bmp(__native.bmpDecode(__bytesOf(b), off == null ? 0 : Number(off), len == null ? -1 : Number(len))); },
  decodeStream: function(s){ return __Bmp(__native.bmpDecode(__bytesOf(s), 0, -1)); },
  Options: function(){ return {}; } };
var __Rect = function(l, t, r, b){ var o = { left: Number(l || 0), top: Number(t || 0), right: Number(r || 0), bottom: Number(b || 0) };
  o.width = function(){ return o.right - o.left; }; o.height = function(){ return o.bottom - o.top; };
  o.set = function(l, t, r, b){ o.left = Number(l); o.top = Number(t); o.right = Number(r); o.bottom = Number(b); };
  return o; };
__Rect.__name = 'Rect';
var __RectF = function(l, t, r, b){ return __Rect(l, t, r, b); }; __RectF.__name = 'RectF';
var __Paint = function(){ return { setAntiAlias: function(){}, setFilterBitmap: function(){}, setDither: function(){} }; };
__Paint.__name = 'Paint'; __Paint.FILTER_BITMAP_FLAG = 2; __Paint.ANTI_ALIAS_FLAG = 1;
var __Matrix = function(){ return { postScale: function(){}, setScale: function(){}, postRotate: function(){}, postTranslate: function(){} }; };
__Matrix.__name = 'Matrix';
var __Canvas = function(bmp){ var c = { __dst: bmp };
  c.drawBitmap = function(src, a, b, p){ if (!src || src.__bmpId == null || !c.__dst) return;
    var sw = src.getWidth(), sh = src.getHeight();
    if (typeof a == 'number') { __native.bmpDraw(c.__dst.__bmpId, src.__bmpId, 0, 0, sw, sh, a, Number(b), sw, sh); return; }
    var s = a || { left: 0, top: 0, right: sw, bottom: sh };
    var d = b || { left: 0, top: 0, right: sw, bottom: sh };
    __native.bmpDraw(c.__dst.__bmpId, src.__bmpId, s.left, s.top, s.right - s.left, s.bottom - s.top,
                     d.left, d.top, d.right - d.left, d.bottom - d.top); };
  c.setBitmap = function(b){ c.__dst = b; };
  c.drawColor = function(){}; c.save = function(){ return 1; }; c.restore = function(){};
  c.getWidth = function(){ return c.__dst ? c.__dst.getWidth() : 0; }; c.getHeight = function(){ return c.__dst ? c.__dst.getHeight() : 0; };
  return c; };
__Canvas.__name = 'Canvas';
var __BAOS = function(){ var o = { __parts: [] };
  o.write = function(b, off, len){ if (b == null) return; if (typeof b == 'number') { o.__parts.push(new Int8Array([b])); return; }
    if (off != null && len != null) b = Array.prototype.slice.call(b, off, off + len); o.__parts.push(b); };
  o.toByteArray = function(){ if (o.__parts.length == 1 && o.__parts[0] instanceof Int8Array) return o.__parts[0];
    var n = 0; o.__parts.forEach(function(p){ n += p.length; }); var r = new Int8Array(n), i = 0;
    o.__parts.forEach(function(p){ r.set(p, i); i += p.length; }); return r; };
  o.size = function(){ var n = 0; o.__parts.forEach(function(p){ n += p.length; }); return n; };
  o.reset = function(){ o.__parts = []; }; o.close = function(){}; o.flush = function(){};
  o.toString = function(){ return java.bytesToStr(o.toByteArray()); };
  return o; };
__BAOS.__name = 'ByteArrayOutputStream';
var __BAIS = function(b){ return { __bytes: b, close: function(){}, available: function(){ return b ? b.length : 0; } }; };
__BAIS.__name = 'ByteArrayInputStream';
Packages.android.graphics = { Bitmap: __Bitmap, BitmapFactory: __BitmapFactory, Canvas: __Canvas, Rect: __Rect, RectF: __RectF,
  Paint: __Paint, Matrix: __Matrix };
Packages.java.io = { ByteArrayOutputStream: __BAOS, ByteArrayInputStream: __BAIS };
Packages.android.util = Packages.android.util || {};
try { java.io = Packages.java.io; } catch (e) {}
var __importInto = function(target, pkg){ if (!pkg) return;
  if (pkg.__name) { target[pkg.__name] = pkg; return; }
  for (var k in pkg) { var v = pkg[k]; if (v && (v.__name || typeof v == 'function')) target[k] = v; } };
JavaImporter = function(){ var imp = {};
  imp.importClass = function(c){ __importInto(imp, c); };
  imp.importPackage = function(){ for (var i = 0; i < arguments.length; i++) __importInto(imp, arguments[i]); };
  for (var i = 0; i < arguments.length; i++) __importInto(imp, arguments[i]);
  return imp; };
importClass = function(c){ __importInto(this, c); };
importPackage = function(){ for (var i = 0; i < arguments.length; i++) __importInto(this, arguments[i]); };