// v1 deployments still own this Durable Object namespace. Keep its export so
// upgrades can retain the stored WeChat data without running the old protocol
// or treating its incompatible SQLite schema as the new Hub's database.
export class WeChatSession {
  fetch() {
    return new Response('The WeChat client has been retired. Reload to use Duo.', {
      status: 410,
      headers: { 'cache-control': 'no-store' }
    })
  }

  // An alarm left by the old polling loop may fire after the upgrade.
  // Consume it without scheduling another poll or modifying stored data.
  async alarm() {}
}
