# Notes for Claude

## iOS IPA

- 每次构建出新的 IPA，先把 `Cuven.ipa` 直接发给用户（SendUserFile），再做发布、截图对比等其他步骤。
  (Whenever a new IPA is built, send `Cuven.ipa` to the user first, before releasing or anything else.)
- IPA 来自 GitHub Actions 的 `iOS IPA` 工作流（`.github/workflows/ios.yml`）的 `Cuven-ipa` 产物；
  提交信息带 `[ios-release]` 时同时发布到 Releases。
