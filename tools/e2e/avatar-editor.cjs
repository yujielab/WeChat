// Sheets in the middle of the open screen, and the avatar editor
// (views/avatar-editor.js): 头像 | 封面 between Cancel and Done, the photo large
// and framed by hand, − to take it away, a new photo cut to a 512px square on
// Done, 最近使用 to go back to an earlier one, the cover with your photo over
// it, and a sheet that takes the photo's colour in either theme. A photo in use that won't load is never
// taken away by a Done meant for the cover.
// Registers a user against a local dev server.
// npm run dev:e2e; node tools/e2e/avatar-editor.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-avatar-editor')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),uniq=Math.random().toString(36).slice(2,8)
const UNFOLDED={width:951,height:669},FOLDED={width:466,height:678}

// A picture drawn in the page: a warm field, a pale disc, a dark band.
const drawPhoto=async(p,[w,h],[a,b])=>Buffer.from(await p.evaluate(async([w,h,a,b])=>{const c=document.createElement('canvas');c.width=w;c.height=h;const g=c.getContext('2d');const gr=g.createLinearGradient(0,0,w,h);gr.addColorStop(0,a);gr.addColorStop(1,b);g.fillStyle=gr;g.fillRect(0,0,w,h);g.fillStyle='#f3efe6';g.beginPath();g.arc(w/2,h/2+10,Math.min(w,h)/3.3,0,7);g.fill();g.fillStyle='#2b2b38';g.fillRect(w*.28,h*.17,w*.44,h*.17);const blob=await new Promise(r=>c.toBlob(r,'image/png'));return[...new Uint8Array(await blob.arrayBuffer())]},[w,h,a,b]))
const me=p=>p.evaluate(async()=>(await import('/js/store.js')).state.me)
const openSettings=p=>p.evaluate(async()=>{const{openSettings}=await import('/js/views/sheets.js');openSettings({onLogout(){},origin:null})})
const closeAll=async p=>{for(let i=0;i<4&&await p.locator('.sheet').count();i++){await p.keyboard.press('Escape');await sleep(350)}}
const sheetBox=async p=>p.locator('.sheet').last().boundingBox()
const lightness=rgb=>{const[r,g,b]=(rgb.match(/[\d.]+/g)||[]).map(Number);return(Math.max(r,g,b)+Math.min(r,g,b))/2/255}

;(async()=>{const browser=await chromium.launch();try{
const ctx=await browser.newContext({viewport:UNFOLDED,locale:'zh-CN',serviceWorkers:'block',deviceScaleFactor:2,hasTouch:true,isMobile:true})
const p=await ctx.newPage(),errors=[];p.on('pageerror',e=>errors.push(e.message));p.setDefaultTimeout(8000)
await p.goto(BASE);await p.locator('.auth').waitFor()
const r=await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username:`av_${uniq}`,password:'hunter22',display:'TOKIO'})
assert.equal(r,200,'registered');await p.reload();await p.locator('.shell').waitFor()
// The photo in use to begin with.
const first=await p.evaluate(async bytes=>{const res=await fetch('/api/media/upload?kind=avatar&name=avatar',{method:'POST',headers:{'content-type':'image/png'},body:new Uint8Array(bytes)});const url=(await res.json()).url;const r=await fetch('/api/profile',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({avatar:url})});return(await r.json()).me.avatar},[...await drawPhoto(p,[600,400],['#c9b48a','#6b5a3a'])])
await p.reload();await p.locator('.shell').waitFor();await sleep(500)

// 1. Unfolded and flat, a sheet sits in the middle of the whole screen.
await openSettings(p);await p.locator('.sheet.on').waitFor();await sleep(500)
let box=await sheetBox(p)
assert.ok(Math.abs(box.x+box.width/2-UNFOLDED.width/2)<=1,'settings centred across the screen: '+JSON.stringify(box))
assert.ok(Math.abs(box.y+box.height/2-UNFOLDED.height/2)<=24,'and down it: '+JSON.stringify(box))
await p.screenshot({path:path.join(OUT,'1-settings-centred.png')})
await closeAll(p)
// Half folded, it keeps to one half, off the hinge.
await p.evaluate(async()=>(await import('/js/ui/viewport.js')).emulateFold({axis:'vertical',size:28}));await sleep(450)
await openSettings(p);await p.locator('.sheet.on').waitFor();await sleep(500)
box=await sheetBox(p)
const hinge=[UNFOLDED.width/2-14,UNFOLDED.width/2+14]
assert.ok(box.x+box.width<=hinge[0]+1||box.x>=hinge[1]-1,'half folded: one side of the hinge '+JSON.stringify(box))
await closeAll(p)
await p.evaluate(async()=>(await import('/js/ui/viewport.js')).emulateFold(null));await sleep(400)

// 2. The editor: Cancel, 头像 | 封面, Done; the photo large; the sheet in its colour, covering the one it came from.
const openEditor=async()=>{await openSettings(p);await p.locator('.sheet.on').waitFor();await sleep(400);await p.locator('.sheet .profile-btn').click();await sleep(600);await p.locator('.sheet .avatar-edit').last().click();await p.locator('.av-editor.on').waitFor();await sleep(900)}
await openEditor()
assert.equal(await p.locator('.av-seg-item[aria-selected="true"]').textContent(),'头像')
assert.equal(await p.locator('.av-editor .av-cancel').count(),1);assert.equal(await p.locator('.av-editor .av-done').count(),1)
assert.equal(await p.locator('.av-preview img.av-photo').getAttribute('src'),first,'the photo in use')
const widths=await p.evaluate(()=>[...document.querySelectorAll('.sheet')].map(s=>Math.round(s.getBoundingClientRect().width)))
assert.equal(new Set(widths).size,1,'as wide as the sheet beneath, so it covers it '+widths)
const tint=await p.evaluate(()=>{const s=document.querySelector('.av-editor');return{light:s.style.getPropertyValue('--av-tint-light'),dark:s.style.getPropertyValue('--av-tint-dark'),bg:getComputedStyle(s).backgroundColor}})
assert.match(tint.light,/^hsl\(\d+ \d+% 80%\)$/);assert.match(tint.dark,/^hsl\(\d+ \d+% 17%\)$/)
assert.ok(lightness(tint.bg)>0.7,'light screen: a light wash '+tint.bg)
const centre=await sheetBox(p);assert.ok(Math.abs(centre.x+centre.width/2-UNFOLDED.width/2)<=1,'the editor is centred too')
await p.screenshot({path:path.join(OUT,'2-editor.png')})

// 3. − takes the photo away: the initials, nothing to adjust.
await p.locator('.av-stage .av-remove').click();await sleep(300)
assert.equal(await p.locator('.av-preview .avatar').count(),1,'the initials');assert.equal(await p.locator('.av-custom').isHidden(),true)

// 4. A new photo, framed by hand, cut to a 512px square on Done.
await p.locator('.av-pane[data-pane="avatar"] input[type=file]').setInputFiles({name:'me.png',mimeType:'image/png',buffer:await drawPhoto(p,[900,600],['#8fb3c9','#2f4f6b'])})
await p.locator('.av-preview.framing img.av-photo').waitFor();await sleep(400)
assert.equal(await p.locator('.av-custom').textContent(),'完成调整','framing at once');assert.equal(await p.locator('.av-zoom').isVisible(),true)
const before=await p.locator('.av-preview .av-photo').evaluate(e=>({l:parseFloat(e.style.left),w:parseFloat(e.style.width)}))
const pv=await p.locator('.av-preview').boundingBox()
await p.mouse.move(pv.x+pv.width/2,pv.y+pv.height/2);await p.mouse.down();await p.mouse.move(pv.x+pv.width/2+60,pv.y+pv.height/2,{steps:6});await p.mouse.up()
const moved=await p.locator('.av-preview .av-photo').evaluate(e=>parseFloat(e.style.left))
assert.ok(moved>before.l+20,'dragged right '+before.l+' → '+moved)
assert.ok(moved<=0.5,'never so far it leaves a gap: '+moved)
await p.locator('.av-zoom').fill('2');await sleep(200)
const zoomed=await p.locator('.av-preview .av-photo').evaluate(e=>parseFloat(e.style.width))
assert.ok(Math.abs(zoomed-before.w*2)<1,'zoom 2 draws it twice as wide '+before.w+' → '+zoomed)
await p.screenshot({path:path.join(OUT,'3-framing.png')})
const saved=p.waitForResponse(r=>r.url().endsWith('/api/profile')&&r.request().method()==='POST')
await p.locator('.av-done').click();const res=await(await saved).json()
const second=res.me.avatar
assert.ok(second&&second!==first&&second.startsWith(`/api/media/avatar/${res.me.id}/`),'a new photo of its own '+second)
const size=await p.evaluate(async u=>{const b=await(await fetch(u)).blob();const i=await createImageBitmap(b);return[i.width,i.height,b.type]},second)
assert.deepEqual(size,[512,512,'image/jpeg'],'cut to the square the circle showed')
await p.locator('.av-editor').waitFor({state:'detached'})
assert.equal(await p.locator('.sheet .avatar-edit img').getAttribute('src'),second,'shown on the profile at once')
await closeAll(p)

// 5. 最近使用: the one replaced, to go back to.
await openEditor()
await p.locator('.av-recent-item').first().waitFor()
assert.deepEqual(await p.locator('.av-recent-item img').evaluateAll(a=>a.map(i=>i.getAttribute('src'))),[first])
await p.locator('.av-recent-item').first().click();await sleep(400)
assert.equal(await p.locator('.av-preview img.av-photo').getAttribute('src'),first)
await p.screenshot({path:path.join(OUT,'4-recent.png')})
const back=p.waitForResponse(r=>r.url().endsWith('/api/profile')&&r.request().method()==='POST')
await p.locator('.av-done').click();assert.equal((await(await back).json()).me.avatar,first,'the earlier photo, as it was')
await p.locator('.av-editor').waitFor({state:'detached'});await closeAll(p)

// 6. The cover: as the profile shows it, your photo over its edge; a style chosen, saved on Done.
await openEditor()
await p.locator('.av-seg-item[data-tab="cover"]').click();await sleep(450)
assert.equal(await p.locator('.av-pane[data-pane="cover"]').isVisible(),true)
assert.equal(await p.locator('.cv-face img').getAttribute('src'),first,'your photo over the cover')
assert.equal(await p.locator('.cv-face-name').textContent(),'TOKIO')
const tile=p.locator('.cv-tile').nth(2);const preset=await tile.getAttribute('aria-label');await tile.click();await sleep(300)
assert.equal(await tile.getAttribute('aria-checked'),'true');assert.equal(await p.locator('.cv-remove').isVisible(),true)
await p.screenshot({path:path.join(OUT,'5-cover.png')})
const cov=p.waitForResponse(r=>r.url().endsWith('/api/profile')&&r.request().method()==='POST')
await p.locator('.av-done').click();const cj=await(await cov).json()
assert.match(cj.me.cover,/^preset:/,'cover '+preset+' saved');assert.equal(cj.me.avatar,first,'the photo left as it was')
await p.locator('.av-editor').waitFor({state:'detached'});await closeAll(p)

// 6b. A photo in use that won't load is still in use: a Done for the cover leaves it be.
await p.evaluate(async u=>{const{state}=await import('/js/store.js');state.me={...state.me,avatar:u+'gone'}},first)
await openEditor()
await p.locator('.av-preview .avatar').waitFor();assert.equal(await p.locator('.av-custom').isHidden(),true,'nothing to adjust')
await p.locator('.av-seg-item[data-tab="cover"]').click();await sleep(300);await p.locator('.cv-tile').nth(3).click()
const keep=p.waitForRequest(r=>r.url().endsWith('/api/profile')&&r.method()==='POST')
await p.locator('.av-done').click();const sent=JSON.parse((await keep).postData())
assert.equal('avatar' in sent,false,'the avatar is not touched '+JSON.stringify(sent))
await p.locator('.av-editor').waitFor({state:'detached'});assert.equal((await me(p)).avatar,first);await closeAll(p)

// 7. Dark: the same hue, deep, and the controls still read.
await p.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('dark'));await sleep(300)
await openEditor()
const dark=await p.evaluate(()=>{const s=document.querySelector('.av-editor');return{bg:getComputedStyle(s).backgroundColor,fg:getComputedStyle(s.querySelector('.av-seg-item[aria-selected="true"]')).color}})
assert.ok(lightness(dark.bg)<0.25,'a deep wash '+dark.bg);assert.ok(lightness(dark.fg)>0.75,'light words on it '+dark.fg)
await p.screenshot({path:path.join(OUT,'6-dark.png')})
// Switched back with it open, it follows.
await p.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('light'));await sleep(600)
assert.ok(lightness(await p.locator('.av-editor').evaluate(s=>getComputedStyle(s).backgroundColor))>0.7,'follows the theme while open')
await p.locator('.av-cancel').click();await p.locator('.av-editor').waitFor({state:'detached'})
assert.equal((await me(p)).avatar,first,'Cancel keeps what was there');await closeAll(p)

// 8. Folded: the editor rises from the bottom, the photo and the tabs in reach.
await p.setViewportSize(FOLDED);await sleep(500)
await openEditor()
const fb=await sheetBox(p)
assert.ok(fb.y+fb.height>=FOLDED.height-12&&fb.width>=FOLDED.width-20&&fb.y<FOLDED.height*.1,'a tall card from the bottom, nearly as wide as the screen '+JSON.stringify(fb))
const seg=await p.locator('.av-seg').boundingBox();assert.ok(Math.abs(seg.x+seg.width/2-FOLDED.width/2)<=2,'the tabs centred')
await p.screenshot({path:path.join(OUT,'7-folded.png')})
await closeAll(p)

assert.deepEqual(errors,[],'no page errors')
console.log('avatar editor e2e passed')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
