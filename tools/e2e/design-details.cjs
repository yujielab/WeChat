// End-to-end design details, driven through actual local registration and media APIs.
// Start npm run dev, then: node tools/e2e/design-details.cjs [outdir]
// Covers preview-before-send, failure/retry, Unicode invite codes and narrow layouts.
const { chromium } = require('playwright')
const fs = require('fs')
const assert = require('node:assert/strict')
const path = require('path')
const OUT = process.argv[2] || path.join(process.cwd(), 'screenshots-design')
fs.mkdirSync(OUT, { recursive: true })
const BASE = process.env.BASE || 'http://127.0.0.1:8787'
if (!['127.0.0.1', 'localhost', '[::1]'].includes(new URL(BASE).hostname)) throw new Error('Run against a local wrangler dev instance')
const sleep = ms => new Promise(r => setTimeout(r, ms))
;(async () => {
 const browser = await chromium.launch()
 try {
 const problems=[]
 const ctx=await browser.newContext({viewport:{width:1200,height:900},locale:'zh-CN',serviceWorkers:'block',deviceScaleFactor:1})
 const bctx=await browser.newContext({viewport:{width:466,height:678},locale:'zh-CN',serviceWorkers:'block',deviceScaleFactor:1})
 const a=await ctx.newPage(), b=await bctx.newPage()
 for(const p of [a,b]) p.on('pageerror',e=>problems.push(e.message))
 const shot=async(p,n)=>{await sleep(850);await p.screenshot({path:`${OUT}/${n}.png`})}
 await a.goto(BASE);await a.waitForSelector('.halftone-stage')
 await a.click('.halftone-controls button:nth-child(2)');await sleep(1000)
 assert.equal(await a.locator('.halftone-art').getAttribute('data-animating'),'false')
 await shot(a,'11-auth-desktop')
 // Optional invite code remains an unrestricted native input; inspect the
 // actual registration body without changing the local server configuration.
 await a.evaluate(async()=>{const {renderAuth}=await import('/js/views/auth.js');renderAuth(document.querySelector('#app'),{needsCode:true,onSuccess:()=>{}})})
 await a.click('.auth-tab:has-text("创建账号")')
 await a.fill('#auth-u','invite_demo');await a.fill('#auth-p','hunter2');await a.fill('#auth-c','Duo-心意-ABCD-1234567890')
 await a.locator('#auth-c').focus();await shot(a,'14-invite-code')
 let captured
 await a.route('**/auth/register',async route=>{captured=route.request().postDataJSON();await route.fulfill({status:403,contentType:'application/json',body:JSON.stringify({ok:false,error:'邀请码无效'})})})
 await a.click('.auth-submit');await a.waitForSelector('.field-error:not(:empty)')
 assert.equal(captured.code,'Duo-心意-ABCD-1234567890')
 assert.equal(await a.inputValue('#auth-c'),captured.code)
 await a.unroute('**/auth/register')
 const uniq=Date.now().toString(36)
 const reg=async(p,user,name)=>{await p.goto(BASE);await p.click('.auth-foot button');await p.fill('#auth-u',user);await p.fill('#auth-d',name);await p.fill('#auth-p','hunter2');await p.click('.auth-submit');await p.waitForSelector('.shell')}
 await reg(a,`refa_${uniq}`,'艾米');await reg(b,`refb_${uniq}`,'本')
 await a.setViewportSize({width:466,height:678})
 await a.click('.list-topbar .bar-btn.tint');await a.fill('.sheet-search input',`refb_${uniq}`)
 await a.locator(`.sheet .cell:has-text("@refb_${uniq}")`).click();await a.waitForSelector('.thread:not([hidden])')
 await b.click('.row');await b.waitForSelector('.thread:not([hidden])')
 await a.fill('.composer textarea','图片、手绘，还有一点心意。');await a.keyboard.press('Enter')
 await b.locator('.bubble.text:has-text("一点心意")').waitFor()
 const png=await a.evaluate(()=>{const c=document.createElement('canvas');c.width=600;c.height=400;const g=c.getContext('2d');g.fillStyle='#eee8dc';g.fillRect(0,0,600,400);g.fillStyle='#262723';g.font='100px sans-serif';g.fillText('hello :)',80,235);return c.toDataURL('image/png').split(',')[1]})
 const file={name:'hello.png',mimeType:'image/png',buffer:Buffer.from(png,'base64')}
 await a.click('.composer .attach');await a.waitForSelector('.menu.on');await a.keyboard.press('Home');await a.keyboard.press('Enter');await a.waitForSelector('.attachment-sheet.on')
 await a.locator('.attachment-file-input').setInputFiles([file]);await a.locator('.attachment-file-input').dispatchEvent('change');assert.equal(await a.locator('.attachment-preview').count(),1)
 await shot(a,'12-attachment-preview')
 // The deliberate network delay lets us inspect a genuine in-flight stage.
 await a.route('**/api/media/upload?**',async route=>{await sleep(1700);await route.continue()})
 await a.click('.attachment-send');await a.locator('.upload-trace-label:has-text("上传图片")').waitFor()
 await a.click('.upload-trace-toggle');await a.setViewportSize({width:890,height:626});await shot(a,'13-send-waterfall')
 await a.locator('.upload-trace-label:has-text("已发送")').waitFor()
 await b.locator('.bubble[data-kind=image]').waitFor()
 await a.unroute('**/api/media/upload?**')
 // Image paste uses the same preview; transport errors keep the real retry.
 await a.evaluate(png=>{const bytes=Uint8Array.from(atob(png),c=>c.charCodeAt(0));const dt=new DataTransfer();dt.items.add(new File([bytes],'retry.png',{type:'image/png'}));document.querySelector('.composer textarea').dispatchEvent(new ClipboardEvent('paste',{clipboardData:dt,bubbles:true,cancelable:true}))},png)
 await a.waitForSelector('.attachment-sheet.on')
 await a.route('**/api/media/upload?**',route=>route.fulfill({status:503,contentType:'application/json',body:JSON.stringify({ok:false,error:'测试网络中断'})}))
 await a.click('.attachment-send');await a.locator('.upload-trace-label:has-text("发送未完成")').waitFor();await a.locator('.m-status').waitFor()
 await a.unroute('**/api/media/upload?**')
 await a.click('.m-status');await a.click('.menu-item:has-text("重新发送")');await a.locator('.upload-trace-label:has-text("已发送")').waitFor();assert.equal(await a.locator('.m-status').count(),0)
 // Drag/drop is preview-first, including at narrow touch dimensions.
 await a.setViewportSize({width:320,height:568})
 await a.evaluate(png=>{const dt=new DataTransfer();dt.items.add(new File([Uint8Array.from(atob(png),c=>c.charCodeAt(0))],'drop.png',{type:'image/png'}));document.querySelector('.thread').dispatchEvent(new DragEvent('drop',{dataTransfer:dt,bubbles:true,cancelable:true}))},png)
 await a.waitForSelector('.attachment-sheet.on');assert.equal(await a.locator('.attachment-preview').count(),1)
 assert.equal(await a.locator('.attachment-sheet').evaluate(el=>el.scrollWidth<=el.clientWidth),true)
 await a.keyboard.press('Escape');await sleep(350)
 await a.evaluate(()=>{document.documentElement.dataset.theme='dark';document.documentElement.dataset.motion='reduce'})
 await a.click('.composer .attach');await a.waitForSelector('.menu.on');await a.keyboard.press('Escape')
 assert.deepEqual(problems,[])
 console.log('PASS: halftone settles; unrestricted invite request; local image preview/upload/recipient/failure/retry; paste/drop; 320px layout; dark/reduced motion; no page errors.')
 } finally {await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1})
