// Local Duo flow (Apple HIG, Designing for iPhone Duo): real accounts/media, photo grouping, reactions,
// gallery, split view and folding region, bars at the foot of each column, overlays per side, drafts and reading anchors.
// Start npm run dev:e2e (calls switched on), then node tools/e2e/duo-layout.cjs [outdir].
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
await b.click('.thread .composer-action');await b.click('.composer-tool[data-tool="photo"]');await b.locator('.attachment-file-input').setInputFiles(images.map((v,i)=>({name:`moment-${i+1}.png`,mimeType:'image/png',buffer:Buffer.from(v,'base64')})));await b.click('.attachment-send')
await a.locator('.photo-stack[data-count="3"]').waitFor();await b.locator('.photo-stack[data-count="3"]').waitFor()
assert.equal(await a.locator('.photo-stack').count(),1)
// The album carries its sender on the cover's corner and a count below (sketch 1).
assert.equal(await a.locator('.m.has-stack .photo-stack-from').evaluate(el=>el.textContent.startsWith('本 · ')),true);assert.equal(await a.locator('.m.has-stack .m-avatar').isVisible(),false)
// Reactions: picked from the message menu, seen by the other side, double-tap to love, kept after reloading.
await b.locator('.m.in .bubble.text:has-text("我在。")').click({button:'right'});await b.locator('.menu.on .menu-reaction').first().waitFor();await sleep(250);await b.locator('.menu-reaction[aria-label="喜欢"]').click()
await a.locator('.m.out .m-reactions .m-reaction:has-text("❤️")').waitFor()
const love=a.locator('.m.in .bubble.text:has-text("这几张")');await love.click();await love.click()
await b.locator('.m.out .m-reactions').waitFor();assert.equal(await a.locator('.m.in .m-reactions.mine').count(),1)
await a.goto(BASE+'/?chat='+room);await a.locator('.m.out .m-reactions').waitFor();await a.locator('.photo-stack[data-count="3"]').waitFor()
await sleep(750);await a.screenshot({path:OUT+'/15-duo-folded.png'})
await a.locator('.photo-stack-open').click({button:'right'});await a.locator('.menu-item:has-text("查看 3 张照片")').waitFor();assert.equal(await a.locator('.ctx-preview').evaluate(el=>el.inert&&el.getAttribute('aria-hidden')==='true'),true);await a.keyboard.press('Escape');await sleep(400)
// Gallery keeps all real images addressable; keyboard, thumbnails and resizing
// preserve the selected image, and closing returns focus to its cover.
const within=(o,p)=>o.x>=p.x-1&&o.x+o.width<=p.x+p.width+1
await a.click('.photo-stack-open');await a.locator('.viewer-gallery-count:has-text("1 / 3")').waitFor();await a.keyboard.press('ArrowRight');await a.locator('.viewer-gallery-count:has-text("2 / 3")').waitFor();await a.click('.viewer-gallery-thumb:nth-child(3)');await a.locator('.viewer-gallery-count:has-text("3 / 3")').waitFor();await a.setViewportSize({width:890,height:626});await a.waitForFunction(()=>!document.documentElement.dataset.posture);await sleep(600);await a.screenshot({path:OUT+'/17-duo-gallery.png'})
// Unfolding mid-gallery moves the open photo to the conversation half; the fold never cuts through it.
assert.ok(within(await a.locator('.viewer').boundingBox(),await a.locator('.pane-thread').boundingBox()),'viewer stays on the conversation side');await a.keyboard.press('Escape');await a.locator('.viewer').waitFor({state:'detached'});assert.equal(await a.locator('.photo-stack-open').evaluate(el=>el===document.activeElement),true)
await a.fill('.composer textarea','这条草稿会跟着我展开和合起。');await a.locator('.composer textarea').evaluate(el=>el.setSelectionRange(3,8));const before=await a.locator('.composer textarea').evaluate(el=>({text:el.value,start:el.selectionStart,end:el.selectionEnd}));await a.setViewportSize({width:466,height:678});await sleep(300);const after=await a.locator('.composer textarea').evaluate(el=>({text:el.value,start:el.selectionStart,end:el.selectionEnd}));assert.deepEqual(after,before)
await a.setViewportSize({width:890,height:626});await a.fill('.composer textarea','');await a.locator('.composer textarea').blur();await a.waitForFunction(()=>!document.documentElement.dataset.posture);await sleep(700);await a.screenshot({path:OUT+'/16-duo-unfolded.png'})
// Split view: two equal columns of the strip, each ending in its bar: the list's Back to the sidebar and filter,
// search and New Chat; the conversation's field and its one button (photos and drawing, or Send), its calls
// and details in its heading.
// Both bars share one baseline across the fold.
const split=await a.evaluate(()=>{const r=s=>document.querySelector(s).getBoundingClientRect(),shown=sel=>[...document.querySelectorAll(sel)].filter(e=>e.getClientRects().length).map(e=>e.dataset.item||'more');return{list:r('.pane-list'),thread:r('.pane-thread'),listBars:shown('.list-bottombar .bar-item'),head:shown('.thread-nav .bar-item'),foot:[...shown('.thread .composer .bar-item'),...[...document.querySelectorAll('.thread .composer-action')].filter(e=>e.getClientRects().length).map(()=>'action')],search:r('.search-pill'),field:r('.thread .composer .field'),filters:getComputedStyle(document.querySelector('.list-filters')).display,capsule:[r('.row-highlight').top-r('.row.selected').top,r('.row-highlight').height-r('.row.selected').height]}})
assert.ok(Math.abs(split.list.width-split.thread.width)<2&&Math.abs(split.list.right-split.thread.left)<2,'two equal adjacent columns '+JSON.stringify(split));assert.deepEqual(split.listBars,['filter','compose']);assert.deepEqual(split.head,['audio','video','info']);assert.deepEqual(split.foot,['action']);assert.ok(split.search.bottom>split.list.bottom-80&&split.search.right<=split.list.right,'search at the foot of the list');assert.ok(Math.abs(split.search.bottom-split.field.bottom)<1,'one baseline across the fold '+JSON.stringify([split.search,split.field]));assert.equal(split.filters,'none');assert.ok(split.capsule.every(v=>Math.abs(v)<1),'selection capsule on the open row')
// Partially folded like a book: both columns meet the folding region at equal widths, overlays open on their own side
// of it, and the details column slides in beside the conversation, also clear of the bend.
await a.evaluate(async()=>(await import('/js/ui/viewport.js')).emulateFold({axis:'vertical',size:28}));await sleep(450)
const book=await a.evaluate(()=>{const l=document.querySelector('.pane-list').getBoundingClientRect(),t=document.querySelector('.pane-thread').getBoundingClientRect(),cs=getComputedStyle(document.documentElement);return{l,t,start:parseFloat(cs.getPropertyValue('--fold-start')),end:parseFloat(cs.getPropertyValue('--fold-end'))}})
assert.ok(Math.abs(book.l.right-book.start)<1&&Math.abs(book.t.left-book.end)<1,'panes meet the fold '+JSON.stringify(book));assert.ok(Math.abs(book.l.width-book.t.width)<2,'equal panes when folded')
const clear=o=>o.x+o.width<=book.start+1||o.x>=book.end-1
await a.click('.pane-list [data-item="compose"]');await a.locator('.sheet.on').waitFor();await sleep(450);await a.screenshot({path:OUT+'/22-duo-sheet-side.png'});let sheet=await a.locator('.sheet').boundingBox();assert.ok(within(sheet,await a.locator('.pane-list').boundingBox())&&clear(sheet),'new chat on the list side');await a.keyboard.press('Escape');await a.locator('.sheet').waitFor({state:'detached'})
await a.click('.thread-title');await a.locator('.shell[data-focus=artifact]:not([data-anim])').waitFor();await a.locator('.art-content .profile').waitFor();const art=await a.evaluate(()=>({t:document.querySelector('.pane-thread').getBoundingClientRect().toJSON(),d:document.querySelector('.pane-artifact').getBoundingClientRect().toJSON(),roles:[...document.querySelectorAll('.pane')].map(p=>p.dataset.role)}));assert.deepEqual(art.roles,['hidden','hidden','leading','trailing']);assert.ok(Math.abs(art.t.right-book.start)<1&&Math.abs(art.d.left-book.end)<1,'details meet the fold beside the conversation '+JSON.stringify(art));assert.equal(await a.locator('.thread [data-item="info"]').getAttribute('aria-pressed'),'true')
await a.keyboard.press('Escape');await a.locator('.shell[data-start=list]:not([data-anim])').waitFor();assert.equal(await a.locator('.pane-artifact .art-body').count(),0,'details let go once out of view')
await a.evaluate(async()=>(await import('/js/ui/viewport.js')).emulateFold(null));await sleep(300)
// Folded like a laptop, messages stay above the fold and writing below it.
await a.setViewportSize({width:626,height:890});await a.waitForFunction(()=>!document.documentElement.dataset.posture);await sleep(400)
await a.evaluate(async()=>(await import('/js/ui/viewport.js')).emulateFold({axis:'horizontal',size:28}));await sleep(450)
const laptop=await a.evaluate(()=>{const cs=getComputedStyle(document.documentElement);return{scroll:document.querySelector('.thread-scroll').getBoundingClientRect().bottom,composer:document.querySelector('.composer').getBoundingClientRect().top,start:parseFloat(cs.getPropertyValue('--fold-start')),end:parseFloat(cs.getPropertyValue('--fold-end'))}})
assert.ok(laptop.scroll<=laptop.start+1&&laptop.composer>=laptop.end-1,'nothing in the bend '+JSON.stringify(laptop));await a.screenshot({path:OUT+'/23-duo-laptop.png'})
await a.evaluate(async()=>(await import('/js/ui/viewport.js')).emulateFold(null));await a.setViewportSize({width:890,height:626});await a.waitForFunction(()=>!document.documentElement.dataset.posture);await sleep(300)
// Grouped photos can be expanded to access each original message's menu.
await a.click('.photo-stack-expand');await a.locator('.photo-stack').waitFor({state:'detached'});assert.equal(await a.locator('.bubble.media[data-kind=image]').count(),3);const first=a.locator('.bubble.media[data-kind=image]').first();await first.click({button:'right'});await a.locator('.menu-item:has-text("从本设备删除")').waitFor();await a.keyboard.press('Escape');await sleep(350)
// Media, labels and toolbar stay inside a keyboard-sized conversation.
await a.setViewportSize({width:320,height:440});await a.fill('.composer textarea','小窗口仍然可以发送。');await a.keyboard.press('Enter');await b.locator('.bubble.text:has-text("小窗口仍然")').waitFor();await a.locator('.m-meta:has-text("已读")').waitFor();const geometry=await a.evaluate(()=>({overflow:document.querySelector('.thread').scrollWidth>document.querySelector('.thread').clientWidth,buttons:[...document.querySelectorAll('.thread .bar-item')].filter(e=>e.getClientRects().length).map(e=>({w:e.offsetWidth,h:e.offsetHeight}))}));assert.equal(geometry.overflow,false);assert.ok(geometry.buttons.every(r=>r.w>=44&&r.h>=44))
await a.setViewportSize({width:466,height:678});await a.click('.thread [data-item="back"]');await a.locator('.shell[data-focus=list]:not([data-anim])').waitFor();await a.locator('.row').first().click();await a.locator('.shell[data-focus=thread]:not([data-anim])').waitFor();await a.setViewportSize({width:890,height:626});await a.evaluate(()=>{document.documentElement.dataset.theme='dark';document.documentElement.dataset.motion='reduce'});await sleep(500);await a.screenshot({path:OUT+'/18-duo-dark.png'})

// A reading anchor survives width changes while older messages are in view.
await a.evaluate(()=>{document.documentElement.dataset.theme='light'});
for(let i=0;i<22;i++) await post(bc,BASE+'/api/messages',{data:{room,type:'text',text:'阅读位置 '+i+' · 这是一段需要在不同宽度下重新换行的内容。'}});
await a.locator('.bubble.text:has-text("阅读位置 21")').waitFor();
await a.evaluate(()=>{document.querySelector('.thread-scroll').scrollTop=-550});await sleep(250);
const anchor=await a.evaluate(()=>{const top=document.querySelector('.thread-nav').getBoundingClientRect().bottom+12;const n=[...document.querySelectorAll('.msgs>.m')].find(e=>e.getBoundingClientRect().bottom>top);return {id:n.dataset.id,y:n.getBoundingClientRect().top}});
await a.setViewportSize({width:466,height:678});await sleep(450);
const moved=await a.locator('.msgs>.m[data-id="'+anchor.id+'"]').evaluate(e=>e.getBoundingClientRect().top);
assert.ok(Math.abs(moved-anchor.y)<8,'reading anchor moved '+(moved-anchor.y));
assert.deepEqual(errors,[]);console.log('PASS: actual two-account photos group and expand; reactions and read receipts; gallery keyboard/thumbnail/resize/focus; split view and folding region; bars at the foot of each column on one baseline; overlays per side; laptop pose; cross-layout draft and selection; 320px send; dark/reduced motion; no page errors')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1})
