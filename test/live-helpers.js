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

module.exports = { looksServerSide, skipServerSide, SERVER_SIDE };
