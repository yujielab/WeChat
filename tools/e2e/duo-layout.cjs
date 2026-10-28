// Local Duo flow: real accounts/media, photo grouping, gallery, drafts and reading anchors.
// Start npm run dev, then node tools/e2e/duo-layout.cjs [outdir].
// The request helper explicitly forwards local-session cookies because APIRequestContext
// excludes Secure cookies over HTTP, while Chromium permits them on loopback.
const {chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs')
const path=require('path')
const BASE=process.env.BASE || 'http://127.0.0.1:8787',OUT=process.argv[2] || path.join(process.cwd(),'screenshots-duo')
if(!['localhost','127.0.0.1','[::1]'].includes(new URL(BASE).hostname)) throw new Error('Use a local wrangler dev instance')
fs.mkdirSync(OUT,{recursive:true})
async function post(ctx,url,options){const cookies=await ctx.cookies();return ctx.request.post(url,{...options,headers:{Origin:BASE,Cookie:cookies.map(c=>c.name+'='+c.value).join('; ')}})}
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
;(async()=>{const browser=await chromium.launch();try{
const opts={viewport:{width:466,height:678},locale:'zh-CN',serviceWorkers:'block',extraHTTPHeaders:{Origin:BASE},deviceScaleFactor:1}
const ac=await browser.newContext(opts),bc=await browser.newContext(opts),stamp=Date.now().toString(36)
const register=async(ctx,n,d)=>(await(await post(ctx,BASE+'/auth/register',{data:{username:n+'_'+stamp,password:'hunter2',display:d}})).json()).me
const am=await register(ac,'sketcha','艾米'),bm=await register(bc,'sketchb','本')
assert.ok(am&&bm)
const room=(await(await post(ac,BASE+'/api/dm',{data:{user:bm.id}})).json()).room.id
for(let i=0;i<5;i++){const c=await browser.newContext(opts);const me=await register(c,'friend'+i,['小禾','阿遥','林间','周末计划','知夏'][i]);const r=(await(await post(ac,BASE+'/api/dm',{data:{user:me.id}})).json()).room.id;await post(c,BASE+'/api/messages',{data:{room:r,type:'text',text:['今天的光刚刚好。','晚点见，带上相机。','发给你一首好听的歌','周六一起去走走吧','收到你的画啦'][i]}});await c.close()}
await post(bc,BASE+'/api/messages',{data:{room,type:'text',text:'这几张喜欢的画面，想分享给你。'}})
await post(ac,BASE+'/api/messages',{data:{room,type:'text',text:'我在。把今天的小事都发过来吧。'}})
const a=await ac.newPage(),b=await bc.newPage(),errors=[]
for(const p of[a,b])p.on('pageerror',e=>errors.push(e.message))
await a.goto(BASE+'/?chat='+room);await b.goto(BASE+'/?chat='+room);await a.locator('.thread:not([hidden])').waitFor();await b.locator('.thread:not([hidden])').waitFor()
const images=await b.evaluate(()=>['心意','日常','见面'].map((t,i)=>{const c=document.createElement('canvas');c.width=600;c.height=400;const g=c.getContext('2d');g.fillStyle=['#d8e4d8','#e5d9ce','#d7dfea'][i];g.fillRect(0,0,600,400);g.strokeStyle='#263d2f';g.lineWidth=3;g.beginPath();g.ellipse(300,185,100+i*20,90-i*10,i*.3,0,Math.PI*2);g.stroke();g.fillStyle='#263d2f';g.font='26px sans-serif';g.textAlign='center';g.fillText(t,300,200);g.font='12px sans-serif';g.fillText('A LITTLE CLOSER',300,340);return c.toDataURL('image/png').split(',')[1]}))
await b.click('.composer .attach');await b.click('.menu-item:has-text("照片")');await b.locator('.attachment-file-input').setInputFiles(images.map((v,i)=>({name:`moment-${i+1}.png`,mimeType:'image/png',buffer:Buffer.from(v,'base64')})));await b.click('.attachment-send')
await a.locator('.photo-stack[data-count="3"]').waitFor();await b.locator('.photo-stack[data-count="3"]').waitFor();await b.locator('.upload-trace-label:has-text("已发送")').waitFor()
assert.equal(await a.locator('.photo-stack').count(),1)
await sleep(750);await a.screenshot({path:OUT+'/15-duo-folded.png'})
await a.locator('.photo-stack-open').click({button:'right'});await a.locator('.menu-item:has-text("查看 3 张照片")').waitFor();assert.equal(await a.locator('.ctx-preview').evaluate(el=>el.inert&&el.getAttribute('aria-hidden')==='true'),true);await a.keyboard.press('Escape');await sleep(400)
// Gallery keeps all real images addressable; keyboard, thumbnails and resizing
// preserve the selected image, and closing returns focus to its cover.
await a.click('.photo-stack-open');await a.locator('.viewer-gallery-count:has-text("1 / 3")').waitFor();await a.keyboard.press('ArrowRight');await a.locator('.viewer-gallery-count:has-text("2 / 3")').waitFor();await a.click('.viewer-gallery-thumb:nth-child(3)');await a.locator('.viewer-gallery-count:has-text("3 / 3")').waitFor();await a.setViewportSize({width:890,height:626});await sleep(600);await a.screenshot({path:OUT+'/17-duo-gallery.png'});await a.keyboard.press('Escape');await a.locator('.viewer').waitFor({state:'detached'});assert.equal(await a.locator('.photo-stack-open').evaluate(el=>el===document.activeElement),true)
await a.fill('.composer textarea','这条草稿会跟着我展开和合起。');await a.locator('.composer textarea').evaluate(el=>el.setSelectionRange(3,8));const before=await a.locator('.composer textarea').evaluate(el=>({text:el.value,start:el.selectionStart,end:el.selectionEnd}));await a.setViewportSize({width:466,height:678});await sleep(300);const after=await a.locator('.composer textarea').evaluate(el=>({text:el.value,start:el.selectionStart,end:el.selectionEnd}));assert.deepEqual(after,before)
await a.setViewportSize({width:890,height:626});await a.fill('.composer textarea','');await a.locator('.composer textarea').blur();await sleep(700);await a.screenshot({path:OUT+'/16-duo-unfolded.png'})
// Grouped photos can be expanded to access each original message's menu.
await a.click('.photo-stack-expand');await a.locator('.photo-stack').waitFor({state:'detached'});assert.equal(await a.locator('.bubble.media[data-kind=image]').count(),3);const first=a.locator('.bubble.media[data-kind=image]').first();await first.click({button:'right'});await a.locator('.menu-item:has-text("从本设备删除")').waitFor();await a.keyboard.press('Escape');await sleep(350)
// Media, labels and toolbar stay inside a keyboard-sized conversation.
await a.setViewportSize({width:320,height:440});await a.fill('.composer textarea','小窗口仍然可以发送。');await a.keyboard.press('Enter');await b.locator('.bubble.text:has-text("小窗口仍然")').waitFor();const geometry=await a.evaluate(()=>({overflow:document.querySelector('.thread').scrollWidth>document.querySelector('.thread').clientWidth,buttons:[...document.querySelectorAll('.thread-tools button')].filter(e=>e.getClientRects().length).map(e=>({w:e.offsetWidth,h:e.offsetHeight}))}));assert.equal(geometry.overflow,false);assert.ok(geometry.buttons.every(r=>r.w>=44&&r.h>=44))
await a.setViewportSize({width:466,height:678});await a.click('.thread-tool-back');await a.locator('.shell[data-thread=closed]').waitFor();await a.locator('.row').first().click();await a.locator('.shell[data-thread=open]').waitFor();await a.setViewportSize({width:890,height:626});await a.evaluate(()=>{document.documentElement.dataset.theme='dark';document.documentElement.dataset.motion='reduce'});await sleep(500);await a.screenshot({path:OUT+'/18-duo-dark.png'})

// A reading anchor survives width changes while older messages are in view.
await a.evaluate(()=>{document.documentElement.dataset.theme='light'});
for(let i=0;i<22;i++) await post(bc,BASE+'/api/messages',{data:{room,type:'text',text:'阅读位置 '+i+' · 这是一段需要在不同宽度下重新换行的内容。'}});
await a.locator('.bubble.text:has-text("阅读位置 21")').waitFor();
await a.evaluate(()=>{document.querySelector('.thread-scroll').scrollTop=-550});await sleep(250);
const anchor=await a.evaluate(()=>{const top=document.querySelector('.thread-nav').getBoundingClientRect().bottom+12;const n=[...document.querySelectorAll('.msgs>.m')].find(e=>e.getBoundingClientRect().bottom>top);return {id:n.dataset.id,y:n.getBoundingClientRect().top}});
await a.setViewportSize({width:466,height:678});await sleep(450);
const moved=await a.locator('.msgs>.m[data-id="'+anchor.id+'"]').evaluate(e=>e.getBoundingClientRect().top);
assert.ok(Math.abs(moved-anchor.y)<8,'reading anchor moved '+(moved-anchor.y));
assert.deepEqual(errors,[]);console.log('PASS: actual two-account photos group and expand; gallery keyboard/thumbnail/resize/focus; cross-layout draft and selection; 320px send; right-rail back; dark/reduced motion; no page errors')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1})
