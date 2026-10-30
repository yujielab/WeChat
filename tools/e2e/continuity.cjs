// One task across the outer and inner displays: open a conversation folded, start a draft with the
// caret mid-word and scroll back a little; unfold, choose a filter beside it, fold again and go back.
// The same conversation, draft, caret, focus, reading position, filter and way back survive every
// change, and nothing is sent twice. Start npm run dev:e2e, then node tools/e2e/continuity.cjs [outdir].
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-continuity')
if(!['localhost','127.0.0.1','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local wrangler dev instance');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
async function post(ctx,url,options){const cookies=await ctx.cookies();return ctx.request.post(url,{...options,headers:{Origin:BASE,Cookie:cookies.map(c=>c.name+'='+c.value).join('; ')}})}
;(async()=>{const browser=await chromium.launch();try{
const opts={viewport:{width:466,height:678},locale:'zh-CN',serviceWorkers:'block',extraHTTPHeaders:{Origin:BASE},deviceScaleFactor:1},stamp=Date.now().toString(36)
const ac=await browser.newContext(opts),bc=await browser.newContext(opts)
const register=async(ctx,n,d)=>(await(await post(ctx,BASE+'/auth/register',{data:{username:n+'_'+stamp,password:'hunter2',display:d}})).json()).me
await register(ac,'conta','艾米');const b=await register(bc,'contb','本')
const room=(await(await post(ac,BASE+'/api/dm',{data:{user:b.id}})).json()).room.id
for(let i=0;i<30;i++)await post(i%2?ac:bc,BASE+'/api/messages',{data:{room,type:'text',text:`第${i+1}条：今天聊到的第${i+1}件事。`}})
const count=async()=>{const cookies=await ac.cookies();return(await(await ac.request.get(BASE+'/api/messages?room='+room+'&limit=100',{headers:{Cookie:cookies.map(c=>c.name+'='+c.value).join('; ')}})).json()).messages.length}
const p=await ac.newPage(),errors=[];p.on('pageerror',e=>errors.push(e.message))
await p.goto(BASE);await p.locator('.pane-list .row').first().waitFor()
const settled=focus=>p.locator(`.shell[data-focus=${focus}]:not([data-anim])`).waitFor()
const unposed=()=>p.waitForFunction(()=>{const l=innerWidth>=700?'split':'stack',r=document.documentElement;return document.querySelector('.shell').dataset.layout===l&&!r.dataset.posture&&!r.classList.contains('no-anim')})
await p.locator('.pane-list .row').first().click();await settled('thread');await sleep(400)

// Folded: a draft with the caret after the fourth character, and the reader a little way back.
const DRAFT='这是一条还没发出的草稿'
await p.fill('.composer textarea',DRAFT);await p.locator('.composer textarea').evaluate(t=>{t.focus();t.setSelectionRange(4,4)})
await p.evaluate(()=>{document.querySelector('.thread-scroll').scrollTop=-420});await sleep(300)
const look=()=>p.evaluate(()=>{const t=document.querySelector('.composer textarea'),top=document.querySelector('.thread-nav').getBoundingClientRect().bottom+12,m=[...document.querySelectorAll('.msgs>.m')].find(e=>e.getBoundingClientRect().bottom>top);return{chat:document.querySelector('.thread-title .name').textContent,draft:t.value,caret:[t.selectionStart,t.selectionEnd],focused:document.activeElement===t,anchor:m?.dataset.id,anchorTop:m?.getBoundingClientRect().top}})
const before=await look();assert.equal(before.focused,true);assert.ok(before.anchor)

// Unfolded: the same conversation carries on beside the list, nothing lost.
await p.setViewportSize({width:951,height:669});await unposed();await sleep(500)
let now=await look()
assert.equal(now.chat,'本');assert.equal(now.draft,DRAFT);assert.deepEqual(now.caret,[4,4]);assert.equal(now.focused,true,'focus stays in the field')
assert.ok(await p.locator(`.msgs>.m[data-id="${before.anchor}"]`).evaluate(e=>{const r=e.getBoundingClientRect();return r.bottom>0&&r.top<innerHeight}),'the message being read stays in view')
// Beside the conversation, a filter from the list's bar.
await p.click('.list-bottombar [data-item="filter"]');await p.locator('.menu.on .menu-item:has-text("私聊")').click();await sleep(300)
await p.screenshot({path:path.join(OUT,'34-unfolded-draft.png')})

// Folded again: still this conversation, draft and caret; Back leads to the list with its filter.
await p.locator('.composer textarea').evaluate(t=>{t.focus();t.setSelectionRange(4,4)})
await p.setViewportSize({width:466,height:678});await unposed();await sleep(500)
now=await look();assert.equal(now.chat,'本');assert.equal(now.draft,DRAFT);assert.deepEqual(now.caret,[4,4]);assert.equal(now.focused,true)
assert.equal(await p.evaluate(()=>document.querySelector('.shell').dataset.focus),'thread','folding keeps the conversation in front')
await p.click('.thread [data-item="back"]');await settled('list')
assert.equal(await p.getAttribute('.filter-tab[data-filter="people"]','aria-pressed'),'true','the filter survives the fold')
// Back into it: the draft is waiting.
await p.locator('.pane-list .row').first().click();await settled('thread');assert.equal(await p.inputValue('.composer textarea'),DRAFT)
assert.equal(await count(),30,'nothing sent twice');assert.deepEqual(errors,[])
console.log('PASS: folded → unfolded → folded keeps the conversation, draft, caret and focus, the message being read, the list filter and the way back; nothing sent twice')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1})
