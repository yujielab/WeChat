// End-to-end design details, driven through actual local registration and media APIs.
// Start npm run dev:e2e (calls switched on), then: node tools/e2e/design-details.cjs [outdir]
// Covers preview-before-send, failure/retry, Unicode invite codes, narrow layouts and the
// status area's colour under a sheet.
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
 await a.goto(BASE);await a.waitForSelector('.auth-name')
 // A release sign-in: the app's name and the form, no logo, tagline or illustration.
 assert.equal(await a.locator('.auth-name').textContent(),'Cuven')
 assert.equal(await a.locator('.auth svg, .auth canvas').count(),0)
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
 const reg=async(p,user,name)=>{await p.goto(BASE);await p.click('.auth-tab:has-text("创建账号")');await p.fill('#auth-u',user);await p.fill('#auth-d',name);await p.fill('#auth-p','hunter2');await p.click('.auth-submit');await p.waitForSelector('.shell')}
 await reg(a,`refa_${uniq}`,'艾米');await reg(b,`refb_${uniq}`,'本')
 await a.setViewportSize({width:466,height:678})
 // Home Screen apps keep the default status bar: with black-translucent, iOS 26.1+ (WebKit 301994)
 // cuts the viewport short and leaves a strip the page cannot paint.
 assert.equal(await a.getAttribute('meta[name="apple-mobile-web-app-status-bar-style"]','content'),'default')
 const themeColor=()=>a.getAttribute('meta[name="theme-color"]','content')
 assert.equal(await themeColor(),'#ffffff')
 await a.click('.pane-list [data-item="compose"]');await a.fill('.sheet-search input',`refb_${uniq}`)
 // While the sheet dims the app, the theme colour is the colour at the screen's edge, so the
 // status area beside the page dims with it.
 await a.waitForSelector('.scrim.on');await sleep(700)
 const edge=(await a.screenshot({clip:{x:233,y:2,width:1,height:1}})).toString('base64')
 const px=await a.evaluate(async src=>{const img=new Image();img.src='data:image/png;base64,'+src;await img.decode();const c=document.createElement('canvas');c.width=c.height=1;const g=c.getContext('2d');g.drawImage(img,0,0);return[...g.getImageData(0,0,1,1).data.slice(0,3)]},edge)
 const dimmed=await themeColor(),want=[1,3,5].map(i=>parseInt(dimmed.slice(i,i+2),16))
 assert.ok(dimmed!=='#ffffff'&&want.every((v,i)=>Math.abs(v-px[i])<=3),'theme colour matches the dimmed edge '+JSON.stringify({dimmed,px}))
 await a.locator(`.sheet .cell:has-text("@refb_${uniq}")`).click();await a.waitForSelector('.thread:not([hidden])')
 assert.equal(await themeColor(),'#ffffff','theme colour restored when the sheet closes')
 await b.click('.row');await b.waitForSelector('.thread:not([hidden])')
 await a.fill('.composer textarea','图片、手绘，还有一点心意。');await a.keyboard.press('Enter')
 await b.locator('.bubble.text:has-text("一点心意")').waitFor()
 const png=await a.evaluate(()=>{const c=document.createElement('canvas');c.width=600;c.height=400;const g=c.getContext('2d');g.fillStyle='#eee8dc';g.fillRect(0,0,600,400);g.fillStyle='#262723';g.font='100px sans-serif';g.fillText('hello :)',80,235);return c.toDataURL('image/png').split(',')[1]})
 const file={name:'hello.png',mimeType:'image/png',buffer:Buffer.from(png,'base64')}
 await a.click('.thread .composer-action');await a.click('.composer-tool[data-tool="photo"]');await a.waitForSelector('.attachment-sheet.on')
 await a.locator('.attachment-file-input').setInputFiles([file]);await a.locator('.attachment-file-input').dispatchEvent('change');assert.equal(await a.locator('.attachment-preview').count(),1)
 await shot(a,'12-attachment-preview')
 // The deliberate network delay lets us inspect a genuine in-flight stage.
 await a.route('**/api/media/upload?**',async route=>{await sleep(1700);await route.continue()})
 await a.click('.attachment-send');await a.locator('.thread .bubble[data-kind=image]').waitFor()
 await a.setViewportSize({width:890,height:626});await shot(a,'13-image-sending')
 await b.locator('.bubble[data-kind=image]').waitFor()
 await a.unroute('**/api/media/upload?**')
 // Image paste uses the same preview; transport errors keep the real retry.
 await a.evaluate(png=>{const bytes=Uint8Array.from(atob(png),c=>c.charCodeAt(0));const dt=new DataTransfer();dt.items.add(new File([bytes],'retry.png',{type:'image/png'}));document.querySelector('.composer textarea').dispatchEvent(new ClipboardEvent('paste',{clipboardData:dt,bubbles:true,cancelable:true}))},png)
 await a.waitForSelector('.attachment-sheet.on')
 await a.route('**/api/media/upload?**',route=>route.fulfill({status:503,contentType:'application/json',body:JSON.stringify({ok:false,error:'测试网络中断'})}))
 await a.click('.attachment-send');await a.locator('.m-retry:has-text("重试")').waitFor()
 await a.unroute('**/api/media/upload?**')
 await a.click('.m-retry');await a.locator('.m-retry').waitFor({state:'detached'})
 // A failed text: 重试 beside it, 发送中 in place while it goes, then gone — the same message, sent once.
 await a.waitForFunction(()=>!document.querySelector('.msgs .m[data-id^="local:"]'))
 let failOnce=true
 const isText=route=>route.request().method()==='POST'&&route.request().postDataJSON()?.type==='text'
 await a.route('**/api/messages',route=>{if(isText(route)&&failOnce){failOnce=false;return route.fulfill({status:503,contentType:'application/json',body:JSON.stringify({ok:false,error:'测试网络中断'})})}return route.continue()})
 await a.fill('.composer textarea','这条先失败再重试');await a.keyboard.press('Enter');await a.locator('.m-retry:has-text("重试")').waitFor()
 const failed=await a.locator('.m:has(.m-retry)').elementHandle()
 let release;const held=new Promise(r=>{release=r})
 await a.unroute('**/api/messages');await a.route('**/api/messages',async route=>{if(isText(route))await held;return route.continue()})
 await a.click('.m-retry');await a.locator('.m-retry.busy:has-text("发送中")').waitFor()
 assert.equal(await failed.evaluate(e=>e.isConnected||Boolean(document.querySelector('.m:has(.m-retry.busy)'))),true,'retried in place')
 await a.click('.m-retry',{force:true}).catch(()=>{});release()
 await a.locator('.m-retry').waitFor({state:'detached'});await a.unroute('**/api/messages')
 assert.equal(await a.locator('.bubble.text:has-text("这条先失败再重试")').count(),1,'sent once')
 await b.locator('.bubble.text:has-text("这条先失败再重试")').waitFor();assert.equal(await b.locator('.bubble.text:has-text("这条先失败再重试")').count(),1)
 // Drag/drop is preview-first, including at narrow touch dimensions.
 await a.setViewportSize({width:320,height:568})
 await a.evaluate(png=>{const dt=new DataTransfer();dt.items.add(new File([Uint8Array.from(atob(png),c=>c.charCodeAt(0))],'drop.png',{type:'image/png'}));document.querySelector('.thread').dispatchEvent(new DragEvent('drop',{dataTransfer:dt,bubbles:true,cancelable:true}))},png)
 await a.waitForSelector('.attachment-sheet.on');assert.equal(await a.locator('.attachment-preview').count(),1)
 assert.equal(await a.locator('.attachment-sheet').evaluate(el=>el.scrollWidth<=el.clientWidth),true)
 await a.keyboard.press('Escape');await sleep(350)
 await a.evaluate(()=>{document.documentElement.dataset.theme='dark';document.documentElement.dataset.motion='reduce'})
 await a.locator('.bubble.text').last().click({button:'right'});await a.waitForSelector('.menu.on');await a.keyboard.press('Escape')
 assert.deepEqual(problems,[])
 console.log('PASS: plain sign-in; unrestricted invite request; local image preview/upload/recipient/failure/retry; failed text retried in place, sent once; paste/drop; 320px layout; dark/reduced motion; no page errors.')
 } finally {await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1})
