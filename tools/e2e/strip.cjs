// The column strip (js/ui/strip.js): sidebar | list | conversation | details behind a window of one column
// folded and two adjacent columns unfolded. Replays the sequence closed chat → open list + chat → slide to
// chat + details → fold to details → swipe back to chat, then checks history, the sidebar, focus within the
// window, the posture morph's entering column, and reduced motion.
// Start npm run dev, then node tools/e2e/strip.cjs [outdir].
const {chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-strip')
if(!['localhost','127.0.0.1','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local wrangler dev instance')
fs.mkdirSync(OUT,{recursive:true})
async function post(ctx,url,options){const cookies=await ctx.cookies();return ctx.request.post(url,{...options,headers:{Origin:BASE,Cookie:cookies.map(c=>c.name+'='+c.value).join('; ')}})}
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
;(async()=>{const browser=await chromium.launch();try{
const opts={viewport:{width:466,height:678},locale:'zh-CN',serviceWorkers:'block',extraHTTPHeaders:{Origin:BASE},deviceScaleFactor:2}
const ac=await browser.newContext(opts),stamp=Date.now().toString(36)
const register=async(ctx,n,d)=>(await(await post(ctx,BASE+'/auth/register',{data:{username:n+'_'+stamp,password:'hunter2',display:d}})).json()).me
assert.ok(await register(ac,'stripa','艾米'))
const names=['小禾','阿遥','林间','周末计划'],texts=['今天的光刚刚好。','晚点见，带上相机。','发给你一首好听的歌','周六一起去走走吧']
let friend,friendRoom
for(let i=0;i<names.length;i++){const c=await browser.newContext(opts);const me=await register(c,'strip'+i,names[i]);const r=(await(await post(ac,BASE+'/api/dm',{data:{user:me.id}})).json()).room.id;await post(c,BASE+'/api/messages',{data:{room:r,type:'text',text:texts[i]}});await post(ac,BASE+'/api/messages',{data:{room:r,type:'text',text:'收到，'+names[i]+'。'}});if(i===names.length-1){friend=c;friendRoom=r}else await c.close()}
const p=await ac.newPage(),errors=[];p.on('pageerror',e=>errors.push(e.message));p.on('console',m=>{if(m.type()==='error'||/view-transition/i.test(m.text()))errors.push(m.text())})
await p.goto(BASE);await p.locator('.pane-list .row').first().waitFor()
const settled=focus=>p.locator(`.shell[data-focus=${focus}]:not([data-anim])`).waitFor()
// The resize lands a frame later; wait for the new layout and for its posture morph (which owns input) to finish.
const unposed=()=>p.waitForFunction(()=>{const l=innerWidth>=700?'split':'stack',r=document.documentElement;return document.querySelector('.shell').dataset.layout===l&&!r.dataset.posture&&!r.classList.contains('no-anim')})
const state=()=>p.evaluate(()=>{const panes=[...document.querySelectorAll('.pane')];return{focus:document.querySelector('.shell').dataset.focus,roles:panes.map(e=>e.dataset.role),shown:panes.filter(e=>!e.classList.contains('off')).map(e=>e.dataset.col),boxes:Object.fromEntries(panes.map(e=>[e.dataset.col,e.getBoundingClientRect().toJSON()]))}})
const shot=async n=>{await p.mouse.move(1,(await p.viewportSize()).height-1);await sleep(150);await p.screenshot({path:path.join(OUT,n+'.png')})}

// Closed: one column. The conversation slides in from the right of the list.
await p.locator('.pane-list .row').first().click();await settled('thread')
let s=await state();assert.deepEqual(s.roles,['hidden','hidden','single','hidden']);assert.deepEqual(s.shown,['thread']);assert.ok(Math.abs(s.boxes.thread.x)<1&&Math.abs(s.boxes.thread.width-466)<1)
await sleep(300);await shot('24-strip-closed-chat')

// Open: two adjacent columns of equal width; the list joins from its own side of the strip.
await p.setViewportSize({width:890,height:626});await p.waitForFunction(()=>document.querySelector('.pane-list').dataset.enter==='leading');await unposed();await sleep(400)
s=await state();assert.deepEqual(s.roles,['hidden','leading','trailing','hidden']);assert.equal(s.focus,'thread');assert.ok(Math.abs(s.boxes.list.width-s.boxes.thread.width)<1&&Math.abs(s.boxes.list.right-s.boxes.thread.x)<1,'equal adjacent columns')
assert.deepEqual(await p.evaluate(()=>[...document.querySelectorAll('.thread .bar-item')].filter(e=>e.getClientRects().length).map(e=>e.dataset.item)),['audio','video','info','draw','photo','compose'],'trailing conversation: no Back, New Chat ends its column')
await shot('25-strip-open-list-chat')

// Details slide the window one column along: the list leaves on the left, details arrive on the right.
await p.click('.thread [data-item="info"]');await sleep(120)
const mid=await state();assert.ok(mid.boxes.thread.x>1&&mid.boxes.thread.x<444,'the strip is mid-slide '+mid.boxes.thread.x);assert.ok(mid.shown.includes('list')&&mid.shown.includes('artifact'),'both outgoing and incoming columns drawn while sliding')
await settled('artifact');await p.locator('.art-content .profile').waitFor();s=await state()
assert.deepEqual(s.roles,['hidden','hidden','leading','trailing']);assert.ok(Math.abs(s.boxes.thread.x)<1&&Math.abs(s.boxes.thread.right-s.boxes.artifact.x)<1)
// The conversation leads now: horizontal bars with Back first; details is pressed.
const lead=await p.evaluate(()=>({axis:document.querySelector('.thread').dataset.bars,items:[...document.querySelectorAll('.thread .bar-item')].filter(e=>e.getClientRects().length).map(e=>e.dataset.item),info:document.querySelector('.thread [data-item="info"]').getAttribute('aria-pressed')}))
assert.deepEqual(lead,{axis:'horizontal',items:['back','audio','video','info','draw','photo'],info:'true'})
assert.equal(await p.locator('.art-body [data-item="close"]').isVisible(),true,'details close beside the conversation')
await sleep(200);await shot('26-strip-open-chat-details')

// Closed again: the focused column — details — stays on screen, with Back instead of Close.
await p.setViewportSize({width:466,height:678});await unposed();await sleep(300)
s=await state();assert.deepEqual(s.roles,['hidden','hidden','hidden','single']);assert.equal(await p.locator('.art-body [data-item="back"]').isVisible(),true)
await shot('27-strip-closed-details')

// Swipe back: 1:1 under the finger, the conversation in view behind it; released past halfway, it settles there.
await p.mouse.move(70,420);await p.mouse.down();for(let x=70;x<=230;x+=20)await p.mouse.move(x,424)
s=await state();assert.ok(s.shown.includes('thread')&&s.shown.includes('artifact'),'both columns drawn mid-swipe '+JSON.stringify(s));assert.ok(Math.abs(s.boxes.artifact.x-140)<4,'tracks the finger '+s.boxes.artifact.x)
for(let x=250;x<=330;x+=40)await p.mouse.move(x,424);await p.mouse.up();await settled('thread')
s=await state();assert.deepEqual(s.roles,['hidden','hidden','single','hidden']);assert.equal(await p.locator('.pane-artifact .art-body').count(),0,'details let go once out of view')
// A short swipe springs back.
await p.mouse.move(70,420);await p.mouse.down();await p.mouse.move(110,421);await p.mouse.move(130,421);await p.mouse.up();await settled('thread');assert.equal((await state()).boxes.thread.x,0)

// History retraces the strip: browser Back to the list, Forward to the conversation again.
await p.goBack();await settled('list');assert.equal(await p.evaluate(()=>localStorage.getItem('ui:open')),null,'folded, the conversation closes once out of view')
await p.goForward();await settled('thread');await p.locator('.thread:not([hidden])').waitFor()
await p.click('.thread [data-item="back"]');await settled('list')

// The sidebar: Back from the list. Scopes filter the list; only unread carries a number.
await p.click('.pane-list [data-item="back"]');await settled('sidebar')
const scopes=await p.evaluate(()=>[...document.querySelectorAll('.side-scope')].map(b=>[b.dataset.scope,b.querySelector('.side-count').textContent,b.getAttribute('aria-current')]))
assert.deepEqual(scopes.map(r=>r[0]),['all','unread','people','groups']);assert.deepEqual([scopes[0][1],scopes[2][1],scopes[3][1]],['','',''],'only unread carries a number');assert.equal(scopes[0][2],'true')
await p.click('.side-scope[data-scope="people"]');await settled('list');assert.equal(await p.locator('.filter-tab[data-filter="people"]').getAttribute('aria-pressed'),'true')
await p.click('.pane-list [data-item="back"]');await settled('sidebar')
// Unfolded from the sidebar: sidebar and list side by side; the list has no Back and no filters of its own there.
await p.setViewportSize({width:890,height:626});await p.waitForFunction(()=>document.querySelector('.pane-list').dataset.enter==='trailing');await unposed();await sleep(400)
s=await state();assert.deepEqual(s.roles,['leading','trailing','hidden','hidden'])
assert.deepEqual(await p.evaluate(()=>[...document.querySelectorAll('.pane-list .bar-item')].filter(e=>e.getClientRects().length).map(e=>e.dataset.item)),['search','compose']);assert.equal(await p.locator('.pane-list .list-filters').isVisible(),false)
await shot('28-strip-open-sidebar');await p.click('.side-scope[data-scope="all"]')
await settled('list');s=await state();assert.deepEqual(s.roles,['hidden','leading','trailing','hidden'])

// Within the window, the column in use takes focus: write in the conversation, fold, and it stays.
await p.locator('.pane-list .row').nth(1).click();await settled('thread');await p.click('.pane-list .list-head');await p.evaluate(()=>document.querySelector('.shell').dataset.focus).then(f=>assert.equal(f,'list'))
await p.click('.composer textarea');assert.equal(await p.evaluate(()=>document.querySelector('.shell').dataset.focus),'thread')
await p.setViewportSize({width:466,height:678});await unposed();await sleep(300);assert.deepEqual((await state()).roles,['hidden','hidden','single','hidden'])

// Escape closes details from either column; with reduced motion the window moves without sliding.
await p.setViewportSize({width:890,height:626});await unposed();await sleep(300)
await p.click('.thread [data-item="draw"]');await settled('artifact');await p.locator('.pane-artifact .draw').waitFor();await p.keyboard.press('Escape');await settled('thread')
await p.evaluate(()=>{document.documentElement.dataset.motion='reduce'});await p.click('.thread [data-item="info"]');assert.equal(await p.evaluate(()=>document.querySelector('.shell').dataset.anim),undefined);await settled('artifact')
await p.click('.art-body [data-item="close"]');await settled('thread')
await p.evaluate(()=>{delete document.documentElement.dataset.motion})

// Out of view beside the sidebar, the open conversation's new messages count as unread; back in view, they're read.
await p.locator(`.pane-list .row[data-id="${friendRoom}"]`).click();await settled('thread');await p.click('.pane-list [data-item="back"]');await settled('sidebar')
await post(friend,BASE+'/api/messages',{data:{room:friendRoom,type:'text',text:'你在看边栏吗？'}})
await p.locator(`.pane-list .row[data-id="${friendRoom}"] .row-count:has-text("1")`).waitFor()
await p.click('.side-scope[data-scope="all"]');await settled('list');await p.locator(`.pane-list .row[data-id="${friendRoom}"] .row-count`).waitFor({state:'hidden'})
await p.locator('.bubble.text:has-text("你在看边栏吗")').waitFor()

// Folding past the conversation (rather than going back past it) keeps it: unfolding again finds it beside the list.
const openId=await p.evaluate(()=>localStorage.getItem('ui:open'));await p.setViewportSize({width:466,height:678});await unposed();assert.deepEqual((await state()).roles,['hidden','single','hidden','hidden'])
await p.setViewportSize({width:890,height:626});await unposed();assert.equal(await p.evaluate(()=>localStorage.getItem('ui:open')),openId);await p.locator('.thread:not([hidden]) .bubble.text:has-text("你在看边栏吗")').waitFor()

// The iPhone Duo matrix (iphone-duo-web skill, assets/devices.json): closed 466×678 / 678×466; open 951×669 and
// 890×626 (the two candidate point grids) and their portrait 669×951 / 626×890; Split View 475×669 / 669×475.
// Open landscape shows two equal columns with the gutter on the crease; everything else one column. Nothing
// overflows, and every visible control is on screen at 44pt.
await p.click('.composer textarea')
for(const [w,h] of [[466,678],[678,466],[951,669],[890,626],[669,951],[626,890],[475,669],[669,475]]){
 await p.setViewportSize({width:w,height:h});await unposed();await sleep(250)
 const m=await p.evaluate(()=>{const panes=[...document.querySelectorAll('.pane')].filter(e=>!e.classList.contains('off'));return{layout:document.querySelector('.shell').dataset.layout,bars:document.documentElement.dataset.bars,boxes:panes.map(e=>e.getBoundingClientRect().toJSON()),overflow:document.documentElement.scrollWidth>innerWidth,items:[...document.querySelectorAll('.pane:not(.off) .bar-item')].filter(e=>e.getClientRects().length).map(e=>e.getBoundingClientRect().toJSON())}})
 const open=w>=700;assert.equal(m.layout,open?'split':'stack',`${w}×${h}`);assert.equal(m.boxes.length,open?2:1);assert.equal(m.overflow,false)
 assert.equal(m.bars,w<h&&h>=760?'horizontal':'vertical',`bar axis at ${w}×${h}`)
 if(open)assert.ok(Math.abs(m.boxes[0].right-w/2)<1.5&&Math.abs(m.boxes[1].left-w/2)<1.5,`gutter on the crease at ${w}`)
 for(const b of m.items)assert.ok(b.width>=44&&b.height>=44&&b.left>=-.5&&b.right<=w+.5&&b.top>=-.5&&b.bottom<=h+.5,`control on screen at 44pt, ${w}×${h} `+JSON.stringify(b))
}
// The transition, not just the states: drag the width 466 → 951 → 466 in 50px steps with the field focused. A fold
// is never a keyboard, the conversation stays focused and on screen, and nothing throws.
const widths=[];for(let w=466;w<=951;w+=50)widths.push(w);widths.push(951);for(let w=951;w>=466;w-=50)widths.push(w);widths.push(466)
for(const w of widths){await p.setViewportSize({width:w,height:669});await sleep(40);assert.equal(await p.evaluate(()=>document.documentElement.dataset.kb),undefined,'a width change is never the keyboard at '+w)}
await unposed();await sleep(200);assert.deepEqual((await state()).roles,['hidden','hidden','single','hidden']);assert.equal(await p.evaluate(()=>document.activeElement?.matches('.composer textarea')),true)
// A sheet opened beside the list stays in its half across the same drag: its middle never lands on the crease.
await p.setViewportSize({width:951,height:669});await unposed();await p.click('.thread [data-item="compose"]');await p.locator('.sheet.on').waitFor()
for(const w of [951,901,851,800,751,700]){await p.setViewportSize({width:w,height:669});await sleep(120);const b=await p.locator('.sheet').boundingBox();assert.ok(b.x+b.width<=w/2+1||b.x>=w/2-1,`sheet clear of the crease at ${w} `+JSON.stringify(b))}
await p.keyboard.press('Escape');await p.locator('.sheet').waitFor({state:'detached'})

assert.deepEqual(errors,[]);console.log('PASS: closed one column / open two equal columns; slide to details and back; fold keeps the focused column; interactive swipe (commit and spring back); history back/forward; sidebar scopes; unread while out of view, read once back; folding keeps the conversation; Duo matrix 466/678/951/890/669/626/475 with the gutter on the crease; width drag never reads as keyboard; sheet stays off the crease; column in use takes focus; posture entering side; Escape; reduced motion; no page errors')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1})
