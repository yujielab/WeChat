// One task across the outer and inner displays: open a conversation folded, start a draft with the
// caret mid-word and scroll back a little; unfold, choose a filter beside it, fold again and go back.
// The same conversation, draft, caret, focus, reading position, filter and way back survive every
// change, and nothing is sent twice. Every visible control has a name and a 44pt target along the way.
// Start npm run dev:e2e, then node tools/e2e/continuity.cjs [outdir].
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
// Every visible control has a name for VoiceOver and a target of 44pt or more (a pseudo-element may extend it).
const AUDIT=`(() => {
  const out = []
  const name = el => (el.getAttribute('aria-label') || el.getAttribute('aria-labelledby') && document.getElementById(el.getAttribute('aria-labelledby'))?.textContent || el.textContent || el.title || el.placeholder || el.closest('label')?.textContent || '').trim()
  for (const el of document.querySelectorAll('button, [role="button"], a[href], input:not([type="hidden"]), textarea, [role="menuitem"], [role="tab"]')) {
    if (!el.getClientRects().length || el.closest('[inert], [aria-hidden="true"], .off')) continue
    const cs = getComputedStyle(el)
    if (cs.visibility === 'hidden' || +cs.opacity === 0) continue
    const r = el.getBoundingClientRect()
    if (r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth) continue
    const id = el.className && typeof el.className === 'string' ? el.className.split(' ').slice(0, 2).join('.') : el.tagName
    if (!name(el)) out.push(\`no name: \${el.tagName}.\${id}\`)
    // The hit area: the element, or a pseudo-element that extends it.
    const ext = Math.max(0, -parseFloat(getComputedStyle(el, '::before').inset || getComputedStyle(el, '::before').top) || 0, -parseFloat(getComputedStyle(el, '::after').top) || 0)
    const w = r.width + 2 * ext, h = r.height + 2 * ext
    if ((w < 43.5 || h < 43.5) && !['INPUT', 'TEXTAREA'].includes(el.tagName) && !el.closest('a') ) out.push(\`small \${Math.round(w)}x\${Math.round(h)}: \${el.tagName}.\${id} "\${name(el).slice(0, 12)}"\`)
  }
  return [...new Set(out)]
})()`
const audit=async label=>{const v=await p.evaluate(AUDIT);assert.deepEqual(v,[],label)}
await audit('folded list')
const settled=focus=>p.locator(`.shell[data-focus=${focus}]:not([data-anim])`).waitFor()
const unposed=()=>p.waitForFunction(()=>{const l=innerWidth>=700?'split':'stack',r=document.documentElement;return document.querySelector('.shell').dataset.layout===l&&!r.dataset.posture&&!r.classList.contains('no-anim')})
await p.locator('.pane-list .row').first().click();await settled('thread');await sleep(400);await audit('folded conversation')

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
await p.screenshot({path:path.join(OUT,'34-unfolded-draft.png')});await audit('unfolded')
// Settings grows out of your avatar in the list's heading (and shrinks back into it).
const grow=await p.evaluate(()=>new Promise(done=>{const me=document.querySelector('.list-me'),r=me.getBoundingClientRect();me.click();setTimeout(()=>{const s=document.querySelector('.sheet'),cs=getComputedStyle(s),m=new DOMMatrix(cs.transform);done({from:s.classList.contains('from-origin'),scale:m.a,origin:cs.transformOrigin,me:[r.left+r.width/2,r.top+r.height/2],box:s.getBoundingClientRect().toJSON()})},70)}))
assert.ok(grow.from&&grow.scale<0.95,'grows from the avatar '+JSON.stringify(grow))
await p.locator('.sheet.on').waitFor();await sleep(500);await audit('settings');await p.keyboard.press('Escape');await sleep(400)

// Searching, the field grows over the bar's other items as they fold away; Cancel gives them back.
await p.click('.list-bottombar .search-pill');await sleep(350)
const searching=await p.evaluate(()=>[...document.querySelectorAll('.list-bottombar .bar-group')].map(g=>[g.getBoundingClientRect().width,getComputedStyle(g).opacity,g.closest('[inert]')!==null]))
assert.ok(searching.every(([w,o,inert])=>w<1&&o==='0'&&inert),'items folded away and out of reach '+JSON.stringify(searching))
await p.click('.list-bottombar .search-cancel');await sleep(350)
assert.ok(await p.evaluate(()=>[...document.querySelectorAll('.list-bottombar .bar-group')].every(g=>g.getBoundingClientRect().width>40&&!g.closest('[inert]'))),'and back')

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
console.log('PASS: folded → unfolded → folded keeps the conversation, draft, caret and focus, the message being read, the list filter and the way back; nothing sent twice; every control named and 44pt; settings grows from your avatar; search folds the bar away and back')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1})
