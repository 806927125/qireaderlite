# 签名证书怎么放

把这两个文件传到仓库的 `ios-certificate/` 目录：

```
ios-certificate/
├── development.p12           ← 你的 .p12（Apple 后台导出的那个）
└── development.mobileprovision  ← 对应的描述文件
```

**`.p12` 一定要加进 `.gitignore`**，别提交到仓库 —— 私钥泄露等于别人能签你的 App。
但 Codemagic 是从仓库读的，所以最稳的做法是：

1. 仓库里**不放** `.p12`
2. 在 Codemagic 网页端 **Team settings → Code signing → iOS certificates** 里手动上传 `.p12` 和 `.mobileprovision`
3. 密码填在那里，`codemagic.yaml` 里的 `${P12_PASSWORD}` 会自动取到

这样证书只在 Codemagic 的加密存储里，不进 git 历史。

---

## 证书类型怎么选

| 你要干嘛 | `ios_method` | profile 类型 |
|---|---|---|
| 装自己一台 iPhone | `development` | 开发描述文件（Development） |
| 装给自己几台设备 | `ad_hoc` | Ad Hoc 描述文件 |
| 上 TestFlight / App Store | `app_store` | App Store 描述文件 |

你说的是装手机，那就是 **`development`**。

---

## bundle id 必须对得上

这是最常见的失败点：**profile 里的 bundle id 和 App 的不一致，签名直接失败**。

三处必须一致：

1. `codemagic.yaml` 里 `p12_file_path` 同级的 `bundle_identifier`
2. `QiReaderLite.xcodeproj/project.pbxproj` 里的 `PRODUCT_BUNDLE_IDENTIFIER`（现在是 `com.qireaderlite.app`）
3. Apple 后台那个 App ID 的 Bundle ID

建议直接把 `PRODUCT_BUNDLE_IDENTIFIER` 改成你证书里的值。

**改完记得两处都改**，我在 `codemagic.yaml` 里留了注释位置。

---

## Apple ID 注册设备

如果 profile 是 development 的，手机的 UDID 必须在 Apple 后台注册过，而且**每 7 天要重新签**（免费账号限制）。

想一劳永逸就买 99 美元/年的开发者账号 —— 就能签 1 年，而且设备数不受限。

---

## 签名失败长什么样

Codemagic 日志里会看到类似：

```
error: No profile matching 'com.xxx.app' with signing identity 'Apple Development'
found: no profiles
```

九成是上面三处 bundle id 没对齐，对着 Apple 后台的 App Identifier 页面核一遍。

另一个常见错：

```
code object is not signed at all
```

说明 `CODE_SIGNING_ALLOWED` 被设成了 NO —— 那是我之前给免签流程留的，你用证书的话它会跟 `codemagic.yaml` 冲突。真遇到了把它删掉。
