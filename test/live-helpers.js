/**
 * 活体门禁的公共helper：**识别站方限流**
 *
 * 背景：🍅大灰狼的服务器（v5.langge.uk）+ 番茄有免登录访问次数上限。
 * 反复跑活体测试会被限流 → 探索返回 0 本 / 详情返回提示句 →
 *   **这不是引擎的锅**，但会让门禁变成随机硬币。
 *
 * ⇒ 识别出「站方侧」的信号 → **跳过**（exit 0），而不是报红。
 *   ⚠️ 但「发现页没有书」是**真 bug**（build160 修过一次）——
 *      所以只认**明确的限流/未登录措辞**，不认「0 本」本身。
 */

/// 站方侧的限流 / 未登录 / 线路故障措辞
const SERVER_SIDE = [
  '免登录访问次数已达上限',
  '今日免登录',
  '次数上限',
  '还未登陆',
  '未登陆',
  '未查询到登录状态',
  '检测登录失败',
  '登录失败',
  '线路故障',
  '会员',
  '密钥',
  'timeout',
  'Timeout',
  'ETIMEDOUT',
  'ENOTFOUND',
  'fetch failed',
  '502',
  '503',
  '504',
];

/**
 * 站方侧失败？（限流 / 未登录 / 网络抖动）
 * @param {string[]} logs   站方的 java.log 输出
 * @param {string[]} toasts 站方的 toast 输出
 */
function looksServerSide(logs = [], toasts = []) {
  const all = logs.concat(toasts).join(' | ');
  if (!all) return false;
  return SERVER_SIDE.some(s => all.indexOf(s) >= 0);
}

/**
 * 打印「站方限流 → 跳过」的说明并退出（exit 0）
 */
function skipServerSide(reason, extra = '') {
  console.log(`  ℹ️ 站方侧问题（${reason}）→ 本门禁跳过，不是引擎的锅`);
  if (extra) console.log('     ' + extra);
  console.log('\n✅ 通过 0 / 失败 0（站方限流，跳过）');
  process.exit(0);
}

/* ================================================================
 * ⭐⭐⭐⭐⭐ **活体代理**（真网络 + 真引擎）—— 2026-10-26 门禁迁移新增
 *
 * ⚠️ **为什么需要**：
 * · 新引擎的 `conformance --op` 只能走**假服务器**（声明式 `routes`）
 *   ⇒ 它**自己发不出真请求** ⇒ 活体门禁不能「让引擎去打真网站」⭐⭐⭐
 * · 而站方 JS 里的 `java.ajax` 由**引擎同步执行** ⇒ 真响应必须**喂进引擎** ⭐⭐⭐
 *
 * ⭐ **正解**：**多轮收敛**
 *   ① 跑一次 op ⇒ 引擎把「它想要哪些 URL」记在 `requests` 里⭐⭐⭐
 *   ② 把**没见过**的 URL **真抓一遍**（Node 的 fetch ⇒ 真网络）⭐⭐⭐
 *   ③ 把真响应加进 `routes`（**放在最前面** ⇒ 先匹配先赢）⇒ 再跑 ⭐⭐⭐
 *   ④ 直到没有新 URL ⇒ 引擎跑的就是**真数据**⭐⭐⭐
 *
 * ⇒ 于是：**真网络 ✓ + 真引擎 ✓** 两条都在 ⭐⭐⭐
 * ================================================================ */

const DEFAULT_UA = 'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36 Edg/138.0.0.0';

/**
 * ⭐ **真抓一个 URL**（Node 的 fetch ⇒ 真网络）
 * @returns {Promise<{ok:boolean, status:number, body:string, error?:string}>}
 */
async function liveFetch(url, opts = {}) {
  const timeout = opts.timeout || 15000;
  try {
    const res = await fetch(url, {
      method: opts.method || 'GET',
      headers: Object.assign({ 'User-Agent': opts.ua || DEFAULT_UA }, opts.headers || {}),
      body: opts.body,
      redirect: 'follow',
      signal: AbortSignal.timeout(timeout),
    });
    const body = await res.text();
    return { ok: res.ok, status: res.status, body };
  } catch (e) {
    return { ok: false, status: 0, body: '', error: String(e && e.message || e) };
  }
}

/** ⭐⭐⭐ **活体代理**：把「真响应」喂给「真引擎」 */
class LiveProxy {
  /**
   * @param {object} opts
   *   · `headers`  源级请求头（真抓时一起带上 ⇒ 与引擎发请求时一致）
   *   · `ua`       User-Agent
   *   · `timeout`  单次请求超时（毫秒）
   *   · `maxRounds` 最多收敛几轮（防死循环）
   */
  constructor(opts = {}) {
    this.headers = opts.headers || {};
    this.ua = opts.ua || DEFAULT_UA;
    this.timeout = opts.timeout || 15000;
    this.maxRounds = opts.maxRounds || 5;
    /** ⭐ 真抓到的响应（按发现顺序） */
    this.fetched = [];
    /** ⭐ 抓失败的 URL（⇒ 门禁要能看到「哪些没验到」） */
    this.failed = [];
    this._known = new Set();
    this._routes = [];
  }

  /** ⭐ **当前的路由表**（真响应在前 + 兜底在后） */
  routes() {
    // ⚠️ 兜底路由放**最后**：匹配到它 = 「这个 URL 还没真抓过」⇒ 下一轮去真抓
    return this._routes.concat([{ match: 'http', status: 200, body: '<html>probe</html>' }]);
  }

  /** ⭐ **真抓一个新 URL 并加进路由表** */
  async _absorb(url) {
    this._known.add(url);
    const r = await liveFetch(url, {
      headers: this.headers, ua: this.ua, timeout: this.timeout,
    });
    if (!r.ok && r.status !== 200) {
      this.failed.push({ url, error: r.error || ('HTTP ' + r.status) });
      // ⚠️ 抓失败 ⇒ 给一个**明确失败**的响应（不是静默 200 ⇒ 不会假绿）⭐⭐⭐
      this._routes.unshift({ match: url, status: r.status || 502, body: r.body || '请求失败' });
      return false;
    }
    this.fetched.push({ url, status: r.status, len: r.body.length, body: r.body });
    this._routes.unshift({ match: url, status: r.status, body: r.body });
    return true;
  }

  /**
   * ⭐⭐⭐ **跑一个 op 并收敛**（真网络把缺的 URL 补上）
   * @param {function(object): Promise<object>} runOp 接收 routes ⇒ 返回 op 结果（含 `requests`）
   * @returns {Promise<object>} 最后一轮的结果
   */
  async converge(runOp) {
    let last = null;
    for (let round = 0; round < this.maxRounds; round++) {
      last = await runOp(this.routes());
      const reqs = (last && last.requests) || [];
      const fresh = reqs.filter(u => /^https?:/i.test(String(u)) && !this._known.has(String(u)));
      if (!fresh.length) return last;
      for (const u of fresh) await this._absorb(String(u));
    }
    // ⚠️⭐⭐ **轮数用完 ⇒ 再跑一次**（这轮的 routes 已经是最全的 ⇒ 结果可信）
    //   ⇒ 否则最后一次可能跑在「还没抓全」的路由表上 ⇒ 结果是假的（探针页）⭐⭐⭐
    return await runOp(this.routes());
  }

  /** ⭐ **真网络到底通不通**（门禁的 SKIP 判据） */
  async probe(url) {
    const r = await liveFetch(url, {
      headers: this.headers, ua: this.ua, timeout: this.timeout,
    });
    return r;
  }
}

module.exports = { looksServerSide, skipServerSide, SERVER_SIDE, liveFetch, LiveProxy, DEFAULT_UA };
